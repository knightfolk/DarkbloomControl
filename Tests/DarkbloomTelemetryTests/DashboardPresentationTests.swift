import DarkbloomTelemetry
import Foundation
import Testing

@Suite("Dashboard presentation")
struct DashboardPresentationTests {
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
}
