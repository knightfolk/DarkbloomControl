import DarkbloomTelemetry
import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Monitor earnings state")
@MainActor
struct MonitorStoreEarningsTests {
    @Test("earnings collection interval is short enough for capped account history")
    func collectionInterval() {
        #expect(MonitorStore.earningsPollingInterval == .seconds(600))
    }

    @Test("a successful authenticated refresh becomes the current menu value")
    func refreshesEarnings() async {
        let store = MonitorStore(
            service: TelemetryService(source: EmptySource()),
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000)),
            earningsClient: StubEarningsClient(result: .success(.available(microUSD: 321_000)))
        )

        await store.refreshEarnings()

        #expect(store.earnings == .available(microUSD: 321_000))
    }

    @Test("a failed refresh marks a prior value stale instead of presenting it as current")
    func marksLastGoodEarningsStale() async {
        let client = SequencedEarningsClient(results: [
            .success(.available(microUSD: 321_000)),
            .failure(TestFailure()),
        ])
        let store = MonitorStore(
            service: TelemetryService(source: EmptySource()),
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000)),
            earningsClient: client
        )

        await store.refreshEarnings()
        await store.refreshEarnings()

        #expect(store.earnings == .stale(
            microUSD: 321_000,
            reason: "Network unavailable"
        ))
    }

    @Test("an authenticated refresh publishes completed-job dashboard metrics")
    func refreshesJobSummary() async {
        let summary = JobCompletionSummary(
            completedToday: 18,
            averagePerDay: 12.5,
            averagingDays: 7
        )
        let store = MonitorStore(
            service: TelemetryService(source: EmptySource()),
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000)),
            earningsClient: StubEarningsClient(
                result: .success(.available(microUSD: 321_000)),
                jobSummaryResult: .success(summary)
            )
        )

        await store.refreshEarnings()

        #expect(store.jobSummary.value == summary)
    }
}

private struct StubEarningsClient: AccountEarningsFetching {
    let result: Result<EarningsPresentationValue, Error>
    var jobSummaryResult: Result<JobCompletionSummary?, Error> = .success(nil)

    func fetch(now: Date) async throws -> EarningsPresentationValue {
        try result.get()
    }

    func jobCompletionSummary(now: Date, calendar: Calendar) async throws -> JobCompletionSummary? {
        try jobSummaryResult.get()
    }
}

private actor SequencedEarningsClient: AccountEarningsFetching {
    private var results: [Result<EarningsPresentationValue, Error>]

    init(results: [Result<EarningsPresentationValue, Error>]) {
        self.results = results
    }

    func fetch(now: Date) async throws -> EarningsPresentationValue {
        try results.removeFirst().get()
    }
}

private struct EmptySource: TelemetrySource {
    func readDaemonState() async throws -> DaemonState { throw TestFailure() }
    func readLoadedModels() async throws -> LoadedModelsState { throw TestFailure() }
    func readStatus() async throws -> StatusSnapshot { throw TestFailure() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw TestFailure() }
}

private struct TestFailure: LocalizedError {
    var errorDescription: String? { "Network unavailable" }
}
