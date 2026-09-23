import DarkbloomTelemetry
import Foundation

enum ActivityChartStyle: String, CaseIterable, Identifiable {
    case bars = "Bars"
    case lines = "Lines"
    case area = "Area"

    var id: Self { self }
}

enum ActivityBarArrangement: String, CaseIterable, Identifiable {
    case stacked = "Stacked"
    case sideBySide = "Side by side"

    var id: Self { self }
}

enum ActivityChartMetric: String, CaseIterable, Identifiable {
    case earnings = "Earnings"
    case estimatedProfit = "Est. profit / hour"

    var id: Self { self }
}

struct ActivityChartValue: Equatable, Identifiable {
    let interval: DateInterval
    let series: String
    let amountUSD: Double
    let run: Int

    var id: String { "\(interval.start.timeIntervalSince1970)-\(series)" }
    var runKey: String { "\(series)-run-\(run)" }
}

struct ActivityChartColorComponents: Equatable {
    let hue: Double
    let saturation: Double
    let brightness: Double
}

enum ActivityChartPalette {
    static func components(for model: String) -> ActivityChartColorComponents {
        let family = ModelFamilyIcon.select(status: .online, activeModel: model)
        let baseHue: Double
        switch family {
        case .google: baseHue = 0.59
        case .qwen: baseHue = 0.09
        case .openai: baseHue = 0.75
        case .nvidia: baseHue = 0.34
        case .prismml: baseHue = 0.95
        case .darkbloom: baseHue = 0.52
        }

        // Closely related hues keep each provider recognizable while still
        // making the provider's individual models distinguishable.
        let hash = stableHash(model)
        let hueOffsets = [-0.018, -0.009, 0.0, 0.009, 0.018]
        let saturationLevels = [0.58, 0.65, 0.72]
        let brightnessLevels = [0.82, 0.90, 0.98]
        let hue = (baseHue + hueOffsets[Int(hash % UInt64(hueOffsets.count))] + 1)
            .truncatingRemainder(dividingBy: 1)
        return ActivityChartColorComponents(
            hue: hue,
            saturation: saturationLevels[Int((hash / 5) % UInt64(saturationLevels.count))],
            brightness: brightnessLevels[Int((hash / 15) % UInt64(brightnessLevels.count))]
        )
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

struct ActivityChartSegment: Equatable, Identifiable {
    let interval: DateInterval
    let series: String
    let startUSD: Double
    let endUSD: Double

    var id: String { "\(interval.start.timeIntervalSince1970)-\(series)" }
}

enum ActivityChartData {
    static func colorScaleDomain(models: [String]) -> [String] {
        var seen = Set<String>()
        return (models + ["Work", "Base rewards"]).filter { seen.insert($0).inserted }
    }

    static func values(
        buckets: [ActivityBucket],
        models: [String],
        modelWorkByBucket: [Date: [String: Int64]],
        selectedModel: String?,
        includeRewards: Bool = true
    ) -> [ActivityChartValue] {
        let chartModels = selectedModel.map { [$0] } ?? models
        var lastBucketIndex: [String: Int] = [:]
        var runBySeries: [String: Int] = [:]
        var result: [ActivityChartValue] = []

        for (bucketIndex, bucket) in buckets.enumerated() {
            guard let totals = bucket.totals else { continue }
            let amounts = modelWorkByBucket[bucket.id] ?? [:]
            var seriesValues: [(String, Double)] = []

            for model in chartModels {
                if let work = amounts[model], work >= 0 {
                    seriesValues.append((model, Double(work) / 1_000_000))
                }
            }

            if selectedModel == nil {
                let modelTotal = amounts.values.reduce(Int64(0)) { total, value in
                    let (sum, overflow) = total.addingReportingOverflow(value)
                    return overflow ? Int64.max : sum
                }
                if modelTotal == totals.workMicroUSD {
                    let known = Set(amounts.keys)
                    for model in models where !known.contains(model) {
                        seriesValues.append((model, 0))
                    }
                }
            } else if !seriesValues.contains(where: { $0.0 == selectedModel }) {
                // A selected-model query is already model-filtered. Retain its
                // totals when an older client does not provide per-model rows.
                if totals.workMicroUSD >= 0 {
                    seriesValues.append((selectedModel!, Double(totals.workMicroUSD) / 1_000_000))
                }
            }

            let hasModelEarnings = seriesValues.contains { $0.0 != "Base rewards" && $0.1 > 0 }
            if !hasModelEarnings, selectedModel == nil, totals.workMicroUSD > 0 {
                // Legacy/custom clients can supply aggregate work only.
                seriesValues.append(("Work", Double(totals.workMicroUSD) / 1_000_000))
            }

            if includeRewards, selectedModel == nil, totals.rewardMicroUSD >= 0 {
                seriesValues.append(("Base rewards", Double(totals.rewardMicroUSD) / 1_000_000))
            }

            for (series, amountUSD) in seriesValues {
                let run: Int
                if let previous = lastBucketIndex[series] {
                    run = runBySeries[series, default: 0] + (previous == bucketIndex - 1 ? 0 : 1)
                } else {
                    run = 0
                }
                runBySeries[series] = run
                lastBucketIndex[series] = bucketIndex
                result.append(ActivityChartValue(
                    interval: bucket.interval,
                    series: series,
                    amountUSD: amountUSD,
                    run: run
                ))
            }
        }
        return result
    }

    static func maximumUSD(values: [ActivityChartValue], stacked: Bool) -> Double {
        guard stacked else { return values.map(\.amountUSD).max() ?? 0 }
        return Dictionary(grouping: values, by: \.interval.start)
            .values
            .map { $0.reduce(0) { $0 + $1.amountUSD } }
            .max() ?? 0
    }

    static func profitValues(
        hourly: [ModelHourlyProfit],
        buckets: [ActivityBucket],
        selectedModel: String?
    ) -> [ActivityChartValue] {
        let points = hourly.filter {
            $0.profitUSD.isFinite && (selectedModel == nil || $0.model == selectedModel)
        }
        var lastBucketIndex: [String: Int] = [:]
        var runBySeries: [String: Int] = [:]
        var result: [ActivityChartValue] = []

        for (bucketIndex, bucket) in buckets.enumerated() {
            let inBucket = points.filter {
                $0.interval.start >= bucket.interval.start && $0.interval.end <= bucket.interval.end
            }
            let byModel = Dictionary(grouping: inBucket, by: \.model)
            for model in byModel.keys.sorted() {
                guard let values = byModel[model], !values.isEmpty else { continue }
                let amount = values.reduce(0) { $0 + $1.profitUSD } / Double(values.count)
                guard amount.isFinite else { continue }
                let run: Int
                if let previous = lastBucketIndex[model] {
                    run = runBySeries[model, default: 0] + (previous == bucketIndex - 1 ? 0 : 1)
                } else {
                    run = 0
                }
                runBySeries[model] = run
                lastBucketIndex[model] = bucketIndex
                result.append(ActivityChartValue(
                    interval: bucket.interval,
                    series: model,
                    amountUSD: amount,
                    run: run
                ))
            }
        }
        return result
    }

    static func profitBounds(values: [ActivityChartValue], stacked: Bool) -> (minimum: Double, maximum: Double) {
        guard stacked else {
            return (values.map(\.amountUSD).min() ?? 0, values.map(\.amountUSD).max() ?? 0)
        }
        let groups = Dictionary(grouping: values, by: \.interval.start).values
        let minimum = groups.map { $0.reduce(0) { $0 + min(0, $1.amountUSD) } }.min() ?? 0
        let maximum = groups.map { $0.reduce(0) { $0 + max(0, $1.amountUSD) } }.max() ?? 0
        return (minimum, maximum)
    }

    static func profitSegments(values: [ActivityChartValue]) -> [ActivityChartSegment] {
        let groups = Dictionary(grouping: values, by: \.interval.start)
        var result: [ActivityChartSegment] = []
        for start in groups.keys.sorted() {
            guard let intervalValues = groups[start]?.sorted(by: { $0.series < $1.series }),
                  let interval = intervalValues.first?.interval else { continue }
            var positive = 0.0
            var negative = 0.0
            for value in intervalValues where value.amountUSD != 0 {
                let beginning = value.amountUSD > 0 ? positive : negative
                let end = beginning + value.amountUSD
                result.append(ActivityChartSegment(
                    interval: interval,
                    series: value.series,
                    startUSD: beginning,
                    endUSD: end
                ))
                if value.amountUSD > 0 { positive = end } else { negative = end }
            }
        }
        return result
    }

    static func segments(
        buckets: [ActivityBucket],
        models: [String],
        modelWorkByBucket: [Date: [String: Int64]],
        selectedModel: String?,
        includeRewards: Bool = true
    ) -> [ActivityChartSegment] {
        var result: [ActivityChartSegment] = []
        for bucket in buckets {
            guard let totals = bucket.totals else { continue }
            var cursor = 0.0
            let chartModels = selectedModel.map { [$0] } ?? models

            for model in chartModels {
                guard let work = modelWorkByBucket[bucket.id]?[model],
                      work > 0 else { continue }
                let amount = Double(work) / 1_000_000
                result.append(ActivityChartSegment(
                    interval: bucket.interval,
                    series: model,
                    startUSD: cursor,
                    endUSD: cursor + amount
                ))
                cursor += amount
            }

            // Keep the aggregate work visible for older/custom earnings clients
            // that can return totals but do not provide per-model activity.
            if cursor == 0, totals.workMicroUSD > 0 {
                let amount = Double(totals.workMicroUSD) / 1_000_000
                result.append(ActivityChartSegment(
                    interval: bucket.interval,
                    series: "Work",
                    startUSD: 0,
                    endUSD: amount
                ))
                cursor = amount
            }

            if includeRewards, selectedModel == nil, totals.rewardMicroUSD > 0 {
                let amount = Double(totals.rewardMicroUSD) / 1_000_000
                result.append(ActivityChartSegment(
                    interval: bucket.interval,
                    series: "Base rewards",
                    startUSD: cursor,
                    endUSD: cursor + amount
                ))
            }
        }
        return result
    }
}

struct ActivityChartYAxis: Equatable {
    let lowerBound: Double
    let upperBound: Double
    let values: [Double]
    let fractionDigits: Int
}

enum ActivityChartAxis {
    static func xValues(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar) -> [Date] {
        guard range.duration > 0 else { return [range.start] }
        let component: Calendar.Component = unit == .hour ? .hour : .day
        let intervalCount: Double
        if unit == .hour {
            intervalCount = range.duration / 3_600
        } else {
            intervalCount = Double(max(1, calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 1))
        }
        let stride = unit == .hour ? 6 : max(1, Int(ceil(intervalCount / 6)))
        guard let containingInterval = calendar.dateInterval(of: component, for: range.start) else {
            return [range.start, range.end]
        }
        var cursor = containingInterval.start
        if cursor < range.start {
            guard let next = calendar.date(byAdding: component, value: stride, to: cursor) else {
                return [range.start, range.end]
            }
            cursor = next
        }

        var values: [Date] = []
        while cursor <= range.end, values.count < 8 {
            if cursor >= range.start { values.append(cursor) }
            guard let next = calendar.date(byAdding: component, value: stride, to: cursor), next > cursor else { break }
            cursor = next
        }
        if values.last != range.end { values.append(range.end) }
        return values
    }

    static func yAxis(maximum: Double) -> ActivityChartYAxis {
        let safeMaximum = maximum.isFinite ? max(0, maximum) : 0
        guard safeMaximum > 0 else {
            return ActivityChartYAxis(lowerBound: 0, upperBound: 1, values: [0, 0.25, 0.5, 0.75, 1], fractionDigits: 2)
        }

        let rawStep = safeMaximum / 4
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let preferred: Double = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 2.5 ? 2.5 : normalized <= 5 ? 5 : 10
        let step = preferred * magnitude
        let upperBound = ceil(safeMaximum / step) * step
        let count = max(1, Int((upperBound / step).rounded()))
        let values = (0...count).map { index in
            (Double(index) * step * 1_000_000).rounded() / 1_000_000
        }
        return ActivityChartYAxis(
            lowerBound: 0,
            upperBound: upperBound,
            values: values,
            fractionDigits: step < 0.01 ? 4 : 2
        )
    }

    static func signedYAxis(minimum: Double, maximum: Double) -> ActivityChartYAxis {
        let safeMinimum = minimum.isFinite ? minimum : 0
        let safeMaximum = maximum.isFinite ? maximum : 0
        let magnitude = max(abs(safeMinimum), abs(safeMaximum))
        let positive = yAxis(maximum: magnitude)
        let step = positive.values.count > 1
            ? ((positive.values[1] - positive.values[0]) * 1_000_000).rounded() / 1_000_000
            : 0.25
        let upperBound = (positive.upperBound * 1_000_000).rounded() / 1_000_000
        let count = max(1, Int((upperBound / step).rounded()))
        let values = (-count...count).map { index in
            (Double(index) * step * 1_000_000).rounded() / 1_000_000
        }
        return ActivityChartYAxis(
            lowerBound: -upperBound,
            upperBound: upperBound,
            values: values,
            fractionDigits: positive.fractionDigits
        )
    }
}
