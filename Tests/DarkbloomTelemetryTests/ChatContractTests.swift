import Foundation
import Testing
@testable import DarkbloomTelemetry

/// Contract-level tests for the chat parsers, request builders, base-URL
/// normalization, key validation, and status mapping. All values are
/// synthetic fixtures; none are usable credentials.
@Suite("Chat contract")
struct ChatContractTests {
    static let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Model list

    @Test("network model list decodes the documented OpenAI shape")
    func networkModels() throws {
        let data = Data(#"""
        {"object":"list","data":[
          {"id":"gpt-oss-20b","object":"model","created":1725000000,"owned_by":"eigeninference","name":"GPT-OSS 20B"},
          {"id":"gemma-4-26b-qat-4bit","object":"model","created":1725000001}
        ]}
        """#.utf8)
        let snapshot = try ChatModelListParser.parse(data, capturedAt: Self.capturedAt)
        #expect(snapshot.modelIDs == ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
        #expect(snapshot.capturedAt == Self.capturedAt)
    }

    @Test("minimal local model list decodes without display fields")
    func localModels() throws {
        let snapshot = try ChatModelListParser.parse(
            Data(#"{"object":"list","data":[{"id":"gpt-oss-20b"}]}"#.utf8),
            capturedAt: Self.capturedAt
        )
        #expect(snapshot.modelIDs == ["gpt-oss-20b"])
    }

    @Test("model list rejects missing data, wrong object, duplicates, blanks, oversize and counts")
    func invalidModelLists() {
        let cases: [String] = [
            #"{}"#,
            #"{"object":"page","data":[]}"#,
            #"{"data":[{"id":"m"},{"id":"m"}]}"#,
            #"{"data":[{"id":"  "}]}"#,
            #"{"data":[{"other":"field"}]}"#,
        ]
        for payload in cases {
            #expect(throws: ChatClientError.invalidResponse) {
                _ = try ChatModelListParser.parse(Data(payload.utf8), capturedAt: Self.capturedAt)
            }
        }
        let oversizedID = String(repeating: "a", count: 513)
        #expect(throws: ChatClientError.invalidResponse) {
            _ = try ChatModelListParser.parse(
                Data(#"{"data":[{"id":"\#(oversizedID)"}]}"#.utf8),
                capturedAt: Self.capturedAt
            )
        }
        let tooMany = (0..<129).map { #"{"id":"m\#($0)"}"# }.joined(separator: ",")
        #expect(throws: ChatClientError.invalidResponse) {
            _ = try ChatModelListParser.parse(
                Data(#"{"data":[\#(tooMany)]}"#.utf8),
                capturedAt: Self.capturedAt
            )
        }
        #expect(throws: ChatClientError.responseTooLarge) {
            _ = try ChatModelListParser.parse(
                Data(repeating: 32, count: ChatModelListSnapshot.maximumResponseBytes + 1),
                capturedAt: Self.capturedAt
            )
        }
    }

    // MARK: Completion request

    @Test("network completion request targets the fixed host with a bounded body")
    func networkRequest() throws {
        let request = try ChatCompletionRequest.makeNetwork(
            consumerKey: "dk-synthetic-test-key",
            model: "gpt-oss-20b",
            messages: [
                ChatMessagePayload(role: .user, content: "hello"),
                ChatMessagePayload(role: .assistant, content: "hi"),
                ChatMessagePayload(role: .user, content: "bye"),
            ]
        ).urlRequest
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.darkbloom.dev/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dk-synthetic-test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == ChatCompletionRequest.networkTimeoutInterval)
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "gpt-oss-20b")
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map(\.self.keys).count == 3)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[2]["content"] as? String == "bye")
    }

    @Test("request validation rejects unbounded input before any network use")
    func requestBounds() {
        #expect(throws: ChatClientError.missingModelID) {
            _ = try ChatCompletionRequest.makeNetwork(
                consumerKey: "k", model: " ", messages: [ChatMessagePayload(role: .user, content: "hi")]
            )
        }
        #expect(throws: ChatClientError.requestTooLarge) {
            _ = try ChatCompletionRequest.makeNetwork(
                consumerKey: "k", model: "m", messages: []
            )
        }
        let long = String(repeating: "a", count: ChatCompletionRequest.maximumMessageCharacters + 1)
        #expect(throws: ChatClientError.requestTooLarge) {
            _ = try ChatCompletionRequest.makeNetwork(
                consumerKey: "k", model: "m", messages: [ChatMessagePayload(role: .user, content: long)]
            )
        }
        let many = (0...(ChatCompletionRequest.maximumMessages + 1))
            .map { ChatMessagePayload(role: .user, content: "m\($0)") }
        #expect(throws: ChatClientError.requestTooLarge) {
            _ = try ChatCompletionRequest.makeNetwork(consumerKey: "k", model: "m", messages: many)
        }
    }

    @Test("local base URLs normalize once: configured /v1 and discovered roots both resolve single paths")
    func localBaseURLContract() throws {
        // Hosting settings' unified URL form, ending in /v1.
        let configured = try #require(ChatLocalEndpoint.make(baseURL: "http://127.0.0.1:8000/v1", token: "dk-local-synthetic"))
        #expect(configured.origin.absoluteString == "http://127.0.0.1:8000")
        #expect(configured.isAuthenticated)
        // Discovery record form without a path, on a LAN address with port.
        let discovered = try #require(ChatLocalEndpoint.make(baseURL: "http://192.168.1.5:8123", token: "dk-local-synthetic"))
        #expect(discovered.origin.absoluteString == "http://192.168.1.5:8123")

        for endpoint in [configured, discovered] {
            let request = try #require(endpoint.withToken { token in
                try ChatCompletionRequest.makeLocal(
                    origin: endpoint.origin,
                    token: token,
                    model: "gpt-oss-20b",
                    messages: [ChatMessagePayload(role: .user, content: "hi")]
                )
            }).urlRequest
            #expect(request.url?.path == "/v1/chat/completions")
            #expect(request.url!.absoluteString.hasSuffix("/v1/chat/completions"))
            #expect(!request.url!.absoluteString.contains("/v1/v1"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dk-local-synthetic")
        }
        // An explicitly unauthenticated endpoint targets the same paths and
        // sends no Authorization header at all.
        let noAuth = try #require(ChatLocalEndpoint.make(baseURL: "http://127.0.0.1:8000/v1", token: nil))
        #expect(noAuth.isAuthenticated == false)
        #expect(noAuth.withToken { _ in true } == nil)
        let request = try ChatCompletionRequest.makeLocal(
            origin: noAuth.origin,
            token: nil,
            model: "gpt-oss-20b",
            messages: [ChatMessagePayload(role: .user, content: "hi")]
        ).urlRequest
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        // A non-origin URL with a path is refused by the builder itself.
        let withPath = try #require(URL(string: "http://127.0.0.1:8000/v1"))
        #expect(throws: ChatClientError.invalidEndpoint) {
            _ = try ChatCompletionRequest.makeLocal(
                origin: withPath,
                token: "dk-local-synthetic",
                model: "m",
                messages: [ChatMessagePayload(role: .user, content: "hi")]
            )
        }
        // Blank tokens are not a way to silently drop authentication.
        #expect(throws: ChatClientError.invalidEndpoint) {
            _ = try ChatCompletionRequest.makeLocal(
                origin: noAuth.origin,
                token: " ",
                model: "m",
                messages: [ChatMessagePayload(role: .user, content: "hi")]
            )
        }
    }

    @Test("local endpoint rejects unusable URLs and tokens and never prints its token")
    func localEndpointValidation() {
        #expect(ChatLocalEndpoint.make(baseURL: "file://127.0.0.1/x", token: "t") == nil)
        #expect(ChatLocalEndpoint.make(baseURL: "http://user:pass@host", token: "t") == nil)
        #expect(ChatLocalEndpoint.make(baseURL: "http://host?a=1", token: "t") == nil)
        #expect(ChatLocalEndpoint.make(baseURL: "http://host", token: " ") == nil)
        #expect(ChatLocalEndpoint.make(baseURL: "http://host", token: String(repeating: "k", count: 257)) == nil)
        #expect(ChatLocalEndpoint.make(baseURL: "not a url", token: nil) == nil)
        let endpoint = ChatLocalEndpoint.make(baseURL: "http://host", token: "dk-local-synthetic")
        #expect(endpoint?.description.contains("dk-local-synthetic") == false)
        #expect(endpoint?.description.contains("authenticated: true") == true)
        #expect(ChatLocalEndpoint.make(baseURL: "http://host", token: nil)?.description.contains("authenticated: false") == true)
    }

    // MARK: Completion response

    @Test("completion response decodes content, finish reason and usage")
    func completionResponse() throws {
        let data = Data(#"""
        {"id":"chatcmpl-1","object":"chat.completion","created":1725000000,"model":"gpt-oss-20b",
         "choices":[{"index":0,"message":{"role":"assistant","content":"Hello there."},
                     "finish_reason":"stop"}],
         "usage":{"prompt_tokens":12,"completion_tokens":34,"total_tokens":46}}
        """#.utf8)
        let outcome = try ChatCompletionParser.parse(data)
        #expect(outcome.content == "Hello there.")
        #expect(outcome.model == "gpt-oss-20b")
        #expect(outcome.finishReason == "stop")
        #expect(outcome.promptTokens == 12)
        #expect(outcome.completionTokens == 34)
    }

    @Test("completion parser fails closed on missing choices, null content, wrong role, bad usage")
    func invalidCompletions() {
        let cases: [String] = [
            #"{}"#,
            #"{"choices":[]}"#,
            #"{"choices":[{"message":{"role":"assistant","content":null}}]}"#,
            #"{"choices":[{"message":{"role":"tool","content":"x"}}]}"#,
            #"{"choices":[{"message":{"content":"x"}}],"usage":{"prompt_tokens":-1}}"#,
        ]
        for payload in cases {
            #expect(throws: ChatClientError.invalidResponse) {
                _ = try ChatCompletionParser.parse(Data(payload.utf8))
            }
        }
    }

    // MARK: Balance

    @Test("balance decodes the documented consumer ledger response")
    func balanceResponse() throws {
        let data = Data(#"""
        {"balance_micro_usd":2400000,"balance_usd":"$2.40",
         "withdrawable_micro_usd":1000000,"withdrawable_usd":"$1.00"}
        """#.utf8)
        let snapshot = try ConsumerBalanceParser.parse(data, capturedAt: Self.capturedAt)
        #expect(snapshot.balanceMicroUSD == 2_400_000)
        #expect(snapshot.balanceUSD == Decimal(string: "2.4"))
        #expect(snapshot.isFresh(at: Self.capturedAt))
        #expect(!snapshot.isFresh(at: Self.capturedAt.addingTimeInterval(ConsumerBalanceSnapshot.maximumAge + 1)))
    }

    @Test("balance parser fails closed on missing, negative, malformed or oversized payloads")
    func invalidBalance() {
        let cases: [String] = [
            #"{}"#,
            #"{"balance_micro_usd":-1}"#,
            #"{"balance_micro_usd":"2400000"}"#,
            #"{"balance_usd":"$2.40"}"#,
        ]
        for payload in cases {
            #expect(throws: ChatClientError.invalidResponse) {
                _ = try ConsumerBalanceParser.parse(Data(payload.utf8), capturedAt: Self.capturedAt)
            }
        }
        #expect(throws: ChatClientError.responseTooLarge) {
            _ = try ConsumerBalanceParser.parse(
                Data(repeating: 32, count: ConsumerBalanceSnapshot.maximumResponseBytes + 1),
                capturedAt: Self.capturedAt
            )
        }
    }

    // MARK: Status mapping and error codes

    @Test("status mapping is route-neutral at the core and refines semantics by machine code")
    func statusMapping() {
        #expect(ChatHTTPStatusMapper.error(for: 401, code: nil) == .unauthorized)
        #expect(ChatHTTPStatusMapper.error(for: 402, code: .insufficientFunds) == .paymentRequired)
        #expect(ChatHTTPStatusMapper.error(for: 402, code: .insufficientQuota) == .paymentRequired)
        #expect(ChatHTTPStatusMapper.error(for: 402, code: nil) == .paymentRequired)
        #expect(ChatHTTPStatusMapper.error(for: 403, code: .modelNotAllowed) == .modelNotAllowed)
        #expect(ChatHTTPStatusMapper.error(for: 403, code: nil) == .httpStatus(403))
        #expect(ChatHTTPStatusMapper.error(for: 404, code: .modelNotFound) == .modelNotFound)
        #expect(ChatHTTPStatusMapper.error(for: 404, code: nil) == .httpStatus(404))
        #expect(ChatHTTPStatusMapper.error(for: 500, code: nil) == .httpStatus(500))
    }

    @Test("error code reader accepts only whitelisted machine codes and never yields free text")
    func errorCodeReader() {
        #expect(ChatErrorCodeReader.code(from: Data(#"{"error":{"code":"model_not_found","message":"free text ignored"}}"#.utf8)) == .modelNotFound)
        #expect(ChatErrorCodeReader.code(from: Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8)) == .insufficientQuota)
        #expect(ChatErrorCodeReader.code(from: Data(#"{"error":{"code":"some_future_code"}}"#.utf8)) == nil)
        #expect(ChatErrorCodeReader.code(from: Data(#"{"error":{"message":"no code"}}"#.utf8)) == nil)
        #expect(ChatErrorCodeReader.code(from: Data("not json".utf8)) == nil)
        #expect(ChatErrorCodeReader.code(from: Data(repeating: 32, count: 4097)) == nil)
    }

    @Test("chat errors never embed server free text in user-facing descriptions")
    func fixedErrorMessages() {
        let errors: [ChatClientError] = [.paymentRequired, .consumerKeyRejected, .unauthorized, .modelNotFound, .httpStatus(418)]
        for error in errors {
            let message = error.errorDescription ?? ""
            #expect(!message.isEmpty)
        }
        #expect(ChatClientError.paymentRequired.errorDescription?.contains("no retry was attempted") == true)
        #expect(ChatClientError.consumerKeyRejected.errorDescription?.contains("consumer API key") == true)
    }

    // MARK: Consumer key format

    @Test("consumer key validation accepts structural keys and rejects whitespace, emptiness and oversize")
    func keyValidation() {
        #expect(ConsumerAPIKey.isValid("dk-synthetic-consumer-key"))
        #expect(ConsumerAPIKey.isValid("  padded-synthetic-key \n"))
        #expect(!ConsumerAPIKey.isValid(""))
        #expect(!ConsumerAPIKey.isValid("   "))
        #expect(!ConsumerAPIKey.isValid("with space"))
        #expect(!ConsumerAPIKey.isValid("with\ttab"))
        #expect(!ConsumerAPIKey.isValid(String(repeating: "k", count: 257)))
        #expect(ConsumerAPIKey.trimmed("  key \n") == "key")
    }
}
