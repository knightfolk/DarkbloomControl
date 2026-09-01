import DarkbloomTelemetry
import Foundation
import Testing

@Suite("Dashboard presentation")
struct DashboardPresentationTests {
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
