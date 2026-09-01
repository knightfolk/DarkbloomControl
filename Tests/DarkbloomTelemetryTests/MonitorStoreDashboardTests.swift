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
        let service = TelemetryService(
            source: source,
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 2_000_000)),
            earningsClient: EmptyDashboardEarningsClient()
        )

        store.start()
        _ = await service.refreshNow()
        _ = await service.refreshNow()
        let observed = await eventually {
            store.averageTokenRate == .available(
                tokensPerSecond: 10,
                label: "active session average"
            )
        }
        await store.stop()

        #expect(observed)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
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
