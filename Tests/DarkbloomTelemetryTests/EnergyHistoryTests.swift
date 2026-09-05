import Foundation
import Testing
@testable import DarkbloomTelemetry

struct EnergyHistoryTests {
    @Test func clockReversalNeverOverlapsSavedEnergy() throws {
        var history = EnergyHistory()
        func reading(_ seconds: Double) -> EnergyReading {
            EnergyReading(date: Date(timeIntervalSince1970: seconds), watts: 100,
                          source: "adapter input", estimated: true)
        }
        for seconds in [100.0, 110, 105, 115, 125] {
            history.append(reading(seconds), usdPerKWh: 0.15)
        }
        #expect(history.intervals.map(\.start.timeIntervalSince1970) == [100, 115])
        #expect(history.intervals.map(\.end.timeIntervalSince1970) == [110, 125])
        let restored = try EnergyHistory(restoring: history.intervals)
        #expect(restored.intervals == history.intervals)
    }

    @Test func gapsAndTariffChangesRemainUnknown() {
        var history = EnergyHistory()
        let origin = Date(timeIntervalSince1970: 1000)
        func reading(_ seconds: Double) -> EnergyReading {
            EnergyReading(date: origin.addingTimeInterval(seconds), watts: 100,
                          source: "adapter input", estimated: true)
        }
        history.append(reading(0), usdPerKWh: 0.15)
        history.append(reading(10), usdPerKWh: 0.15)
        history.append(reading(60), usdPerKWh: 0.15)
        history.append(reading(70), usdPerKWh: 0.20)
        history.append(reading(80), usdPerKWh: 0.20)
        #expect(history.intervals.count == 2)
        #expect(history.intervals.map(\.usdPerKWh) == [0.15, 0.20])
        history.breakContinuity()
        history.append(reading(90), usdPerKWh: 0.20)
        #expect(history.intervals.count == 2)
        #expect(history.intervals(in: DateInterval(start: origin.addingTimeInterval(5),
                                                  end: origin.addingTimeInterval(80))).count == 1)
    }
}
