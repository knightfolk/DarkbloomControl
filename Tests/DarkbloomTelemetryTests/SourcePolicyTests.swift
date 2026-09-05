import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Source policy")
struct SourcePolicyTests {
    @Test("legacy four-argument process executors remain source compatible")
    func preservesLegacyProcessExecutorConformance() async throws {
        let runner: any ProcessExecuting = LegacyOnlyProcessExecutor()

        let result = try await runner.run(
            .testOnly(executable: URL(fileURLWithPath: "/inert"), arguments: []),
            timeout: .seconds(1),
            outputLimit: 64,
            onOutput: nil
        )

        #expect(result.exitCode == 0)
    }

    @Test("telemetry reads use the approved telemetry-file allowlist")
    func allowlistsTelemetryFiles() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let policy = DarkbloomSourcePolicy(homeDirectory: home, environmentPath: "/usr/bin:/bin")
        #expect(policy.daemonState.path == "/Users/example/.darkbloom/daemon-state.json")
        #expect(policy.loadedModels.path == "/Users/example/.darkbloom/loaded-models.json")
        #expect(policy.legacyLog.path == "/Users/example/.darkbloom/provider.log")
        #expect(policy.providerConfig.path == "/Users/example/.config/darkbloom/provider.toml")
        #expect(policy.allowedFiles == [policy.daemonState, policy.loadedModels, policy.legacyLog])
        #expect(!policy.allowedFiles.map(\.lastPathComponent).contains("auth_token"))
        // The provider config is a separate, narrowly managed control surface,
        // not a read-only telemetry file.
        #expect(!policy.allowedFiles.map(\.lastPathComponent).contains("provider.toml"))
    }

    @Test("production commands remain shell-free and bounded to the allowlist")
    func fixesProviderCommandSurface() {
        let executable = URL(fileURLWithPath: "/Users/example/.darkbloom/bin/darkbloom")
        let config = URL(fileURLWithPath: "/Users/example/.config/darkbloom/provider.toml")
        let commands = [
            DarkbloomCommand.status(executable: executable, config: config),
            DarkbloomCommand.catalog(executable: executable, config: config),
            DarkbloomCommand.localModels(executable: executable, config: config),
            DarkbloomCommand.download(executable: executable, config: config, modelID: "safe-id"),
            DarkbloomCommand.remove(executable: executable, modelID: "safe-id"),
            DarkbloomCommand.start(executable: executable, config: config, models: ["first", "second"]),
            DarkbloomCommand.stop(executable: executable),
            DarkbloomCommand.restart(executable: executable, config: config),
        ]

        #expect(commands.allSatisfy { $0.executable == executable })
        #expect(DarkbloomCommand.stop(executable: executable).arguments == ["stop"])
        #expect(!DarkbloomCommand.stop(executable: executable).arguments.contains("--uninstall"))
        #expect(DarkbloomCommand.start(executable: executable, config: config, models: ["first", "second"]).arguments == [
            "start", "--config", config.path, "--model", "first", "--model", "second",
        ])
        #expect(!commands.flatMap(\.arguments).contains("--no-auth"))
    }

    @Test("polling and byte bounds match the approved design")
    func fixesBounds() {
        #expect(DarkbloomSourcePolicy.stateInterval == .seconds(2))
        #expect(DarkbloomSourcePolicy.logInterval == .seconds(5))
        #expect(DarkbloomSourcePolicy.statusInterval == .seconds(30))
        #expect(DarkbloomSourcePolicy.legacyLogByteLimit == 131_072)
        #expect(DarkbloomSourcePolicy.processOutputByteLimit == 262_144)
        #expect(DarkbloomSourcePolicy.processTimeout == .seconds(3))
        #expect(DarkbloomSourcePolicy.lifecycleTimeout == .seconds(30))
        #expect(DarkbloomSourcePolicy.catalogTimeout == .seconds(15))
        #expect(DarkbloomSourcePolicy.downloadTimeout == .seconds(21_600))
        #expect(DarkbloomSourcePolicy.mutationOutputByteLimit == 1_048_576)
    }

    @Test("CLI candidate descriptions cover home bundled app and PATH")
    func describesCLICandidatesWithoutDiscovery() {
        #expect(DarkbloomSourcePolicy.cliCandidateDescriptions == [
            "~/.darkbloom/bin/darkbloom",
            "~/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom",
            "PATH entries ending in /darkbloom",
        ])
    }

    @Test("config-save errors do not expose fixture secret text")
    func redactsConfigSaveErrors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourcePolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = directory.appendingPathComponent("provider.toml")
        try Data("""
        enabled_models = []
        private_value = "never-display-me"
        preload_models = []
        """.utf8).write(to: config)
        let runner = RejectingConfigValidationRunner()
        let store = LocalProviderConfigStore(
            configURL: config,
            executable: directory.appendingPathComponent("darkbloom"),
            runner: runner
        )
        let draft = try await store.load()

        do {
            _ = try await store.save(draft.withSelection(
                ProviderModelSelection(enabled: ["safe-id"], preloaded: [])
            ))
            Issue.record("Expected candidate validation to fail")
        } catch {
            #expect(error as? ProviderConfigError == .validationFailed(
                "Darkbloom rejected the candidate configuration"
            ))
            #expect(!String(describing: error).contains("never-display-me"))
        }
        #expect(await runner.invocationCount == 1)
    }
}

private actor LegacyOnlyProcessExecutor: ProcessExecuting {
    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}

private actor RejectingConfigValidationRunner: ProcessExecuting {
    private var invocations = 0

    var invocationCount: Int { invocations }

    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult {
        invocations += 1
        return CommandResult(
            exitCode: 2,
            standardOutput: Data(),
            standardError: Data("never-display-me".utf8)
        )
    }
}
