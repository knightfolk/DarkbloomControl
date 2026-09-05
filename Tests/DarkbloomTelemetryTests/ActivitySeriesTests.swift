import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Calendar activity intervals")
struct ActivitySeriesTests {
    @Test("date ranges include the final calendar day across DST")
    func inclusiveDateRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 8)))
        let range = try ActivityCalendar.dateRange(from: start, through: end, calendar: calendar)
        #expect(range.duration == 71 * 3600)
        #expect(calendar.component(.day, from: range.end) == 10)
        #expect(throws: ActivityCalendarError.invalidInterval) {
            try ActivityCalendar.dateRange(from: end, through: start, calendar: calendar)
        }
        #expect(throws: ActivityCalendarError.tooManyBuckets) {
            try ActivityCalendar.dateRange(from: start, through: end, calendar: calendar, maximumDays: 2)
        }
    }

    @Test("spring and fall calendar days contain 23 and 25 distinct hours")
    func daylightSavingHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        for (month, day, count) in [(3, 8, 23), (11, 1, 25)] {
            let date = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
            let interval = try #require(calendar.dateInterval(of: .day, for: date))
            let hours = try ActivityCalendar.intervals(in: interval, unit: .hour, calendar: calendar)
            #expect(hours.count == count)
            #expect(Set(hours.map(\.start)).count == count)
            #expect(hours.first?.start == interval.start)
            #expect(hours.last?.end == interval.end)
            for pair in zip(hours, hours.dropFirst()) { #expect(pair.0.end == pair.1.start) }
        }
    }

    @Test("partial first and last hours are clipped rather than expanded")
    func clipsPartialHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let interval = DateInterval(start: Date(timeIntervalSince1970: 900), end: Date(timeIntervalSince1970: 4500))
        let values = try ActivityCalendar.intervals(in: interval, unit: .hour, calendar: calendar)
        #expect(values == [
            DateInterval(start: Date(timeIntervalSince1970: 900), end: Date(timeIntervalSince1970: 3600)),
            DateInterval(start: Date(timeIntervalSince1970: 3600), end: Date(timeIntervalSince1970: 4500))
        ])
    }

    @Test("oversized requests fail instead of silently truncating history")
    func boundedRequest() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600 * 100)
        #expect(throws: ActivityCalendarError.tooManyBuckets) {
            try ActivityCalendar.intervals(in: interval, unit: .hour, calendar: Calendar(identifier: .gregorian), maximumBuckets: 24)
        }
    }
}
