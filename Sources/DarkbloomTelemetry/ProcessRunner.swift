import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded(limit: Int)
    case nonzeroExit(code: Int32, message: String)
}

public struct CappedProcessRunner: ProcessExecuting, Sendable {
    private let testOnlyCleanupObserver: (@Sendable (ProcessCleanupState) -> Void)?

    public init() {
        testOnlyCleanupObserver = nil
    }

    init(testOnlyCleanupObserver: @escaping @Sendable (ProcessCleanupState) -> Void) {
        self.testOnlyCleanupObserver = testOnlyCleanupObserver
    }

    public func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)? = nil
    ) async throws -> CommandResult {
        guard outputLimit > 0 else {
            throw ProcessRunnerError.outputLimitExceeded(limit: outputLimit)
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let session = ProcessSession(process: process, outputLimit: outputLimit, onOutput: onOutput)

        process.executableURL = command.executable
        process.arguments = command.arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { [weak session] _ in
            session?.didTerminate()
        }

        session.beginReading(standardOutput.fileHandleForReading, destination: .standardOutput)
        session.beginReading(standardError.fileHandleForReading, destination: .standardError)
        var processWasLaunched = false
        defer {
            cleanup(
                process: process,
                standardOutput: standardOutput,
                standardError: standardError,
                processWasLaunched: processWasLaunched,
                session: session
            )
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            do {
                try process.run()
                processWasLaunched = true
                // The parent never writes to either pipe. Closing its write ends immediately
                // makes EOF a reliable completion signal once the owned child exits.
                _ = close(standardOutput.fileHandleForWriting)
                _ = close(standardError.fileHandleForWriting)
            } catch {
                throw ProcessRunnerError.launchFailed(error.localizedDescription)
            }

            if session.didLaunch() {
                session.requestCancellation()
            }

            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                    if !Task.isCancelled {
                        session.requestTermination(for: .timedOut)
                    }
                } catch {
                    // Cancellation ends the timeout race after the child exits.
                }
            }
            defer { timeoutTask.cancel() }

            await session.waitForTermination()
            await session.waitForReaders(timeout: .milliseconds(250))
            try Task.checkCancellation()
            if session.cancellationWasRequested {
                throw CancellationError()
            }

            if let error = session.failure {
                throw error
            }

            let result = session.result(exitCode: process.terminationStatus)
            guard result.exitCode == 0 else {
                throw ProcessRunnerError.nonzeroExit(
                    code: result.exitCode,
                    message: String(decoding: result.standardError, as: UTF8.self)
                )
            }
            return result
        } onCancel: {
            session.requestCancellation()
        }
    }

    private func close(_ handle: FileHandle) -> Bool {
        do {
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    private func cleanup(
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe,
        processWasLaunched: Bool,
        session: ProcessSession
    ) {
        let standardOutputHandle = standardOutput.fileHandleForReading
        let standardErrorHandle = standardError.fileHandleForReading
        standardOutputHandle.readabilityHandler = nil
        standardErrorHandle.readabilityHandler = nil
        session.finishReaders()
        process.terminationHandler = nil
        if !processWasLaunched {
            process.standardOutput = nil
            process.standardError = nil
        }
        let standardOutputReadHandleClosed = close(standardOutputHandle)
        let standardErrorReadHandleClosed = close(standardErrorHandle)
        let standardOutputWriteHandleClosed = close(standardOutput.fileHandleForWriting)
        let standardErrorWriteHandleClosed = close(standardError.fileHandleForWriting)
        testOnlyCleanupObserver?(
            ProcessCleanupState(
                terminationHandlerCleared: process.terminationHandler == nil,
                standardOutputCleared: !processWasLaunched && process.standardOutput == nil,
                standardErrorCleared: !processWasLaunched && process.standardError == nil,
                standardOutputHandlerCleared: standardOutputHandle.readabilityHandler == nil,
                standardErrorHandlerCleared: standardErrorHandle.readabilityHandler == nil,
                standardOutputReadHandleClosed: standardOutputReadHandleClosed,
                standardErrorReadHandleClosed: standardErrorReadHandleClosed,
                standardOutputWriteHandleClosed: standardOutputWriteHandleClosed,
                standardErrorWriteHandleClosed: standardErrorWriteHandleClosed
            )
        )
    }
}

struct ProcessCleanupState: Equatable, Sendable {
    let terminationHandlerCleared: Bool
    let standardOutputCleared: Bool
    let standardErrorCleared: Bool
    let standardOutputHandlerCleared: Bool
    let standardErrorHandlerCleared: Bool
    let standardOutputReadHandleClosed: Bool
    let standardErrorReadHandleClosed: Bool
    let standardOutputWriteHandleClosed: Bool
    let standardErrorWriteHandleClosed: Bool
}

private final class ProcessSession: @unchecked Sendable {
    enum Destination {
        case standardOutput
        case standardError
    }

    private weak var process: Process?
    private let outputLimit: Int
    private let onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    private let lock = NSLock()
    private let readerGroup = DispatchGroup()
    private var standardOutput = Data()
    private var standardError = Data()
    private var recordedFailure: ProcessRunnerError?
    private var cancellationRequested = false
    private var terminationStarted = false
    private var terminated = false
    private var terminationContinuation: CheckedContinuation<Void, Never>?
    private var readerWaitContinuation: CheckedContinuation<Void, Never>?
    private var ownedProcessID: Int32?
    private var standardOutputReaderFinished = false
    private var standardErrorReaderFinished = false
    private var readersClosed = false

    init(process: Process, outputLimit: Int, onOutput: (@Sendable (ProcessOutputChunk) -> Void)?) {
        self.process = process
        self.outputLimit = outputLimit
        self.onOutput = onOutput
    }

    var failure: ProcessRunnerError? {
        lock.withLock { recordedFailure }
    }

    var cancellationWasRequested: Bool {
        lock.withLock { cancellationRequested }
    }

    func beginReading(_ handle: FileHandle, destination: Destination) {
        readerGroup.enter()
        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            guard let self else {
                readableHandle.readabilityHandler = nil
                return
            }
            guard !data.isEmpty else {
                readableHandle.readabilityHandler = nil
                self.readerDidEnd(destination)
                return
            }
            let outputDestination: ProcessOutputDestination = destination == .standardOutput ? .standardOutput : .standardError
            self.onOutput?(ProcessOutputChunk(destination: outputDestination, data: data))
            self.append(data, to: destination)
        }
    }

    func didTerminate() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !terminated else { return nil }
            terminated = true
            defer { terminationContinuation = nil }
            return terminationContinuation
        }
        continuation?.resume()
    }

    func waitForTermination() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if terminated {
                    return true
                }
                terminationContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func waitForReaders(timeout: Duration) async {
        // A direct child can exit while a descendant still holds an inherited pipe.
        // Give normal readers a short drain window, then close the session-owned ends
        // rather than allowing a finite acquisition to wait forever for EOF.
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !readersClosed,
                      !(standardOutputReaderFinished && standardErrorReaderFinished)
                else {
                    return true
                }
                readerWaitContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
                return
            }

            Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // The bounded cleanup still runs when this timer is cancelled.
                }
                self?.finishReaders()
            }
        }
    }

    func didLaunch() -> Bool {
        lock.withLock {
            ownedProcessID = process?.processIdentifier
            return cancellationRequested
        }
    }

    func requestCancellation() {
        lock.withLock {
            cancellationRequested = true
        }
        terminateIfNeeded()
    }

    func requestTermination(for error: ProcessRunnerError) {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !terminated, process?.isRunning == true, recordedFailure == nil else {
                return false
            }
            recordedFailure = error
            return true
        }
        if shouldTerminate {
            terminateIfNeeded()
        }
    }

    func result(exitCode: Int32) -> CommandResult {
        lock.withLock {
            CommandResult(
                exitCode: exitCode,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }
    }

    private func append(_ data: Data, to destination: Destination) {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard recordedFailure == nil, !cancellationRequested, !readersClosed else {
                return false
            }
            let combinedCount = standardOutput.count + standardError.count
            guard data.count <= outputLimit - combinedCount else {
                recordedFailure = .outputLimitExceeded(limit: outputLimit)
                return true
            }
            switch destination {
            case .standardOutput:
                standardOutput.append(data)
            case .standardError:
                standardError.append(data)
            }
            return false
        }
        if shouldTerminate {
            terminateIfNeeded()
        }
    }

    func finishReaders() {
        let result = lock.withLock { () -> (Int, CheckedContinuation<Void, Never>?) in
            guard !readersClosed else { return (0, nil) }
            readersClosed = true
            var count = 0
            if !standardOutputReaderFinished {
                standardOutputReaderFinished = true
                count += 1
            }
            if !standardErrorReaderFinished {
                standardErrorReaderFinished = true
                count += 1
            }
            let continuation = readerWaitContinuation
            readerWaitContinuation = nil
            return (count, continuation)
        }
        for _ in 0..<result.0 {
            readerGroup.leave()
        }
        result.1?.resume()
    }

    private func readerDidEnd(_ destination: Destination) {
        let result: (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
            switch destination {
            case .standardOutput:
                guard !standardOutputReaderFinished else { return (false, nil) }
                standardOutputReaderFinished = true
            case .standardError:
                guard !standardErrorReaderFinished else { return (false, nil) }
                standardErrorReaderFinished = true
            }
            let continuation: CheckedContinuation<Void, Never>?
            if standardOutputReaderFinished && standardErrorReaderFinished {
                continuation = readerWaitContinuation
                readerWaitContinuation = nil
            } else {
                continuation = nil
            }
            return (true, continuation)
        }
        if result.0 {
            readerGroup.leave()
        }
        result.1?.resume()
    }

    private func terminateIfNeeded() {
        let target = lock.withLock { () -> (Process, Int32)? in
            guard !terminationStarted,
                  let process,
                  let ownedProcessID,
                  ownedProcessID > 0
            else {
                return nil
            }
            terminationStarted = true
            return (process, ownedProcessID)
        }
        guard let (process, ownedProcessID) = target else { return }

        if process.isRunning {
            process.terminate()
            let graceDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            while process.isRunning, ContinuousClock.now < graceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning, process.processIdentifier == ownedProcessID {
                kill(ownedProcessID, SIGKILL)
            }
        }

        process.waitUntilExit()
        didTerminate()
        finishReaders()
    }
}

