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
}
