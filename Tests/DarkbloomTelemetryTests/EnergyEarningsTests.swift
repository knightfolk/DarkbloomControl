import Foundation
import Testing
@testable import DarkbloomTelemetry

struct EnergyEarningsTests {
    @Test func calendarDayExcludesYesterdayAndUnfinishedHoursAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let day = try #require(calendar.dateInterval(of: .day, for: date))
        #expect(day.duration == 23 * 3600)
        let now = day.start.addingTimeInterval(5400)
        func bucket(_ start: Date) -> ActivityBucket {
            .init(interval: DateInterval(start: start, duration: 3600),
                  totals: .init(workMicroUSD: 1_000_000, rewardMicroUSD: 0,
                                jobs: 1, promptTokens: 0, completionTokens: 0), coverage: .recorded)
        }
        let buckets = [-3600.0, 0, 3600].map { bucket(day.start.addingTimeInterval($0)) }
        let energy = stride(from: -3600.0, to: 7200, by: 10).map { offset in
            EnergyInterval(start: day.start.addingTimeInterval(offset),
                           end: day.start.addingTimeInterval(offset + 10),
                           kWh: 1.0 / 3600, usdPerKWh: 0.2, source: "fixture", estimated: true)
        }
        let result = try #require(EnergyEarnings.matching(buckets: buckets, energy: energy, day: day, now: now))
        #expect(result.earningsUSD == 1)
        #expect(result.coveredSeconds == 3600)
        #expect(abs(result.electricityUSD - 0.02) < 0.000000001)
    }

    @Test func excludesGapsAndDoesNotProrateEarnings() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(20)
        let period = DateInterval(start: start, end: end)
        let bucket = ActivityBucket(interval: period, totals: .init(workMicroUSD: 1_000_000,
            rewardMicroUSD: 0, jobs: 1, promptTokens: 0, completionTokens: 0), coverage: .recorded)
        let first = EnergyInterval(start: start, end: start.addingTimeInterval(10),
            kWh: 0.001, usdPerKWh: 0.2, source: "test", estimated: true)
        #expect(EnergyEarnings.matching(buckets: [bucket], energy: [first], day: period, now: end) == nil)
        let second = EnergyInterval(start: first.end, end: end,
            kWh: 0.001, usdPerKWh: 0.3, source: "test", estimated: true)
        let result = try #require(EnergyEarnings.matching(buckets: [bucket], energy: [first, second], day: period, now: end))
        #expect(result.electricityUSD == 0.0005)
        #expect(result.afterElectricityUSD == 0.9995)
        #expect(result.coveredSeconds == 20)
        #expect(EnergyEarnings.matching(buckets: [bucket, bucket], energy: [first, second], day: period, now: end) == nil)
    }
}
