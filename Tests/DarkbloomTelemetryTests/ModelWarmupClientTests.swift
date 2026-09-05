import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Bounded local model warmup client")
struct ModelWarmupClientTests {
    @Test("current chat-completion warmup is explicitly classified as eviction-capable")
    func exposesLoadSafety() {
        #expect(ModelWarmupClient(transport: StubWarmupTransport(
            response: .init(statusCode: 200, data: Data())
        )).loadSafety == .mayEvictResident)
    }

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

    @Test("protected control discovers capability and uses separate load and retire routes")
    func protectedControlContract() async throws {
        let payload = Data(#"{"api_version":1,"protected_load":true,"idle_retire":true,"max_model_slots":2,"advertised_models":["warm","target","prefetched"],"launch_models":["warm","target"],"configured_max_model_slots":2,"enabled_models":["family"],"preload_models":["warm"],"loaded_models":["warm"]}"#.utf8)
        let transport = RecordingWarmupTransport(responses: [
            .init(statusCode: 200, data: payload),
            .init(statusCode: 200, data: payload),
            .init(statusCode: 200, data: payload),
        ])
        let client = ProtectedModelControlClient(transport: transport)

        let capability = try await client.controlSnapshot(using: discovery())
        _ = try await client.warm(modelID: "target", using: discovery())
        try await client.retire(modelID: "warm", using: discovery())

        #expect(client.loadSafety == .preservesResidents)
        #expect(capability == ModelControlSnapshot(
            apiVersion: 1,
            protectedLoad: true,
            idleRetire: true,
            maxModelSlots: 2,
            loadedModels: ["warm"],
            advertisedModels: ["warm", "target", "prefetched"],
            launchModels: ["warm", "target"],
            configuredMaxModelSlots: 2,
            configuredEnabledModels: ["family"],
            configuredPreloadModels: ["warm"]
        ))
        let requests = await transport.requests
        #expect(requests.map(\.url?.absoluteString) == [
            "http://127.0.0.1:8100/v1/provider/model-control",
            "http://127.0.0.1:8100/v1/provider/model-control/load",
            "http://127.0.0.1:8100/v1/provider/model-control/retire",
        ])
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "POST"])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret"
        })
    }

    @Test("warmup launch evidence is emitted by the transport dispatch boundary")
    func reportsTransportLaunch() async throws {
        let transport = RecordingWarmupTransport(responses: [
            .init(statusCode: 200, data: Data())
        ])
        let client = ModelWarmupClient(transport: transport)
        let evidence = LaunchEvidence()

        _ = try await client.warm(
            modelID: "target",
            using: discovery(),
            onLaunch: { evidence.mark() }
        )

        #expect(evidence.didLaunch)
        #expect((await transport.requests).count == 1)
    }

    @Test("protected control distinguishes an older response with no advertised-model proof")
    func protectedControlAllowsMissingAdvertisedProof() async throws {
        let payload = Data(#"{"api_version":1,"protected_load":true,"idle_retire":true,"max_model_slots":1,"loaded_models":[]}"#.utf8)
        let client = ProtectedModelControlClient(transport: StubWarmupTransport(
            response: .init(statusCode: 200, data: payload)
        ))

        let capability = try #require(await client.controlSnapshot(using: discovery()))

        #expect(capability.advertisedModels == nil)
    }

    @Test("protected control treats a missing capability route as unsupported")
    func protectedControlRequiresCapabilityRoute() async throws {
        let client = ProtectedModelControlClient(transport: StubWarmupTransport(
            response: .init(statusCode: 404, data: Data())
        ))

        #expect(try await client.controlSnapshot(using: discovery()) == nil)
        await #expect(throws: ModelWarmupClientError.unsupported) {
            _ = try await client.warm(modelID: "target", using: discovery())
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

private actor RecordingWarmupTransport: ModelWarmupTransporting {
    private var responses: [ModelWarmupTransportResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [ModelWarmupTransportResponse]) {
        self.responses = responses
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
        onLaunch?()
        requests.append(request)
        guard !responses.isEmpty else { throw ModelWarmupTransportError.invalidResponse }
        return responses.removeFirst()
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

private final class LaunchEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var launched = false

    func mark() {
        lock.lock()
        launched = true
        lock.unlock()
    }

    var didLaunch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return launched
    }
}
