import Foundation

public struct EnergyEarnings: Equatable, Sendable {
    public let earningsUSD: Double
    public let electricityUSD: Double
    public let coveredSeconds: Double
    public let estimated: Bool
    public var afterElectricityUSD: Double { earningsUSD - electricityUSD }

    /// Include only completed earnings buckets with uninterrupted energy data.
    /// A boundary fragment uses proportional interval energy, so this remains
    /// an estimate even for a future wall-power source. No earnings prorating.
    public static func matching(buckets: [ActivityBucket], energy: [EnergyInterval],
                                day: DateInterval, now: Date) -> Self? {
        let intervals = energy.sorted { $0.start < $1.start }
        var previousEnd: Date?
        for item in intervals {
            guard item.end > item.start, item.kWh.isFinite, item.kWh >= 0,
                  item.usdPerKWh.isFinite, item.usdPerKWh >= 0,
                  item.costUSD.isFinite,
                  previousEnd.map({ item.start >= $0 }) ?? true else { return nil }
            previousEnd = item.end
        }
        var earnings = 0.0, cost = 0.0, seconds = 0.0
        var bucketEnd: Date?
        for bucket in buckets.sorted(by: { $0.interval.start < $1.interval.start }) {
            guard bucketEnd.map({ bucket.interval.start >= $0 }) ?? true else { return nil }
            bucketEnd = bucket.interval.end
            guard bucket.interval.duration > 0, bucket.interval.start >= day.start,
                  bucket.interval.end <= day.end, bucket.interval.end <= now,
                  bucket.coverage == .recorded, let totals = bucket.totals,
                  totals.workMicroUSD >= 0, totals.rewardMicroUSD >= 0 else { continue }
            var cursor = bucket.interval.start
            var bucketCost = 0.0
            for item in intervals where item.end > cursor && item.start < bucket.interval.end {
                guard item.start <= cursor else { break }
                let end = min(item.end, bucket.interval.end)
                bucketCost += item.costUSD * end.timeIntervalSince(cursor) / item.end.timeIntervalSince(item.start)
                cursor = end
                if cursor == bucket.interval.end { break }
            }
            guard cursor == bucket.interval.end else { continue }
            earnings += (Double(totals.workMicroUSD) + Double(totals.rewardMicroUSD)) / 1_000_000
            cost += bucketCost
            seconds += bucket.interval.duration
        }
        guard seconds > 0, earnings.isFinite, cost.isFinite else { return nil }
        return Self(earningsUSD: earnings, electricityUSD: cost, coveredSeconds: seconds, estimated: true)
    }
}
