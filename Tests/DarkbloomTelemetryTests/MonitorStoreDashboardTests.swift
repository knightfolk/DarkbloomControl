import DarkbloomTelemetry
import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Monitor dashboard state")
@MainActor
struct MonitorStoreDashboardTests {
    @Test("network demand refresh publishes fresh data and preserves the last good sample as stale")
    func refreshesNetworkDemand() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let capacity = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"gemma","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":4,"running_providers":2,"cold_providers":6,"active_requests":5,"queued_requests":1,"queue_limit":8,"aggregate_tps":120.5,"estimated_ttft_ms":300,"token_budget_remaining":900,"token_budget_total":1000}]}"#.utf8),
            capturedAt: now.addingTimeInterval(-1)
        )
        let client = DashboardCapacityClient(result: .success(capacity))
        let store = MonitorStore(
            service: TelemetryService(source: AdvancingDashboardSource()),
            initial: .unavailable(now: Date(timeIntervalSince1970: 2_000_000)),
            earningsClient: EmptyDashboardEarningsClient(),
            networkCapacityClient: client,
            now: { now }
        )

        await store.refreshNetworkCapacity()
        guard case .available(let fresh, _) = store.networkCapacity else {
            Issue.record("Expected fresh network demand")
            return
        }
        #expect(fresh.models.first?.id == "gemma")

        await client.setResult(.failure(DashboardCapacityError()))
        await store.refreshNetworkCapacity()
        guard case .stale(let stale, _, _) = store.networkCapacity else {
            Issue.record("Expected the last good network demand to become stale")
            return
        }
        #expect(stale.models.first?.activeRequests == 5)
    }

    @Test("expired network demand preserves the last good sample as stale")
    func expiresNetworkDemand() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fresh = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"fresh","ready":true,"can_accept":true,"routable_providers":1,"warm_providers":1,"running_providers":1,"cold_providers":0,"active_requests":1,"queued_requests":0,"queue_limit":8,"aggregate_tps":10,"estimated_ttft_ms":100,"token_budget_remaining":9,"token_budget_total":10}]}"#.utf8),
            capturedAt: now.addingTimeInterval(-1)
        )
        let expired = NetworkCapacitySnapshot(
            models: fresh.models,
            capturedAt: now.addingTimeInterval(-NetworkCapacitySnapshot.maximumAge - 1)
        )
        let client = DashboardCapacityClient(result: .success(fresh))
        let store = MonitorStore(
            service: TelemetryService(source: AdvancingDashboardSource()),
            initial: .unavailable(now: now),
            earningsClient: EmptyDashboardEarningsClient(),
            networkCapacityClient: client,
            now: { now }
        )

        await store.refreshNetworkCapacity()
        await client.setResult(.success(expired))
        await store.refreshNetworkCapacity()

        guard case .stale(let stale, let capturedAt, _) = store.networkCapacity else {
            Issue.record("Expected an expired sample to preserve the last good sample as stale")
            return
        }
        #expect(stale == fresh)
        #expect(capturedAt == fresh.capturedAt)
    }

    @Test("future-dated network demand is rejected")
    func rejectsFutureNetworkDemand() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let future = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"future","ready":true,"can_accept":true,"routable_providers":1,"warm_providers":1,"running_providers":1,"cold_providers":0,"active_requests":1,"queued_requests":0,"queue_limit":8,"aggregate_tps":10,"estimated_ttft_ms":100,"token_budget_remaining":9,"token_budget_total":10}]}"#.utf8),
            capturedAt: now.addingTimeInterval(NetworkCapacitySnapshot.maximumFutureSkew + 1)
        )
        let client = DashboardCapacityClient(result: .success(future))
        let store = MonitorStore(
            service: TelemetryService(source: AdvancingDashboardSource()),
            initial: .unavailable(now: now),
            earningsClient: EmptyDashboardEarningsClient(),
            networkCapacityClient: client,
            now: { now }
        )

        await store.refreshNetworkCapacity()

        #expect(store.networkCapacity == .unavailable(reason: "Network demand is unavailable"))
    }

    @Test("an older overlapping refresh cannot replace a newer network sample")
    func ignoresOutOfOrderNetworkRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let older = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"older","ready":true,"can_accept":true,"routable_providers":1,"warm_providers":1,"running_providers":1,"cold_providers":0,"active_requests":1,"queued_requests":0,"queue_limit":8,"aggregate_tps":10,"estimated_ttft_ms":100,"token_budget_remaining":9,"token_budget_total":10}]}"#.utf8),
            capturedAt: now.addingTimeInterval(-1)
        )
        let newer = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"newer","ready":true,"can_accept":true,"routable_providers":1,"warm_providers":1,"running_providers":1,"cold_providers":0,"active_requests":2,"queued_requests":0,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":90,"token_budget_remaining":8,"token_budget_total":10}]}"#.utf8),
            capturedAt: now.addingTimeInterval(-1)
        )
        let client = OverlappingDashboardCapacityClient(older: older, newer: newer)
        let store = MonitorStore(
            service: TelemetryService(source: AdvancingDashboardSource()),
            initial: .unavailable(now: now),
            earningsClient: EmptyDashboardEarningsClient(),
            networkCapacityClient: client,
            now: { now }
        )

        let first = Task { await store.refreshNetworkCapacity() }
        await client.waitForFirstRequest()
        await store.refreshNetworkCapacity()
        await client.releaseOlderRequest()
        await first.value

        guard case .available(let value, let capturedAt) = store.networkCapacity else {
            Issue.record("Expected the newer network sample to remain available")
            return
        }
        #expect(value == newer)
        #expect(capturedAt == newer.capturedAt)
    }

    @Test("observed token progress updates the active-session average")
    func updatesAverageTokenRate() async {
        let source = AdvancingDashboardSource()
        let recorder = RecordingModelTokenRates()
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 2_000_000)),
            earningsClient: EmptyDashboardEarningsClient(),
            tokenRateRecorder: recorder
        )

        await store.refreshTelemetryImmediately()

        #expect(store.modelTokenRateAverages == [
            ModelTokenRateAverage(model: "gemma", tokensPerSecond: 10, sampleCount: 1),
        ])
        #expect(await recorder.recordedModels == ["gemma"])
        #expect(store.currentModelTokenRateAverages.isEmpty)
        #expect(store.currentDayAverageTokenRate == nil)
    }

    @Test("immediate telemetry refresh awaits a new post-command read")
    func refreshesTelemetryImmediately() async throws {
        let source = ImmediateDashboardRefreshSource()
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 2_000_000)),
            earningsClient: EmptyDashboardEarningsClient()
        )

        await store.refreshTelemetryImmediately()

        #expect(await source.stateReadCount == 2)
        #expect(await source.statusReadCount == 2)
        #expect(store.snapshot.status.value?.enabledModelFilter == "generation-2")
    }

    @Test("an empty calendar day never falls back to an older session average")
    func doesNotCarrySessionAverageIntoEmptyDay() async {
        let service = TelemetryService(
            source: AdvancingDashboardSource(),
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 2_000_000)),
            earningsClient: EmptyDashboardEarningsClient(),
            tokenRateRecorder: DiscardingModelTokenRates()
        )

        await store.refreshTelemetryImmediately()

        #expect(store.averageTokenRate == .unavailable(
            reason: "No measured token rates today"
        ))
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private struct DashboardCapacityError: Error {}

