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

public protocol ModelWarmupTransporting: Sendable {
    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> ModelWarmupTransportResponse
}

public protocol ModelWarmupRequesting: Sendable {
    func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelWarmupResponseUsage?
}

public struct ModelWarmupClient: ModelWarmupRequesting, Sendable {
    public static let maximumResponseBytes = 65_536

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
        let request = try ModelWarmupRequest.make(
            discovery: discovery,
            modelID: modelID
        )
        let response: ModelWarmupTransportResponse
        do {
            response = try await transport.send(
                request.urlRequest,
                maximumResponseBytes: Self.maximumResponseBytes
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
