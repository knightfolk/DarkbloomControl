import Foundation

/// Transport primitives shared by the local-endpoint and Darkbloom-network
/// chat routes. Both routes speak the OpenAI-compatible chat contract, but
/// they are separate trust domains: the local route targets this Mac's own
/// hosting endpoint, the network route targets one fixed public HTTPS host
/// authenticated with a consumer API key that is distinct from every provider
/// credential.
///
/// Errors never carry server-provided text. A response body can echo
/// credentials or prompt content, and whitespace sanitizing is not secret
/// redaction, so every user-facing message here is a fixed local string; the
/// server's machine-readable `error.code` token is matched against a
/// whitelist but never displayed.
public enum ChatClientError: Error, Equatable, Sendable {
    /// No endpoint configuration exists for the local route (hosting is off
    /// and no live standalone endpoint is advertised).
    case localEndpointUnavailable
    case missingModelID
    case missingConsumerKey
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case requestTooLarge
    /// 401/403 authentication failure on the local endpoint token.
    case unauthorized
    /// 401 on the network route: specifically the consumer API key was
    /// rejected. No provider credential is ever tried in its place.
    case consumerKeyRejected
    /// 402: the network's authoritative decision that the account balance or
    /// key quota cannot cover the request's reservation. Never retried.
    case paymentRequired
    /// 404 with `model_not_found`: the model is not in the route's catalog.
    case modelNotFound
    /// 403 with `model_not_allowed`: the key may not use the model.
    case modelNotAllowed
    case httpStatus(Int)

    public var isPaymentRequired: Bool {
        self == .paymentRequired
    }
}

extension ChatClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .localEndpointUnavailable:
            "No local chat endpoint is configured. Start local hosting first, or start a new chat on the Darkbloom network route."
        case .missingModelID:
            "Choose a model before sending."
        case .missingConsumerKey:
            "A consumer API key is required for the Darkbloom network route. Add one in Chat settings."
        case .invalidEndpoint:
            "The chat endpoint address is invalid."
        case .invalidResponse:
            "The chat response was invalid."
        case .responseTooLarge:
            "The chat response exceeded the allowed size."
        case .requestTooLarge:
            "The message is too long to send."
        case .unauthorized:
            "The local chat endpoint rejected its token. Reapply the hosting settings so a fresh token is issued."
        case .consumerKeyRejected:
            "The Darkbloom network rejected this consumer API key. Check the key or add a new one in Chat settings."
        case .paymentRequired:
            "The Darkbloom network declined the request as unpaid (insufficient credit or key spend quota). This is the network's authoritative decision; no retry was attempted."
        case .modelNotFound:
            "The route does not offer the selected model. Refresh models and choose from the verified list."
        case .modelNotAllowed:
            "This consumer API key is not allowed to use the selected model."
        case .httpStatus(let status):
            "The chat request returned HTTP \(status)."
        }
    }
}

/// A machine-readable error code decoded from an OpenAI-style error envelope.
/// Only these bounded tokens are ever read from an error body; the free-text
/// `error.message` field is deliberately ignored everywhere.
public enum ChatErrorCode: String, Decodable, Sendable {
    case modelNotFound = "model_not_found"
    case modelNotAllowed = "model_not_allowed"
    case insufficientFunds = "insufficient_funds"
    case insufficientQuota = "insufficient_quota"
}

enum ChatErrorCodeReader {
    /// Returns the whitelisted `error.code` token from an error response, or
    /// nil for absent, unknown or malformed codes. Never yields free text.
    static func code(from data: Data) -> ChatErrorCode? {
        guard data.count <= 4 * 1_024 else { return nil }
        struct Envelope: Decodable {
            struct Body: Decodable {
                let code: ChatErrorCode?
            }
            let error: Body?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.code
    }
}

/// Maps an HTTP status plus whitelisted machine code to a typed chat error
/// with a fixed local message. The code refines 403/404 semantics only. A 401
/// maps to the generic endpoint-token rejection here; the network clients
/// re-report it as the key-specific `consumerKeyRejected` at their boundary,
/// so the local and network routes keep distinct credential semantics.
public enum ChatHTTPStatusMapper {
    public static func error(for status: Int, code: ChatErrorCode?) -> ChatClientError {
        switch status {
        case 401: return .unauthorized
        case 402: return .paymentRequired
        case 403: return code == .modelNotAllowed ? .modelNotAllowed : .httpStatus(403)
        case 404: return code == .modelNotFound ? .modelNotFound : .httpStatus(404)
        default: return .httpStatus(status)
        }
    }
}

/// Collects a streamed response body with a hard byte ceiling.
enum ChatBoundedBody {
    static func collect<Bytes: AsyncSequence>(_ bytes: Bytes, maximumBytes: Int) async throws -> Data where Bytes.Element == UInt8 {
        try Task.checkCancellation()
        var data = Data()
        data.reserveCapacity(min(max(maximumBytes, 0), 4096))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw ChatClientError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

/// The single session used for chat traffic. It is ephemeral, carries no
/// cookies, credentials or cache, and rejects every redirect so a chat route
/// can never be silently re-pointed, mirroring `PublicHTTPSession`. Unlike the
/// public collectors, its resource timeout accommodates long non-streaming
/// inference; per-request timeouts are still set by the request builders.
public enum ChatHTTPSession {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 330
        return URLSession(configuration: configuration, delegate: ChatSessionPolicy(), delegateQueue: nil)
    }()
}

/// Local-route chat traffic is plain HTTP on purpose: it targets this Mac's
/// own hosting endpoint exactly as configured in Hosting settings. The policy
/// still rejects redirects for that route too.
final class ChatSessionPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
