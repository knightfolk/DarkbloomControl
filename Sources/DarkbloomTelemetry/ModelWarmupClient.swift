import Foundation

public struct ModelWarmupResponseUsage: Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum ModelWarmupClientError: Error, Equatable, Sendable {
    case invalidModel
    case unauthorized
    case busy
    case unsupported
    case redirected
    case httpStatus(Int)
    case responseTooLarge
    case invalidResponse
}

extension ModelWarmupClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidModel:
            "The selected model is invalid"
        case .unauthorized:
            "The local provider rejected its endpoint credential"
        case .busy:
            "The provider is busy and did not accept the model warmup"
        case .unsupported:
            "This provider does not support protected model switching"
        case .redirected:
            "The local provider attempted an unsafe redirect"
        case .httpStatus(let status):
            "The local provider returned HTTP \(status)"
        case .responseTooLarge:
            "The local provider response exceeded the allowed size"
        case .invalidResponse:
            "The local provider response was invalid"
        }
    }
}

public struct ModelWarmupRequest: Sendable {
    private struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    public let urlRequest: URLRequest

    public static func make(
        discovery: LocalEndpointDiscovery,
        modelID: String
    ) throws -> Self {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelWarmupClientError.invalidModel
        }
        let url = discovery.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(discovery.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(
            model: modelID,
            messages: [.init(role: "user", content: "Reply with OK.")],
            stream: false,
            maxTokens: 1
        ))
        return Self(urlRequest: request)
    }
}

public struct ModelWarmupTransportResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public enum ModelWarmupTransportError: Error, Equatable, Sendable {
    case responseTooLarge
    case invalidResponse
}

/// Called at the transport boundary, immediately before a provider request is
/// handed to the underlying networking implementation.  This is deliberately
/// lower-level than a UI progress phase: a phase may be emitted and then
/// cancelled before any request is dispatched.
public typealias ModelWarmupRequestLaunchObserver = @Sendable () -> Void

public protocol ModelWarmupTransporting: Sendable {
    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> ModelWarmupTransportResponse
    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws -> ModelWarmupTransportResponse
}

public extension ModelWarmupTransporting {
    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws -> ModelWarmupTransportResponse {
        try await send(request, maximumResponseBytes: maximumResponseBytes)
    }
}

public enum ModelWarmupLoadSafety: Equatable, Sendable {
    case mayEvictResident
    case preservesResidents
}

public struct ModelControlSnapshot: Decodable, Equatable, Sendable {
    public let apiVersion: Int
    public let protectedLoad: Bool
    public let idleRetire: Bool
    public let maxModelSlots: Int
    public let loadedModels: [String]
    /// Exact model identifiers accepted by the running provider. `nil` means
    /// the provider predates this proof field, not that it advertises none.
    public let advertisedModels: [String]?
    /// Exact model IDs selected when this provider process launched. Unlike
    /// `advertisedModels`, this does not change during coordinator prefetch.
    public let launchModels: [String]?
    /// Raw provider configuration loaded by this exact process. These proof
    /// fields are optional so an older provider remains readable but cannot
    /// falsely clear a pending restart requirement.
    public let configuredMaxModelSlots: Int?
    public let configuredEnabledModels: [String]?
    public let configuredPreloadModels: [String]?

    public init(
        apiVersion: Int,
        protectedLoad: Bool,
        idleRetire: Bool,
        maxModelSlots: Int,
        loadedModels: [String],
        advertisedModels: [String]? = nil,
        launchModels: [String]? = nil,
        configuredMaxModelSlots: Int? = nil,
        configuredEnabledModels: [String]? = nil,
        configuredPreloadModels: [String]? = nil
    ) {
        self.apiVersion = apiVersion
        self.protectedLoad = protectedLoad
        self.idleRetire = idleRetire
        self.maxModelSlots = maxModelSlots
        self.loadedModels = loadedModels
        self.advertisedModels = advertisedModels
        self.launchModels = launchModels
        self.configuredMaxModelSlots = configuredMaxModelSlots
        self.configuredEnabledModels = configuredEnabledModels
        self.configuredPreloadModels = configuredPreloadModels
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case protectedLoad = "protected_load"
        case idleRetire = "idle_retire"
        case maxModelSlots = "max_model_slots"
        case loadedModels = "loaded_models"
        case advertisedModels = "advertised_models"
        case launchModels = "launch_models"
        case configuredMaxModelSlots = "configured_max_model_slots"
        case configuredEnabledModels = "enabled_models"
        case configuredPreloadModels = "preload_models"
    }
}

