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
    public init() {}

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
        process.terminationHandler = { _ in
            session.didTerminate()
        }

        session.beginReading(standardOutput.fileHandleForReading, destination: .standardOutput)
        session.beginReading(standardError.fileHandleForReading, destination: .standardError)

        do {
            try process.run()
        } catch {
            close(standardOutput.fileHandleForReading)
            close(standardError.fileHandleForReading)
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
        close(standardOutput.fileHandleForReading)
        close(standardError.fileHandleForReading)

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
}

private final class ProcessSession: @unchecked Sendable {
    enum Destination {
        case standardOutput
        case standardError
    }

    private let process: Process
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
        guard process.isRunning else { return }
        let shouldTerminate = lock.withLock { () -> Bool in
            guard recordedFailure == nil else { return false }
            recordedFailure = error
            guard !terminationRequested else { return false }
            terminationRequested = true
            return true
        }
        if shouldTerminate && process.isRunning {
            process.terminate()
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
        if shouldTerminate && process.isRunning {
            process.terminate()
        }
    }
}
