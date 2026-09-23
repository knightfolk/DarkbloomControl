import Foundation
import Testing
@testable import DarkbloomTelemetry

struct ModelScenarioForecastTests {
    @Test("model runtime power samples survive the energy interval")
    func carriesModelStateIntoPowerInterval() throws {
        var history = EnergyHistory()
        history.append(
            EnergyReading(date: Date(timeIntervalSince1970: 10), watts: 50, source: "adapter", estimated: true),
            usdPerKWh: 0.2,
            modelActivity: ModelPowerActivity(modelID: "google/gemma", inferenceActive: true)
        )
        history.append(
            EnergyReading(date: Date(timeIntervalSince1970: 20), watts: 100, source: "adapter", estimated: true),
            usdPerKWh: 0.2,
            modelActivity: ModelPowerActivity(modelID: "google/gemma", inferenceActive: false)
        )

        let interval = try #require(history.intervals.first)
        #expect(interval.activeModelID == "google/gemma")
        #expect(interval.inferenceActive == true)
    }

    @Test("older saved energy intervals decode without model activity fields")
    func decodesLegacyEnergyInterval() throws {
        let data = Data(#"{"start":100,"end":110,"kWh":0.001,"usdPerKWh":0.2,"source":"adapter","estimated":true}"#.utf8)

        let interval = try JSONDecoder().decode(EnergyInterval.self, from: data)

        #expect(interval.activeModelID == nil)
        #expect(interval.inferenceActive == nil)
    }

    @Test("measured serving hours estimate earnings and incremental power separately")
    func derivesServingProfitFromObservedPower() throws {
        let hour = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let energy = (0..<360).map { index -> EnergyInterval in
            let start = hour.start.addingTimeInterval(Double(index * 10))
            let active = index < 180
            let watts = active ? 100.0 : 50.0
            let kWh = watts / 1_000 * 10 / 3_600
            return EnergyInterval(
                start: start,
                end: start.addingTimeInterval(10),
                kWh: kWh,
                usdPerKWh: 0.2,
                source: "adapter",
                estimated: true,
                activeModelID: "google/gemma",
                inferenceActive: active
            )
        }
        let activity = [ModelActivityBucket(interval: hour, model: "google/gemma", workMicroUSD: 500_000)]

        let average = try #require(ModelProfitability.servingAverages(activity: activity, energy: energy).first)

        #expect(average.coveredEarningHours == 1)
        #expect(abs(average.activeHours - 0.5) < 0.000_001)
        #expect(abs(average.grossUSDPerActiveHour - 1.0) < 0.000_001)
        #expect(abs((average.incrementalElectricityUSDPerActiveHour ?? -1) - 0.01) < 0.000_001)
        #expect(abs((average.profitUSDPerActiveHour ?? -1) - 0.99) < 0.000_001)
    }

    @Test("gross serving rate stays visible while the idle-power baseline is missing")
    func preservesGrossRateWithoutIdleBaseline() throws {
        let hour = DateInterval(start: Date(timeIntervalSince1970: 7_200), duration: 3_600)
        let energy = (0..<360).map { index -> EnergyInterval in
            let start = hour.start.addingTimeInterval(Double(index * 10))
            return EnergyInterval(
                start: start,
                end: start.addingTimeInterval(10),
                kWh: 0.000_1,
                usdPerKWh: 0.2,
                source: "adapter",
                estimated: true,
                activeModelID: "google/gemma",
                inferenceActive: true
            )
        }
        let activity = [ModelActivityBucket(interval: hour, model: "google/gemma", workMicroUSD: 500_000)]

        let average = try #require(ModelProfitability.servingAverages(activity: activity, energy: energy).first)

        #expect(average.grossUSDPerActiveHour == 0.5)
        #expect(average.incrementalElectricityUSDPerActiveHour == nil)
        #expect(average.profitUSDPerActiveHour == nil)
    }

    @Test("daily runtime forecast converts duty cycle to hours and preserves missing data")
    func projectsRuntimeAndProfit() throws {
        let economics = ModelServingProfitAverage(
            model: "google/gemma",
            grossUSDPerActiveHour: 1,
            incrementalElectricityUSDPerActiveHour: 0.01,
            profitUSDPerActiveHour: 0.99,
            activeHours: 2.5,
            coveredEarningHours: 3,
            activePowerSamples: 900,
            idlePowerSamples: 500
        )
        let rate = ModelTokenRateAverage(model: "google/gemma", tokensPerSecond: 20, sampleCount: 12)

        let forecast = ModelRunForecast.calculate(runPercent: 50, serving: economics, tokenRate: rate)

        #expect(forecast.hoursPerDay == 12)
        #expect(forecast.tokensPerDay == 864_000)
        #expect(forecast.grossUSDPerDay == 12)
        #expect(forecast.incrementalElectricityUSDPerDay == 0.12)
        #expect(abs((forecast.profitUSDPerDay ?? -1) - 11.88) < 0.000_001)
        #expect(ModelRunForecast.calculate(runPercent: 15, serving: economics, tokenRate: nil).hoursPerDay == 3.6)
        #expect(ModelRunForecast.calculate(runPercent: 0, serving: nil, tokenRate: nil).profitUSDPerDay == 0)
        #expect(ModelRunForecast.calculate(runPercent: 50, serving: nil, tokenRate: nil).profitUSDPerDay == nil)
    }
}