public protocol ModelWarmupRequesting: Sendable {
    var loadSafety: ModelWarmupLoadSafety { get }
    func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelWarmupResponseUsage?
    func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws -> ModelWarmupResponseUsage?
    func controlSnapshot(
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelControlSnapshot?
    func retire(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws
    func retire(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws
}

public extension ModelWarmupRequesting {
    func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws -> ModelWarmupResponseUsage? {
        try await warm(modelID: modelID, using: discovery)
    }

    var loadSafety: ModelWarmupLoadSafety { .mayEvictResident }
    func controlSnapshot(
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelControlSnapshot? { nil }
    func retire(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws {
        throw ModelWarmupClientError.unsupported
    }

    func retire(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws {
        try await retire(modelID: modelID, using: discovery)
    }
}

public struct ModelWarmupClient: ModelWarmupRequesting, Sendable {
    public static let maximumResponseBytes = 65_536
    public let loadSafety: ModelWarmupLoadSafety = .mayEvictResident

    private let transport: any ModelWarmupTransporting

    public init() {
        transport = URLSessionModelWarmupTransport(session: Self.ephemeralSession())
    }

    public init(session: URLSession) {
        transport = URLSessionModelWarmupTransport(session: session)
    }

    init(transport: any ModelWarmupTransporting) {
        self.transport = transport
    }

    public func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelWarmupResponseUsage? {
        try await warm(modelID: modelID, using: discovery, onLaunch: nil)
    }

    public func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws -> ModelWarmupResponseUsage? {
        let request = try ModelWarmupRequest.make(
            discovery: discovery,
            modelID: modelID
        )
        let response: ModelWarmupTransportResponse
        do {
            response = try await transport.send(
                request.urlRequest,
                maximumResponseBytes: Self.maximumResponseBytes,
                onLaunch: onLaunch
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ModelWarmupTransportError.responseTooLarge {
            throw ModelWarmupClientError.responseTooLarge
        } catch ModelWarmupTransportError.invalidResponse {
            throw ModelWarmupClientError.invalidResponse
        }

        switch response.statusCode {
        case 200..<300:
            return Self.decodeUsage(response.data)
        case 301...399:
            throw ModelWarmupClientError.redirected
        case 401, 403:
            throw ModelWarmupClientError.unauthorized
        case 409, 423, 429:
            throw ModelWarmupClientError.busy
        default:
            throw ModelWarmupClientError.httpStatus(response.statusCode)
        }
    }

    private static func decodeUsage(_ data: Data) -> ModelWarmupResponseUsage? {
        struct Response: Decodable {
            struct Usage: Decodable {
                let promptTokens: Int
                let completionTokens: Int

                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                }
            }
            let usage: Usage?
        }

        guard !data.isEmpty,
              let usage = try? JSONDecoder().decode(Response.self, from: data).usage
        else { return nil }
        return ModelWarmupResponseUsage(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens
        )
    }

    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }
}

/// Client for the provider's authenticated operator-only model-control API.
/// Its load route is contractually non-evicting; retirement is a separate,
/// exact-model operation that the provider refuses while that model is busy.
public struct ProtectedModelControlClient: ModelWarmupRequesting, Sendable {
    public static let maximumResponseBytes = 65_536
    public let loadSafety: ModelWarmupLoadSafety = .preservesResidents

    private let transport: any ModelWarmupTransporting

    public init() {
        transport = URLSessionModelWarmupTransport(session: Self.ephemeralSession())
    }

    public init(session: URLSession) {
        transport = URLSessionModelWarmupTransport(session: session)
    }

    init(transport: any ModelWarmupTransporting) {
        self.transport = transport
    }

    public func controlSnapshot(
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelControlSnapshot? {
        let request = try Self.request(
            discovery: discovery, path: "provider/model-control", method: "GET")
        let response = try await send(request)
        guard response.statusCode != 404 else { return nil }
        try Self.requireSuccess(response.statusCode)
        return try Self.decodeSnapshot(response.data)
    }

    public func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelWarmupResponseUsage? {
        try await warm(modelID: modelID, using: discovery, onLaunch: nil)
    }

    public func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws -> ModelWarmupResponseUsage? {
        let request = try Self.request(
            discovery: discovery, path: "provider/model-control/load",
            method: "POST", modelID: modelID)
        let response = try await send(request, onLaunch: onLaunch)
        try Self.requireSuccess(response.statusCode)
        _ = try Self.decodeSnapshot(response.data)
        return nil
    }

    public func retire(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws {
        try await retire(modelID: modelID, using: discovery, onLaunch: nil)
    }

    public func retire(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws {
        let request = try Self.request(
            discovery: discovery, path: "provider/model-control/retire",
            method: "POST", modelID: modelID)
        let response = try await send(request, onLaunch: onLaunch)
        try Self.requireSuccess(response.statusCode)
        _ = try Self.decodeSnapshot(response.data)
    }

    private func send(
        _ request: URLRequest,
        onLaunch: ModelWarmupRequestLaunchObserver? = nil
    ) async throws -> ModelWarmupTransportResponse {
        do {
            return try await transport.send(
                request,
                maximumResponseBytes: Self.maximumResponseBytes,
                onLaunch: onLaunch
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ModelWarmupTransportError.responseTooLarge {
            throw ModelWarmupClientError.responseTooLarge
        } catch {
            throw ModelWarmupClientError.invalidResponse
        }
    }

    private static func request(
        discovery: LocalEndpointDiscovery,
        path: String,
        method: String,
        modelID: String? = nil
    ) throws -> URLRequest {
        if let modelID,
           modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ModelWarmupClientError.invalidModel
        }
        let url = discovery.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: method == "GET" ? 5 : 600)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(discovery.apiKey)", forHTTPHeaderField: "Authorization")
        if let modelID {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["model": modelID])
        }
        return request
    }

    private static func requireSuccess(_ status: Int) throws {
        switch status {
        case 200..<300:
            return
        case 301...399:
            throw ModelWarmupClientError.redirected
        case 401, 403:
            throw ModelWarmupClientError.unauthorized
        case 404:
            throw ModelWarmupClientError.unsupported
        case 409, 423, 429:
            throw ModelWarmupClientError.busy
        default:
            throw ModelWarmupClientError.httpStatus(status)
        }
    }

    private static func decodeSnapshot(_ data: Data) throws -> ModelControlSnapshot {
        guard let snapshot = try? JSONDecoder().decode(ModelControlSnapshot.self, from: data),
              snapshot.apiVersion == 1,
              snapshot.protectedLoad,
              snapshot.idleRetire,
              snapshot.maxModelSlots > 0
        else { throw ModelWarmupClientError.invalidResponse }
        return snapshot
    }

    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }
}

private final class RejectingRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private actor URLSessionModelWarmupTransport: ModelWarmupTransporting {
    private let session: URLSession
    private let redirectDelegate = RejectingRedirectsDelegate()

    init(session: URLSession) {
        self.session = session
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> ModelWarmupTransportResponse {
        try await send(
            request,
            maximumResponseBytes: maximumResponseBytes,
            onLaunch: nil
        )
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws -> ModelWarmupTransportResponse {
        try Task.checkCancellation()
        onLaunch?()
        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: redirectDelegate
        )
        guard let http = response as? HTTPURLResponse else {
            throw ModelWarmupTransportError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 4_096))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw ModelWarmupTransportError.responseTooLarge
            }
            data.append(byte)
        }
        return ModelWarmupTransportResponse(statusCode: http.statusCode, data: data)
    }
}
