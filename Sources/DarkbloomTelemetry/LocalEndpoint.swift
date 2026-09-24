import Darwin
import Foundation

/// The live local endpoint as advertised by `darkbloom local --json`.
/// `apiKey` is a secret: it exists in memory only for the explicit
/// user-triggered copy action and never appears in diagnostics, logs,
/// persistence, or the type's printed description.
public struct LocalEndpointRecord: Equatable, Sendable {
    public let baseURL: String
    private let apiKey: String
    public let host: String
    public let port: UInt16
    public let processID: Int32
    public let version: String?
    public let updatedAt: Date?

    public init(
        baseURL: String,
        apiKey: String,
        host: String,
        port: UInt16,
        processID: Int32,
        version: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.host = host
        self.port = port
        self.processID = processID
        self.version = version
        self.updatedAt = updatedAt
    }

    /// False only when the endpoint was started with authentication disabled,
    /// which this app never does. Surfaced so the UI can warn honestly.
    public var hasBearerToken: Bool { !apiKey.isEmpty }

    /// Gives the secret to a synchronous, explicit user action without
    /// exposing it as a readable stored property on the endpoint record.
    public func withBearerToken(_ action: (String) -> Void) {
        guard hasBearerToken else { return }
        action(apiKey)
    }
}

extension LocalEndpointRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let token = hasBearerToken ? "present" : "absent"
        return "LocalEndpointRecord(baseURL: \(baseURL), host: \(host), port: \(port), processID: \(processID), bearerToken: \(token))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "baseURL": baseURL,
            "host": host,
            "port": port,
            "processID": processID,
            "version": version as Any,
            "updatedAt": updatedAt as Any,
            "hasBearerToken": hasBearerToken,
        ])
    }
}

public enum LocalEndpointParseError: Error, Equatable, Sendable {
    case invalidPayload
}

public enum LocalEndpointAvailability: Equatable, Sendable {
    /// No live local endpoint is advertised. The reason is a fixed string,
    /// never CLI output.
    case none(String)
    case live(LocalEndpointRecord)
}

/// Exposes the provider's bearer token only inside an explicit user action.
public protocol LocalEndpointTokenProviding: Sendable {
    @discardableResult
    func withBearerToken(_ action: (String) -> Void) -> Bool
}

/// Safely reads the provider-owned `0600` token file without following a
/// symlink. The token is passed to the caller synchronously and is never
/// returned as a value that could accidentally be logged or persisted.
public struct LocalEndpointTokenFile: LocalEndpointTokenProviding, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    @discardableResult
    public func withBearerToken(_ action: (String) -> Void) -> Bool {
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o077 == 0,
              metadata.st_mode & 0o400 != 0,
              metadata.st_uid == getuid(),
              metadata.st_size > 0,
              metadata.st_size <= 256
        else { return false }

        var data = Data(count: Int(metadata.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.read(descriptor, baseAddress, buffer.count)
        }
        guard bytesRead == data.count,
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              token.hasPrefix("dk-local-"),
              token.utf8.count <= 256,
              token.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                      || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
              })
        else { return false }

        action(token)
        return true
    }
}

public enum LocalEndpointParser {
    public static let maximumPayloadBytes = DarkbloomSourcePolicy.localEndpointOutputByteLimit

    /// Parses the discovery JSON. An empty object `{}` is the CLI's documented
    /// "no live local server" answer and decodes to nil; anything malformed or
    /// out of bounds is rejected.
    public static func parse(_ data: Data) throws -> LocalEndpointRecord? {
        guard data.count <= maximumPayloadBytes else {
            throw LocalEndpointParseError.invalidPayload
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.allSatisfy({ ["base_url", "api_key", "host", "port", "pid", "version", "updated_at"].contains($0) })
        else {
            throw LocalEndpointParseError.invalidPayload
        }
        guard !object.isEmpty else { return nil }

        guard let baseURL = object["base_url"] as? String,
              !baseURL.isEmpty, baseURL.utf8.count <= 256,
              let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { throw LocalEndpointParseError.invalidPayload }
        let apiKey = object["api_key"] as? String ?? ""
        guard apiKey.utf8.count <= 256 else { throw LocalEndpointParseError.invalidPayload }
        guard let host = object["host"] as? String,
              !host.isEmpty, host.utf8.count <= 64
        else { throw LocalEndpointParseError.invalidPayload }
        guard let portValue = object["port"] as? Int,
              (1...65_535).contains(portValue)
        else { throw LocalEndpointParseError.invalidPayload }
        let effectiveURLPort = components.port ?? (scheme == "https" ? 443 : 80)
        if effectiveURLPort != portValue {
            throw LocalEndpointParseError.invalidPayload
        }
        guard let pid = object["pid"] as? Int, pid > 0, pid <= Int(Int32.max)
        else { throw LocalEndpointParseError.invalidPayload }
        let version = object["version"] as? String
        if let version, (version.isEmpty || version.utf8.count > 64) {
            throw LocalEndpointParseError.invalidPayload
        }

        var updatedAt: Date?
        if let stamp = object["updated_at"] {
            if let seconds = stamp as? Double, seconds.isFinite, seconds >= 0 {
                updatedAt = Date(timeIntervalSince1970: seconds)
            } else if let text = stamp as? String,
                      let date = ISO8601DateFormatter().date(from: text) {
                updatedAt = date
            } else {
                throw LocalEndpointParseError.invalidPayload
            }
        }

        return LocalEndpointRecord(
            baseURL: baseURL,
            apiKey: apiKey,
            host: host,
            port: UInt16(portValue),
            processID: Int32(pid),
            version: version,
            updatedAt: updatedAt
        )
    }
}

public protocol LocalEndpointFetching: Sendable {
    func fetch() async -> LocalEndpointAvailability
}

/// Performs the documented on-demand `darkbloom local --json` read through the
/// bounded runner. Nonzero exit means no live endpoint; stderr and raw errors
/// are never surfaced.
public struct LocalEndpointClient: LocalEndpointFetching, Sendable {
    public static let noLiveEndpointReason = "No live local endpoint is advertised"

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

    public func fetch() async -> LocalEndpointAvailability {
        guard capturedNowIsFinite(), let executable = resolveExecutable() else {
            return .none(Self.noLiveEndpointReason)
        }
        do {
            let result = try await runner.run(
                DarkbloomCommand.localEndpointInfo(executable: executable),
                timeout: DarkbloomSourcePolicy.localEndpointTimeout,
                outputLimit: DarkbloomSourcePolicy.localEndpointOutputByteLimit,
                onOutput: nil
            )
            guard let record = try LocalEndpointParser.parse(result.standardOutput) else {
                return .none(Self.noLiveEndpointReason)
            }
            return .live(record)
        } catch {
            // Includes the documented nonzero exit when no server is live.
            return .none(Self.noLiveEndpointReason)
        }
    }

    private func capturedNowIsFinite() -> Bool {
        now().timeIntervalSince1970.isFinite
    }

    private func resolveExecutable() -> URL? {
        if let testOnlyExecutable { return testOnlyExecutable }
        return policy.cliCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
