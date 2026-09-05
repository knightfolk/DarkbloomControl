import Foundation

/// Descriptive network factors, not a recommendation or payout forecast.
public struct OpportunityFactors: Equatable, Sendable {
    public let demandPressure: Double
    public let warmScarcity: Double
    public let queuePressure: Double

    public init(activeRequests: Int, queuedRequests: Int, routableProviders: Int,
                warmProviders: Int, queueLimit: Int) {
        // Convert before addition so even bounded-decoder Int maxima cannot trap.
        demandPressure = (Double(activeRequests) + Double(queuedRequests))
            / Double(max(routableProviders, 1))
        // Preserve the formula even when public populations are inconsistent;
        // the presentation must explain a negative result, not clamp it silently.
        warmScarcity = 1 - Double(warmProviders) / Double(max(routableProviders, 1))
        queuePressure = Double(queuedRequests) / Double(max(queueLimit, 1))
    }
}
