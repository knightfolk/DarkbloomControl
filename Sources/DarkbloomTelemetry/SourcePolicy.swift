import Foundation

public struct DarkbloomSourcePolicy: Equatable, Sendable {
    public static let stateInterval: Duration = .seconds(2)
    public static let logInterval: Duration = .seconds(5)
    public static let statusInterval: Duration = .seconds(30)
    public static let legacyLogByteLimit = 128 * 1_024
    public static let processOutputByteLimit = 256 * 1_024
    public static let processTimeout: Duration = .seconds(3)
    public static let cliCandidateDescriptions = [
        "~/.darkbloom/bin/darkbloom",
        "~/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom",
        "PATH entries ending in /darkbloom",
    ]

    public let daemonState: URL
    public let loadedModels: URL
    public let legacyLog: URL
    public let cliCandidates: [URL]

    public var allowedFiles: [URL] {
        [daemonState, loadedModels, legacyLog]
    }

    public init(homeDirectory: URL, environmentPath: String) {
        let root = homeDirectory.appendingPathComponent(".darkbloom", isDirectory: true)
        daemonState = root.appendingPathComponent("daemon-state.json")
        loadedModels = root.appendingPathComponent("loaded-models.json")
        legacyLog = root.appendingPathComponent("provider.log")
        cliCandidates = [
            root.appendingPathComponent("bin/darkbloom"),
            root.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom"),
        ] + environmentPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("darkbloom")
        }
    }
}

public struct ReadOnlyCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]

    private init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public static func darkbloomStatus(executable: URL) -> Self {
        Self(executable: executable, arguments: ["status"])
    }

    public static let unifiedLogStream = Self(
        executable: URL(fileURLWithPath: "/usr/bin/log"),
        arguments: [
            "stream",
            "--style", "json",
            "--level", "info",
            "--predicate", "subsystem == \"dev.darkbloom.provider\"",
        ]
    )

    static func testOnly(executable: URL, arguments: [String]) -> Self {
        Self(executable: executable, arguments: arguments)
    }
}
