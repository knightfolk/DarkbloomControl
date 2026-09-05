import Foundation
import Testing
@testable import DarkbloomTelemetry

struct CalendarTokenRateTests {
    @Test("today rates reject old undated duplicate and future query windows")
    func currentDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 86399)
        let valid = ModelTokenRateAverage(model: "a", tokensPerSecond: 10, sampleCount: 1,
            queryPeriod: DateInterval(start: Date(timeIntervalSince1970: 0), end: now))
        let undated = ModelTokenRateAverage(model: "b", tokensPerSecond: 30, sampleCount: 3)
        #expect(CalendarTokenRates.current([valid, undated], at: now, calendar: calendar) == [valid])
        #expect(CalendarTokenRates.current([valid, valid], at: now, calendar: calendar).isEmpty)
        #expect(CalendarTokenRates.current([valid], at: now.addingTimeInterval(1), calendar: calendar).isEmpty)
        #expect(CalendarTokenRates.current([valid], at: now.addingTimeInterval(-1), calendar: calendar).isEmpty)
        let early = ModelTokenRateAverage(model: "a", tokensPerSecond: 10, sampleCount: 1,
            queryPeriod: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100)))
        #expect(CalendarTokenRates.current([early], at: Date(timeIntervalSince1970: 701), calendar: calendar).isEmpty)
    }

    @Test("day average weights real sample counts and omits invalid input")
    func weighted() {
        let values = [ModelTokenRateAverage(model: "a", tokensPerSecond: 10, sampleCount: 1),
                      ModelTokenRateAverage(model: "b", tokensPerSecond: 30, sampleCount: 3)]
        #expect(CalendarTokenRates.weightedAverage(values) == 25)
        #expect(CalendarTokenRates.weightedAverage([]) == nil)
        #expect(CalendarTokenRates.weightedAverage([ModelTokenRateAverage(model: "a", tokensPerSecond: .infinity, sampleCount: 1)]) == nil)
    }
}
