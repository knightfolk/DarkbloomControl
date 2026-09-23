import Foundation
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Activity chart model colors")
struct ActivityChartDataTests {
    @Test("chart values keep model earnings separate until the selected layout is applied")
    func independentChartValues() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let values = ActivityChartData.values(
            buckets: [bucket(interval, work: 300_000, reward: 10_000)],
            models: ["gemma", "qwen"],
            modelWorkByBucket: [interval.start: ["gemma": 100_000, "qwen": 200_000]],
            selectedModel: nil
        )

        #expect(values.map(\.series) == ["gemma", "qwen", "Base rewards"])
        #expect(values.map(\.amountUSD) == [0.1, 0.2, 0.01])
        #expect(values.map(\.run) == [0, 0, 0])
    }

    @Test("base rewards can be hidden independently from the model series")
    func hidesRewards() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let values = ActivityChartData.values(
            buckets: [bucket(interval, work: 100_000, reward: 20_000)],
            models: ["gemma"],
            modelWorkByBucket: [interval.start: ["gemma": 100_000]],
            selectedModel: nil,
            includeRewards: false
        )

        #expect(values.map(\.series) == ["gemma"])
        #expect(values.map(\.amountUSD) == [0.1])
    }

    @Test("selected model chart values exclude other models and account rewards")
    func selectedModelValues() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let values = ActivityChartData.values(
            buckets: [bucket(interval, work: 200_000, reward: 10_000)],
            models: ["gemma", "qwen"],
            modelWorkByBucket: [interval.start: ["gemma": 100_000, "qwen": 200_000]],
            selectedModel: "qwen"
        )

        #expect(values.map(\.series) == ["qwen"])
        #expect(values.map(\.amountUSD) == [0.2])
    }

    @Test("company palettes keep sibling models visually related and readable")
    func companyPaletteGroups() {
        let gemma = ActivityChartPalette.components(for: "google/gemma-4-26b")
        let anotherGemma = ActivityChartPalette.components(for: "google/gemma-4-12b")
        let qwen = ActivityChartPalette.components(for: "qwen/qwen3.8-27b")

        #expect(gemma == ActivityChartPalette.components(for: "google/gemma-4-26b"))
        #expect(abs(gemma.hue - anotherGemma.hue) < 0.04)
        #expect(abs(gemma.hue - qwen.hue) > 0.20)
        #expect(gemma.brightness >= 0.76)
    }

    @Test("chart choices cover bars, lines, and area with both bar arrangements")
    func availableChartChoices() {
        #expect(ActivityChartStyle.allCases.map(\.rawValue) == ["Bars", "Lines", "Area"])
        #expect(ActivityBarArrangement.allCases.map(\.rawValue) == ["Stacked", "Side by side"])
    }

    @Test("profit chart shows signed per-model hourly averages and honors model filtering")
    func profitValuesAverageCoveredModelHours() {
        let start = Date(timeIntervalSince1970: 86_400)
        let day = DateInterval(start: start, duration: 86_400)
        let firstHour = DateInterval(start: start, duration: 3_600)
        let secondHour = DateInterval(start: start.addingTimeInterval(3_600), duration: 3_600)
        let buckets = [bucket(day, work: 500_000)]
        let profits = [
            ModelHourlyProfit(interval: firstHour, model: "gemma", grossUSD: 0.3,
                              allocatedElectricityUSD: 0.1, profitUSD: 0.2, estimated: true),
            ModelHourlyProfit(interval: secondHour, model: "gemma", grossUSD: 0.1,
                              allocatedElectricityUSD: 0.2, profitUSD: -0.1, estimated: true),
            ModelHourlyProfit(interval: firstHour, model: "qwen", grossUSD: 0.5,
                              allocatedElectricityUSD: 0.1, profitUSD: 0.4, estimated: true),
        ]

        let all = ActivityChartData.profitValues(hourly: profits, buckets: buckets, selectedModel: nil)
        let selected = ActivityChartData.profitValues(hourly: profits, buckets: buckets, selectedModel: "gemma")

        #expect(all.map(\.series) == ["gemma", "qwen"])
        #expect(abs(all[0].amountUSD - 0.05) < 0.000_001)
        #expect(all[1].amountUSD == 0.4)
        #expect(selected.map(\.series) == ["gemma"])
        #expect(abs(selected[0].amountUSD - 0.05) < 0.000_001)
    }

    @Test("profit axis is symmetric around zero for positive and negative values")
    func signedProfitAxis() {
        let axis = ActivityChartAxis.signedYAxis(minimum: -0.13, maximum: 0.07)

        #expect(axis.lowerBound == -0.15)
        #expect(axis.upperBound == 0.15)
        #expect(axis.values == [-0.15, -0.1, -0.05, 0, 0.05, 0.1, 0.15])
    }

    @Test("line and area series break into new runs across unknown buckets")
    func unknownBucketsBreakRuns() {
        let first = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let missing = DateInterval(start: Date(timeIntervalSince1970: 7_200), duration: 3_600)
        let last = DateInterval(start: Date(timeIntervalSince1970: 10_800), duration: 3_600)
        let buckets = [
            bucket(first, work: 200_000),
            ActivityBucket(interval: missing, totals: nil, coverage: .unavailable),
            bucket(last, work: 300_000),
        ]
        let values = ActivityChartData.values(
            buckets: buckets,
            models: ["qwen"],
            modelWorkByBucket: [first.start: ["qwen": 200_000], last.start: ["qwen": 300_000]],
            selectedModel: "qwen"
        )

        #expect(values.map(\.amountUSD) == [0.2, 0.3])
        #expect(values.map(\.run) == [0, 1])
    }

    @Test("stacked charts scale to combined series while side-by-side uses the largest value")
    func chartMaximumMatchesLayout() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 3_600), duration: 3_600)
        let values = ActivityChartData.values(
            buckets: [bucket(interval, work: 300_000, reward: 10_000)],
            models: ["gemma", "qwen"],
            modelWorkByBucket: [interval.start: ["gemma": 100_000, "qwen": 200_000]],
            selectedModel: nil
        )

        let stacked = ActivityChartData.maximumUSD(values: values, stacked: true)
        let sideBySide = ActivityChartData.maximumUSD(values: values, stacked: false)
        #expect(abs(stacked - 0.31) < 0.000_001)
        #expect(abs(sideBySide - 0.2) < 0.000_001)
    }

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

        #expect(segments.map(\.series) == ["qwen"])
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