private actor DashboardCapacityClient: NetworkCapacityFetching {
    private var result: Result<NetworkCapacitySnapshot, any Error>

    init(result: Result<NetworkCapacitySnapshot, any Error>) {
        self.result = result
    }

    func setResult(_ result: Result<NetworkCapacitySnapshot, any Error>) {
        self.result = result
    }

    func fetch(at capturedAt: Date) async throws -> NetworkCapacitySnapshot {
        try result.get()
    }
}

private actor OverlappingDashboardCapacityClient: NetworkCapacityFetching {
    private let older: NetworkCapacitySnapshot
    private let newer: NetworkCapacitySnapshot
    private var callCount = 0
    private var firstRequestStarted = false
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var olderRequestContinuation: CheckedContinuation<NetworkCapacitySnapshot, Never>?

    init(older: NetworkCapacitySnapshot, newer: NetworkCapacitySnapshot) {
        self.older = older
        self.newer = newer
    }

    func waitForFirstRequest() async {
        if firstRequestStarted { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func releaseOlderRequest() {
        olderRequestContinuation?.resume(returning: older)
        olderRequestContinuation = nil
    }

    func fetch(at capturedAt: Date) async throws -> NetworkCapacitySnapshot {
        callCount += 1
        if callCount == 1 {
            firstRequestStarted = true
            firstRequestWaiters.forEach { $0.resume() }
            firstRequestWaiters.removeAll()
            return await withCheckedContinuation { continuation in
                olderRequestContinuation = continuation
            }
        }
        return newer
    }
}

private actor DiscardingModelTokenRates: ModelTokenRateRecording {
    func record(
        model: String,
        tokensPerSecond: Double,
        capturedAt: Date,
        processIdentity: ProcessIdentity,
        writtenAt: TimeInterval
    ) {}

    func averages(
        from start: Date,
        through end: Date
    ) -> [ModelTokenRateAverage] {
        []
    }
}

private actor RecordingModelTokenRates: ModelTokenRateRecording {
    private(set) var recordedModels: [String] = []
    private var rates: [Double] = []

    func record(
        model: String,
        tokensPerSecond: Double,
        capturedAt: Date,
        processIdentity: ProcessIdentity,
        writtenAt: TimeInterval
    ) {
        recordedModels.append(model)
        rates.append(tokensPerSecond)
    }

    func averages(
        from start: Date,
        through end: Date
    ) -> [ModelTokenRateAverage] {
        guard !rates.isEmpty else { return [] }
        return [ModelTokenRateAverage(
            model: "gemma",
            tokensPerSecond: rates.reduce(0, +) / Double(rates.count),
            sampleCount: rates.count
        )]
    }
}

private actor ImmediateDashboardRefreshSource: TelemetrySource {
    private(set) var stateReadCount = 0
    private(set) var statusReadCount = 0

    func readDaemonState() async throws -> DaemonState {
        stateReadCount += 1
        return DaemonState(
            schema: 1,
            version: "1.0",
            currentModel: "model-\(stateReadCount)",
            warmModels: [],
            stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
            trust: TrustState(
                level: "hardware",
                status: "online",
                reason: "same_binary",
                receivedAt: 1_999_900
            ),
            capacity: MemoryCapacity(
                totalMemoryGB: 64,
                gpuMemoryActiveGB: 0,
                gpuMemoryCacheGB: 0
            ),
            slots: [],
            inferenceActive: false,
            startedAt: 1_999_000,
            writtenAt: 1_999_900 + Double(stateReadCount),
            pid: 42,
            processIdentity: ProcessIdentity(pid: 42, startTimeMicros: 9_000)
        )
    }

    func readLoadedModels() async throws -> LoadedModelsState {
        LoadedModelsState(schema: 1, models: [], updatedAt: 1_999_900)
    }

    func readStatus() async throws -> StatusSnapshot {
        statusReadCount += 1
        var status = StatusSnapshot()
        status.enabledModelFilter = "generation-\(statusReadCount)"
        return status
    }

    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { [] }
}

private actor AdvancingDashboardSource: TelemetrySource {
    private var stateReads: Int64 = 0

    func readDaemonState() async throws -> DaemonState {
        stateReads += 1
        return DaemonState(
            schema: 1,
            version: "1.0",
            currentModel: "gemma",
            warmModels: ["gemma"],
            stats: ProviderStats(
                tokensGenerated: stateReads * 20,
                requestsServed: stateReads,
                usageGaps: 0
            ),
            trust: TrustState(
                level: "hardware",
                status: "online",
                reason: "same_binary",
                receivedAt: 1_999_900
            ),
            capacity: MemoryCapacity(
                totalMemoryGB: 64,
                gpuMemoryActiveGB: 20,
                gpuMemoryCacheGB: 2
            ),
            slots: [],
            inferenceActive: true,
            startedAt: 1_999_000,
            writtenAt: 1_999_900 + Double(stateReads * 2),
            pid: 42,
            processIdentity: ProcessIdentity(pid: 42, startTimeMicros: 9_000)
        )
    }

    func readLoadedModels() async throws -> LoadedModelsState {
        LoadedModelsState(schema: 1, models: ["gemma"], updatedAt: 1_999_900)
    }

    func readStatus() async throws -> StatusSnapshot {
        var status = StatusSnapshot()
        status.enabledModelFilter = "gemma, gpt-oss"
        return status
    }

    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { [] }
}

private struct EmptyDashboardEarningsClient: AccountEarningsFetching {
    func fetch(now: Date) async throws -> EarningsPresentationValue {
        .unavailable(reason: "unused")
    }
}
