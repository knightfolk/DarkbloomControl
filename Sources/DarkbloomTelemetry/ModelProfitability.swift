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

/// Model-specific earning and adapter-power rates derived only from measured
/// intervals that have both complete hourly earnings and fresh model activity.
public struct ModelServingProfitAverage: Equatable, Sendable, Identifiable {
    public let model: String
    public let grossUSDPerActiveHour: Double
    public let incrementalElectricityUSDPerActiveHour: Double?
    public let profitUSDPerActiveHour: Double?
    public let activeHours: Double
    public let coveredEarningHours: Int
    public let activePowerSamples: Int
    public let idlePowerSamples: Int

    public var id: String { model }

    public init(
        model: String,
        grossUSDPerActiveHour: Double,
        incrementalElectricityUSDPerActiveHour: Double?,
        profitUSDPerActiveHour: Double?,
        activeHours: Double,
        coveredEarningHours: Int,
        activePowerSamples: Int,
        idlePowerSamples: Int
    ) {
        self.model = model
        self.grossUSDPerActiveHour = grossUSDPerActiveHour
        self.incrementalElectricityUSDPerActiveHour = incrementalElectricityUSDPerActiveHour
        self.profitUSDPerActiveHour = profitUSDPerActiveHour
        self.activeHours = activeHours
        self.coveredEarningHours = coveredEarningHours
        self.activePowerSamples = activePowerSamples
        self.idlePowerSamples = idlePowerSamples
    }
}

public struct ModelRunForecast: Equatable, Sendable {
    public let runPercent: Int
    public let hoursPerDay: Double
    public let tokensPerDay: Double?
    public let grossUSDPerDay: Double?
    public let incrementalElectricityUSDPerDay: Double?
    public let profitUSDPerDay: Double?
    public let profitUSDPerClockHour: Double?

    public static func calculate(
        runPercent: Int,
        serving: ModelServingProfitAverage?,
        tokenRate: ModelTokenRateAverage?
    ) -> Self {
        let percent = min(100, max(0, runPercent))
        let hours = 24 * Double(percent) / 100
        guard percent > 0 else {
            return Self(
                runPercent: percent,
                hoursPerDay: 0,
                tokensPerDay: 0,
                grossUSDPerDay: 0,
                incrementalElectricityUSDPerDay: 0,
                profitUSDPerDay: 0,
                profitUSDPerClockHour: 0
            )
        }

        let tokens = tokenRate.flatMap { value -> Double? in
            guard value.tokensPerSecond.isFinite, value.tokensPerSecond > 0, value.sampleCount > 0 else { return nil }
            let projected = value.tokensPerSecond * 3_600 * hours
            return projected.isFinite ? projected : nil
        }
        let gross = serving.map { $0.grossUSDPerActiveHour * hours }
        let electricity = serving?.incrementalElectricityUSDPerActiveHour.map { $0 * hours }
        let profit = serving?.profitUSDPerActiveHour.map { $0 * hours }
        return Self(
            runPercent: percent,
            hoursPerDay: hours,
            tokensPerDay: tokens,
            grossUSDPerDay: gross.flatMap { $0.isFinite ? $0 : nil },
            incrementalElectricityUSDPerDay: electricity.flatMap { $0.isFinite ? $0 : nil },
            profitUSDPerDay: profit.flatMap { $0.isFinite ? $0 : nil },
            profitUSDPerClockHour: profit.flatMap { $0.isFinite ? $0 / 24 : nil }
        )
    }
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

