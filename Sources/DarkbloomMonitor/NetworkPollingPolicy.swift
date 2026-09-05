import Foundation

struct NetworkPollingPolicy {
    private(set) var failures = 0

    mutating func failed() { failures = min(failures + 1, 5) }
    mutating func succeeded() { failures = 0 }

    func delay(dashboardVisible: Bool, automaticSwitching: Bool, jitter: Double = 0) -> TimeInterval {
        let base: Double = automaticSwitching ? 30 : (dashboardVisible ? 60 : 300)
        return PublicPollingBackoff.delay(base: base, cap: 900, failures: failures, jitter: jitter)
    }
}
