import Foundation
import Darwin
import Testing
@testable import DarkbloomTelemetry

@Suite("Capped process runner")
struct ProcessRunnerTests {
    @Test("publishes chunks without bypassing the retained output cap")
    func publishesOutputChunks() async throws {
        let recorder = OutputChunkRecorder()
        let result = try await CappedProcessRunner().run(
            .testOnly(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["progress"]),
            timeout: .seconds(3),
            outputLimit: 64,
            onOutput: recorder.record
        )
        #expect(result.standardOutput == Data("progress".utf8))
        #expect(recorder.data(for: .standardOutput) == Data("progress".utf8))
    }

    @Test("captures a finite process result")
    func capturesOutput() async throws {
        let result = try await CappedProcessRunner().run(
            .testOnly(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["darkbloom 0.8.15"]),
            timeout: .seconds(3),
            outputLimit: 256
        )
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == Data("darkbloom 0.8.15".utf8))
        #expect(result.standardError.isEmpty)
    }

    @Test("terminates output beyond the cap")
    func capsOutput() async {
        await #expect(throws: ProcessRunnerError.outputLimitExceeded(limit: 8)) {
            try await CappedProcessRunner().run(
                .testOnly(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["123456789"]),
                timeout: .seconds(3),
                outputLimit: 8
            )
        }
    }

    @Test("terminates an owned timed-out child")
    func timesOut() async {
        await #expect(throws: ProcessRunnerError.timedOut) {
            try await CappedProcessRunner().run(
                .testOnly(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"]),
                timeout: .milliseconds(50),
                outputLimit: 256
            )
        }
    }

    @Test("stdout and stderr share one output cap")
    func appliesGlobalOutputCap() async {
        await #expect(throws: ProcessRunnerError.outputLimitExceeded(limit: 10)) {
            try await CappedProcessRunner().run(
                .testOnly(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf 123456; printf 789012 >&2", "sh"]
                ),
                timeout: .seconds(3),
                outputLimit: 10
            )
        }
    }

    @Test("timeout reaps a TERM-resistant owned child within bounded grace")
    func timeoutReapsTermResistantChild() async throws {
        let pidFile = try makeTemporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let outcome = RunOutcomeRecorder()
        let finished = CompletionFlag()
        let runner = CappedProcessRunner()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let runTask = Task {
            defer { finished.set() }
            do {
                _ = try await runner.run(
                    termResistantCommand(pidFile: pidFile),
                    timeout: .milliseconds(50),
                    outputLimit: 256
                )
                outcome.record(.success)
            } catch let error as ProcessRunnerError {
                outcome.record(.processRunner(error))
            } catch is CancellationError {
                outcome.record(.cancelled)
            } catch {
                outcome.record(.other(String(describing: error)))
            }
        }

        guard let pid = await waitForPID(at: pidFile) else {
            Issue.record("The TERM-resistant child did not publish its PID")
            runTask.cancel()
            _ = await runTask.value
            return
        }

        let completedWithinBound = await waitForCompletion(
            finished,
            timeout: .seconds(1)
        )
        if !completedWithinBound, processExists(pid) {
            kill(pid, SIGKILL)
        }
        _ = await runTask.value

        let elapsed = startedAt.duration(to: clock.now)
        #expect(completedWithinBound)
        #expect(outcome.value == .processRunner(.timedOut))
        #expect(elapsed < .seconds(1))
        #expect(!processExists(pid))
    }

    @Test("outer task cancellation reaps the owned finite child")
    func cancellationReapsOwnedChild() async throws {
        let pidFile = try makeTemporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let outcome = RunOutcomeRecorder()
        let finished = CompletionFlag()
        let runner = CappedProcessRunner()
        let runTask = Task {
            defer { finished.set() }
            do {
                _ = try await runner.run(
                    termResistantCommand(pidFile: pidFile),
                    timeout: .seconds(30),
                    outputLimit: 256
                )
                outcome.record(.success)
            } catch let error as ProcessRunnerError {
                outcome.record(.processRunner(error))
            } catch is CancellationError {
                outcome.record(.cancelled)
            } catch {
                outcome.record(.other(String(describing: error)))
            }
        }

        guard let pid = await waitForPID(at: pidFile) else {
            Issue.record("The TERM-resistant child did not publish its PID")
            runTask.cancel()
            _ = await runTask.value
            return
        }

        runTask.cancel()
        let completedWithinBound = await waitForCompletion(
            finished,
            timeout: .seconds(1)
        )
        if !completedWithinBound, processExists(pid) {
            kill(pid, SIGKILL)
        }
        _ = await runTask.value

        #expect(completedWithinBound)
        #expect(outcome.value == .cancelled)
        #expect(!processExists(pid))
    }

    @Test("cleans handlers and pipes after a launch failure")
    func cleansUpAfterLaunchFailure() async {
        let recorder = CleanupRecorder()
        let runner = CappedProcessRunner(testOnlyCleanupObserver: { state in
            recorder.recordCleanup(state)
        })

        do {
            _ = try await runner.run(
                .testOnly(
                    executable: URL(fileURLWithPath: "/tmp/darkbloom-monitor-missing-executable"),
                    arguments: []
                ),
                timeout: .seconds(3),
                outputLimit: 256
            )
            Issue.record("Expected a launch failure")
        } catch let error as ProcessRunnerError {
            guard case .launchFailed = error else {
                Issue.record("Expected a launch failure, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
            return
        }

        #expect(recorder.cleanupState == ProcessCleanupState(
            terminationHandlerCleared: true,
            standardOutputCleared: true,
            standardErrorCleared: true,
            standardOutputHandlerCleared: true,
            standardErrorHandlerCleared: true,
            standardOutputReadHandleClosed: true,
            standardErrorReadHandleClosed: true,
            standardOutputWriteHandleClosed: true,
            standardErrorWriteHandleClosed: true
        ))
    }

    @Test("closes both pipe ends after a finite process completes")
    func closesHandlesAfterFiniteCompletion() async throws {
        let recorder = CleanupRecorder()
        let runner = CappedProcessRunner(testOnlyCleanupObserver: recorder.recordCleanup)

        _ = try await runner.run(
            .testOnly(
                executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["finite output"]
            ),
            timeout: .seconds(3),
            outputLimit: 256
        )

        let state = try #require(recorder.cleanupState)
        #expect(state.terminationHandlerCleared)
        #expect(state.standardOutputHandlerCleared)
        #expect(state.standardErrorHandlerCleared)
        #expect(state.standardOutputReadHandleClosed)
        #expect(state.standardErrorReadHandleClosed)
        #expect(state.standardOutputWriteHandleClosed)
        #expect(state.standardErrorWriteHandleClosed)
    }

    @Test("bounds reader cleanup when a descendant retains the pipe")
    func boundsReaderCleanupAfterOwnedExit() async throws {
        let pidFile = try makeTemporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let task = Task {
            try await CappedProcessRunner().run(
                .testOnly(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "sleep 30 & printf '%s' \"$!\" > \"$1\"; printf done; exit 0",
                        "sh",
                        pidFile.path,
                    ]
                ),
                timeout: .seconds(3),
                outputLimit: 256
            )
        }
        guard let descendantPID = await waitForPID(at: pidFile) else {
            task.cancel()
            _ = await task.result
            throw TestError.missingPID
        }

        let startedAt = ContinuousClock.now
        let result = try await task.value
        let elapsed = startedAt.duration(to: ContinuousClock.now)

        if processExists(descendantPID) {
            kill(descendantPID, SIGKILL)
        }
        let descendantExited = await waitForProcessExit(descendantPID)

        #expect(result.standardOutput == Data("done".utf8))
        #expect(elapsed < .seconds(1))
        #expect(descendantExited)
    }

    private func makeTemporaryPIDFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-monitor-\(UUID().uuidString).pid")
        try Data().write(to: url)
        return url
    }

    private func termResistantCommand(pidFile: URL) -> ProcessCommand {
        .testOnly(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf '%s' \"$$\" > \"$1\"; trap '' TERM; while :; do :; done",
                "sh",
                pidFile.path,
            ]
        )
    }

    private func waitForPID(at url: URL) async -> Int32? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if let value = try? String(contentsOf: url),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func waitForCompletion(
        _ flag: CompletionFlag,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !flag.read(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return flag.read()
    }

    private func processExists(_ pid: Int32) -> Bool {
        errno = 0
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func waitForProcessExit(_ pid: Int32) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while processExists(pid), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !processExists(pid)
    }
}

private final class OutputChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [ProcessOutputChunk] = []

    func record(_ chunk: ProcessOutputChunk) {
        lock.withLock { chunks.append(chunk) }
    }

    func data(for destination: ProcessOutputDestination) -> Data {
        lock.withLock {
            chunks.lazy.filter { $0.destination == destination }
                .reduce(into: Data()) { $0.append($1.data) }
        }
    }
}

private final class CleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessCleanupState?

    var cleanupState: ProcessCleanupState? {
        lock.withLock { state }
    }

    func recordCleanup(_ state: ProcessCleanupState) {
        lock.withLock {
            self.state = state
        }
    }
}

private enum RunOutcome: Equatable, Sendable {
    case success
    case processRunner(ProcessRunnerError)
    case cancelled
    case other(String)
}

private enum TestError: Error {
    case missingPID
}

private final class RunOutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: RunOutcome?

    var value: RunOutcome? {
        lock.withLock { recorded }
    }

    func record(_ outcome: RunOutcome) {
        lock.withLock { recorded = outcome }
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func set() {
        lock.withLock { completed = true }
    }

    func read() -> Bool {
        lock.withLock { completed }
    }
}