public struct UnifiedLogStreamer: Sendable {
    private let command: ProcessCommand
    private let testOnlyReadChunkLimit: Int?
    private let testOnlyCleanupObserver: (@Sendable (UnifiedLogStreamCleanupState) -> Void)?

    public init() {
        command = .unifiedLogStream
        testOnlyReadChunkLimit = nil
        testOnlyCleanupObserver = nil
    }

    init(
        testOnlyCommand: ProcessCommand,
        testOnlyReadChunkLimit: Int? = nil,
        testOnlyCleanupObserver: (@Sendable (UnifiedLogStreamCleanupState) -> Void)? = nil
    ) {
        command = testOnlyCommand
        self.testOnlyReadChunkLimit = testOnlyReadChunkLimit.flatMap { $0 > 0 ? $0 : nil }
        self.testOnlyCleanupObserver = testOnlyCleanupObserver
    }

    public func events() -> AsyncThrowingStream<LogEvent, Error> {
        let session = UnifiedLogStreamSession(
            command: command,
            testOnlyReadChunkLimit: testOnlyReadChunkLimit,
            testOnlyCleanupObserver: testOnlyCleanupObserver
        )
        return AsyncThrowingStream(unfolding: {
            try await session.next()
        })
    }
}

struct UnifiedLogStreamCleanupState: Equatable, Sendable {
    let processID: Int32
    let terminationRequested: Bool
    let terminationHandlerCleared: Bool
    let standardOutputHandlerCleared: Bool
    let standardErrorHandlerCleared: Bool
    let standardOutputReadHandleClosed: Bool
    let standardErrorReadHandleClosed: Bool
    let standardOutputWriteHandleClosed: Bool
    let standardErrorWriteHandleClosed: Bool
}

