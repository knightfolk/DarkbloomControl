import Foundation
import Testing
@testable import DarkbloomTelemetry

struct MacAdapterPowerTests {
    @Test func convertsMilliwattsAndKeepsProvenance() {
        let reading = MacAdapterPower.decode(connected: true,
            telemetry: ["SystemPowerIn": 19277], now: Date(timeIntervalSince1970: 100))
        #expect(reading?.watts == 19.277)
        #expect(reading?.estimated == true)
        #expect(reading?.source == "Mac adapter input (DC estimate)")
    }

    @Test func unavailableDoesNotBecomeZero() {
        let now = Date()
        #expect(MacAdapterPower.decode(connected: false, telemetry: ["SystemPowerIn": 20000], now: now) == nil)
        for telemetry: [String: Any] in [[:], ["SystemPowerIn": 0], ["SystemPowerIn": -1],
                                        ["SystemPowerIn": true], ["SystemPowerIn": "20000"],
                                        ["SystemPowerIn": Double.infinity]] {
            #expect(MacAdapterPower.decode(connected: true, telemetry: telemetry, now: now) == nil)
        }
    }

    @Test("opt-in live adapter read", .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_ENERGY_PROBE"] == "1"))
    func liveRead() throws {
        let reading = try #require(MacAdapterPower.read())
        #expect(reading.watts > 0)
        print("Adapter input estimate: \(reading.watts) W")
    }
}
