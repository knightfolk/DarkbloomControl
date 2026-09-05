import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Activity query identity")
struct ActivityQueryTests {
    @Test("This Week follows the configured calendar week boundary")
    func weekBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 23)))
        let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7)))
        let first = ActivityQuery(period: .thisWeek, selectedDate: sunday, endDate: sunday, now: sunday, calendar: calendar, model: nil, revision: 0, refreshID: 0)
        let next = ActivityQuery(period: .thisWeek, selectedDate: sunday, endDate: sunday, now: monday, calendar: calendar, model: nil, revision: 0, refreshID: 0)
        #expect(first != next)
        #expect(next.range?.start == monday)
    }

    @Test("calendar rollover changes Today but not a selected historical range")
    func midnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = Date(timeIntervalSince1970: 86399)
        let after = Date(timeIntervalSince1970: 86400)
        func query(_ period: ActivityPeriod, _ now: Date, model: String? = nil) -> ActivityQuery {
            ActivityQuery(period: period, selectedDate: before, endDate: before, now: now,
                          calendar: calendar, model: model, revision: 0, refreshID: 0)
        }
        #expect(query(.today, before).range?.start == Date(timeIntervalSince1970: 0))
        #expect(query(.today, after).range?.start == after)
        #expect(query(.today, before) != query(.today, after))
        #expect(query(.dateRange, before) == query(.dateRange, after))
        #expect(query(.today, before) != query(.today, before, model: "all"))
    }
}
