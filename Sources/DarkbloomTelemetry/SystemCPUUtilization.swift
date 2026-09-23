import Foundation

/// Cumulative host CPU ticks from macOS. These are system-wide counters, not
/// utilization attributed to Darkbloom or any other individual process.
public struct SystemCPUTimes: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let nice: UInt64
    public let idle: UInt64

    public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
    }
}

public enum SystemCPUUtilization {
    /// Returns the percentage of elapsed host CPU ticks spent non-idle.
    /// A reset, rollback, or unchanged counter set is unavailable rather than
    /// being interpreted as zero usage.
    public static func percentage(from previous: SystemCPUTimes, to current: SystemCPUTimes) -> Double? {
        guard current.user >= previous.user,
              current.system >= previous.system,
              current.nice >= previous.nice,
              current.idle >= previous.idle else { return nil }

        let busy = (current.user - previous.user)
            + (current.system - previous.system)
            + (current.nice - previous.nice)
        let idle = current.idle - previous.idle
        let total = busy + idle
        guard total > 0 else { return nil }
        let value = Double(busy) / Double(total) * 100
        return value.isFinite ? min(100, max(0, value)) : nil
    }
}
