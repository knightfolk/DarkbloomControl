import Foundation
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Network cache health collector")
@MainActor
struct NetworkCacheStoreTests {
    @Test func failedRefreshKeepsExplicitlyStaleEvidence() async throws {
        let client = CacheFixtureClient()
        let store = NetworkCacheStore(client: client)
        await store.refresh()
        guard case .available = store.source else { Issue.record("Expected fresh source"); return }
        await client.fail()
        await store.refresh()
        guard case .stale(let value, _, _) = store.source else { Issue.record("Expected stale source"); return }
        #expect(value.plannerReady == true)
    }

    @Test func cancellationDoesNotPublishLateData() async {
        let store = NetworkCacheStore(client: CacheFixtureClient())
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; await store.refresh() }
        await task.value
        #expect(store.source.value == nil)
    }
}

private actor CacheFixtureClient: NetworkCacheFetching {
    var shouldFail = false
    func fail() { shouldFail = true }
    func fetch(at capturedAt: Date) async throws -> NetworkCacheSnapshot {
        if shouldFail { throw NetworkCapacityError.invalidResponse }
        return try NetworkCacheSnapshot.parse(Data(#"{"routing_mode":"on","sidecar":{"ready":true}}"#.utf8), capturedAt: capturedAt)
    }
}
