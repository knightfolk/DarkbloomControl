import Foundation

public enum EarningsHourlyRate {
    public static func derive(
        microUSD: Int64,
        observedSeconds: TimeInterval
    ) -> Double? {
        guard microUSD >= 0,
              observedSeconds.isFinite,
              observedSeconds > 0
        else { return nil }
        let value = (Double(microUSD) / 1_000_000) / (observedSeconds / 3_600)
        return value.isFinite ? value : nil
    }
}

public struct ModelTokenRateAverage: Equatable, Sendable {
    public let model: String
    public let tokensPerSecond: Double
    public let sampleCount: Int
    public let queryPeriod: DateInterval?

    public init(model: String, tokensPerSecond: Double, sampleCount: Int, queryPeriod: DateInterval? = nil) {
        self.model = model
        self.tokensPerSecond = tokensPerSecond
        self.sampleCount = sampleCount
        self.queryPeriod = queryPeriod
    }
}

public struct ModelOpportunityRecommendation: Equatable, Sendable {
    public let modelID: String
    public let demandBand: NetworkDemandBand
    public let demandPerWarmProvider: Double?
    public let observedMicroUSDPerJob: Double?
    public let observedTokensPerSecond: Double?

    public init(
        modelID: String,
        demandBand: NetworkDemandBand,
        demandPerWarmProvider: Double?,
        observedMicroUSDPerJob: Double?,
        observedTokensPerSecond: Double?
    ) {
        self.modelID = modelID
        self.demandBand = demandBand
        self.demandPerWarmProvider = demandPerWarmProvider
        self.observedMicroUSDPerJob = observedMicroUSDPerJob
        self.observedTokensPerSecond = observedTokensPerSecond
    }
}

public enum ModelOpportunityRanker {
    /// Dated observation path. Partial work is a descriptive tie-breaker, not
    /// estimated profit or proof of full-period earnings coverage.
    public static func recommend(
        capacity: NetworkCapacitySnapshot, enabledModelIDs: [String],
        observedWork: [ModelWorkEarnings], tokenRates: [ModelTokenRateAverage],
        now: Date, calendar: Calendar
    ) -> ModelOpportunityRecommendation? {
        guard capacity.isFresh(at: now) else { return nil }
        let counts = Dictionary(grouping: observedWork, by: \.model).mapValues(\.count)
        let earnings = observedWork.compactMap { value -> ModelEarnings? in
            guard counts[value.model] == 1, value.recordedHours > 0,
                  value.queryPeriod.start == calendar.startOfDay(for: now),
                  value.queryPeriod.end <= now,
                  let captured = value.sourceCapturedAt,
                  let amount = value.workMicroUSD, amount >= 0,
                  let jobs = value.jobs, jobs > 0 else { return nil }
            let age = now.timeIntervalSince(captured)
            let queryAge = now.timeIntervalSince(value.queryPeriod.end)
            guard age.isFinite, (0...600).contains(age),
                  queryAge.isFinite, (0...600).contains(queryAge) else { return nil }
            return ModelEarnings(model: value.model, microUSD: amount, jobs: jobs)
        }
        return recommend(capacity: capacity, enabledModelIDs: enabledModelIDs, earnings: earnings,
            tokenRates: CalendarTokenRates.current(tokenRates, at: now, calendar: calendar))
    }

