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

    public init(model: String, tokensPerSecond: Double, sampleCount: Int) {
        self.model = model
        self.tokensPerSecond = tokensPerSecond
        self.sampleCount = sampleCount
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
