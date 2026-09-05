import Foundation

public enum ActivityCoverage: Equatable, Sendable {
    /// Recorded events are a lower bound, not proof of complete account history.
    case recorded
    case unavailable
    /// UTC-hour persistence cannot be split precisely at this local boundary.
    case boundaryUncertain
}

public struct ActivityTotals: Equatable, Sendable {
    public let workMicroUSD: Int64
    public let rewardMicroUSD: Int64
    public let jobs: Int64
    public let promptTokens: Int64
    public let completionTokens: Int64
}

public struct ActivityBucket: Equatable, Sendable, Identifiable {
    public let interval: DateInterval
    public let totals: ActivityTotals?
    public let coverage: ActivityCoverage
    public var id: Date { interval.start }
}

/// Observed work only, never a complete payout or account-wide reward claim.
public struct ModelWorkEarnings: Equatable, Sendable {
    public let model: String
    public let queryPeriod: DateInterval
    public let sourceCapturedAt: Date?
    public let workMicroUSD: Int64?
    public let jobs: Int64?
    public let recordedHours: Int
    public let unknownHours: Int
    public let uncertainBoundaryHours: Int
}

public enum ActivityCalendarError: Error, Equatable, Sendable {
    case invalidInterval
    case tooManyBuckets
}

public enum ActivityCalendarUnit: Hashable, Sendable {
    case hour, day

    fileprivate var component: Calendar.Component {
        switch self { case .hour: .hour; case .day: .day }
    }
}

/// Calendar boundaries are computed in the caller's timezone, never by assuming
/// that a day contains 24 hours. Date identity keeps repeated DST hours distinct.
public enum ActivityCalendar {
    public static func dateRange(
        from firstDate: Date,
        through lastDate: Date,
        calendar: Calendar,
        maximumDays: Int = 366
    ) throws -> DateInterval {
        guard firstDate.timeIntervalSince1970.isFinite,
              lastDate.timeIntervalSince1970.isFinite,
              maximumDays > 0 else { throw ActivityCalendarError.invalidInterval }
        let start = calendar.startOfDay(for: firstDate)
        let lastStart = calendar.startOfDay(for: lastDate)
        guard lastStart >= start,
              let end = calendar.date(byAdding: .day, value: 1, to: lastStart),
              let days = calendar.dateComponents([.day], from: start, to: end).day else {
            throw ActivityCalendarError.invalidInterval
        }
        guard days <= maximumDays else { throw ActivityCalendarError.tooManyBuckets }
        return DateInterval(start: start, end: end)
    }

    public static func intervals(
        in range: DateInterval,
        unit: ActivityCalendarUnit,
        calendar: Calendar,
        maximumBuckets: Int = 744
    ) throws -> [DateInterval] {
        guard range.start.timeIntervalSince1970.isFinite,
              range.end.timeIntervalSince1970.isFinite,
              range.duration >= 0, maximumBuckets > 0 else {
            throw ActivityCalendarError.invalidInterval
        }
        var result: [DateInterval] = []
        var cursor = range.start
        while cursor < range.end {
            guard result.count < maximumBuckets else { throw ActivityCalendarError.tooManyBuckets }
            guard let boundary = calendar.dateInterval(of: unit.component, for: cursor),
                  boundary.end > cursor else { throw ActivityCalendarError.invalidInterval }
            let end = min(boundary.end, range.end)
            result.append(DateInterval(start: cursor, end: end))
            cursor = end
        }
        return result
    }
}
