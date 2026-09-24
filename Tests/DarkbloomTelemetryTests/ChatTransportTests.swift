import Foundation
import Testing
@testable import DarkbloomTelemetry

/// Transport-level tests for the local and network chat clients through an
/// injected URLProtocol. Every response is a synthetic fixture; no live
/// endpoint, provider, or paid inference is contacted.
@Suite("Chat transport")
struct ChatTransportTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Local client

    struct FixedProvider: ChatLocalEndpointProviding {
        let endpoint: ChatLocalEndpoint?
        func endpoint() async -> ChatLocalEndpoint? { endpoint }
    }

    private func localClient(provider: FixedProvider, mode: String) -> LocalChatClient {
        LocalChatClient(endpointProvider: provider, session: makeSession(mode: mode))
    }

    @Test("local client verifies models with the endpoint token against a single /v1 path")
    func localModelsRequest() async throws {
        let provider = FixedProvider(endpoint: ChatLocalEndpoint.make(
            baseURL: "http://127.0.0.1:8123/v1", token: "dk-local-synthetic"
        ))
        let snapshot = try await localClient(provider: provider, mode: "models-ok").models(now: Self.now)
        #expect(snapshot.modelIDs == ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
    }

    @Test("local completion posts to /v1/chat/completions exactly once under the origin")
    func localCompletionRequest() async throws {
        let provider = FixedProvider(endpoint: ChatLocalEndpoint.make(
            baseURL: "http://127.0.0.1:8123/v1", token: "dk-local-synthetic"
        ))
        let outcome = try await localClient(provider: provider, mode: "chat-ok").complete(
            model: "gpt-oss-20b",
            messages: [ChatMessagePayload(role: .user, content: "hi")]
        )
        #expect(outcome.content == "Local synthetic reply.")
    }

    @Test("local 401 stays the endpoint-token rejection, never the consumer-key error")
    func local401() async {
        let provider = FixedProvider(endpoint: ChatLocalEndpoint.make(
            baseURL: "http://127.0.0.1:8123", token: "dk-local-synthetic"
        ))
        await #expect(throws: ChatClientError.unauthorized) {
            _ = try await localClient(provider: provider, mode: "401").models(now: Self.now)
        }
        await #expect(throws: ChatClientError.unauthorized) {
            _ = try await localClient(provider: provider, mode: "401").complete(
                model: "m", messages: [ChatMessagePayload(role: .user, content: "x")]
            )
        }
    }

    @Test("explicitly unauthenticated local endpoints send no Authorization on models and completion")
    func localNoAuth() async throws {
        let provider = FixedProvider(endpoint: ChatLocalEndpoint.make(
            baseURL: "http://127.0.0.1:8123", token: nil
        ))
        let models = try await localClient(provider: provider, mode: "models-noauth").models(now: Self.now)
        #expect(models.modelIDs.count == 2)
        let outcome = try await localClient(provider: provider, mode: "chat-noauth").complete(
            model: "gpt-oss-20b",
            messages: [ChatMessagePayload(role: .user, content: "hi")]
        )
        #expect(outcome.content == "Local synthetic reply.")
    }

    @Test("a blank token is not a way to silently drop local authentication")
    func localBlankTokenFails() async {
        // ChatLocalEndpoint rejects a blank non-nil token, so the client
        // reports the endpoint unavailable instead of sending unauthenticated.
        let client = LocalChatClient(
            endpointProvider: FixedProvider(endpoint: ChatLocalEndpoint.make(
                baseURL: "http://127.0.0.1:8123", token: " "
            )),
            session: makeSession(mode: "must-not-start")
        )
        await #expect(throws: ChatClientError.localEndpointUnavailable) {
            _ = try await client.models(now: Self.now)
        }
    }

    @Test("missing endpoint or missing local token fails before any request")
    func localEndpointUnavailable() async {
        for endpoint in [nil, ChatLocalEndpoint.make(baseURL: "http://127.0.0.1:8123", token: "")] {
            let client = LocalChatClient(
                endpointProvider: FixedProvider(endpoint: endpoint),
                session: makeSession(mode: "must-not-start")
            )
            await #expect(throws: ChatClientError.localEndpointUnavailable) {
                _ = try await client.models(now: Self.now)
            }
        }
    }

    // MARK: Network client

    @Test("network models request authenticates with the consumer key")
    func networkModelsRequest() async throws {
        let client = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "models-ok"))
        let snapshot = try await client.models(now: Self.now)
        #expect(snapshot.modelIDs.count == 2)
    }

    @Test("network 401 is the key-specific rejection on both endpoints")
    func network401() async {
        let client = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "401"))
        await #expect(throws: ChatClientError.consumerKeyRejected) {
            _ = try await client.models(now: Self.now)
        }
        await #expect(throws: ChatClientError.consumerKeyRejected) {
            _ = try await client.complete(model: "m", messages: [ChatMessagePayload(role: .user, content: "x")])
        }
    }

    @Test("missing consumer key never reaches the network")
    func networkMissingKey() async {
        let client = NetworkChatClient(consumerKeyProvider: { nil }, session: makeSession(mode: "must-not-start"))
        await #expect(throws: ChatClientError.missingConsumerKey) {
            _ = try await client.models(now: Self.now)
        }
        await #expect(throws: ChatClientError.missingConsumerKey) {
            _ = try await client.complete(model: "m", messages: [ChatMessagePayload(role: .user, content: "x")])
        }
    }

    @Test("402 with any body shape is the authoritative, unretried payment decision")
    func network402() async {
        for mode in ["chat-402", "chat-402-huge", "chat-402-malformed"] {
            let client = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: mode))
            await #expect(throws: ChatClientError.paymentRequired) {
                _ = try await client.complete(model: "m", messages: [ChatMessagePayload(role: .user, content: "x")])
            }
        }
    }

    @Test("model-scoped 403 and 404 refine through the machine code whitelist")
    func networkModelErrors() async {
        let allowed = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "chat-403-code"))
        await #expect(throws: ChatClientError.modelNotAllowed) {
            _ = try await allowed.complete(model: "m", messages: [ChatMessagePayload(role: .user, content: "x")])
        }
        let missing = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "chat-404-code"))
        await #expect(throws: ChatClientError.modelNotFound) {
            _ = try await missing.complete(model: "m", messages: [ChatMessagePayload(role: .user, content: "x")])
        }
        let plain = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "403"))
        await #expect(throws: ChatClientError.httpStatus(403)) {
            _ = try await plain.complete(model: "m", messages: [ChatMessagePayload(role: .user, content: "x")])
        }
    }

    @Test("success completion decodes through the network client")
    func networkCompletion() async throws {
        let client = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "chat-ok"))
        let outcome = try await client.complete(
            model: "gpt-oss-20b",
            messages: [ChatMessagePayload(role: .user, content: "hi")]
        )
        #expect(outcome.content == "Local synthetic reply.")
        #expect(outcome.completionTokens == 34)
    }

    // MARK: Balance client

    @Test("balance authenticates with the consumer key and decodes the ledger")
    func balanceSuccess() async throws {
        let client = ConsumerBalanceClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "balance-ok"))
        let snapshot = try await client.fetch(now: Self.now)
        #expect(snapshot.balanceMicroUSD == 2_400_000)
        #expect(snapshot.capturedAt == Self.now)
    }

    @Test("balance without a key never reaches the network; 401 is key-specific")
    func balanceFailures() async {
        let keyless = ConsumerBalanceClient(consumerKeyProvider: { nil }, session: makeSession(mode: "must-not-start"))
        await #expect(throws: ChatClientError.missingConsumerKey) {
            _ = try await keyless.fetch(now: Self.now)
        }
        let rejected = ConsumerBalanceClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "401"))
        await #expect(throws: ChatClientError.consumerKeyRejected) {
            _ = try await rejected.fetch(now: Self.now)
        }
    }

    // MARK: Shared bounds

    @Test("declared and streamed oversized bodies are rejected")
    func sizeLimits() async {
        let client = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "declared-large"))
        await #expect(throws: ChatClientError.responseTooLarge) {
            _ = try await client.models(now: Self.now)
        }
        let streamed = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "streamed-large"))
        await #expect(throws: ChatClientError.responseTooLarge) {
            _ = try await streamed.models(now: Self.now)
        }
    }

    @Test("transport timeout propagates and pre-cancelled calls never start")
    func cancellationAndTimeout() async {
        let timingOut = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "timeout"))
        do {
            _ = try await timingOut.models(now: Self.now)
            Issue.record("Accepted a transport timeout")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        let cancelled = NetworkChatClient(consumerKeyProvider: { "dk-synthetic-consumer" }, session: makeSession(mode: "must-not-start"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await cancelled.models(now: Self.now)
                Issue.record("Accepted a cancelled request")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await task.value
    }

    @Test("chat session is isolated: no cookies, credentials or cache, long resource bound, redirects refused")
    func chatSessionPolicy() async throws {
        let configuration = try #require(ChatHTTPSession.shared.configuration as URLSessionConfiguration?)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForResource == 330)

        let policy = ChatSessionPolicy()
        let expectation = LockedBox<URLRequest?>(nil)
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.darkbloom.dev/v1/models")!)
        // The completion handler runs synchronously inside the delegate call,
        // so the box is set before the call returns.
        policy.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://api.darkbloom.dev/v1/models")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://elsewhere.test/v1/models"]
            )!,
            newRequest: URLRequest(url: URL(string: "https://elsewhere.test/v1/models")!)
        ) { redirected in
            expectation.value = redirected
        }
        #expect(expectation.value == nil)
    }

    // MARK: Fixture session

    private func makeSession(mode: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Chat-Fixture": mode]
        return URLSession(configuration: configuration)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { self.stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// Synthetic fixture protocol. Asserts the request properties each route
/// contract requires and answers with mode-selected bodies.
private final class ChatFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let mode = request.value(forHTTPHeaderField: "X-Chat-Fixture"), mode != "must-not-start" else {
            Issue.record("Unexpected HTTP acquisition")
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if mode == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }

        let url = request.url
        let path = url?.path ?? ""
        let isLocal = url?.host == "127.0.0.1"

        // Shared request contract.
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        if path == "/v1/chat/completions" {
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.timeoutInterval == ChatCompletionRequest.networkTimeoutInterval)
            // URLProtocol exposes the body as a stream, not httpBody.
            if let body = Self.bodyData(of: request),
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                #expect(object["stream"] as? Bool == false)
                #expect((object["messages"] as? [[String: Any]])?.isEmpty == false)
            } else {
                Issue.record("Chat completion without a JSON body")
            }
        } else {
            #expect(request.httpMethod == "GET")
        }
        // Local requests carry the endpoint token when authenticated and no
        // Authorization header at all when the endpoint is explicitly
        // unauthenticated; network requests always carry the synthetic
        // consumer key.
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        if isLocal {
            if mode.hasSuffix("-noauth") {
                #expect(authorization.isEmpty)
            } else {
                #expect(authorization == "Bearer dk-local-synthetic")
            }
            #expect(url?.scheme == "http")
        } else {
            #expect(authorization == "Bearer dk-synthetic-consumer")
            #expect(url?.scheme == "https")
            #expect(url?.host == "api.darkbloom.dev")
        }

        if mode == "redirect" {
            let response = HTTPURLResponse(
                url: url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://api.darkbloom.dev/v1/elsewhere"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var body: Data
        var status = 200
        // Error statuses take precedence over path defaults so every route
        // surfaces its mapped failure instead of a success body.
        let mappedStatus = Self.status(for: mode)
        if mappedStatus != 200 {
            status = mappedStatus
            body = Self.errorBody(for: mode)
        } else {
            switch path {
            case "/v1/models":
                body = Data(#"""
                {"object":"list","data":[
                  {"id":"gpt-oss-20b","object":"model","created":1725000000,"owned_by":"eigeninference"},
                  {"id":"gemma-4-26b-qat-4bit","object":"model"}
                ]}
                """#.utf8)
            case "/v1/payments/balance":
                body = Data(#"{"balance_micro_usd":2400000,"balance_usd":"$2.40","withdrawable_micro_usd":0,"withdrawable_usd":"$0.00"}"#.utf8)
            default:
                body = Data(#"""
                {"id":"chatcmpl-1","object":"chat.completion","created":1725000000,"model":"gpt-oss-20b",
                 "choices":[{"index":0,"message":{"role":"assistant","content":"Local synthetic reply."},"finish_reason":"stop"}],
                 "usage":{"prompt_tokens":12,"completion_tokens":34,"total_tokens":46}}
                """#.utf8)
            }
        }

        if mode == "declared-large" {
            // Succeed-status bodies that declare an over-cap length are
            // rejected before reading.
            body = Data(#"{"object":"list","data":[]}"#.utf8)
            let response = HTTPURLResponse(
                url: url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Content-Length": String(256 * 1_024 + 1)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if mode == "streamed-large" {
            body = Data(repeating: 32, count: 256 * 1_024 + 1)
        }

        let response = HTTPURLResponse(
            url: url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Reads a request body through whichever channel URLProtocol exposed.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    private static func status(for mode: String) -> Int {
        switch mode {
        case "chat-402", "chat-402-huge", "chat-402-malformed": 402
        case "chat-403-code": 403
        case "chat-404-code": 404
        case "401": 401
        case "403": 403
        default: Int(mode) ?? 200
        }
    }

    private static func errorBody(for mode: String) -> Data {
        switch mode {
        case "chat-402":
            Data(#"{"error":{"message":"free text is ignored","type":"insufficient_funds","code":"insufficient_quota"}}"#.utf8)
        case "chat-402-huge":
            Data(repeating: 32, count: 64 * 1_024)
        case "chat-402-malformed":
            Data("not json at all".utf8)
        case "chat-403-code":
            Data(#"{"error":{"code":"model_not_allowed"}}"#.utf8)
        case "chat-404-code":
            Data(#"{"error":{"code":"model_not_found"}}"#.utf8)
        default:
            Data(#"{"error":{"message":"free text is ignored","code":"authentication_error"}}"#.utf8)
        }
    }
}
