import Foundation
import Testing
@testable import DarkbloomTelemetry

struct CalendarMenuEarningsTests {
    @Test("completed jobs cannot be presented as today after midnight or expiry")
    func jobFreshness() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 0)
        let captured = Date(timeIntervalSince1970: 86399)
        let value = JobCompletionSummary(completedToday: 7, averagePerDay: 2, averagingDays: 7,
            dayStart: day, capturedAt: captured)
        #expect(value.isCurrent(at: captured, calendar: calendar))
        #expect(!value.isCurrent(at: Date(timeIntervalSince1970: 86400), calendar: calendar))
        #expect(!value.isCurrent(at: captured.addingTimeInterval(-1), calendar: calendar))
        let old = JobCompletionSummary(completedToday: 0, averagePerDay: nil, averagingDays: 7,
            dayStart: day, capturedAt: day)
        #expect(old.isCurrent(at: day.addingTimeInterval(600), calendar: calendar))
        #expect(!old.isCurrent(at: day.addingTimeInterval(601), calendar: calendar))
        #expect(!JobCompletionSummary(completedToday: 7, averagePerDay: 2, averagingDays: 7)
            .isCurrent(at: captured, calendar: calendar))
    }
    @Test("weekly totals expire across the locale week boundary and on stale capture")
    func weeklyFreshness() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let before = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 23, minute: 59, second: 59)))
        let start = try #require(calendar.dateInterval(of: .weekOfYear, for: before)?.start)
        let value = CalendarWeekEarningsSummary(microUSD: 0, isComplete: false, weekStart: start, capturedAt: before)
        #expect(value.isCurrent(at: before, calendar: calendar))
        #expect(!value.isCurrent(at: before.addingTimeInterval(1), calendar: calendar))
        #expect(!value.isCurrent(at: before.addingTimeInterval(-1), calendar: calendar))
        let early = CalendarWeekEarningsSummary(microUSD: 100, isComplete: true, weekStart: start, capturedAt: start)
        #expect(early.isCurrent(at: start.addingTimeInterval(600), calendar: calendar))
        #expect(!early.isCurrent(at: start.addingTimeInterval(601), calendar: calendar))
        #expect(!CalendarWeekEarningsSummary(microUSD: 100, isComplete: true).isCurrent(at: before, calendar: calendar))
        calendar.firstWeekday = 1
        #expect(!value.isCurrent(at: before, calendar: calendar))
    }
    @Test("calendar menu earnings expire at midnight and reject old observations")
    func freshness() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_788_480_000)
        let captured = day.addingTimeInterval(86_390)
        let value = ObservedEarningsWindow(microUSD: 123_000, observedSeconds: 86_390,
            calendarDayStart: day, capturedAt: captured, coversDayToDate: true)
        #expect(EarningsPresentationValue.calendarDay(value, now: captured, calendar: calendar) == .day(microUSD: 123_000, complete: true))
        if case .unavailable = EarningsPresentationValue.calendarDay(value, now: day.addingTimeInterval(86_401), calendar: calendar) {} else { Issue.record("Yesterday was displayed as today") }
        if case .unavailable = EarningsPresentationValue.calendarDay(value, now: captured.addingTimeInterval(-1), calendar: calendar) {} else { Issue.record("Future observation accepted") }
        let partial = ObservedEarningsWindow(microUSD: 0, observedSeconds: 60, calendarDayStart: day, capturedAt: day.addingTimeInterval(120))
        #expect(EarningsPresentationValue.calendarDay(partial, now: day.addingTimeInterval(120), calendar: calendar) == .day(microUSD: 0, complete: false))
        if case .unavailable = EarningsPresentationValue.calendarDay(partial, now: day.addingTimeInterval(721), calendar: calendar) {} else { Issue.record("Expired observation accepted") }
    }
}
