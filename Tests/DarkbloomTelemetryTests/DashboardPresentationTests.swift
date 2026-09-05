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

    @Test("automatic switching requires three consistent high-demand samples")
    func automaticSwitchUsesHysteresis() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recommendation = ModelOpportunityRecommendation(
            modelID: "target",
            demandBand: .high,
            demandPerWarmProvider: 1,
            observedMicroUSDPerJob: nil,
            observedTokensPerSecond: nil
        )
        var tracker = AutomaticModelSwitchTracker()

        #expect(tracker.observe(
            recommendation, residentModelIDs: [], sampledAt: now, now: now) == nil)
        #expect(tracker.observe(
            recommendation, residentModelIDs: [], sampledAt: now.addingTimeInterval(1), now: now) == nil)
        #expect(tracker.observe(
            recommendation, residentModelIDs: [], sampledAt: now.addingTimeInterval(2), now: now) == "target")
    }

    @Test("automatic switching ignores weak demand and enforces cooldown")
    func automaticSwitchUsesSafetyGates() {
        let now = Date(timeIntervalSince1970: 10_000)
        let low = ModelOpportunityRecommendation(
            modelID: "target",
            demandBand: .moderate,
            demandPerWarmProvider: 0.2,
            observedMicroUSDPerJob: nil,
            observedTokensPerSecond: nil
        )
        let high = ModelOpportunityRecommendation(
            modelID: "target",
            demandBand: .urgent,
            demandPerWarmProvider: 2,
            observedMicroUSDPerJob: nil,
            observedTokensPerSecond: nil
        )
        var tracker = AutomaticModelSwitchTracker()

        #expect(tracker.observe(
            low, residentModelIDs: [], sampledAt: now, now: now) == nil)
        #expect(tracker.observe(
            high, residentModelIDs: ["target"], sampledAt: now.addingTimeInterval(1), now: now) == nil)
        _ = tracker.observe(
            high, residentModelIDs: [], sampledAt: now.addingTimeInterval(2), now: now)
        _ = tracker.observe(
            high, residentModelIDs: [], sampledAt: now.addingTimeInterval(3), now: now)
        #expect(tracker.observe(
            high, residentModelIDs: [], sampledAt: now.addingTimeInterval(4), now: now) == "target")
        tracker.recordAttempt(at: now)
        #expect(tracker.observe(
            high, residentModelIDs: [], sampledAt: now.addingTimeInterval(5),
            now: now.addingTimeInterval(1_799)
        ) == nil)
        #expect(tracker.observe(
            high, residentModelIDs: [], sampledAt: now.addingTimeInterval(6),
            now: now.addingTimeInterval(1_800)
        ) == nil)
    }

    @Test("automatic switching restores its attempt cooldown after relaunch")
    func automaticSwitchRestoresCooldown() {
        let attemptedAt = Date(timeIntervalSince1970: 10_000)
        let high = ModelOpportunityRecommendation(
            modelID: "target",
            demandBand: .high,
            demandPerWarmProvider: 1,
            observedMicroUSDPerJob: nil,
            observedTokensPerSecond: nil
        )
        var tracker = AutomaticModelSwitchTracker(lastAttemptAt: attemptedAt)

        for offset in 1...3 {
            #expect(tracker.observe(
                high,
                residentModelIDs: [],
                sampledAt: attemptedAt.addingTimeInterval(Double(offset)),
                now: attemptedAt.addingTimeInterval(Double(offset))
            ) == nil)
        }
        #expect(tracker.observe(
            high,
            residentModelIDs: [],
            sampledAt: attemptedAt.addingTimeInterval(1_800),
            now: attemptedAt.addingTimeInterval(1_800)
        ) == nil)
        #expect(tracker.observe(
            high,
            residentModelIDs: [],
            sampledAt: attemptedAt.addingTimeInterval(1_801),
            now: attemptedAt.addingTimeInterval(1_801)
        ) == nil)
        #expect(tracker.observe(
            high,
            residentModelIDs: [],
            sampledAt: attemptedAt.addingTimeInterval(1_802),
            now: attemptedAt.addingTimeInterval(1_802)
        ) == "target")
    }

    @Test("automatic evaluator needs three fresh samples and cools down only after launch")
    @MainActor
    func automaticEvaluatorUsesLaunchOutcomeForCooldown() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = try automaticSwitchSnapshot(at: now)
        let capacity = try automaticSwitchCapacity(at: now)
        let recorder = AutomaticWarmRecorder(outcomes: [false, true])
        let coordinator = AutomaticModelSwitchCoordinator()

        for offset in 0..<3 {
            let outcome = await coordinator.evaluate(
                enabled: true,
                capacity: capacity,
                sampledAt: now.addingTimeInterval(Double(offset)),
                operation: .idle,
                draftHasChanges: false,
                restartRequired: false,
                pendingConfirmation: nil,
                controlSnapshot: snapshot,
                earnings: [],
                tokenRates: [],
                now: now.addingTimeInterval(Double(offset)),
                minimumHeadroomGB: 8,
                availableSystemMemoryGB: 64,
                warm: { modelID in await recorder.warm(modelID) }
            )
            if offset < 2 {
                #expect(outcome == .noAction)
            } else {
                #expect(outcome == .attempted(modelID: "target", didLaunch: false))
            }
        }
        #expect(await recorder.calls == ["target"])

        // A failed/cancelled warmup did not launch, so a new three-sample
        // sequence may try again instead of inheriting a cooldown.
        for offset in 3..<6 {
            _ = await coordinator.evaluate(
                enabled: true,
                capacity: capacity,
                sampledAt: now.addingTimeInterval(Double(offset)),
                operation: .idle,
                draftHasChanges: false,
                restartRequired: false,
                pendingConfirmation: nil,
                controlSnapshot: snapshot,
                earnings: [],
                tokenRates: [],
                now: now.addingTimeInterval(Double(offset)),
                minimumHeadroomGB: 8,
                availableSystemMemoryGB: 64,
                warm: { modelID in await recorder.warm(modelID) }
            )
        }
        #expect(await recorder.calls == ["target", "target"])

        for offset in 6..<9 {
            _ = await coordinator.evaluate(
                enabled: true,
                capacity: capacity,
                sampledAt: now.addingTimeInterval(Double(offset)),
                operation: .idle,
                draftHasChanges: false,
                restartRequired: false,
                pendingConfirmation: nil,
                controlSnapshot: snapshot,
                earnings: [],
                tokenRates: [],
                now: now.addingTimeInterval(Double(offset)),
                minimumHeadroomGB: 8,
                availableSystemMemoryGB: 64,
                warm: { modelID in await recorder.warm(modelID) }
            )
        }
        #expect(await recorder.calls == ["target", "target"])
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

