import Foundation

enum PublicPollingBackoff {
    static func delay(base: TimeInterval, cap: TimeInterval, failures: Int, jitter: Double) -> TimeInterval {
        let attempts = min(max(failures, 0), 16)
        guard attempts > 0 else { return min(base, cap) }
        let fraction = jitter.isFinite ? min(max(jitter, 0), 0.2) : 0
        return min(cap, base * pow(2, Double(attempts)) * (1 + fraction))
    }
}
