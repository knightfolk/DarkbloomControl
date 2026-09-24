import Foundation

public struct DarkbloomSourcePolicy: Equatable, Sendable {
    public static let stateInterval: Duration = .seconds(2)
    public static let logInterval: Duration = .seconds(5)
    public static let statusInterval: Duration = .seconds(30)
    public static let legacyLogByteLimit = 128 * 1_024
    public static let processOutputByteLimit = 256 * 1_024
    public static let processTimeout: Duration = .seconds(3)
    public static let lifecycleTimeout: Duration = .seconds(30)
    /// Darkbloom's native stop may wait ten minutes for accepted work and usage acknowledgement.
    public static let stopDrainTimeoutSeconds = 600
    /// Give the stop command additional time to finish after its own drain deadline.
    public static let stopCommandTimeout: Duration = .seconds(630)
    public static let catalogTimeout: Duration = .seconds(15)
    public static let downloadTimeout: Duration = .seconds(21_600)
    public static let mutationOutputByteLimit = 1_048_576
    /// `darkbloom local --json` reads its discovery record and verifies the
    /// recorded process is still alive, so a short bound is sufficient.
    public static let localEndpointTimeout: Duration = .seconds(5)
    public static let localEndpointOutputByteLimit = 64 * 1024
    public static let cliCandidateDescriptions = [
        "~/.darkbloom/bin/darkbloom",
        "~/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom",
        "PATH entries ending in /darkbloom",
    ]

    public let daemonState: URL
    public let loadedModels: URL
    public let legacyLog: URL
    /// Provider-owned local bearer token, read or replaced only after an
    /// explicit user action. This is intentionally excluded from `allowedFiles`.
    public let localEndpointToken: URL
    public let providerConfig: URL
    public let cliCandidates: [URL]

    public var allowedFiles: [URL] { [daemonState, loadedModels, legacyLog] }

    public init(homeDirectory: URL, environmentPath: String) {
        let root = homeDirectory.appendingPathComponent(".darkbloom", isDirectory: true)
        daemonState = root.appendingPathComponent("daemon-state.json")
        loadedModels = root.appendingPathComponent("loaded-models.json")
        legacyLog = root.appendingPathComponent("provider.log")
        localEndpointToken = root.appendingPathComponent("local_token")
        providerConfig = homeDirectory.appendingPathComponent(".config/darkbloom/provider.toml")
        cliCandidates = [root.appendingPathComponent("bin/darkbloom"), root.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom")] + environmentPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("darkbloom")
        }
    }
}

public struct ProcessCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public init(executable: URL, arguments: [String]) { self.executable = executable; self.arguments = arguments }
    static func testOnly(executable: URL, arguments: [String]) -> Self { Self(executable: executable, arguments: arguments) }

    static let unifiedLogStream = Self(
        executable: URL(fileURLWithPath: "/usr/bin/log"),
        arguments: ["stream", "--style", "json", "--level", "info", "--predicate", "subsystem == \"dev.darkbloom.provider\""]
    )
}

public enum ProcessOutputDestination: Equatable, Sendable { case standardOutput, standardError }

public struct ProcessOutputChunk: Equatable, Sendable {
    public let destination: ProcessOutputDestination
    public let data: Data
    public init(destination: ProcessOutputDestination, data: Data) { self.destination = destination; self.data = data }
}

public protocol ProcessExecuting: Sendable {
    func run(_ command: ProcessCommand, timeout: Duration, outputLimit: Int, onOutput: (@Sendable (ProcessOutputChunk) -> Void)?) async throws -> CommandResult
}

/// An optional executor capability that reports the exact point at which a
/// child process has successfully launched. On successful launch, the callback
/// must be invoked once, synchronously before any later cancellation is
/// returned. It must not be invoked for pre-launch cancellation or failure.
public protocol LaunchReportingProcessExecuting: ProcessExecuting {
    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?,
        onLaunch: (@Sendable () -> Void)?
    ) async throws -> CommandResult
}

public enum DarkbloomCommand {
    public static func status(executable: URL, config: URL? = nil) -> ProcessCommand {
        var args = ["status"]; if let config { args += ["--config", config.path] }; return ProcessCommand(executable: executable, arguments: args)
    }
    public static func catalog(executable: URL, config: URL) -> ProcessCommand { ProcessCommand(executable: executable, arguments: ["models", "catalog", "--config", config.path, "--json"]) }
    public static func localModels(executable: URL, config: URL) -> ProcessCommand { ProcessCommand(executable: executable, arguments: ["models", "list", "--config", config.path, "--json", "--all"]) }
    public static func download(executable: URL, config: URL, modelID: String) -> ProcessCommand { ProcessCommand(executable: executable, arguments: ["models", "download", "--config", config.path, modelID]) }
    public static func remove(executable: URL, modelID: String) -> ProcessCommand { ProcessCommand(executable: executable, arguments: ["models", "remove", modelID, "--force"]) }
    /// Hosted start flags are appended exactly as documented by the official
    /// CLI reference. Bearer-token authentication remains the default; the
    /// user must explicitly opt out before `--no-auth` is dispatched.
    public static func start(
        executable: URL,
        config: URL,
        models: [String],
        hosting: HostingOptions = .default
    ) -> ProcessCommand {
        precondition(hosting.isValid, "Hosting options must be validated before dispatch")
        var args = ["start", "--config", config.path]
        for model in models { args += ["--model", model] }
        args += hosting.startArguments
        return ProcessCommand(executable: executable, arguments: args)
    }
    /// The documented on-demand view of the live local endpoint. The JSON
    /// payload contains the bearer API key: callers must never log, export, or
    /// persist it.
    public static func localEndpointInfo(executable: URL) -> ProcessCommand {
        ProcessCommand(executable: executable, arguments: ["local", "--json"])
    }
    public static func stop(executable: URL) -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: ["stop", "--timeout", String(DarkbloomSourcePolicy.stopDrainTimeoutSeconds)]
        )
    }
    public static func restart(executable: URL, config: URL) -> ProcessCommand { ProcessCommand(executable: executable, arguments: ["restart", "--config", config.path]) }
}
