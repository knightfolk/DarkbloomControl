import Foundation

/// Verified model IDs for one chat route, captured from a successful
/// authenticated `GET /v1/models`. The chat model picker only ever offers
/// IDs from this snapshot; nothing is guessed or carried over between routes.
public struct ChatModelListSnapshot: Equatable, Sendable {
    public static let maximumResponseBytes = 256 * 1_024
    public static let maximumModels = 128

    public let modelIDs: [String]
    public let capturedAt: Date

    public init(modelIDs: [String], capturedAt: Date) {
        self.modelIDs = modelIDs
        self.capturedAt = capturedAt
    }
}

public enum ChatModelListParser {
    /// Parses the OpenAI-compatible `{"object": "list", "data": [{"id": …}]}`
    /// shape served by both the local endpoint and the Darkbloom network.
    /// `object` is validated when present; per-model display fields beyond
    /// `id` are ignored. Unknown, blank, duplicated or oversized IDs fail the
    /// parse so a picker can never offer an unverified model.
    public static func parse(_ data: Data, capturedAt: Date) throws -> ChatModelListSnapshot {
        guard data.count <= ChatModelListSnapshot.maximumResponseBytes else {
            throw ChatClientError.responseTooLarge
        }
        struct Envelope: Decodable {
            struct Entry: Decodable {
                let id: String?
                let object: String?
            }
            let object: String?
            let data: [Entry]?
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ChatClientError.invalidResponse
        }
        if let object = envelope.object, object != "list" {
            throw ChatClientError.invalidResponse
        }
        guard let entries = envelope.data else { throw ChatClientError.invalidResponse }
        guard entries.count <= ChatModelListSnapshot.maximumModels else {
            throw ChatClientError.invalidResponse
        }
        var ids: [String] = []
        for entry in entries {
            guard let id = entry.id,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  id.utf8.count <= 512,
                  !ids.contains(id)
            else { throw ChatClientError.invalidResponse }
            ids.append(id)
        }
        return ChatModelListSnapshot(modelIDs: ids, capturedAt: capturedAt)
    }
}

/// One turn in a chat completion request. Roles are restricted to the plain
/// text conversation roles; multimodal content parts are not supported.
public struct ChatMessagePayload: Equatable, Sendable, Codable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// The validated, non-streaming completion request. The URL is fixed by the
/// route; the body is bounded before transmission.
public struct ChatCompletionRequest: CustomStringConvertible, Sendable {
    public static let maximumBodyBytes = 256 * 1_024
    public static let maximumMessages = 64
    public static let maximumMessageCharacters = 16_384
    public static let networkTimeoutInterval: TimeInterval = 300
    public static let localTimeoutInterval: TimeInterval = 300

    public let urlRequest: URLRequest

    public var description: String {
        "POST \(urlRequest.url?.absoluteString ?? "invalid-url") (chat completion)"
    }

    /// Builds the request for the Darkbloom network route. The host is fixed;
    /// there is no redirect following and no route derivation from user text.
    public static func makeNetwork(
        consumerKey: String,
        model: String,
        messages: [ChatMessagePayload]
    ) throws -> Self {
        try make(
            url: URL(string: "https://api.darkbloom.dev/v1/chat/completions")!,
            token: consumerKey,
            model: model,
            messages: messages,
            timeout: networkTimeoutInterval
        )
    }

    /// Builds the request for the local hosting endpoint. `origin` must be a
    /// normalized `ChatLocalEndpoint` origin (`scheme://host[:port]`, no
    /// path); a URL carrying a path is rejected so `/v1` can never be
    /// doubled. `token` nil means an explicitly unauthenticated endpoint and
    /// omits the Authorization header; a non-nil token must be usable. The
    /// only base-URL normalization lives in `ChatLocalEndpoint.make`.
    public static func makeLocal(
        origin: URL,
        token: String?,
        model: String,
        messages: [ChatMessagePayload]
    ) throws -> Self {
        if let token {
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  token.utf8.count <= 256
            else { throw ChatClientError.invalidEndpoint }
        }
        guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http" || components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = URL(string: origin.absoluteString + "/v1/chat/completions")
        else { throw ChatClientError.invalidEndpoint }
        return try make(url: url, token: token, model: model, messages: messages, timeout: localTimeoutInterval)
    }

    private static func make(
        url: URL,
        token: String?,
        model: String,
        messages: [ChatMessagePayload],
        timeout: TimeInterval
    ) throws -> Self {
        try validate(model: model, messages: messages)
        let body = try Self.encode(model: model, messages: messages)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return Self(urlRequest: request)
    }

    static func validate(model: String, messages: [ChatMessagePayload]) throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 512
        else { throw ChatClientError.missingModelID }
        guard (1...maximumMessages).contains(messages.count) else {
            throw ChatClientError.requestTooLarge
        }
        for message in messages where message.content.utf8.count > maximumMessageCharacters {
            throw ChatClientError.requestTooLarge
        }
    }

    static func encode(model: String, messages: [ChatMessagePayload]) throws -> Data {
        struct Body: Encodable {
            let model: String
            let messages: [ChatMessagePayload]
            let stream = false
        }
        let data = try JSONEncoder().encode(Body(model: model, messages: messages))
        guard data.count <= maximumBodyBytes else { throw ChatClientError.requestTooLarge }
        return data
    }
}

/// The outcome of one successful non-streaming completion. `content` is the
/// assistant's visible text; usage counters are optional because the local
/// endpoint may omit them.
public struct ChatCompletionOutcome: Equatable, Sendable {
    public let content: String
    public let model: String?
    public let finishReason: String?
    public let promptTokens: Int?
    public let completionTokens: Int?

    public init(
        content: String,
        model: String? = nil,
        finishReason: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.content = content
        self.model = model
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum ChatCompletionParser {
    public static func parse(_ data: Data) throws -> ChatCompletionOutcome {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String?
                    let content: String?
                }
                let message: Message?
                let finishReason: String?

                enum CodingKeys: String, CodingKey {
                    case message
                    case finishReason = "finish_reason"
                }
            }
            struct Usage: Decodable {
                let promptTokens: Int?
                let completionTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                }
            }
            let model: String?
            let choices: [Choice]?
            let usage: Usage?
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ChatClientError.invalidResponse
        }
        guard let choice = response.choices?.first,
              let message = choice.message,
              let content = message.content
        else { throw ChatClientError.invalidResponse }
        if let role = message.role, role != "assistant" {
            throw ChatClientError.invalidResponse
        }
        if let usage = response.usage {
            let valid = { (value: Int?) in value == nil || value! >= 0 }
            guard valid(usage.promptTokens), valid(usage.completionTokens) else {
                throw ChatClientError.invalidResponse
            }
        }
        if let model = response.model, model.utf8.count > 512 {
            throw ChatClientError.invalidResponse
        }
        if let finishReason = choice.finishReason, finishReason.utf8.count > 64 {
            throw ChatClientError.invalidResponse
        }
        return ChatCompletionOutcome(
            content: content,
            model: response.model,
            finishReason: choice.finishReason,
            promptTokens: response.usage?.promptTokens,
            completionTokens: response.usage?.completionTokens
        )
    }
}
