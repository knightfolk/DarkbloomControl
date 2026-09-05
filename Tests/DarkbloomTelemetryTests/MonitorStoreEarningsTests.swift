@testable import DarkbloomTelemetry
import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Monitor earnings state")
@MainActor
struct MonitorStoreEarningsTests {
    @Test("model work uses the calendar query and clears observations after read failure")
    func calendarModelWork() async throws {
        let now = Date(timeIntervalSince1970: 1788562800)
        let range = DateInterval(start: Calendar.current.startOfDay(for: now), end: now)
        let client = CalendarWorkClient(expectedRange: range)
        let store = MonitorStore(service: TelemetryService(source: EmptySource()), initial: .unavailable(now: now),
            earningsClient: client, now: { now })
        await store.refreshEarnings()
        #expect(store.modelWorkEarnings.count == 1)
        #expect(store.modelWorkEarnings.first?.queryPeriod == range)
        await store.refreshEarnings()
        #expect(store.modelWorkEarnings.isEmpty)
    }
    @Test("expired daily summary is not exposed to calendar UI")
    func expiredCalendarSummary() async {
        let now = Date()
        let store = MonitorStore(service: TelemetryService(source: EmptySource()), initial: .unavailable(now: now),
            earningsClient: StubEarningsClient(result: .success(.available(microUSD: 9_000_000)),
                todayEarningsResult: .success(ObservedEarningsWindow(microUSD: 1_000_000, observedSeconds: 60,
                    calendarDayStart: Calendar.current.startOfDay(for: now), capturedAt: now.addingTimeInterval(-601))),
                weekEarningsResult: .success(CalendarWeekEarningsSummary(microUSD: 2_000_000, isComplete: true,
                    weekStart: Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start,
                    capturedAt: now.addingTimeInterval(-601)))),
            now: { now })
        await store.refreshEarnings()
        #expect(store.todayEarnings != nil)
        #expect(store.currentTodayEarnings == nil)
        #expect(store.weekEarnings != nil)
        #expect(store.currentWeekEarnings == nil)
    }

    @Test("menu uses calendar earnings rather than the rolling account amount")
    func menuUsesCalendarDay() async {
        let captured = Date()
        let store = MonitorStore(
            service: TelemetryService(source: EmptySource()),
            initial: .unavailable(now: captured),
            earningsClient: StubEarningsClient(
                result: .success(.available(microUSD: 9_000_000)),
                todayEarningsResult: .success(ObservedEarningsWindow(
                    microUSD: 1_230_000, observedSeconds: 60,
                    calendarDayStart: Calendar.current.startOfDay(for: captured),
                    capturedAt: captured, coversDayToDate: false))),
            now: { captured }
        )
        await store.refreshEarnings()
        let menu = store.menuPresentation(mode: .earnings)
        #expect(menu.metricText == "$1.23/d*")
        #expect(menu.accessibilityLabel.contains("partial-day coverage"))
        #expect(!menu.accessibilityLabel.contains("24 hours"))
        #expect(store.currentTodayEarnings?.microUSD == 1_230_000)
    }

    @Test("each completed earnings acquisition invalidates Activity even when totals are unchanged")
    func invalidatesActivity() async {
        let store = MonitorStore(
            service: TelemetryService(source: EmptySource()),
            initial: .unavailable(now: Date()),
            earningsClient: StubEarningsClient(result: .success(.available(microUSD: 321_000)))
        )
        #expect(store.activityRevision == 0)
        await store.refreshEarnings()
        #expect(store.activityRevision == 1)
        await store.refreshEarnings()
        #expect(store.activityRevision == 2)
    }

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
        let now = Date()
        let summary = JobCompletionSummary(
            completedToday: 18,
            averagePerDay: 12.5,
            averagingDays: 7,
            dayStart: Calendar.current.startOfDay(for: now),
            capturedAt: now
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
        #expect(store.currentJobSummary == summary)
    }

    @Test("an authenticated refresh publishes recent earnings grouped by model")
    func refreshesModelEarnings() async {
        let values = [
            ModelEarnings(model: "gemma", microUSD: 500_000, jobs: 4),
            ModelEarnings(model: "gpt-oss", microUSD: 300_000, jobs: 2),
        ]
        let store = MonitorStore(
            service: TelemetryService(source: EmptySource()),
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000)),
            earningsClient: StubEarningsClient(
                result: .success(.available(microUSD: 800_000)),
                modelEarningsResult: .success(values)
            )
        )

        await store.refreshEarnings()

        #expect(store.modelEarnings == values)
    }
}

private struct StubEarningsClient: AccountEarningsFetching {
    let result: Result<EarningsPresentationValue, Error>
    var jobSummaryResult: Result<JobCompletionSummary?, Error> = .success(nil)
    var todayEarningsResult: Result<ObservedEarningsWindow?, Error> = .success(nil)
    var weekEarningsResult: Result<CalendarWeekEarningsSummary?, Error> = .success(nil)
    var modelEarningsResult: Result<[ModelEarnings], Error> = .success([])

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

    func modelEarnings(since: Date) async throws -> [ModelEarnings] {
        try modelEarningsResult.get()
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

private actor CalendarWorkClient: AccountEarningsFetching {
    let expectedRange: DateInterval
    var reads = 0
    init(expectedRange: DateInterval) { self.expectedRange = expectedRange }
    func fetch(now: Date) -> EarningsPresentationValue { .available(microUSD: 1) }
    func modelWorkEarnings(in range: DateInterval, calendar: Calendar) throws -> [ModelWorkEarnings] {
        #expect(range == expectedRange)
        reads += 1
        if reads > 1 { throw TestFailure() }
        return [ModelWorkEarnings(model: "model", queryPeriod: range, sourceCapturedAt: range.end,
            workMicroUSD: 100, jobs: 1, recordedHours: 1, unknownHours: 0, uncertainBoundaryHours: 1)]
    }
}
