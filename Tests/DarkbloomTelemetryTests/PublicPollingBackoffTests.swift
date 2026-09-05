import Testing
@testable import DarkbloomMonitor

struct PublicPollingBackoffTests {
    @Test("successful sources keep their normal cadence and failures receive bounded jitter")
    func cadence() {
        #expect(PublicPollingBackoff.delay(base: 900, cap: 21_600, failures: 0, jitter: 0.2) == 900)
        #expect(PublicPollingBackoff.delay(base: 900, cap: 21_600, failures: 1, jitter: 0.2) == 2_160)
        #expect(abs(PublicPollingBackoff.delay(base: 1_800, cap: 21_600, failures: 2, jitter: 0.1) - 7_920) < 0.000_001)
        #expect(PublicPollingBackoff.delay(base: 300, cap: 3_600, failures: 1, jitter: 0.2) == 720)
    }

    @Test("invalid jitter cannot accelerate retries or exceed the cap")
    func bounds() {
        for jitter in [-1, Double.nan, Double.infinity] {
            #expect(PublicPollingBackoff.delay(base: 300, cap: 3_600, failures: 1, jitter: jitter) == 600)
        }
        #expect(PublicPollingBackoff.delay(base: 300, cap: 3_600, failures: 1, jitter: 5) == 720)
        #expect(PublicPollingBackoff.delay(base: 300, cap: 3_600, failures: Int.max, jitter: 0.2) == 3_600)
    }
}