private final class UnifiedLogStreamSession: @unchecked Sendable {
    private enum Reader {
        case standardOutput
        case standardError
    }

    private enum TerminalState {
        case active
        case finished
        case failed(ProcessRunnerError)
        case cancelled
    }

    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let testOnlyReadChunkLimit: Int?
    private let testOnlyCleanupObserver: (@Sendable (UnifiedLogStreamCleanupState) -> Void)?
    private let lineLimit = DarkbloomSourcePolicy.processOutputByteLimit
    private let lock = NSLock()
    private var queuedEvents = EventBuffer(capacity: 100)
    private var waiter: CheckedContinuation<LogEvent?, Error>?
    private var standardOutputBuffer = Data()
    private var droppingOversizedLine = false
    private var standardErrorLineBytes = 0
    private var standardOutputEnded = false
    private var standardErrorEnded = false
    private var exitCode: Int32?
    private var terminalState = TerminalState.active
    private var cleanedUp = false

    init(
        command: ProcessCommand,
        testOnlyReadChunkLimit: Int?,
        testOnlyCleanupObserver: (@Sendable (UnifiedLogStreamCleanupState) -> Void)?
    ) {
        self.testOnlyReadChunkLimit = testOnlyReadChunkLimit
        self.testOnlyCleanupObserver = testOnlyCleanupObserver
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(exitCode: process.terminationStatus)
        }

