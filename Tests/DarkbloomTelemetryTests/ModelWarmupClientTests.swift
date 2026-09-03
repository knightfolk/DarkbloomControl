import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Bounded local model warmup client")
struct ModelWarmupClientTests {
    @Test("request targets the exact model through the authenticated loopback endpoint")
    func requestContract() throws {
        let discovery = LocalEndpointDiscovery(
            baseURL: URL(string: "http://127.0.0.1:8100/v1")!,
            apiKey: "fixture-secret",
            evidenceAt: Date(timeIntervalSince1970: 1)
        )

        let request = try ModelWarmupRequest.make(
            discovery: discovery,
            modelID: "qwen3.5-35b-a3b"
        ).urlRequest

        #expect(request.url == URL(string: "http://127.0.0.1:8100/v1/chat/completions"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 600)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen3.5-35b-a3b")
        #expect(json["stream"] as? Bool == false)
        #expect(json["max_tokens"] as? Int == 1)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Reply with OK."]])
    }

    @Test("successful response returns optional usage without retaining response text")
    func decodesUsage() async throws {
        let transport = StubWarmupTransport(response: .init(
            statusCode: 200,
            data: Data(#"{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":1}}"#.utf8)
        ))
        let client = ModelWarmupClient(transport: transport)

        let usage = try await client.warm(
            modelID: "qwen3.5-35b-a3b",
            using: discovery()
        )

        #expect(usage == ModelWarmupResponseUsage(promptTokens: 4, completionTokens: 1))
    }

    @Test("empty successful response does not require usage")
    func permitsMissingUsage() async throws {
        let client = ModelWarmupClient(transport: StubWarmupTransport(
            response: .init(statusCode: 204, data: Data())
        ))

        #expect(try await client.warm(modelID: "model", using: discovery()) == nil)
    }

    @Test("HTTP failures map to fixed non-secret errors", arguments: [
        (401, ModelWarmupClientError.unauthorized),
        (403, ModelWarmupClientError.unauthorized),
        (409, ModelWarmupClientError.busy),
        (423, ModelWarmupClientError.busy),
        (429, ModelWarmupClientError.busy),
        (500, ModelWarmupClientError.httpStatus(500)),
        (302, ModelWarmupClientError.redirected),
    ])
    func mapsHTTPFailures(statusCode: Int, expected: ModelWarmupClientError) async throws {
        let secretBody = Data("Authorization: Bearer response-secret".utf8)
        let client = ModelWarmupClient(transport: StubWarmupTransport(
            response: .init(statusCode: statusCode, data: secretBody)
        ))

        do {
            _ = try await client.warm(modelID: "model", using: discovery())
            Issue.record("Expected HTTP failure")
        } catch {
            #expect(error as? ModelWarmupClientError == expected)
            #expect(!error.localizedDescription.contains("response-secret"))
            #expect(!error.localizedDescription.contains("fixture-secret"))
        }
    }

    @Test("transport bounds and cancellation remain typed")
    func mapsTransportFailures() async throws {
        for failure in [
            ModelWarmupTransportError.responseTooLarge,
            ModelWarmupTransportError.invalidResponse,
        ] {
            let client = ModelWarmupClient(transport: StubWarmupTransport(error: failure))
            do {
                _ = try await client.warm(modelID: "model", using: discovery())
                Issue.record("Expected transport failure")
            } catch {
                let expected: ModelWarmupClientError = failure == .responseTooLarge
                    ? .responseTooLarge
                    : .invalidResponse
                #expect(error as? ModelWarmupClientError == expected)
            }
        }

        let cancelled = ModelWarmupClient(
            transport: StubWarmupTransport(error: CancellationError())
        )
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.warm(modelID: "model", using: discovery())
        }
    }

    private func discovery() -> LocalEndpointDiscovery {
        LocalEndpointDiscovery(
            baseURL: URL(string: "http://127.0.0.1:8100/v1")!,
            apiKey: "fixture-secret",
            evidenceAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private actor StubWarmupTransport: ModelWarmupTransporting {
    private let result: Result<ModelWarmupTransportResponse, any Error & Sendable>

    init(response: ModelWarmupTransportResponse) {
        result = .success(response)
    }

    init<E: Error & Sendable>(error: E) {
        result = .failure(error)
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> ModelWarmupTransportResponse {
        try result.get()
    }
}
