import Foundation

public enum CalendarTokenRates {
    public static func current(_ values: [ModelTokenRateAverage], at now: Date, calendar: Calendar) -> [ModelTokenRateAverage] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        let counts = Dictionary(grouping: values, by: \.model).mapValues(\.count)
        let start = calendar.startOfDay(for: now)
        return values.filter { value in
            guard counts[value.model] == 1, value.sampleCount > 0,
                  value.tokensPerSecond.isFinite, value.tokensPerSecond > 0,
                  let period = value.queryPeriod, period.start == start else { return false }
            let age = now.timeIntervalSince(period.end)
            return age.isFinite && (0...600).contains(age)
        }
    }

    /// Caller supplies a single qualified query period, not mixed historical windows.
    public static func weightedAverage(_ values: [ModelTokenRateAverage]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0.sampleCount > 0 && $0.tokensPerSecond.isFinite && $0.tokensPerSecond > 0 }) else { return nil }
        let samples = values.reduce(0.0) { $0 + Double($1.sampleCount) }
        let result = values.reduce(0.0) { $0 + $1.tokensPerSecond * (Double($1.sampleCount) / samples) }
        return result.isFinite ? result : nil
    }
}
