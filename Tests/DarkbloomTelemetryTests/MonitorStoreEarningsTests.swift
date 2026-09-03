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
            earningsClient: StubEarningsClient(
                result: .success(.available(microUSD: 321_000)),
                todayEarningsResult: .success(ObservedEarningsWindow(
                    microUSD: 321_000,
                    observedSeconds: 86_400
                )),
                weekEarningsResult: .success(CalendarWeekEarningsSummary(
                    microUSD: 2_321_000,
                    isComplete: false
                ))
            )
        )

        await store.refreshEarnings()

        #expect(store.earnings == .available(microUSD: 321_000))
        #expect(abs((store.earningsPerHourUSD ?? 0) - 0.013_375) < 0.000_001)
        #expect(store.weekEarnings == CalendarWeekEarningsSummary(
            microUSD: 2_321_000,
            isComplete: false
        ))
    }

    @Test("stale earnings remove the hourly rate")
    func removesStaleHourlyRate() async {
        let client = SequencedEarningsClient(results: [
            .success(.available(microUSD: 2_400_000)),
            .failure(TestFailure()),
        ])
        let store = MonitorStore(
            service: TelemetryService(source: EmptySource()),
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000)),
            earningsClient: client
        )

        await store.refreshEarnings()
        #expect(store.earningsPerHourUSD != nil)
        await store.refreshEarnings()

        #expect(store.earningsPerHourUSD == nil)
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
    var todayEarningsResult: Result<ObservedEarningsWindow?, Error> = .success(nil)
    var weekEarningsResult: Result<CalendarWeekEarningsSummary?, Error> = .success(nil)

    func fetch(now: Date) async throws -> EarningsPresentationValue {
        try result.get()
    }

    func jobCompletionSummary(now: Date, calendar: Calendar) async throws -> JobCompletionSummary? {
        try jobSummaryResult.get()
    }

    func todayEarningsSummary(
        now: Date,
        calendar: Calendar
    ) async throws -> ObservedEarningsWindow? {
        try todayEarningsResult.get()
    }

    func weekEarningsSummary(
        now: Date,
        calendar: Calendar
    ) async throws -> CalendarWeekEarningsSummary? {
        try weekEarningsResult.get()
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

    func todayEarningsSummary(
        now: Date,
        calendar: Calendar
    ) -> ObservedEarningsWindow? {
        ObservedEarningsWindow(microUSD: 2_400_000, observedSeconds: 86_400)
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
