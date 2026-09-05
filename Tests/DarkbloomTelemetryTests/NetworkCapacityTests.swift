import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Public network model capacity")
struct NetworkCapacityTests {
    @Test("capacity rejects oversized model identities and populations")
    func boundedIdentities() throws {
        func payload(_ ids: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["models": ids.map { id in
                ["id": id, "ready": true, "can_accept": true,
                 "routable_providers": 1, "warm_providers": 1, "running_providers": 0,
                 "cold_providers": 0, "active_requests": 0, "queued_requests": 0,
                 "queue_limit": 1, "aggregate_tps": 1, "estimated_ttft_ms": 1,
                 "token_budget_remaining": 1, "token_budget_total": 1] as [String: Any]
            }])
        }
        let exact = try payload([String(repeating: "x", count: 512)])
        #expect(try NetworkCapacityParser.parse(exact, capturedAt: .now).models.count == 1)
        let long = try payload([String(repeating: "x", count: 513)])
        #expect(throws: NetworkCapacityError.invalidResponse) {
            try NetworkCapacityParser.parse(long, capturedAt: .now)
        }
        let full = try payload((0..<128).map { "model-\($0)" })
        #expect(try NetworkCapacityParser.parse(full, capturedAt: .now).models.count == 128)
        let overflow = try payload((0..<129).map { "model-\($0)" })
        #expect(throws: NetworkCapacityError.invalidResponse) {
            try NetworkCapacityParser.parse(overflow, capturedAt: .now)
        }
    }

    @Test("a cancelled response reader consumes no further bytes")
    func cancelledBody() async {
        let counter = NetworkByteCounter(total: 10)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BoundedNetworkBody.collect(NetworkTestBytes(counter: counter), maximumBytes: 10)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled body was accepted")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await counter.reads == 0)
    }

    @Test("streaming response limit stops consuming bytes immediately after the cap")
    func streamingLimit() async throws {
        let counter = NetworkByteCounter(total: 10_000)
        do {
            _ = try await BoundedNetworkBody.collect(NetworkTestBytes(counter: counter), maximumBytes: 3)
            Issue.record("Oversized body was accepted")
        } catch {
            #expect(error as? NetworkCapacityError == .responseTooLarge)
        }
        #expect(await counter.reads == 4)
        let exact = try await BoundedNetworkBody.collect(NetworkTestBytes(counter: NetworkByteCounter(total: 3)), maximumBytes: 3)
        #expect(exact == Data([65, 65, 65]))
    }

    @Test("decodes current per-model demand without inventing unavailable values")
    func decodesDemand() throws {
        let data = Data(#"""
        {"models":[
          {"id":"gemma","ready":true,"can_accept":true,"routable_providers":10,
           "warm_providers":4,"running_providers":2,"cold_providers":6,
           "active_requests":5,"queued_requests":1,"queue_limit":8,
           "aggregate_tps":120.5,"estimated_ttft_ms":300,
           "token_budget_remaining":900,"token_budget_total":1000}
        ]}
        """#.utf8)

        let response = try NetworkCapacityParser.parse(data, capturedAt: .init(timeIntervalSince1970: 5))
        let model = try #require(response.models.first)

        #expect(model.id == "gemma")
        #expect(model.activeRequests == 5)
        #expect(model.queuedRequests == 1)
        #expect(model.warmProviders == 4)
        #expect(model.demandPerWarmProvider == 1.5)
        #expect(model.demandBand == .urgent)
    }

    @Test("demand bands are derived from queue and active work per warm provider")
    func demandBands() {
        #expect(NetworkModelCapacity.demandBand(
            activeRequests: 0,
            queuedRequests: 0,
            warmProviders: 10
        ) == .low)
        #expect(NetworkModelCapacity.demandBand(
            activeRequests: 3,
            queuedRequests: 0,
            warmProviders: 10
        ) == .moderate)
        #expect(NetworkModelCapacity.demandBand(
            activeRequests: 7,
            queuedRequests: 0,
            warmProviders: 10
        ) == .high)
        #expect(NetworkModelCapacity.demandBand(
            activeRequests: 1,
            queuedRequests: 1,
            warmProviders: 100
        ) == .urgent)
        #expect(NetworkModelCapacity.demandBand(
            activeRequests: 1,
            queuedRequests: 0,
            warmProviders: 0
        ) == .urgent)
    }

    @Test("invalid negative or non-finite capacity is rejected")
    func rejectsInvalidCapacity() {
        let negative = Data(#"{"models":[{"id":"x","ready":true,"can_accept":true,"routable_providers":1,"warm_providers":1,"running_providers":0,"cold_providers":0,"active_requests":-1,"queued_requests":0,"queue_limit":8,"aggregate_tps":1,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1}]}"#.utf8)
        #expect(throws: NetworkCapacityError.invalidResponse) {
            try NetworkCapacityParser.parse(negative, capturedAt: .now)
        }
    }

    @Test("request uses the public capacity endpoint")
    func requestContract() {
        let request = NetworkCapacityRequest.make().urlRequest
        #expect(request.url?.absoluteString == "https://api.darkbloom.dev/v1/models/capacity")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 15)
    }

    @Test("capacity samples have a bounded age and future-skew window")
    func validatesSampleFreshnessWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fresh = NetworkCapacitySnapshot(
            models: [],
            capturedAt: now.addingTimeInterval(-NetworkCapacitySnapshot.maximumAge + 1)
        )
        let expired = NetworkCapacitySnapshot(
            models: [],
            capturedAt: now.addingTimeInterval(-NetworkCapacitySnapshot.maximumAge - 1)
        )
        let future = NetworkCapacitySnapshot(
            models: [],
            capturedAt: now.addingTimeInterval(NetworkCapacitySnapshot.maximumFutureSkew + 1)
        )

        #expect(fresh.isFresh(at: now))
        #expect(!expired.isFresh(at: now))
        #expect(!future.isFresh(at: now))
    }
}

private actor NetworkByteCounter {
    var reads = 0
    let total: Int
    init(total: Int) { self.total = total }
    func next() -> UInt8? {
        reads += 1
        return reads <= total ? 65 : nil
    }
}

private struct NetworkTestBytes: AsyncSequence {
    typealias Element = UInt8
    let counter: NetworkByteCounter
    func makeAsyncIterator() -> Iterator { Iterator(counter: counter) }
    struct Iterator: AsyncIteratorProtocol {
        let counter: NetworkByteCounter
        mutating func next() async -> UInt8? { await counter.next() }
    }
}
