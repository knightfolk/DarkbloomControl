import Foundation
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("CLI update status")
@MainActor
struct CLIUpdateStatusTests {
    @Test("parses the four check-only outcomes and drops URLs and quarantine reasons")
    func parsesReadOnlyOutcomes() throws {
        #expect(try CLIUpdateParser.parse(output("Up to date (v0.9.7).")) == .upToDate(version: "0.9.7"))

        #expect(try CLIUpdateParser.parse(output("""
            Update available: v0.9.7 -> v0.10.0
            Download URL: https://private.example/releases/0.10.0.zip?token=secret
            Bundle SHA-256: abcdef
            """)) == .updateAvailable(current: "0.9.7", latest: "0.10.0"))

        #expect(try CLIUpdateParser.parse(output("""
            v0.10.0 is already installed on disk but this process is v0.9.7.
            Restart the provider to activate the installed version.
            """)) == .restartRequired(current: "0.9.7", installed: "0.10.0"))

        #expect(try CLIUpdateParser.parse(output("""
            Latest release v0.10.0 is quarantined on this machine.
            Reason: /Users/private/operator/session-token
            A strictly newer release remains eligible automatically.
            """)) == .quarantined(version: "0.10.0"))
    }

    @Test("rejects changed output, malformed versions, duplicate outcomes, and oversized output")
    func rejectsUnrecognizedOutput() {
        #expect(throws: CLIUpdateParseError.invalidPayload) {
            try CLIUpdateParser.parse(Data("update available at https://secret.invalid".utf8))
        }
        #expect(throws: CLIUpdateParseError.invalidPayload) {
            try CLIUpdateParser.parse(output("Update available: v../../private -> v0.10.0"))
        }
        #expect(throws: CLIUpdateParseError.invalidPayload) {
            try CLIUpdateParser.parse(output("Up to date (v0.9.7).\nUpdate available: v0.9.7 -> v0.10.0"))
        }
        #expect(throws: CLIUpdateParseError.invalidPayload) {
            try CLIUpdateParser.parse(Data(repeating: 65, count: CLIUpdateParser.maximumPayloadBytes + 1))
        }
    }

    @Test("runs only the bounded check-only command with the approved config")
    func clientUsesFixedReadOnlyCommand() async {
        let policy = cliUpdateTestPolicy()
        let runner = CLIUpdateRunner(
            result: CommandResult(
                exitCode: 0,
                standardOutput: output("Update available: v0.9.7 -> v0.10.0"),
                standardError: Data()
            )
        )
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let client = CLIUpdateClient(
            policy: policy,
            runner: runner,
            now: { fixedDate },
            testOnlyExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )

        let availability = await client.checkForUpdate()
        #expect(availability.value == .updateAvailable(current: "0.9.7", latest: "0.10.0"))
        if case .available(_, let capturedAt) = availability {
            #expect(capturedAt == fixedDate)
        } else {
            Issue.record("A valid check-only result should be available")
        }

        let command = await runner.command
        #expect(command == CLIUpdateCommand.checkOnly(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            config: policy.providerConfig
        ))
        #expect(await runner.timeout == CLIUpdateClient.processTimeout)
        #expect(await runner.outputLimit == CLIUpdateClient.outputLimit)
    }

    @Test("does not trust nonzero output or expose runner errors")
    func sanitizesFailures() async {
        let runner = CLIUpdateRunner(
            result: CommandResult(
                exitCode: 1,
                standardOutput: output("Update available: v0.9.7 -> v9.9.9"),
                standardError: Data("https://private.invalid/token=secret".utf8)
            )
        )
        let client = CLIUpdateClient(
            policy: cliUpdateTestPolicy(),
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            testOnlyExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )

        let availability = await client.checkForUpdate()
        guard case .unavailable(let reason) = availability else {
            Issue.record("A nonzero exit code must not produce update status")
            return
        }
        #expect(!reason.contains("private"))
        #expect(!reason.contains("secret"))
        #expect(await runner.command?.arguments == [
            "update", "--check-only", "--config", cliUpdateTestPolicy().providerConfig.path,
        ])
    }

    @Test("does not invoke a CLI outside the approved executable candidates")
    func requiresApprovedExecutable() async {
        let home = URL(fileURLWithPath: "/tmp/dc-cli-update-missing-\(UUID().uuidString)")
        let policy = DarkbloomSourcePolicy(homeDirectory: home, environmentPath: "/missing-path")
        let runner = CLIUpdateRunner(
            result: CommandResult(exitCode: 0, standardOutput: output("Up to date (v0.9.7)."), standardError: Data())
        )
        let client = CLIUpdateClient(
            policy: policy,
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        guard case .unavailable = await client.checkForUpdate() else {
            Issue.record("Missing approved CLI candidates should produce unknown status")
            return
        }
        #expect(await runner.command == nil)
    }

    @Test("store preserves the last confirmed status as stale when a later check fails")
    func retainsLastGoodStatus() async {
        let confirmedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = CLIUpdateProviderFake(result: .available(
            value: .updateAvailable(current: "0.9.7", latest: "0.10.0"),
            capturedAt: confirmedAt
        ))
        let store = CLIUpdateStatusStore(client: provider)
        await store.refresh()
        await provider.set(.unavailable(reason: "safe failure"))
        await store.refresh()

        guard case .stale(let value, let capturedAt, _) = store.status else {
            Issue.record("The last confirmed result should remain visible as stale")
            await store.stop()
            return
        }
        #expect(value == .updateAvailable(current: "0.9.7", latest: "0.10.0"))
        #expect(capturedAt == confirmedAt)
        await store.stop()
    }
}

private func output(_ stateLine: String) -> Data {
    Data("""
        darkbloom update
        Current version: 0.9.7

        \(stateLine)
        """.utf8)
}

private func cliUpdateTestPolicy() -> DarkbloomSourcePolicy {
    DarkbloomSourcePolicy(
        homeDirectory: URL(fileURLWithPath: "/tmp/dc-cli-update-tests"),
        environmentPath: "/usr/bin"
    )
}

private actor CLIUpdateRunner: ProcessExecuting {
    let result: CommandResult
    private(set) var command: ProcessCommand?
    private(set) var timeout: Duration?
    private(set) var outputLimit: Int?

    init(result: CommandResult) {
        self.result = result
    }

    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult {
        self.command = command
        self.timeout = timeout
        self.outputLimit = outputLimit
        return result
    }
}

private actor CLIUpdateProviderFake: CLIUpdateProviding {
    private var result: SourceAvailability<CLIUpdateStatus>

    init(result: SourceAvailability<CLIUpdateStatus>) {
        self.result = result
    }

    func set(_ result: SourceAvailability<CLIUpdateStatus>) {
        self.result = result
    }

    func checkForUpdate() async -> SourceAvailability<CLIUpdateStatus> {
        result
    }
}
