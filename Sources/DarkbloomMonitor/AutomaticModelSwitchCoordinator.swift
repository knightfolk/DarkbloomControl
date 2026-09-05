import DarkbloomTelemetry
import Foundation

enum AutomaticModelSwitchOutcome: Equatable {
    case noAction
    case attempted(modelID: String, didLaunch: Bool)
}

/// Coordinates the stateful safety gates around automatic demand switching.
/// The app delegate supplies fresh snapshots and the warm closure; keeping the
/// tracker and the launch result here makes the hysteresis/cooldown behavior
/// testable without driving the private application delegate loop.
@MainActor
final class AutomaticModelSwitchCoordinator {
    private var tracker: AutomaticModelSwitchTracker

    init(lastAttemptAt: Date? = nil) {
        tracker = AutomaticModelSwitchTracker(lastAttemptAt: lastAttemptAt)
    }

    func clearCandidate() {
        tracker.clearCandidate()
    }

    func evaluate(
        enabled: Bool,
        capacity: NetworkCapacitySnapshot?,
        sampledAt: Date?,
        operation: ProviderOperation,
        draftHasChanges: Bool,
        restartRequired: Bool,
        pendingConfirmation: LifecycleConfirmation?,
        controlSnapshot: ProviderControlSnapshot?,
        earnings: [ModelWorkEarnings],
        tokenRates: [ModelTokenRateAverage],
        now: Date,
        minimumHeadroomGB: Double,
        availableSystemMemoryGB: Double?,
        warm: @escaping (String) async -> Bool
    ) async -> AutomaticModelSwitchOutcome {
        guard enabled,
              let capacity,
              let sampledAt,
              capacity.isFresh(at: now),
              let controlSnapshot
        else {
            tracker.clearCandidate()
            return .noAction
        }

        let enabledModelIDs = controlSnapshot.inventory.myCatalog
            .filter { $0.isEnabled }
            .map(\.catalogID)
        let recommendation = ModelOpportunityRanker.recommend(
            capacity: capacity,
            enabledModelIDs: enabledModelIDs,
            observedWork: earnings,
            tokenRates: tokenRates,
            now: now,
            calendar: .current
        )
        guard let recommendation,
              let item = controlSnapshot.inventory.myCatalog.first(where: {
                  $0.catalogID == recommendation.modelID
              }),
              ModelWarmupPresentation.blockReason(
                  operation: operation,
                  draftHasChanges: draftHasChanges,
                  restartRequired: restartRequired,
                  pendingConfirmation: pendingConfirmation,
                  item: item,
                  snapshot: controlSnapshot,
                  currentTime: now,
                  minimumHeadroomGB: minimumHeadroomGB,
                  availableSystemMemoryGB: availableSystemMemoryGB
              ) == nil
        else {
            tracker.clearCandidate()
            return .noAction
        }

        guard let target = tracker.observe(
            recommendation,
            residentModelIDs: controlSnapshot.residentModelIDs,
            sampledAt: sampledAt,
            now: now
        ) else { return .noAction }

        let didLaunch = await warm(target)
        guard didLaunch else {
            // A blocked/cancelled store operation must not consume the
            // automatic-switch cooldown or leave a stale candidate behind.
            tracker.clearCandidate()
            return .attempted(modelID: target, didLaunch: false)
        }
        tracker.recordAttempt(at: now)
        return .attempted(modelID: target, didLaunch: true)
    }
}
