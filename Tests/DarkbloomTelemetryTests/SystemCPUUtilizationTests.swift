import Testing
@testable import DarkbloomTelemetry

struct SystemCPUUtilizationTests {
    @Test("system CPU percentage uses busy ticks across all cores")
    func computesBusyPercentage() {
        let before = SystemCPUTimes(user: 100, system: 50, nice: 10, idle: 840)
        let after = SystemCPUTimes(user: 120, system: 60, nice: 10, idle: 910)

        #expect(SystemCPUUtilization.percentage(from: before, to: after) == 30)
    }

    @Test("CPU percentage is unavailable when counters do not advance or roll back")
    func rejectsInvalidCounterDelta() {
        let same = SystemCPUTimes(user: 100, system: 50, nice: 10, idle: 840)
        let reset = SystemCPUTimes(user: 1, system: 1, nice: 0, idle: 1)

        #expect(SystemCPUUtilization.percentage(from: same, to: same) == nil)
        #expect(SystemCPUUtilization.percentage(from: same, to: reset) == nil)
    }
}
