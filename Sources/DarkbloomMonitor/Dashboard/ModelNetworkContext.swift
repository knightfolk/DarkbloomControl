import DarkbloomTelemetry
import Foundation

/// Read-only context. Never used to derive local model state or enable controls.
enum ModelNetworkContext {
    static func workLabel(modelID: String, values: [ModelWorkEarnings], now: Date, calendar: Calendar = .current) -> String? {
        let matches = values.filter { $0.model == modelID }
        guard matches.count == 1, let value = matches.first,
              value.queryPeriod.start == calendar.startOfDay(for: now), value.queryPeriod.end <= now,
              let amount = value.workMicroUSD, amount >= 0, let jobs = value.jobs, jobs >= 0,
              value.recordedHours > 0, let captured = value.sourceCapturedAt else { return nil }
        let age = now.timeIntervalSince(captured)
        guard age.isFinite, age >= 0 else { return nil }
        let money = (Decimal(amount) / 1_000_000).formatted(.number.precision(.fractionLength(2...6)))
        return "Observed work today: $\(money) · \(jobs) jobs · partial · \(value.recordedHours) recorded / \(value.unknownHours) unknown / \(value.uncertainBoundaryHours) boundary hours · \(age <= 600 ? "current" : "stale") · \(ageLabel(captured, now: now))"
    }

    static func performanceLabel(modelID: String, averages: [ModelTokenRateAverage], now: Date) -> String? {
        let matches = averages.filter { $0.model == modelID }
        guard matches.count == 1, let value = matches.first,
              value.sampleCount > 0, value.tokensPerSecond.isFinite, value.tokensPerSecond > 0,
              let period = value.queryPeriod, period.start.timeIntervalSince1970.isFinite,
              period.end.timeIntervalSince1970.isFinite, period.duration >= 0, period.end <= now else { return nil }
        let rate = value.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))
        let start = period.start.formatted(date: .abbreviated, time: .shortened)
        let end = period.end.formatted(date: .abbreviated, time: .shortened)
        return "Observed average: \(rate) tok/s · \(value.sampleCount) samples · Query: \(start) – \(end)"
    }

    static func labels(modelID: String, capacity: SourceAvailability<NetworkCapacitySnapshot>,
                       pricing: SourceAvailability<PublicPricingSnapshot>, now: Date) -> [String] {
        var labels: [String] = []
        if let snapshot = capacity.value, let model = snapshot.models.first(where: { $0.id == modelID }) {
            let current: Bool
            if case .available = capacity { current = snapshot.isFresh(at: now) } else { current = false }
            labels.append("Network: \(model.activeRequests) active · \(model.queuedRequests) queued · \(current ? "current" : "stale") · \(ageLabel(snapshot.capturedAt, now: now))")
        }
        if let snapshot = pricing.value, let price = snapshot.price(for: modelID) {
            let age = now.timeIntervalSince(snapshot.capturedAt)
            let current: Bool
            if case .available = pricing { current = age.isFinite && (0...900).contains(age) } else { current = false }
            labels.append("Customer /1M tokens: $\(price.inputUSDPerMillion) in · $\(price.outputUSDPerMillion) out · \(current ? "current" : "stale") · \(ageLabel(snapshot.capturedAt, now: now))")
        }
        return labels
    }

    private static func ageLabel(_ captured: Date, now: Date) -> String {
        let age = now.timeIntervalSince(captured)
        guard age.isFinite else { return "age unavailable" }
        guard age >= 0 else { return "future timestamp" }
        if age < 60 { return "\(Int(age))s ago" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        if age < 86400 { return "\(Int(age / 3600))h ago" }
        return "over a day ago"
    }
}
