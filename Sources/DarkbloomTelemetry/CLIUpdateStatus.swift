import Foundation

/// The safe, user-facing outcomes of `darkbloom update --check-only`.
/// Version strings are validated before they enter this value. CLI URLs,
/// quarantine reasons, paths, and raw errors are deliberately not retained.
public enum CLIUpdateStatus: Equatable, Sendable {
    case upToDate(version: String)
    case updateAvailable(current: String, latest: String)
    case restartRequired(current: String, installed: String)
    case quarantined(version: String)
}

public enum CLIUpdateParseError: Error, Equatable, Sendable {
    case invalidPayload
}

public enum CLIUpdateCommand {
    /// This command performs a network check only. It never installs an update
    /// and intentionally does not pass `--override-quarantine`.
    public static func checkOnly(executable: URL, config: URL) -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: ["update", "--check-only", "--config", config.path]
        )
    }
}

public enum CLIUpdateParser {
    public static let maximumPayloadBytes = 32 * 1_024

    /// Parses the fixed status lines emitted by the official CLI. Other output
    /// is ignored and never surfaced; this includes release URLs, hashes, and
    /// free-form quarantine reasons.
    public static func parse(_ data: Data) throws -> CLIUpdateStatus {
        guard data.count <= maximumPayloadBytes,
              let output = String(data: data, encoding: .utf8),
              !output.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      && $0 != "\n" && $0 != "\r" && $0 != "\t"
              })
        else {
            throw CLIUpdateParseError.invalidPayload
        }

        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard lines.contains("darkbloom update"),
              let currentLine = lines.first(where: { $0.hasPrefix("Current version: ") }),
              let current = parseVersion(String(currentLine.dropFirst("Current version: ".count)))
        else {
            throw CLIUpdateParseError.invalidPayload
        }

        var matches: [CLIUpdateStatus] = []
        for line in lines {
            if let value = parseWrappedVersion(
                line,
                prefix: "Up to date (v",
                suffix: ")."
            ) {
                matches.append(.upToDate(version: value))
            } else if line.hasPrefix("Update available: v"),
                      let separator = line.range(of: " -> v") {
                let foundCurrent = String(line["Update available: v".endIndex..<separator.lowerBound])
                let foundLatest = String(line[separator.upperBound...])
                if let foundCurrent = parseVersion(foundCurrent),
                   let foundLatest = parseVersion(foundLatest) {
                    matches.append(.updateAvailable(current: foundCurrent, latest: foundLatest))
                }
            } else if line.hasPrefix("v"), line.hasSuffix("."),
                      let separator = line.range(of: " is already installed on disk but this process is v") {
                let installedText = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
                let currentText = String(line[separator.upperBound...].dropLast())
                if let installed = parseVersion(installedText),
                   let processCurrent = parseVersion(currentText) {
                    matches.append(.restartRequired(current: processCurrent, installed: installed))
                }
            } else if let value = parseWrappedVersion(
                line,
                prefix: "Latest release v",
                suffix: " is quarantined on this machine."
            ) {
                matches.append(.quarantined(version: value))
            }
        }

        // The CLI prints one and only one outcome. Requiring a single parsed
        // state avoids guessing if a future CLI changes its output format.
        guard matches.count == 1 else {
            throw CLIUpdateParseError.invalidPayload
        }

        // The current-version banner confirms that the payload belongs to the
        // expected command; state-specific version values remain authoritative
        // because an already-installed version can differ from this process.
        _ = current
        return matches[0]
    }

    private static func parseWrappedVersion(
        _ line: String,
        prefix: String,
        suffix: String
    ) -> String? {
        guard line.hasPrefix(prefix), line.hasSuffix(suffix),
              line.count > prefix.count + suffix.count
        else {
            return nil
        }
        return parseVersion(String(line.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    private static func parseVersion(_ rawValue: String) -> String? {
        let value = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        guard value.utf8.count <= 64, !value.isEmpty else { return nil }

        let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let versionAndPrerelease = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard versionAndPrerelease.count <= 2 else { return nil }
        let core = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy(isNumericIdentifier) else { return nil }

        if versionAndPrerelease.count == 2,
           !isValidIdentifiers(versionAndPrerelease[1], allowNumericLeadingZero: false) {
            return nil
        }
        if buildParts.count == 2,
           !isValidIdentifiers(buildParts[1], allowNumericLeadingZero: true) {
            return nil
        }
        return value
    }

    private static func isNumericIdentifier(_ value: Substring) -> Bool {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
        else {
            return false
        }
        return value == "0" || value.first != "0"
    }

    private static func isValidIdentifiers(
        _ value: Substring,
        allowNumericLeadingZero: Bool
    ) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.utf8.allSatisfy({
                      ($0 >= 48 && $0 <= 57)
                          || ($0 >= 65 && $0 <= 90)
                          || ($0 >= 97 && $0 <= 122)
                          || $0 == 45
                  })
            else {
                return false
            }
            if !allowNumericLeadingZero,
               identifier.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
               identifier.count > 1,
               identifier.first == "0" {
                return false
            }
            return true
        }
    }
}

public protocol CLIUpdateProviding: Sendable {
    func checkForUpdate() async -> SourceAvailability<CLIUpdateStatus>
}

/// Performs a bounded, read-only update check using only the approved CLI
/// candidates from `DarkbloomSourcePolicy`.
public struct CLIUpdateClient: CLIUpdateProviding, Sendable {
    public static let processTimeout: Duration = .seconds(25)
    public static let outputLimit = CLIUpdateParser.maximumPayloadBytes

    public let policy: DarkbloomSourcePolicy
    private let runner: any ProcessExecuting
    private let now: @Sendable () -> Date
    private let testOnlyExecutable: URL?

    public init(
        policy: DarkbloomSourcePolicy,
        runner: any ProcessExecuting = CappedProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.runner = runner
        self.now = now
        self.testOnlyExecutable = nil
    }

    init(
        policy: DarkbloomSourcePolicy,
        runner: any ProcessExecuting,
        now: @escaping @Sendable () -> Date,
        testOnlyExecutable: URL
    ) {
        self.policy = policy
        self.runner = runner
        self.now = now
        self.testOnlyExecutable = testOnlyExecutable
    }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        runner: any ProcessExecuting = CappedProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            policy: DarkbloomSourcePolicy(
                homeDirectory: homeDirectory,
                environmentPath: environmentPath
            ),
            runner: runner,
            now: now
        )
    }

    public func checkForUpdate() async -> SourceAvailability<CLIUpdateStatus> {
        let capturedAt = now()
        guard capturedAt.timeIntervalSince1970.isFinite else {
            return .unavailable(reason: "Darkbloom CLI update status is unavailable")
        }
        guard let executable = resolveExecutable() else {
            return .unavailable(reason: "Darkbloom CLI update status is unavailable")
        }

        let command = CLIUpdateCommand.checkOnly(
            executable: executable,
            config: policy.providerConfig
        )
        do {
            let result = try await runner.run(
                command,
                timeout: Self.processTimeout,
                outputLimit: Self.outputLimit,
                onOutput: nil
            )
            guard result.exitCode == 0 else {
                return .unavailable(reason: "Darkbloom CLI update status is unavailable")
            }
            let status = try CLIUpdateParser.parse(result.standardOutput)
            return .available(value: status, capturedAt: capturedAt)
        } catch {
            // Never surface stderr, raw runner errors, paths, or release URLs.
            return .unavailable(reason: "Darkbloom CLI update status is unavailable")
        }
    }

    private func resolveExecutable() -> URL? {
        if let testOnlyExecutable { return testOnlyExecutable }
        return policy.cliCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
