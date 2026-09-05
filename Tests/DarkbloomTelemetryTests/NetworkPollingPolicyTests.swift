import Testing
@testable import DarkbloomMonitor

@Suite("Network polling policy")
struct NetworkPollingPolicyTests {
    @Test("visibility controls the network polling cadence")
    func cadence() {
        let policy = NetworkPollingPolicy()
        #expect(policy.delay(dashboardVisible: true) == 60)
        #expect(policy.delay(dashboardVisible: false) == 300)
    }

    @Test("failures back off to a cap and a successful acquisition resets the delay")
    func backoff() {
        var policy = NetworkPollingPolicy()
        policy.failed()
        #expect(policy.delay(dashboardVisible: true) == 120)
        policy.failed()
        #expect(policy.delay(dashboardVisible: true, jitter: 0.1) == 264)
        for _ in 0..<20 { policy.failed() }
        #expect(policy.delay(dashboardVisible: true, jitter: 0.2) == 900)
        policy.succeeded()
        #expect(policy.delay(dashboardVisible: true) == 60)
    }
}