private actor AutomaticWarmRecorder {
    private var outcomes: [Bool]
    private(set) var calls: [String] = []

    init(outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    func warm(_ modelID: String) -> Bool {
        calls.append(modelID)
        return outcomes.removeFirst()
    }
}

private func automaticSwitchCapacity(at capturedAt: Date) throws -> NetworkCapacitySnapshot {
    try NetworkCapacityParser.parse(
        Data(#"{"models":[{"id":"target","ready":true,"can_accept":true,"routable_providers":4,"warm_providers":1,"running_providers":1,"cold_providers":3,"active_requests":1,"queued_requests":0,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1}]}"#.utf8),
        capturedAt: capturedAt
    )
}

private func automaticSwitchSnapshot(at capturedAt: Date) throws -> ProviderControlSnapshot {
    let selection = ProviderModelSelection(enabled: ["target"], preloaded: [])
    let capacity = MemoryCapacity(
        totalMemoryGB: 64,
        gpuMemoryActiveGB: 0,
        gpuMemoryCacheGB: 0
    )
    let daemon = DaemonState(
        schema: 1,
        version: "fixture",
        currentModel: "",
        warmModels: [],
        stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
        trust: TrustState(level: "trusted", status: "online", reason: "", receivedAt: capturedAt.timeIntervalSince1970),
        capacity: capacity,
        slots: [],
        inferenceActive: false,
        startedAt: capturedAt.timeIntervalSince1970,
        writtenAt: capturedAt.timeIntervalSince1970,
        pid: 1,
        processIdentity: ProcessIdentity(pid: 1, startTimeMicros: 1)
    )
    let inventory = ModelInventoryBuilder.build(
        catalog: [CatalogModel(
            id: "target",
            displayName: "Target",
            family: "target-family",
            modelType: "llm",
            capabilities: ["text"],
            sizeGB: 4,
            minimumRAMGB: 8,
            active: true
        )],
        local: [LocalModel(
            id: "target",
            modelType: "llm",
            sizeBytes: 4_000_000_000,
            estimatedMemoryGB: 4
        )],
        selection: selection,
        daemon: daemon,
        loadedModels: []
    )
    let draft = ProviderConfigDraft(
        sourceRevision: "fixture",
        original: selection,
        selection: selection,
        originalMaxModelSlots: 2,
        maxModelSlots: 2
    )
    let freshSources = ProviderControlSourceStates(
        catalog: .fresh(evidenceAt: capturedAt),
        localModels: .fresh(evidenceAt: capturedAt),
        daemon: .fresh(evidenceAt: capturedAt),
        loadedModels: .fresh(evidenceAt: capturedAt)
    )
    return ProviderControlSnapshot(
        inventory: inventory,
        draft: draft,
        daemonState: daemon,
        supportsProtectedWarmup: true,
        protectedWarmupMaxModelSlots: 2,
        protectedWarmupAdvertisedModelIDs: ["target"],
        protectedWarmupLaunchModelIDs: ["target"],
        protectedWarmupConfiguredMaxModelSlots: 2,
        protectedWarmupConfiguredEnabledModels: ["target"],
        protectedWarmupConfiguredPreloadModels: [],
        residentModelIDs: [],
        capturedAt: capturedAt,
        sources: freshSources
    )
}
