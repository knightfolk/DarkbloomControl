import Foundation
import Testing
@testable import DarkbloomTelemetry

struct ModelProfitabilityTests {
    @Test("allocates covered whole-Mac electricity evenly across earning models per hour")
    func sharesHourlyDeviceCostAcrossModels() throws {
        let hour = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let activity = [
            ModelActivityBucket(interval: hour, model: "google/gemma", workMicroUSD: 300_000),
            ModelActivityBucket(interval: hour, model: "qwen/qwen", workMicroUSD: 500_000),
        ]

        let points = ModelProfitability.hourlyProfits(activity: activity, energy: powerIntervals(for: hour))

        #expect(points.map(\.model) == ["google/gemma", "qwen/qwen"])
        #expect(abs(points[0].allocatedElectricityUSD - 0.10) < 0.000_000_001)
        #expect(abs(points[0].profitUSD - 0.20) < 0.000_000_001)
        #expect(abs(points[1].profitUSD - 0.40) < 0.000_000_001)
        #expect(points.allSatisfy { $0.estimated })
    }

    @Test("does not estimate model profit for an hour with an energy coverage gap")
    func omitsUncoveredHour() throws {
        let hour = DateInterval(start: Date(timeIntervalSince1970: 7_200), duration: 3_600)
        var intervals = powerIntervals(for: hour)
        intervals.remove(at: 180)
        let activity = [ModelActivityBucket(interval: hour, model: "gemma", workMicroUSD: 100_000)]

        #expect(ModelProfitability.hourlyProfits(activity: activity, energy: intervals).isEmpty)
    }

    @Test("averages positive and negative net returns over covered model-hours")
    func averagesNetProfitPerModelHour() throws {
        let first = DateInterval(start: Date(timeIntervalSince1970: 10_800), duration: 3_600)
        let second = DateInterval(start: Date(timeIntervalSince1970: 14_400), duration: 3_600)
        let activity = [
            ModelActivityBucket(interval: first, model: "gemma", workMicroUSD: 300_000),
            ModelActivityBucket(interval: second, model: "gemma", workMicroUSD: 50_000),
        ]
        let points = ModelProfitability.hourlyProfits(
            activity: activity,
            energy: powerIntervals(for: first) + powerIntervals(for: second)
        )

        let average = try #require(ModelProfitability.averages(points).first)
        #expect(average.model == "gemma")
        #expect(average.coveredHours == 2)
        #expect(abs(average.profitUSDPerHour - (-0.025)) < 0.000_000_001)
    }
}

private func powerIntervals(for hour: DateInterval) -> [EnergyInterval] {
    (0..<360).map { index in
        let start = hour.start.addingTimeInterval(Double(index * 10))
        return EnergyInterval(
            start: start,
            end: start.addingTimeInterval(10),
            kWh: 1.0 / 360.0,
            usdPerKWh: 0.2,
            source: "fixture-adapter",
            estimated: true
        )
    }
}
