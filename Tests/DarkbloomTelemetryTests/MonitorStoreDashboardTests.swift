import DarkbloomTelemetry
import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Monitor dashboard state")
@MainActor
struct MonitorStoreDashboardTests {
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
