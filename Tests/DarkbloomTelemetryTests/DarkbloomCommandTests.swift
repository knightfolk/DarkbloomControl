import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Darkbloom commands")
struct DarkbloomCommandTests {
    let executable = URL(fileURLWithPath: "/Users/example/.darkbloom/bin/darkbloom")
    let config = URL(fileURLWithPath: "/Users/example/.config/darkbloom/provider.toml")

    @Test("start repeats model arguments and skips the picker")
    func startArguments() {
        let command = DarkbloomCommand.start(
            executable: executable,
            config: config,
            models: ["gemma-4-26b-qat-4bit", "gpt-oss"]
        )
        #expect(command.arguments == [
            "start", "--config", config.path,
            "--model", "gemma-4-26b-qat-4bit",
            "--model", "gpt-oss",
        ])
        #expect(!command.arguments.contains("--all"))
        #expect(!command.arguments.contains("--no-auth"))
    }

    @Test("stop cannot uninstall")
    func stopArguments() {
        #expect(DarkbloomCommand.stop(executable: executable).arguments == ["stop"])
    }

    @Test("model commands keep identifiers as single arguments")
    func modelArguments() {
        #expect(DarkbloomCommand.catalog(executable: executable, config: config).arguments == [
            "models", "catalog", "--config", config.path, "--json",
        ])
        #expect(DarkbloomCommand.localModels(executable: executable, config: config).arguments == [
            "models", "list", "--config", config.path, "--json", "--all",
        ])
        #expect(DarkbloomCommand.download(executable: executable, config: config, modelID: "safe-id").arguments == [
            "models", "download", "--config", config.path, "safe-id",
        ])
        #expect(DarkbloomCommand.remove(executable: executable, modelID: "safe-id").arguments == [
            "models", "remove", "safe-id", "--force",
        ])
    }
}
