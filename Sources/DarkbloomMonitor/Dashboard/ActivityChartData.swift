import DarkbloomTelemetry
import Foundation

struct ActivityChartSegment: Equatable, Identifiable {
    let interval: DateInterval
    let series: String
    let startUSD: Double
    let endUSD: Double

    var id: String { "\(interval.start.timeIntervalSince1970)-\(series)" }
}

enum ActivityChartData {
    static func segments(
        buckets: [ActivityBucket],
        models: [String],
        modelWorkByBucket: [Date: [String: Int64]],
        selectedModel: String?
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
                    series: selectedModel == nil ? model : "Work",
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

            if selectedModel == nil, totals.rewardMicroUSD > 0 {
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
            return ActivityChartYAxis(upperBound: 1, values: [0, 0.25, 0.5, 0.75, 1], fractionDigits: 2)
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
            upperBound: upperBound,
            values: values,
            fractionDigits: step < 0.01 ? 4 : 2
        )
    }
}
