import Darwin
import Foundation

public struct LocalEndpointDiscovery: Sendable {
    public let baseURL: URL
    public let apiKey: String
    public let evidenceAt: Date

    public init(baseURL: URL, apiKey: String, evidenceAt: Date) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.evidenceAt = evidenceAt
    }
}

public enum LocalEndpointDiscoveryError: Error, Equatable, Sendable {
    case unavailable
    case notRegularFile
    case insecureOwner
    case insecurePermissions
    case tooLarge
    case stale
    case future
    case invalidRecord
    case insecureEndpoint
}

extension LocalEndpointDiscoveryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Live model switching is unavailable until the provider starts with its local endpoint"
        case .notRegularFile:
            "Local endpoint discovery is not a regular file"
        case .insecureOwner:
            "Local endpoint discovery has an unexpected owner"
        case .insecurePermissions:
            "Local endpoint discovery permissions are not private"
        case .tooLarge:
            "Local endpoint discovery exceeds the allowed size"
        case .stale:
            "Local endpoint discovery belongs to an older provider run"
        case .future:
            "Local endpoint discovery timestamp is in the future"
        case .invalidRecord:
            "Local endpoint discovery is invalid"
        case .insecureEndpoint:
            "Local endpoint discovery does not name an authenticated loopback endpoint"
        }
    }
}

public protocol LocalEndpointDiscoveryReading: Sendable {
    func read(for provider: DaemonState) async throws -> LocalEndpointDiscovery
}

struct LocalEndpointFileMetadata: Equatable, Sendable {
    let ownerID: uid_t
    let permissions: Int
    let size: Int
    let modifiedAt: Date
    let isRegularFile: Bool

    init(
        ownerID: uid_t,
        permissions: Int,
        size: Int,
        modifiedAt: Date,
        isRegularFile: Bool
    ) {
        self.ownerID = ownerID
        self.permissions = permissions
        self.size = size
        self.modifiedAt = modifiedAt
        self.isRegularFile = isRegularFile
    }
}

public struct LocalEndpointDiscoveryReader: LocalEndpointDiscoveryReading, Sendable {
    private struct Record: Decodable {
        let baseURL: URL
        let apiKey: String

        enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case apiKey = "api_key"
        }
    }

    private let url: URL
    private let expectedOwnerID: uid_t
    private let now: @Sendable () -> Date

    public init(
        url: URL,
        expectedOwnerID: uid_t = getuid(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.url = url
        self.expectedOwnerID = expectedOwnerID
        self.now = now
    }

    public func read(for provider: DaemonState) async throws -> LocalEndpointDiscovery {
        let opened = try Self.openAndRead(
            url: url,
            byteLimit: DarkbloomSourcePolicy.localEndpointDiscoveryByteLimit
        )
        let currentTime = now()
        try Self.validate(
            metadata: opened.metadata,
            expectedOwnerID: expectedOwnerID,
            providerStartedAt: provider.startedAt,
            now: currentTime
        )

        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: opened.data)
        } catch {
            throw LocalEndpointDiscoveryError.invalidRecord
        }
        let apiKey = record.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw LocalEndpointDiscoveryError.invalidRecord
        }
        guard Self.isApprovedLoopbackBaseURL(record.baseURL) else {
            throw LocalEndpointDiscoveryError.insecureEndpoint
        }
        return LocalEndpointDiscovery(
            baseURL: record.baseURL,
            apiKey: apiKey,
            evidenceAt: opened.metadata.modifiedAt
        )
    }

    static func validate(
        metadata: LocalEndpointFileMetadata,
        expectedOwnerID: uid_t,
        providerStartedAt: TimeInterval,
        now: Date
    ) throws {
        guard metadata.isRegularFile else {
            throw LocalEndpointDiscoveryError.notRegularFile
        }
        guard metadata.ownerID == expectedOwnerID else {
            throw LocalEndpointDiscoveryError.insecureOwner
        }
        guard metadata.permissions & 0o077 == 0 else {
            throw LocalEndpointDiscoveryError.insecurePermissions
        }
        guard metadata.size > 0,
              metadata.size <= DarkbloomSourcePolicy.localEndpointDiscoveryByteLimit
        else {
            throw LocalEndpointDiscoveryError.tooLarge
        }
        guard providerStartedAt.isFinite,
              metadata.modifiedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite
        else {
            throw LocalEndpointDiscoveryError.stale
        }
        guard metadata.modifiedAt.timeIntervalSince1970 >= providerStartedAt - 5 else {
            throw LocalEndpointDiscoveryError.stale
        }
        guard metadata.modifiedAt <= now.addingTimeInterval(1) else {
            throw LocalEndpointDiscoveryError.future
        }
    }

    private static func isApprovedLoopbackBaseURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              let port = url.port,
              (1...65_535).contains(port),
              let host = url.host?.lowercased(),
              ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)
        else { return false }
        return url.path == "/v1" || url.path == "/v1/"
    }

    private static func openAndRead(
        url: URL,
        byteLimit: Int
    ) throws -> (data: Data, metadata: LocalEndpointFileMetadata) {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw LocalEndpointDiscoveryError.notRegularFile }
            throw LocalEndpointDiscoveryError.unavailable
        }
        defer { Darwin.close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            throw LocalEndpointDiscoveryError.unavailable
        }
        let fileType = fileStatus.st_mode & S_IFMT
        let metadata = LocalEndpointFileMetadata(
            ownerID: fileStatus.st_uid,
            permissions: Int(fileStatus.st_mode & 0o777),
            size: Int(fileStatus.st_size),
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(fileStatus.st_mtimespec.tv_sec)
                    + TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            isRegularFile: fileType == S_IFREG
        )
        guard metadata.isRegularFile else {
            throw LocalEndpointDiscoveryError.notRegularFile
        }
        guard metadata.size <= byteLimit else {
            throw LocalEndpointDiscoveryError.tooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let remaining = byteLimit + 1 - data.count
            guard remaining > 0 else {
                throw LocalEndpointDiscoveryError.tooLarge
            }
            let readCount = Darwin.read(
                descriptor,
                &buffer,
                min(buffer.count, remaining)
            )
            if readCount == 0 { break }
            guard readCount > 0 else {
                if errno == EINTR { continue }
                throw LocalEndpointDiscoveryError.unavailable
            }
            data.append(contentsOf: buffer.prefix(readCount))
        }
        guard data.count <= byteLimit else {
            throw LocalEndpointDiscoveryError.tooLarge
        }
        return (data, metadata)
    }
}
