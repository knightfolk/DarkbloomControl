import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Read-only source policy")
struct SourcePolicyTests {
    @Test("only approved Darkbloom files are readable")
    func allowlistsFiles() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let policy = DarkbloomSourcePolicy(homeDirectory: home, environmentPath: "/usr/bin:/bin")
        #expect(policy.daemonState.path == "/Users/example/.darkbloom/daemon-state.json")
        #expect(policy.loadedModels.path == "/Users/example/.darkbloom/loaded-models.json")
        #expect(policy.legacyLog.path == "/Users/example/.darkbloom/provider.log")
        #expect(policy.allowedFiles == [policy.daemonState, policy.loadedModels, policy.legacyLog])
        #expect(!policy.allowedFiles.map(\.lastPathComponent).contains("auth_token"))
        #expect(!policy.allowedFiles.map(\.lastPathComponent).contains("provider.toml"))
    }

    @Test("the only Darkbloom command is status")
    func fixesStatusArguments() {
        let executable = URL(fileURLWithPath: "/Users/example/.darkbloom/bin/darkbloom")
        let command = ReadOnlyCommand.darkbloomStatus(executable: executable)
        #expect(command.executable == executable)
        #expect(command.arguments == ["status"])
    }

    @Test("polling and byte bounds match the approved design")
    func fixesBounds() {
        #expect(DarkbloomSourcePolicy.stateInterval == .seconds(2))
        #expect(DarkbloomSourcePolicy.logInterval == .seconds(5))
        #expect(DarkbloomSourcePolicy.statusInterval == .seconds(30))
        #expect(DarkbloomSourcePolicy.legacyLogByteLimit == 131_072)
        #expect(DarkbloomSourcePolicy.processOutputByteLimit == 262_144)
        #expect(DarkbloomSourcePolicy.processTimeout == .seconds(3))
    }
}