    public static func recommend(
        capacity: NetworkCapacitySnapshot,
        enabledModelIDs: [String],
        earnings: [ModelEarnings],
        tokenRates: [ModelTokenRateAverage]
    ) -> ModelOpportunityRecommendation? {
        let enabled = Set(enabledModelIDs)
        var payouts: [String: Double] = [:]
        for value in earnings where value.jobs > 0 && value.microUSD >= 0 {
            payouts[value.model] = Double(value.microUSD) / Double(value.jobs)
        }
        var rates: [String: Double] = [:]
        for value in tokenRates {
            guard value.tokensPerSecond.isFinite,
                  value.tokensPerSecond >= 0,
                  value.sampleCount > 0
            else { continue }
            rates[value.model] = value.tokensPerSecond
        }
        let candidates = capacity.models.filter { enabled.contains($0.id) }
        guard let best = candidates.sorted(by: { left, right in
            let leftBand = demandRank(left.demandBand)
            let rightBand = demandRank(right.demandBand)
            if leftBand != rightBand { return leftBand < rightBand }
            if left.queuedRequests != right.queuedRequests {
                return left.queuedRequests > right.queuedRequests
            }
            let leftPressure = left.demandPerWarmProvider
                ?? (left.activeRequests > 0 ? .infinity : 0)
            let rightPressure = right.demandPerWarmProvider
                ?? (right.activeRequests > 0 ? .infinity : 0)
            if leftPressure != rightPressure { return leftPressure > rightPressure }
            let leftPayout = payouts[left.id] ?? -1
            let rightPayout = payouts[right.id] ?? -1
            if leftPayout != rightPayout { return leftPayout > rightPayout }
            let leftRate = rates[left.id] ?? -1
            let rightRate = rates[right.id] ?? -1
            if leftRate != rightRate { return leftRate > rightRate }
            return left.id.localizedStandardCompare(right.id) == .orderedAscending
        }).first,
              best.activeRequests > 0 || best.queuedRequests > 0
        else { return nil }

        return ModelOpportunityRecommendation(
            modelID: best.id,
            demandBand: best.demandBand,
            demandPerWarmProvider: best.demandPerWarmProvider,
            observedMicroUSDPerJob: payouts[best.id],
            observedTokensPerSecond: rates[best.id]
        )
    }

    private static func demandRank(_ band: NetworkDemandBand) -> Int {
        switch band {
        case .urgent: 0
        case .high: 1
        case .moderate: 2
        case .low: 3
        }
    }
}

public enum ModelTokenRatePresentation {
    public static func breakdown(
        _ averages: [ModelTokenRateAverage]
    ) -> [ModelTokenRateAverage] {
        averages.count > 1 ? averages : []
    }
}

public enum DashboardModelState: Equatable, Sendable {
    case active
    case loadedIdle
    case availableUnloaded
}

public struct DashboardModel: Equatable, Identifiable, Sendable {
    public let name: String
    public let state: DashboardModelState

    public var id: String { name }

    public init(name: String, state: DashboardModelState) {
        self.name = name
        self.state = state
    }
}

public enum DashboardModelDeriver {
    public static func models(
        enabledFilter: String?,
        loadedModels: [String],
        warmModels: [String],
        slotModels: [String],
        currentModel: String?,
        inferenceActive: Bool
    ) -> [DashboardModel] {
        let enabled = enabledFilter?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let current = currentModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        var loaded = Set(loadedModels + warmModels + slotModels)
        if let current, !current.isEmpty {
            loaded.insert(current)
        }

        var seen = Set<String>()
        let inventory = (enabled + loadedModels + warmModels + slotModels + [current ?? ""])
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        return inventory
            .map { name in
                let state: DashboardModelState
                if inferenceActive, name == current {
                    state = .active
                } else if loaded.contains(name) {
                    state = .loadedIdle
                } else {
                    state = .availableUnloaded
                }
                return DashboardModel(name: name, state: state)
            }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank(lhs.element.state)
                let rhsRank = rank(rhs.element.state)
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }
            .map(\.element)
    }

    private static func rank(_ state: DashboardModelState) -> Int {
        switch state {
        case .active: 0
        case .loadedIdle: 1
        case .availableUnloaded: 2
        }
    }
}

public struct ActiveTokenRateAccumulator: Sendable {
    public private(set) var value: TokenRate = .unavailable(
        reason: "Waiting for active inference samples"
    )

    private var total = 0.0
    private var sampleCount = 0
    private var lastProcessIdentity: ProcessIdentity?
    private var lastWrittenAt: TimeInterval?

    public init() {}

    public mutating func record(
        _ rate: TokenRate,
        processIdentity: ProcessIdentity,
        writtenAt: TimeInterval
    ) {
        if let lastProcessIdentity, processIdentity != lastProcessIdentity {
            total = 0
            sampleCount = 0
            value = .unavailable(reason: "Waiting for active inference samples")
            lastWrittenAt = nil
        }
        guard processIdentity != lastProcessIdentity || writtenAt != lastWrittenAt else { return }
        lastProcessIdentity = processIdentity
        lastWrittenAt = writtenAt

        guard case .available(let tokensPerSecond, _) = rate,
              tokensPerSecond.isFinite,
              tokensPerSecond > 0,
              (total + tokensPerSecond).isFinite
        else { return }

        total += tokensPerSecond
        sampleCount += 1
        value = .available(
            tokensPerSecond: total / Double(sampleCount),
            label: "active session average"
        )
    }
}
