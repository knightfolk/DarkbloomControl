import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Capped process runner")
struct ProcessRunnerTests {
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
            standardErrorHandlerCleared: true
        ))
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
