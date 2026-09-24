import Foundation

/// Shared execution for chat-route requests: one bounded body read, redirect
/// rejection inherited from the session, whitelisted error-code matching, and
/// cancellation at every await. Server free text is never surfaced. Error
/// bodies are read only up to the small error cap, never the (much larger)
/// success capacity.
enum ChatRouteExecutor {
    static let errorBodyCap = 4 * 1_024

    static func execute<Response>(
        request: URLRequest,
        session: URLSession,
        successCapacity: Int,
        parse: (Data) throws -> Response
    ) async throws -> Response {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw ChatClientError.invalidResponse
        }
        let succeeded = (200..<300).contains(http.statusCode)
        if succeeded, response.expectedContentLength > Int64(successCapacity) {
            throw ChatClientError.responseTooLarge
        }
        let data: Data
        do {
            data = try await ChatBoundedBody.collect(
                bytes,
                maximumBytes: succeeded ? successCapacity : errorBodyCap
            )
        } catch let error as ChatClientError {
            // An oversized error body must not mask the authoritative HTTP
            // status — a 402 stays a payment decision even if its body is
            // oversized or unparseable. Discard the body and map the status.
            if error == .responseTooLarge, !succeeded {
                throw ChatHTTPStatusMapper.error(for: http.statusCode, code: nil)
            }
            throw error
        }
        guard succeeded else {
            throw ChatHTTPStatusMapper.error(for: http.statusCode, code: ChatErrorCodeReader.code(from: data))
        }
        return try parse(data)
    }
}

/// The live local chat endpoint as resolved from the app's hosting settings
/// or the standalone discovery record. The token is the local endpoint's own
/// bearer token; it is never a consumer API key, a provider device token, or
/// anything else, and it is exposed only inside an explicit action.
///
/// Base URL contract: this type is the single normalization point. A
/// configured unified URL like `http://127.0.0.1:8000/v1` (Hosting settings)
/// and a discovered base URL like `http://192.168.1.5:8000` both normalize to
/// the same origin form `scheme://host[:port]`; every local request path
/// (`/v1/models`, `/v1/chat/completions`) is appended exactly once from
/// there.
public struct ChatLocalEndpoint: Sendable, CustomStringConvertible, CustomReflectable {
    public let origin: URL
    private let token: String

    public var description: String {
        "ChatLocalEndpoint(origin: \(origin.absoluteString), token: present)"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin.absoluteString, "hasToken": !token.isEmpty])
    }

    /// Validates the endpoint URL (http/https, host present, no user, query
    /// or fragment) and normalizes it to its origin. Returns nil for anything
    /// else, including unusable tokens.
    public static func make(baseURL: String, token: String) -> ChatLocalEndpoint? {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              token.utf8.count <= 256,
              let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }
        var originComponents = URLComponents()
        originComponents.scheme = scheme
        originComponents.host = host
        originComponents.port = components.port
        guard let origin = originComponents.url else { return nil }
        return ChatLocalEndpoint(origin: origin, token: token)
    }

    func withToken<R>(_ body: (String) throws -> R) rethrows -> R {
        try body(token)
    }
}

public protocol ChatLocalEndpointProviding: Sendable {
    /// Resolves the current local endpoint, or nil when hosting is off and no
    /// standalone endpoint is advertised. Called before every local request so
    /// a restarted endpoint with a rotated token is picked up.
    func endpoint() async -> ChatLocalEndpoint?
}

public protocol ChatModelListing: Sendable {
    func models(now: Date) async throws -> ChatModelListSnapshot
}

public protocol ChatCompleting: Sendable {
    func complete(model: String, messages: [ChatMessagePayload]) async throws -> ChatCompletionOutcome
}

/// Chat client for this Mac's own hosting endpoint. Reachability and model
/// verification are the same authenticated `GET /v1/models` call.
public struct LocalChatClient: ChatModelListing, ChatCompleting, Sendable {
    private let endpointProvider: any ChatLocalEndpointProviding
    private let session: URLSession

    public init(
        endpointProvider: any ChatLocalEndpointProviding,
        session: URLSession? = nil
    ) {
        self.endpointProvider = endpointProvider
        self.session = session ?? ChatHTTPSession.shared
    }

    public func models(now: Date) async throws -> ChatModelListSnapshot {
        let endpoint = try await resolvedEndpoint()
        let request = try endpoint.withToken { token in
            try Self.modelsRequest(endpoint: endpoint, token: token)
        }
        return try await ChatRouteExecutor.execute(
            request: request,
            session: session,
            successCapacity: ChatModelListSnapshot.maximumResponseBytes
        ) { data in
            try ChatModelListParser.parse(data, capturedAt: now)
        }
    }

    public func complete(model: String, messages: [ChatMessagePayload]) async throws -> ChatCompletionOutcome {
        let endpoint = try await resolvedEndpoint()
        let request = try endpoint.withToken { token in
            try ChatCompletionRequest.makeLocal(
                origin: endpoint.origin,
                token: token,
                model: model,
                messages: messages
            )
        }
        return try await ChatRouteExecutor.execute(
            request: request.urlRequest,
            session: session,
            successCapacity: 1_048_576
        ) { data in
            try ChatCompletionParser.parse(data)
        }
    }

    private func resolvedEndpoint() async throws -> ChatLocalEndpoint {
        guard let endpoint = await endpointProvider.endpoint() else {
            throw ChatClientError.localEndpointUnavailable
        }
        return endpoint
    }

    private static func modelsRequest(endpoint: ChatLocalEndpoint, token: String) throws -> URLRequest {
        guard let url = URL(string: endpoint.origin.absoluteString + "/v1/models") else {
            throw ChatClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Chat client for the Darkbloom network. All requests target one fixed
/// HTTPS host and authenticate with the consumer API key supplied by the
/// keychain-backed provider; the key is never stored, logged, or persisted
/// here. A 401 is reported as a key-specific rejection.
public struct NetworkChatClient: ChatModelListing, ChatCompleting, Sendable {
    public static let modelsURL = URL(string: "https://api.darkbloom.dev/v1/models")!

    private let consumerKeyProvider: @Sendable () async -> String?
    private let session: URLSession

    public init(
        consumerKeyProvider: @escaping @Sendable () async -> String?,
        session: URLSession? = nil
    ) {
        self.consumerKeyProvider = consumerKeyProvider
        self.session = session ?? ChatHTTPSession.shared
    }

    public func models(now: Date) async throws -> ChatModelListSnapshot {
        let token = try await consumerKey()
        var request = URLRequest(url: Self.modelsURL, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await ChatRouteExecutor.execute(
                request: request,
                session: session,
                successCapacity: ChatModelListSnapshot.maximumResponseBytes
            ) { data in
                try ChatModelListParser.parse(data, capturedAt: now)
            }
        } catch ChatClientError.unauthorized {
            throw ChatClientError.consumerKeyRejected
        }
    }

    public func complete(model: String, messages: [ChatMessagePayload]) async throws -> ChatCompletionOutcome {
        let token = try await consumerKey()
        let request = try ChatCompletionRequest.makeNetwork(
            consumerKey: token,
            model: model,
            messages: messages
        )
        do {
            return try await ChatRouteExecutor.execute(
                request: request.urlRequest,
                session: session,
                successCapacity: 1_048_576
            ) { data in
                try ChatCompletionParser.parse(data)
            }
        } catch ChatClientError.unauthorized {
            throw ChatClientError.consumerKeyRejected
        }
    }

    private func consumerKey() async throws -> String {
        guard let token = await consumerKeyProvider(), !token.isEmpty else {
            throw ChatClientError.missingConsumerKey
        }
        return token
    }
}
