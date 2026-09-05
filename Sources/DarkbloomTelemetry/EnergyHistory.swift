import Foundation

public struct EnergyReading: Codable, Equatable, Sendable {
    public let date: Date
    public let watts: Double
    public let source: String
    public let estimated: Bool

    public init(date: Date, watts: Double, source: String, estimated: Bool) {
        self.date = date
        self.watts = watts
        self.source = source
        self.estimated = estimated
    }
}

public struct EnergyInterval: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let kWh: Double
    public let usdPerKWh: Double
    public let source: String
    public let estimated: Bool
    public var costUSD: Double { kWh * usdPerKWh }
}

/// Bounded measured intervals. A new process starts a new sample chain, never
/// interpolating across downtime. Each interval preserves the rate used then.
public struct EnergyHistory: Sendable {
    public private(set) var intervals: [EnergyInterval] = []
    private var previous: EnergyReading?
    private var previousRate: Double?
    public static let maximumIntervals = 60_480

    public init() {}

    public init(restoring intervals: [EnergyInterval]) throws {
        guard intervals.count <= Self.maximumIntervals else { throw EnergyHistoryError.invalidHistory }
        var end: Date?
        for interval in intervals {
            let duration = interval.end.timeIntervalSince(interval.start)
            guard interval.start.timeIntervalSince1970.isFinite,
                  interval.end.timeIntervalSince1970.isFinite,
                  duration > 0, duration <= 30,
                  end.map({ interval.start >= $0 }) ?? true,
                  interval.kWh.isFinite, interval.kWh >= 0,
                  interval.usdPerKWh.isFinite, interval.usdPerKWh >= 0,
                  interval.costUSD.isFinite, !interval.source.isEmpty else {
                throw EnergyHistoryError.invalidHistory
            }
            end = interval.end
        }
        self.intervals = intervals
    }

    public mutating func breakContinuity() {
        previous = nil
        previousRate = nil
    }

    public mutating func append(_ reading: EnergyReading, usdPerKWh: Double) {
        guard reading.date.timeIntervalSince1970.isFinite, reading.watts.isFinite,
              reading.watts >= 0, usdPerKWh.isFinite, usdPerKWh >= 0,
              !reading.source.isEmpty else { breakContinuity(); return }
        // A clock correction must not charge for time already recorded. Drop
        // the chain until the clock catches up, including after restoration.
        guard intervals.last.map({ reading.date >= $0.end }) ?? true,
              previous.map({ reading.date > $0.date }) ?? true else {
            breakContinuity()
            return
        }
        defer { previous = reading; previousRate = usdPerKWh }
        guard let last = previous, previousRate == usdPerKWh,
              last.source == reading.source, last.estimated == reading.estimated,
              let energy = ElectricityCost.kilowattHours(startWatts: last.watts,
                  endWatts: reading.watts, seconds: reading.date.timeIntervalSince(last.date)),
              (energy * usdPerKWh).isFinite else { return }
        intervals.append(EnergyInterval(start: last.date, end: reading.date, kWh: energy,
            usdPerKWh: usdPerKWh, source: reading.source, estimated: reading.estimated))
        if intervals.count > Self.maximumIntervals {
            intervals.removeFirst(intervals.count - Self.maximumIntervals)
        }
    }

    /// Entirely covered intervals only; no invented allocation at day boundaries.
    public func intervals(in period: DateInterval) -> [EnergyInterval] {
        intervals.filter { $0.start >= period.start && $0.end <= period.end }
    }
}

public enum EnergyHistoryError: Error {
    case invalidHistory
    case unsupportedSchema
    case tooLarge
}
