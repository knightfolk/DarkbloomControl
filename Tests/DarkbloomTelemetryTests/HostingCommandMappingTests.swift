import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Hosting command mapping")
struct HostingCommandMappingTests {
    private let executable = URL(fileURLWithPath: "/test/bin/darkbloom")
    private let config = URL(fileURLWithPath: "/test/.config/darkbloom/provider.toml")

    @Test("off mode preserves the historical start arguments")
    func offModeIsUnchanged() {
        let command = DarkbloomCommand.start(
            executable: executable,
            config: config,
            models: ["model-a", "model-b"]
        )
        #expect(command.arguments == [
            "start", "--config", config.path,
            "--model", "model-a", "--model", "model-b",
        ])
        #expect(command.executable == executable)
    }

    @Test("default hosting options match off mode")
    func defaultOptionsAreOff() {
        let command = DarkbloomCommand.start(
            executable: executable,
            config: config,
            models: ["model-a"],
            hosting: .default
        )
        #expect(command.arguments == [
            "start", "--config", config.path, "--model", "model-a",
        ])
    }

    @Test("unified mode appends the documented local-endpoint flags")
    func unifiedModeArguments() {
        let options = HostingOptions(mode: .unified, port: 8123, bindAddress: "127.0.0.1")
        let command = DarkbloomCommand.start(
            executable: executable,
            config: config,
            models: ["model-a"],
            hosting: options
        )
        #expect(command.arguments == [
            "start", "--config", config.path, "--model", "model-a",
            "--local-endpoint", "--port", "8123", "--bind", "127.0.0.1",
        ])
        #expect(!command.arguments.contains("--local"))
    }

    @Test("unified mode always passes explicit port and bind, even at CLI defaults")
    func unifiedModeIsExplicit() {
        let options = HostingOptions(mode: .unified, port: 8000, bindAddress: "127.0.0.1")
        #expect(options.startArguments == [
            "--local-endpoint", "--port", "8000", "--bind", "127.0.0.1",
        ])
    }

    @Test("standalone mode maps to --local and stays mutually exclusive with --local-endpoint")
    func standaloneModeArguments() {
        let options = HostingOptions(mode: .standalone, port: 9000, bindAddress: "192.168.1.20")
        #expect(options.startArguments == [
            "--local", "--port", "9000", "--bind", "192.168.1.20",
        ])
        #expect(!options.startArguments.contains("--local-endpoint"))
    }

    @Test("bearer authentication stays on by default and opts out only explicitly")
    func authenticationMapping() {
        for mode in HostingEndpointMode.allCases {
            let options = HostingOptions(mode: mode, port: 8000, bindAddress: "127.0.0.1")
            #expect(!options.startArguments.contains("--no-auth"))
            let command = DarkbloomCommand.start(
                executable: executable,
                config: config,
                models: ["model-a"],
                hosting: options
            )
            #expect(!command.arguments.contains("--no-auth"))
        }

        let unauthenticated = HostingOptions(
            mode: .unified,
            port: 8123,
            bindAddress: "127.0.0.1",
            requiresAuthentication: false
        )
        #expect(unauthenticated.startArguments == [
            "--local-endpoint", "--port", "8123", "--bind", "127.0.0.1", "--no-auth",
        ])
    }

    @Test("local endpoint discovery uses the documented read-only command")
    func localEndpointInfoCommand() {
        let command = DarkbloomCommand.localEndpointInfo(executable: executable)
        #expect(command.arguments == ["local", "--json"])
        #expect(command.executable == executable)
    }
}