    /// Estimates model payout and incremental adapter-power cost per hour of
    /// actual inference. Legacy energy rows without fresh model-state tags are
    /// excluded from this calibration.
    public static func servingAverages(
        activity: [ModelActivityBucket],
        energy: [EnergyInterval]
    ) -> [ModelServingProfitAverage] {
        let sortedEnergy = energy.sorted { $0.start < $1.start }
        guard validEnergy(sortedEnergy) else { return [] }

        struct IdlePower {
            var costPerHourSeconds = 0.0
            var seconds = 0.0
            var samples = 0

            mutating func add(_ interval: EnergyInterval, overlap: TimeInterval) {
                guard overlap > 0 else { return }
                let duration = interval.end.timeIntervalSince(interval.start)
                let hourlyCost = interval.costUSD / duration * 3_600
                guard hourlyCost.isFinite else { return }
                costPerHourSeconds += hourlyCost * overlap
                seconds += overlap
                samples += 1
            }

            var averageCostPerHour: Double? {
                guard seconds > 0 else { return nil }
                return costPerHourSeconds / seconds
            }
        }

        var modelIdle: [String: IdlePower] = [:]
        var machineIdle = IdlePower()
        for interval in sortedEnergy where interval.inferenceActive == false {
            let duration = interval.end.timeIntervalSince(interval.start)
            if let model = interval.activeModelID {
                modelIdle[model, default: IdlePower()].add(interval, overlap: duration)
            } else {
                machineIdle.add(interval, overlap: duration)
            }
        }

        var totals: [String: (grossUSD: Double, activeSeconds: Double, netGrossUSD: Double,
            netActiveSeconds: Double, incrementalElectricityUSD: Double, coveredHours: Int,
            activeSamples: Int)] = [:]
        let activityByHour = Dictionary(grouping: activity, by: \.interval.start)
        for (hourStart, entries) in activityByHour {
            guard entries.allSatisfy({ $0.interval.duration == 3_600 && $0.workMicroUSD >= 0 }) else { continue }
            let hour = DateInterval(start: hourStart, duration: 3_600)
            guard coveredCost(for: hour, energy: sortedEnergy) != nil,
                  hasActivityCoverage(for: hour, energy: sortedEnergy) else { continue }

            for entry in entries {
                let model = entry.model
                let samples = sortedEnergy.filter { $0.end > hour.start && $0.start < hour.end }
                var activeSeconds = 0.0
                var activeCostPerHourSeconds = 0.0
                var activeCount = 0
                for sample in samples where sample.inferenceActive == true && sample.activeModelID == model {
                    let seconds = min(sample.end, hour.end).timeIntervalSince(max(sample.start, hour.start))
                    guard seconds > 0 else { continue }
                    let duration = sample.end.timeIntervalSince(sample.start)
                    let costPerHour = sample.costUSD / duration * 3_600
                    guard costPerHour.isFinite else { continue }
                    activeSeconds += seconds
                    activeCostPerHourSeconds += costPerHour * seconds
                    activeCount += 1
                }
                guard activeSeconds > 0 else { continue }

                let grossUSD = Double(entry.workMicroUSD) / 1_000_000
                guard grossUSD.isFinite else { continue }
                var total = totals[model] ?? (0, 0, 0, 0, 0, 0, 0)
                total.grossUSD += grossUSD
                total.activeSeconds += activeSeconds
                total.coveredHours += 1
                total.activeSamples += activeCount
                if let baseline = modelIdle[model]?.averageCostPerHour ?? machineIdle.averageCostPerHour {
                    let activeCostPerHour = activeCostPerHourSeconds / activeSeconds
                    let incrementalCostPerHour = max(0, activeCostPerHour - baseline)
                    guard activeCostPerHour.isFinite, incrementalCostPerHour.isFinite else { continue }
                    total.netGrossUSD += grossUSD
                    total.netActiveSeconds += activeSeconds
                    total.incrementalElectricityUSD += incrementalCostPerHour * activeSeconds / 3_600
                }
                totals[model] = total
            }
        }

        return totals.keys.sorted().compactMap { model in
            guard let value = totals[model], value.activeSeconds > 0 else { return nil }
            let activeHours = value.activeSeconds / 3_600
            let grossPerHour = value.grossUSD / activeHours
            let electricityPerHour = value.netActiveSeconds > 0
                ? value.incrementalElectricityUSD / (value.netActiveSeconds / 3_600)
                : nil
            let profitPerHour = electricityPerHour.map { value.netGrossUSD / (value.netActiveSeconds / 3_600) - $0 }
            guard activeHours.isFinite, grossPerHour.isFinite,
                  electricityPerHour.map(\.isFinite) ?? true,
                  profitPerHour.map(\.isFinite) ?? true else { return nil }
            return ModelServingProfitAverage(
                model: model,
                grossUSDPerActiveHour: grossPerHour,
                incrementalElectricityUSDPerActiveHour: electricityPerHour,
                profitUSDPerActiveHour: profitPerHour,
                activeHours: activeHours,
                coveredEarningHours: value.coveredHours,
                activePowerSamples: value.activeSamples,
                idlePowerSamples: modelIdle[model]?.samples ?? machineIdle.samples
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
                  item.activeModelID?.utf8.count ?? 0 <= 512,
                  item.inferenceActive != true || item.activeModelID?.isEmpty == false,
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

    private static func hasActivityCoverage(for period: DateInterval, energy: [EnergyInterval]) -> Bool {
        var cursor = period.start
        for item in energy where item.end > cursor && item.start < period.end {
            guard item.start <= cursor, item.inferenceActive != nil else { return false }
            cursor = min(item.end, period.end)
            if cursor >= period.end { return true }
        }
        return false
    }
}