        beginReading(standardOutput.fileHandleForReading, reader: .standardOutput)
        beginReading(standardError.fileHandleForReading, reader: .standardError)

        do {
            try process.run()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
        } catch {
            complete(with: .failed(.launchFailed(error.localizedDescription)))
        }
    }

    deinit {
        cleanup(terminateProcess: true)
    }

    func next() async throws -> LogEvent? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let event = queuedEvents.popFirst() {
                    lock.unlock()
                    continuation.resume(returning: event)
                    return
                }

                switch terminalState {
                case .active:
                    waiter = continuation
                    lock.unlock()
                case .finished:
                    lock.unlock()
                    continuation.resume(returning: nil)
                case let .failed(error):
                    lock.unlock()
                    continuation.resume(throwing: error)
                case .cancelled:
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    private func beginReading(_ handle: FileHandle, reader: Reader) {
        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            guard let self else {
                readableHandle.readabilityHandler = nil
                return
            }
            guard !data.isEmpty else {
                readableHandle.readabilityHandler = nil
                self.readerDidEnd(reader)
                return
            }

            switch reader {
            case .standardOutput:
                self.consumeStandardOutputRead(data)
            case .standardError:
                self.drainStandardError(data)
            }
        }
    }

    private func consumeStandardOutputRead(_ data: Data) {
        guard let testOnlyReadChunkLimit else {
            consumeStandardOutput(data)
            return
        }

        var start = data.startIndex
        while start < data.endIndex {
            let length = min(testOnlyReadChunkLimit, data.distance(from: start, to: data.endIndex))
            let end = data.index(start, offsetBy: length)
            consumeStandardOutput(Data(data[start..<end]))
            start = end
        }
    }

    private func consumeStandardOutput(_ data: Data) {
        let lines = lock.withLock { () -> [Data] in
            guard case .active = terminalState else { return [] }
            standardOutputBuffer.append(data)
            var lines: [Data] = []

            while let newline = standardOutputBuffer.firstIndex(of: 0x0A) {
                let line = Data(standardOutputBuffer[..<newline])
                standardOutputBuffer.removeSubrange(...newline)
                if !droppingOversizedLine && line.count <= lineLimit {
                    lines.append(line)
                }
                droppingOversizedLine = false
            }

            if standardOutputBuffer.count > lineLimit {
                standardOutputBuffer.removeAll(keepingCapacity: true)
                droppingOversizedLine = true
            }
            return lines
        }

        for line in lines {
            if let event = UnifiedLogParser.parse(line: line) {
                enqueue(event)
            }
        }
    }

    private func drainStandardError(_ data: Data) {
        lock.withLock {
            guard case .active = terminalState else { return }
            for byte in data {
                if byte == 0x0A {
                    standardErrorLineBytes = 0
                } else if standardErrorLineBytes <= lineLimit {
                    standardErrorLineBytes += 1
                }
            }
        }
    }

    private func enqueue(_ event: LogEvent) {
        let continuation = lock.withLock { () -> CheckedContinuation<LogEvent?, Error>? in
            guard case .active = terminalState else { return nil }
            guard let waiter else {
                queuedEvents.insert([event])
                return nil
            }
            self.waiter = nil
            return waiter
        }
        continuation?.resume(returning: event)
    }

    private func readerDidEnd(_ reader: Reader) {
        lock.withLock {
            switch reader {
            case .standardOutput:
                standardOutputEnded = true
                standardOutputBuffer.removeAll(keepingCapacity: false)
            case .standardError:
                standardErrorEnded = true
                standardErrorLineBytes = 0
            }
        }
        completeIfReady()
    }

    private func processDidTerminate(exitCode: Int32) {
        lock.withLock {
            self.exitCode = exitCode
        }
        completeIfReady()
    }

    private func completeIfReady() {
        let state = lock.withLock { () -> TerminalState? in
            guard case .active = terminalState,
                  standardOutputEnded,
                  standardErrorEnded,
                  let exitCode
            else {
                return nil
            }
            return exitCode == 0
                ? .finished
                : .failed(.nonzeroExit(code: exitCode, message: "Unified log stream exited"))
        }
        if let state {
            complete(with: state)
        }
    }

    private func cancel() {
        complete(with: .cancelled, terminateProcess: true)
    }

    private func complete(with state: TerminalState, terminateProcess: Bool = false) {
        let continuation = lock.withLock { () -> CheckedContinuation<LogEvent?, Error>? in
            guard case .active = terminalState else { return nil }
            terminalState = state
            let continuation = waiter
            waiter = nil
            if case .cancelled = state {
                queuedEvents = EventBuffer(capacity: 100)
            }
            return continuation
        }

        if case .cancelled = state, terminateProcess {
            let terminationRequested = terminateAndReapOwnedProcess()
            cleanup(
                terminateProcess: false,
                terminationRequestedOverride: terminationRequested
            )
            continuation?.resume(throwing: CancellationError())
            return
        }

        cleanup(terminateProcess: terminateProcess)

        switch state {
        case .active:
            break
        case .finished:
            continuation?.resume(returning: nil)
        case let .failed(error):
            continuation?.resume(throwing: error)
        case .cancelled:
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func terminateAndReapOwnedProcess() -> Bool {
        guard process.isRunning else { return false }

        let ownedProcessID = process.processIdentifier
        guard ownedProcessID > 0 else { return false }
        process.terminate()

        let graceDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while process.isRunning, ContinuousClock.now < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning, process.processIdentifier == ownedProcessID {
            kill(ownedProcessID, SIGKILL)
        }
        process.waitUntilExit()
        return true
    }

    private func cleanup(
        terminateProcess: Bool,
        terminationRequestedOverride: Bool? = nil
    ) {
        let shouldCleanup = lock.withLock { () -> Bool in
            guard !cleanedUp else { return false }
            cleanedUp = true
            return true
        }
        guard shouldCleanup else { return }

        let processID = process.processIdentifier
        let shouldTerminateNow = terminateProcess && process.isRunning
        let terminationRequested = terminationRequestedOverride
            ?? shouldTerminateNow
        if shouldTerminateNow {
            process.terminate()
        }
        process.terminationHandler = nil
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        let standardOutputReadHandleClosed = close(standardOutput.fileHandleForReading)
        let standardErrorReadHandleClosed = close(standardError.fileHandleForReading)
        let standardOutputWriteHandleClosed = close(standardOutput.fileHandleForWriting)
        let standardErrorWriteHandleClosed = close(standardError.fileHandleForWriting)
        testOnlyCleanupObserver?(
            UnifiedLogStreamCleanupState(
                processID: processID,
                terminationRequested: terminationRequested,
                terminationHandlerCleared: process.terminationHandler == nil,
                standardOutputHandlerCleared: standardOutput.fileHandleForReading.readabilityHandler == nil,
                standardErrorHandlerCleared: standardError.fileHandleForReading.readabilityHandler == nil,
                standardOutputReadHandleClosed: standardOutputReadHandleClosed,
                standardErrorReadHandleClosed: standardErrorReadHandleClosed,
                standardOutputWriteHandleClosed: standardOutputWriteHandleClosed,
                standardErrorWriteHandleClosed: standardErrorWriteHandleClosed
            )
        )
    }

    private func close(_ handle: FileHandle) -> Bool {
        do {
            try handle.close()
            return true
        } catch {
            return false
        }
    }
}
