import Foundation
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Activity chart model colors")
struct ActivityChartDataTests {
    @Test("all-model bars are segmented by model and rewards remain separate")
    func segmentsAllModels() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let aggregate = bucket(interval, work: 300_000, reward: 10_000)
        let segments = ActivityChartData.segments(
            buckets: [aggregate],
            models: ["gemma", "qwen"],
            modelWorkByBucket: [interval.start: ["gemma": 100_000, "qwen": 200_000]],
            selectedModel: nil
        )

        #expect(segments.map(\.series) == ["gemma", "qwen", "Base rewards"])
        for (actual, expected) in zip(segments.map(\.startUSD), [0.0, 0.1, 0.3]) {
            #expect(abs(actual - expected) < 0.000_000_001)
        }
        for (actual, expected) in zip(segments.map(\.endUSD), [0.1, 0.3, 0.31]) {
            #expect(abs(actual - expected) < 0.000_000_001)
        }
    }

    @Test("single-model view retains its work-only bar")
    func segmentsSelectedModel() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let aggregate = bucket(interval, work: 200_000, reward: 10_000)

        let segments = ActivityChartData.segments(
            buckets: [aggregate],
            models: ["gemma", "qwen"],
            modelWorkByBucket: [interval.start: ["qwen": 200_000]],
            selectedModel: "qwen"
        )

        #expect(segments.map(\.series) == ["Work"])
        #expect(segments[0].startUSD == 0)
        #expect(segments[0].endUSD == 0.2)
    }

    @Test("aggregate work remains visible when per-model history is unavailable")
    func fallsBackToAggregateWork() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let aggregate = bucket(interval, work: 125_000, reward: 5_000)

        let segments = ActivityChartData.segments(
            buckets: [aggregate], models: ["gemma"], modelWorkByBucket: [:], selectedModel: nil
        )

        #expect(segments.map(\.series) == ["Work", "Base rewards"])
        #expect(segments[0].endUSD == 0.125)
        #expect(segments[1].startUSD == 0.125)
        #expect(segments[1].endUSD == 0.13)
    }

    @Test("currency axis rounds up to readable increments")
    func currencyAxis() {
        let small = ActivityChartAxis.yAxis(maximum: 0.17)
        #expect(small.upperBound == 0.2)
        for (actual, expected) in zip(small.values, [0.0, 0.05, 0.1, 0.15, 0.2]) {
            #expect(abs(actual - expected) < 0.000_001)
        }
        #expect(small.fractionDigits == 2)

        let large = ActivityChartAxis.yAxis(maximum: 18.2)
        #expect(large.upperBound == 20)
        #expect(large.values == [0, 5, 10, 15, 20])
    }

    @Test("time axis marks five evenly spaced local hour boundaries")
    func hourlyAxis() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 0)
        let ticks = ActivityChartAxis.xValues(
            in: DateInterval(start: start, duration: 86_400), unit: .hour, calendar: calendar
        )
        #expect(ticks.map { $0.timeIntervalSince(start) } == [0, 21_600, 43_200, 64_800, 86_400])
    }

    private func bucket(_ interval: DateInterval, work: Int64, reward: Int64 = 0) -> ActivityBucket {
        ActivityBucket(
            interval: interval,
            totals: ActivityTotals(
                workMicroUSD: work,
                rewardMicroUSD: reward,
                jobs: 1,
                promptTokens: 0,
                completionTokens: 0
            ),
            coverage: .recorded
        )
    }
}
