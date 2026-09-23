import Foundation

/// Estimated net earnings for one model with a recorded work row in one hour.
/// Whole-Mac adapter electricity is divided evenly among earning models.
public struct ModelHourlyProfit: Equatable, Sendable, Identifiable {
    public let interval: DateInterval
    public let model: String
    public let grossUSD: Double
    public let allocatedElectricityUSD: Double
    public let profitUSD: Double
    public let estimated: Bool

    public var id: String { "\(interval.start.timeIntervalSince1970)-\(model)" }
}

public struct ModelHourlyProfitAverage: Equatable, Sendable, Identifiable {
    public let model: String
    public let grossUSDPerHour: Double
    public let electricityUSDPerHour: Double
    public let profitUSDPerHour: Double
    public let coveredHours: Int

    public var id: String { model }
}

public enum ModelProfitability {
    /// Computes only full hours with contiguous whole-Mac power coverage.
    /// Device cost is split equally across models that recorded work in the
    /// hour. This is an estimate, not measured per-model power consumption.
    public static func hourlyProfits(
        activity: [ModelActivityBucket],
        energy: [EnergyInterval]
    ) -> [ModelHourlyProfit] {
        let sortedEnergy = energy.sorted { $0.start < $1.start }
        guard validEnergy(sortedEnergy) else { return [] }

        var workByHour: [Date: [String: Int64]] = [:]
        for item in activity {
            guard item.interval.duration == 3_600,
                  !item.model.isEmpty,
                  item.workMicroUSD >= 0 else { continue }
            let previous = workByHour[item.interval.start]?[item.model] ?? 0
            let (sum, overflow) = previous.addingReportingOverflow(item.workMicroUSD)
            guard !overflow else { return [] }
            workByHour[item.interval.start, default: [:]][item.model] = sum
        }

        var result: [ModelHourlyProfit] = []
        for (start, values) in workByHour.sorted(by: { $0.key < $1.key }) {
            let interval = DateInterval(start: start, duration: 3_600)
            guard let cost = coveredCost(for: interval, energy: sortedEnergy), !values.isEmpty else { continue }
            let allocation = cost / Double(values.count)
            for (model, microUSD) in values.sorted(by: { $0.key < $1.key }) {
                let gross = Double(microUSD) / 1_000_000
                let profit = gross - allocation
                guard gross.isFinite, allocation.isFinite, profit.isFinite else { continue }
                result.append(ModelHourlyProfit(
                    interval: interval,
                    model: model,
                    grossUSD: gross,
                    allocatedElectricityUSD: allocation,
                    profitUSD: profit,
                    estimated: true
                ))
            }
        }
        return result
    }

    public static func averages(_ points: [ModelHourlyProfit]) -> [ModelHourlyProfitAverage] {
        let grouped = Dictionary(grouping: points, by: \.model)
        return grouped.keys.sorted().compactMap { model in
            guard let values = grouped[model], !values.isEmpty else { return nil }
            let count = Double(values.count)
            let gross = values.reduce(0) { $0 + $1.grossUSD } / count
            let electricity = values.reduce(0) { $0 + $1.allocatedElectricityUSD } / count
            let profit = values.reduce(0) { $0 + $1.profitUSD } / count
            guard gross.isFinite, electricity.isFinite, profit.isFinite else { return nil }
            return ModelHourlyProfitAverage(
                model: model,
                grossUSDPerHour: gross,
                electricityUSDPerHour: electricity,
                profitUSDPerHour: profit,
                coveredHours: values.count
            )
        }
    }

    private static func validEnergy(_ energy: [EnergyInterval]) -> Bool {
        var previousEnd: Date?
        for item in energy {
            let duration = item.end.timeIntervalSince(item.start)
            guard item.start.timeIntervalSince1970.isFinite,
                  item.end.timeIntervalSince1970.isFinite,
                  duration > 0, duration <= 30,
                  item.kWh.isFinite, item.kWh >= 0,
                  item.usdPerKWh.isFinite, item.usdPerKWh >= 0,
                  item.costUSD.isFinite,
                  previousEnd.map({ item.start >= $0 }) ?? true else { return false }
            previousEnd = item.end
        }
        return true
    }

    private static func coveredCost(for period: DateInterval, energy: [EnergyInterval]) -> Double? {
        var cursor = period.start
        var cost = 0.0
        for item in energy where item.end > cursor && item.start < period.end {
            guard item.start <= cursor else { return nil }
            let end = min(item.end, period.end)
            let sourceDuration = item.end.timeIntervalSince(item.start)
            cost += item.costUSD * end.timeIntervalSince(cursor) / sourceDuration
            guard cost.isFinite else { return nil }
            cursor = end
            if cursor >= period.end { return cost }
        }
        return nil
    }
}
