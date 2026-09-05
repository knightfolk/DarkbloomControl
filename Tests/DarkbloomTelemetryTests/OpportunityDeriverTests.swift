import Testing
@testable import DarkbloomTelemetry

@Suite("Opportunity factors")
struct OpportunityDeriverTests {
    @Test("pressure uses routable providers, not warm providers")
    func denominators() {
        let factors = OpportunityFactors(activeRequests: 6, queuedRequests: 2,
                                         routableProviders: 4, warmProviders: 1, queueLimit: 8)
        #expect(factors.demandPressure == 2)
        #expect(factors.warmScarcity == 0.75)
        #expect(factors.queuePressure == 0.25)
    }

    @Test("zero denominators use the documented floor without hiding overload")
    func zeroDenominators() {
        let factors = OpportunityFactors(activeRequests: 2, queuedRequests: 3,
                                         routableProviders: 0, warmProviders: 0, queueLimit: 0)
        #expect(factors.demandPressure == 5)
        #expect(factors.warmScarcity == 1)
        #expect(factors.queuePressure == 3)
    }

    @Test("counts cannot overflow and inconsistent populations remain explicit")
    func limits() {
        let factors = OpportunityFactors(activeRequests: .max, queuedRequests: .max,
                                         routableProviders: 2, warmProviders: 3, queueLimit: 1)
        #expect(factors.demandPressure == Double(Int.max))
        #expect(factors.demandPressure.isFinite)
        #expect(factors.warmScarcity == -0.5)
    }
}
