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

public struct CappedProcessRunner: Sendable {
    private let testOnlyCleanupObserver: (@Sendable (ProcessCleanupState) -> Void)?

    public init() {
        testOnlyCleanupObserver = nil
    }

    init(testOnlyCleanupObserver: @escaping @Sendable (ProcessCleanupState) -> Void) {
        self.testOnlyCleanupObserver = testOnlyCleanupObserver
    }

    public func run(
        _ command: ReadOnlyCommand,
        timeout: Duration,
        outputLimit: Int
    ) async throws -> CommandResult {
        guard outputLimit > 0 else {
            throw ProcessRunnerError.outputLimitExceeded(limit: outputLimit)
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let session = ProcessSession(process: process, outputLimit: outputLimit)

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
                processWasLaunched: processWasLaunched
            )
        }

        do {
            try process.run()
            processWasLaunched = true
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
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

        await session.waitForTermination()
        timeoutTask.cancel()
        await session.waitForReaders()

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
    }

    private func close(_ handle: FileHandle) {
        try? handle.close()
    }

    private func cleanup(
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe,
        processWasLaunched: Bool
    ) {
        let standardOutputHandle = standardOutput.fileHandleForReading
        let standardErrorHandle = standardError.fileHandleForReading
        standardOutputHandle.readabilityHandler = nil
        standardErrorHandle.readabilityHandler = nil
        process.terminationHandler = nil
        if !processWasLaunched {
            process.standardOutput = nil
            process.standardError = nil
        }
        // Foundation makes Process stream setters immutable after launch. The session holds
        // the process weakly, so after this scope closes its completed process releases pipes.
        close(standardOutputHandle)
        close(standardErrorHandle)
        testOnlyCleanupObserver?(
            ProcessCleanupState(
                terminationHandlerCleared: process.terminationHandler == nil,
                standardOutputCleared: !processWasLaunched && process.standardOutput == nil,
                standardErrorCleared: !processWasLaunched && process.standardError == nil,
                standardOutputHandlerCleared: standardOutputHandle.readabilityHandler == nil,
                standardErrorHandlerCleared: standardErrorHandle.readabilityHandler == nil
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
}

private final class ProcessSession: @unchecked Sendable {
    enum Destination {
        case standardOutput
        case standardError
    }

    private weak var process: Process?
    private let outputLimit: Int
    private let lock = NSLock()
    private let readerGroup = DispatchGroup()
    private var standardOutput = Data()
    private var standardError = Data()
    private var recordedFailure: ProcessRunnerError?
    private var terminationRequested = false
    private var terminated = false
    private var terminationContinuation: CheckedContinuation<Void, Never>?

    init(process: Process, outputLimit: Int) {
        self.process = process
        self.outputLimit = outputLimit
    }

    var failure: ProcessRunnerError? {
        lock.withLock { recordedFailure }
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
                self.readerGroup.leave()
                return
            }
            self.append(data, to: destination)
        }
    }

    func didTerminate() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
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

    func waitForReaders() async {
        await withCheckedContinuation { continuation in
            readerGroup.notify(queue: .global()) {
                continuation.resume()
            }
        }
    }

    func requestTermination(for error: ProcessRunnerError) {
        guard process?.isRunning == true else { return }
        let shouldTerminate = lock.withLock { () -> Bool in
            guard recordedFailure == nil else { return false }
            recordedFailure = error
            guard !terminationRequested else { return false }
            terminationRequested = true
            return true
        }
        if shouldTerminate && process?.isRunning == true {
            process?.terminate()
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
            guard recordedFailure == nil else { return false }
            let combinedCount = standardOutput.count + standardError.count
            guard data.count <= outputLimit - combinedCount else {
                recordedFailure = .outputLimitExceeded(limit: outputLimit)
                terminationRequested = true
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
        if shouldTerminate && process?.isRunning == true {
            process?.terminate()
        }
    }
}

public struct UnifiedLogStreamer: Sendable {
    private let command: ReadOnlyCommand
    private let testOnlyReadChunkLimit: Int?
    private let testOnlyCleanupObserver: (@Sendable (UnifiedLogStreamCleanupState) -> Void)?

    public init() {
        command = .unifiedLogStream
        testOnlyReadChunkLimit = nil
        testOnlyCleanupObserver = nil
    }

    init(
        testOnlyCommand: ReadOnlyCommand,
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
        command: ReadOnlyCommand,
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

    private func cleanup(terminateProcess: Bool) {
        let shouldCleanup = lock.withLock { () -> Bool in
            guard !cleanedUp else { return false }
            cleanedUp = true
            return true
        }
        guard shouldCleanup else { return }

        let processID = process.processIdentifier
        let terminationRequested = terminateProcess && process.isRunning
        if terminationRequested {
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
