import Testing
@testable import DarkbloomTelemetry

struct ElectricityCostTests {
    @Test func validatesTariff() {
        #expect(ElectricityCost.rate(" 0.15 ") == 0.15)
        #expect(ElectricityCost.rate("0") == 0)
        for value in ["", "-1", "nan", "inf", "15 cents"] {
            #expect(ElectricityCost.rate(value) == nil)
        }
    }
    @Test func integratesMeasuredIntervalsOnly() {
        #expect(ElectricityCost.kilowattHours(startWatts: 100, endWatts: 200, seconds: 24) == 0.001)
        #expect(ElectricityCost.kilowattHours(startWatts: 100, endWatts: 100, seconds: 31) == nil)
        #expect(ElectricityCost.kilowattHours(startWatts: -1, endWatts: 100, seconds: 10) == nil)
        #expect(ElectricityCost.kilowattHours(startWatts: 100, endWatts: 100, seconds: 0) == nil)
    }
}
