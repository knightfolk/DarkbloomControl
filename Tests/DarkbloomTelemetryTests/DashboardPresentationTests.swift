import Foundation
import DarkbloomTelemetry
import Testing
@testable import DarkbloomMonitor

@Suite("Dashboard presentation")
struct DashboardPresentationTests {
    @Test("model opportunity prioritizes demand then observed payout and throughput")
    func ranksModelOpportunity() throws {
        let capacity = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"urgent","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":2,"running_providers":1,"cold_providers":8,"active_requests":2,"queued_requests":1,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1},{"id":"high-pay","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":10,"running_providers":1,"cold_providers":0,"active_requests":1,"queued_requests":0,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1}]}"#.utf8),
            capturedAt: .now
        )

        let recommendation = ModelOpportunityRanker.recommend(
            capacity: capacity,
            enabledModelIDs: ["urgent", "high-pay"],
            earnings: [
                ModelEarnings(model: "urgent", microUSD: 10, jobs: 1),
                ModelEarnings(model: "high-pay", microUSD: 1_000, jobs: 1),
            ],
            tokenRates: []
        )

        #expect(recommendation?.modelID == "urgent")
        #expect(recommendation?.demandBand == .urgent)
    }

    @Test("observed payout breaks equal-demand opportunity ties")
    func payoutBreaksOpportunityTie() throws {
        let capacity = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"a","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":10,"running_providers":1,"cold_providers":0,"active_requests":5,"queued_requests":0,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1},{"id":"b","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":10,"running_providers":1,"cold_providers":0,"active_requests":5,"queued_requests":0,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1}]}"#.utf8),
            capturedAt: .now
        )

        let recommendation = ModelOpportunityRanker.recommend(
            capacity: capacity,
            enabledModelIDs: ["a", "b"],
            earnings: [
                ModelEarnings(model: "a", microUSD: 100, jobs: 2),
                ModelEarnings(model: "b", microUSD: 300, jobs: 2),
            ],
            tokenRates: []
        )

        #expect(recommendation?.modelID == "b")
        #expect(recommendation?.observedMicroUSDPerJob == 150)
    }

    @Test("zero network work produces no model recommendation")
    func omitsRecommendationWithoutDemand() throws {
        let capacity = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"idle","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":10,"running_providers":0,"cold_providers":0,"active_requests":0,"queued_requests":0,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1}]}"#.utf8),
            capturedAt: .now
        )

        #expect(ModelOpportunityRanker.recommend(
            capacity: capacity,
            enabledModelIDs: ["idle"],
            earnings: [ModelEarnings(model: "idle", microUSD: 1_000, jobs: 1)],
            tokenRates: []
        ) == nil)
    }

    @Test("earnings per hour divides a full calendar day")
    func derivesFullCalendarDayEarningsPerHour() {
        let rate = EarningsHourlyRate.derive(microUSD: 2_400_000, observedSeconds: 86_400)
        #expect(abs((rate ?? 0) - 0.1) < 0.000_001)
    }

    @Test("earnings per hour uses the actual partial observation window")
    func derivesObservedEarningsPerHour() {
        let rate = EarningsHourlyRate.derive(microUSD: 600_000, observedSeconds: 10_800)
        #expect(abs((rate ?? 0) - 0.2) < 0.000_001)
    }

    @Test("earnings per hour omits invalid observations")
    func omitsInvalidEarningsPerHour() {
        #expect(EarningsHourlyRate.derive(microUSD: 100_000, observedSeconds: 0) == nil)
        #expect(EarningsHourlyRate.derive(microUSD: -1, observedSeconds: 3_600) == nil)
    }

    @Test("model average breakdown requires at least two observed models")
    func requiresTwoModelsForBreakdown() {
        let gemma = ModelTokenRateAverage(model: "gemma", tokensPerSecond: 20, sampleCount: 2)
        let qwen = ModelTokenRateAverage(model: "qwen", tokensPerSecond: 30, sampleCount: 3)

        #expect(ModelTokenRatePresentation.breakdown([gemma]).isEmpty)
        #expect(ModelTokenRatePresentation.breakdown([gemma, qwen]) == [gemma, qwen])
    }

    @Test("model badges distinguish active, loaded-idle, and available-unloaded models")
    func classifiesModelBadges() {
        let models = DashboardModelDeriver.models(
            enabledFilter: "gemma, qwen, gpt-oss",
            loadedModels: ["gemma"],
            warmModels: ["qwen"],
            slotModels: ["qwen"],
            currentModel: "gemma",
            inferenceActive: true
        )

        #expect(models == [
            DashboardModel(name: "gemma", state: .active),
            DashboardModel(name: "qwen", state: .loadedIdle),
            DashboardModel(name: "gpt-oss", state: .availableUnloaded),
        ])
    }

    @Test("a resident current model becomes loaded-idle when inference stops")
    func classifiesIdleCurrentModel() {
        let models = DashboardModelDeriver.models(
            enabledFilter: "gemma",
            loadedModels: ["gemma"],
            warmModels: ["gemma"],
            slotModels: ["gemma"],
            currentModel: "gemma",
            inferenceActive: false
        )

        #expect(models == [DashboardModel(name: "gemma", state: .loadedIdle)])
    }

    @Test("active-session average ignores unavailable and duplicate telemetry samples")
    func averagesUniqueAvailableTokenRates() {
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 9_000)
        var average = ActiveTokenRateAccumulator()

        average.record(
            .available(tokensPerSecond: 20, label: "derived"),
            processIdentity: identity,
            writtenAt: 100
        )
        average.record(
            .unavailable(reason: "No token progress in the polling window"),
            processIdentity: identity,
            writtenAt: 101
        )
        average.record(
            .available(tokensPerSecond: 40, label: "derived"),
            processIdentity: identity,
            writtenAt: 102
        )
        average.record(
            .available(tokensPerSecond: 100, label: "derived"),
            processIdentity: identity,
            writtenAt: 102
        )

        #expect(average.value == .available(
            tokensPerSecond: 30,
            label: "active session average"
        ))
    }

    @Test("active-session average resets when the provider process changes")
    func resetsAverageAcrossProviderProcesses() {
        let first = ProcessIdentity(pid: 42, startTimeMicros: 9_000)
        let second = ProcessIdentity(pid: 43, startTimeMicros: 10_000)
        var average = ActiveTokenRateAccumulator()

        average.record(
            .available(tokensPerSecond: 20, label: "derived"),
            processIdentity: first,
            writtenAt: 100
        )
        average.record(
            .available(tokensPerSecond: 40, label: "derived"),
            processIdentity: first,
            writtenAt: 101
        )
        average.record(
            .unavailable(reason: "Waiting for a positive token delta"),
            processIdentity: second,
            writtenAt: 1
        )

        #expect(average.value == .unavailable(
            reason: "Waiting for active inference samples"
        ))

        average.record(
            .available(tokensPerSecond: 12, label: "derived"),
            processIdentity: second,
            writtenAt: 2
        )
        #expect(average.value == .available(
            tokensPerSecond: 12,
            label: "active session average"
        ))
    }
}
