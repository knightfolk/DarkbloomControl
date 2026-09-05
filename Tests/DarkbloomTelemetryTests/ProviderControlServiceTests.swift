import Foundation
import Testing
@testable import DarkbloomTelemetry

private let serviceNow = Date(timeIntervalSince1970: 1_788_282_000)

@Suite("Provider control service")
struct ProviderControlServiceTests {
    @Test("refresh combines catalog local config and live telemetry")
    func refreshesInventory() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }

        let snapshot = try await harness.service.refresh()

        #expect(snapshot.inventory.myCatalog.count == 2)
        #expect(snapshot.inventory.available.count == 1)
        #expect(snapshot.draft.selection.enabled == ["gemma-4-26b-qat-4bit"])
        #expect(snapshot.capturedAt == harness.now)
        #expect(snapshot.inventory.myCatalog.first { $0.catalogID == "gemma-4-26b-qat-4bit" }?.liveState == .loadedIdle)
    }

    @Test("protected endpoint residency participates in the model inventory")
    func protectedEndpointResidencyMarksModelLoaded() async throws {
        let harness = try ServiceHarness.make(
            loadedModels: [],
            protectedWarmupLoadedModels: ["gemma-4-26b-qat-4bit"],
            protectedWarmupAdvertisedModels: [
                "gemma-4-26b-qat-4bit",
                "gpt-oss-20b",
            ],
            protectedWarmupLaunchModels: ["gemma-4-26b-qat-4bit"],
            protectedWarmupConfiguredMaxModelSlots: 2,
            protectedWarmupConfiguredEnabledModels: ["gemma"],
            protectedWarmupConfiguredPreloadModels: ["gemma-4-26b-qat-4bit"]
        )
        defer { harness.cleanup() }

        let snapshot = try await harness.service.refresh()

        #expect(snapshot.residentModelIDs == ["gemma-4-26b-qat-4bit"])
        #expect(snapshot.protectedWarmupAdvertisedModelIDs == [
            "gemma-4-26b-qat-4bit",
            "gpt-oss-20b",
        ])
        #expect(snapshot.protectedWarmupLaunchModelIDs == [
            "gemma-4-26b-qat-4bit"
        ])
        #expect(snapshot.protectedWarmupConfiguredMaxModelSlots == 2)
        #expect(snapshot.protectedWarmupConfiguredEnabledModels == ["gemma"])
        #expect(snapshot.protectedWarmupConfiguredPreloadModels == [
            "gemma-4-26b-qat-4bit"
        ])
        #expect(snapshot.inventory.myCatalog.first {
            $0.catalogID == "gemma-4-26b-qat-4bit"
        }?.liveState == .loadedIdle)
    }

    @Test("download and delete never change configuration")
    func mutationsStaySeparate() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }

        try await harness.service.download("qwen3-8b", onOutput: nil)
        try await harness.service.delete("gpt-oss-20b")

        #expect(await harness.configStore.saveCount == 0)
        #expect(await harness.runner.mutationArguments == [
            ["models", "download", "--config", harness.configURL.path, "qwen3-8b"],
            ["models", "remove", "gpt-oss-20b", "--force"],
        ])
    }

    @Test("catalog and local caches become stale independently")
    func cachesSourcesIndependently() async throws {
        let catalogHarness = try ServiceHarness.make()
        defer { catalogHarness.cleanup() }
        _ = try await catalogHarness.service.refresh()
        await catalogHarness.runner.failNextCatalog()
        await catalogHarness.runner.useNextLocal(localGemmaOnlyJSON)

        let staleCatalog = try await catalogHarness.service.refresh()

        #expect(staleCatalog.inventory.issues.contains("Model catalog is stale; showing the last successful result"))
        #expect(!staleCatalog.inventory.issues.contains("Local model list is stale; download state may be outdated"))
        #expect(staleCatalog.inventory.myCatalog.map(\.catalogID) == ["gemma-4-26b-qat-4bit"])

        let localHarness = try ServiceHarness.make()
        defer { localHarness.cleanup() }
        _ = try await localHarness.service.refresh()
        await localHarness.runner.useNextCatalog(catalogWithExtraModelJSON)
        await localHarness.runner.failNextLocal()

        let staleLocal = try await localHarness.service.refresh()

        #expect(staleLocal.inventory.issues.contains("Local model list is stale; download state may be outdated"))
        #expect(!staleLocal.inventory.issues.contains("Model catalog is stale; showing the last successful result"))
        #expect(staleLocal.inventory.available.map(\.catalogID).contains("llama-3-8b"))
        #expect(staleLocal.inventory.myCatalog.count == 2)
    }

    @Test("refresh exposes independent typed source freshness")
    func exposesTypedSourceFreshness() async throws {
        let catalogHarness = try ServiceHarness.make()
        defer { catalogHarness.cleanup() }
        _ = try await catalogHarness.service.refresh()
        await catalogHarness.runner.failNextCatalog()

        let staleCatalog = try await catalogHarness.service.refresh()

        #expect(staleCatalog.sources.catalog == .stale(
            "Model catalog is stale; showing the last successful result"
        ))
        #expect(staleCatalog.sources.localModels == .fresh(evidenceAt: serviceNow))

        let residencyHarness = try ServiceHarness.make(
            loadedModelsUpdatedAt: serviceNow.timeIntervalSince1970 - 11
        )
        defer { residencyHarness.cleanup() }
        await residencyHarness.telemetry.failNextDaemonRead()

        let unknownResidency = try await residencyHarness.service.refresh()

        #expect(unknownResidency.sources.daemon == .unavailable(
            "Provider activity is unavailable"
        ))
        #expect(unknownResidency.sources.loadedModels == .fresh(evidenceAt: serviceNow))
        #expect(unknownResidency.inventory.issues.contains("Provider activity is unavailable"))
        #expect(!unknownResidency.inventory.issues.contains("Loaded model state is stale"))
    }

    @Test("refresh uses acquisition time for unchanged loaded-model evidence")
    func usesAcquisitionTimeForLoadedModels() async throws {
        let daemonEvidence = serviceNow.addingTimeInterval(-9)
        let loadedEvidence = serviceNow.addingTimeInterval(-8)
        let harness = try ServiceHarness.make(
            daemonState: daemon(
                currentModel: "",
                inferenceActive: false,
                writtenAt: daemonEvidence.timeIntervalSince1970
            ),
            loadedModelsUpdatedAt: loadedEvidence.timeIntervalSince1970
        )
        defer { harness.cleanup() }

        let snapshot = try await harness.service.refresh()

        #expect(snapshot.capturedAt == serviceNow)
        #expect(snapshot.sources.catalog == .fresh(evidenceAt: serviceNow))
        #expect(snapshot.sources.localModels == .fresh(evidenceAt: serviceNow))
        #expect(snapshot.sources.daemon == .fresh(evidenceAt: daemonEvidence))
        #expect(snapshot.sources.loadedModels == .fresh(evidenceAt: serviceNow))
    }

    @Test("an older refresh cannot replace the cache from a completed mutation")
    func mutationRefreshWinsCacheRace() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        await harness.runner.blockNextLocal(with: localJSON)
        let olderRefresh = Task { try await harness.service.refresh() }
        await harness.runner.waitUntilLocalBlocked()

        await harness.runner.useNextLocal(localJSON)
        await harness.runner.useLocalByDefault(localWithQwenJSON)
        try await harness.service.download("qwen3-8b", onOutput: nil)

        await harness.runner.releaseBlockedLocal()
        _ = try await olderRefresh.value
        await harness.runner.failNextLocal()
        let stale = try await harness.service.refresh()

        #expect(stale.inventory.issues.contains(
            "Local model list is stale; download state may be outdated"
        ))
        #expect(stale.inventory.myCatalog.map(\.catalogID).contains("qwen3-8b"))
    }

    @Test("a required source that has never decoded throws a bounded unavailable error")
    func rejectsUnavailableFirstRefresh() async throws {
        let catalogHarness = try ServiceHarness.make()
        defer { catalogHarness.cleanup() }
        await catalogHarness.runner.failNextCatalog()

        await #expect(throws: ProviderControlError.inventoryUnavailable("Model catalog is unavailable")) {
            try await catalogHarness.service.refresh()
        }
        #expect(await catalogHarness.runner.sourceArguments.count == 2)

        let localHarness = try ServiceHarness.make()
        defer { localHarness.cleanup() }
        await localHarness.runner.failNextLocal()

        await #expect(throws: ProviderControlError.inventoryUnavailable("Local model list is unavailable")) {
            try await localHarness.service.refresh()
        }
        #expect(await localHarness.runner.sourceArguments.count == 2)
    }

    @Test("delete requires a fresh inventory")
    func deleteRequiresFreshInventory() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        _ = try await harness.service.refresh()
        await harness.runner.failNextCatalog()

        await #expect(throws: ProviderControlError.inventoryUnavailable("Model catalog is unavailable")) {
            try await harness.service.delete("gpt-oss-20b")
        }

        #expect(await harness.runner.mutationArguments.isEmpty)
    }

    @Test("delete rejects active loaded enabled and preloaded models in the service")
    func deleteRejectsUnsafeStates() async throws {
        let active = try ServiceHarness.make(
            daemonState: daemon(currentModel: "gpt-oss-20b", inferenceActive: true),
            loadedModels: []
        )
        defer { active.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("The active model cannot be deleted")) {
            try await active.service.delete("gpt-oss-20b")
        }

        let loaded = try ServiceHarness.make(loadedModels: ["gpt-oss-20b"])
        defer { loaded.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("A loaded model cannot be deleted")) {
            try await loaded.service.delete("gpt-oss-20b")
        }

        let enabled = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: ["gpt-oss-20b"],
            preloaded: []
        ))
        defer { enabled.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("Disable the model and save before deleting it")) {
            try await enabled.service.delete("gpt-oss-20b")
        }

        let preloaded = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: [],
            preloaded: ["gpt-oss-20b"]
        ))
        defer { preloaded.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("Remove the model from preload and save before deleting it")) {
            try await preloaded.service.delete("gpt-oss-20b")
        }

        #expect(await active.runner.mutationArguments.isEmpty)
        #expect(await loaded.runner.mutationArguments.isEmpty)
        #expect(await enabled.runner.mutationArguments.isEmpty)
        #expect(await preloaded.runner.mutationArguments.isEmpty)
    }

    @Test("delete fails closed when either live residency source is unavailable")
    func deleteRequiresLiveResidencySources() async throws {
        let daemonUnavailable = try ServiceHarness.make()
        defer { daemonUnavailable.cleanup() }
        await daemonUnavailable.telemetry.failNextDaemonRead()

        await #expect(throws: ProviderControlError.deleteBlocked(
            "Provider activity is unavailable; deletion was not attempted"
        )) {
            try await daemonUnavailable.service.delete("gpt-oss-20b")
        }
        #expect(await daemonUnavailable.runner.mutationArguments.isEmpty)

        let loadedUnavailable = try ServiceHarness.make()
        defer { loadedUnavailable.cleanup() }
        await loadedUnavailable.telemetry.failNextLoadedModelsRead()

        await #expect(throws: ProviderControlError.deleteBlocked(
            "Loaded model state is unavailable; deletion was not attempted"
        )) {
            try await loadedUnavailable.service.delete("gpt-oss-20b")
        }
        #expect(await loadedUnavailable.runner.mutationArguments.isEmpty)
    }

    @Test("delete rejects stale daemon state, previous-run residency, and future timestamps")
    func deleteRequiresCurrentResidencyEvidence() async throws {
        let staleDaemon = try ServiceHarness.make(daemonState: daemon(
            currentModel: "",
            inferenceActive: false,
            writtenAt: serviceNow.timeIntervalSince1970 - 10.001
        ))
        defer { staleDaemon.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked(
            "Provider activity is stale; deletion was not attempted"
        )) {
            try await staleDaemon.service.delete("gpt-oss-20b")
        }

        let futureDaemon = try ServiceHarness.make(daemonState: daemon(
            currentModel: "",
            inferenceActive: false,
            writtenAt: serviceNow.timeIntervalSince1970 + 0.001
        ))
        defer { futureDaemon.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked(
            "Provider activity timestamp is in the future; deletion was not attempted"
        )) {
            try await futureDaemon.service.delete("gpt-oss-20b")
        }

        let staleLoaded = try ServiceHarness.make(
            daemonState: daemon(
                currentModel: "",
                inferenceActive: false,
                startedAt: serviceNow.timeIntervalSince1970 - 20
            ),
            loadedModelsUpdatedAt: serviceNow.timeIntervalSince1970 - 20.001
        )
        defer { staleLoaded.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked(
            "Loaded model state predates the current provider run; deletion was not attempted"
        )) {
            try await staleLoaded.service.delete("gpt-oss-20b")
        }

        let futureLoaded = try ServiceHarness.make(
            loadedModelsUpdatedAt: serviceNow.timeIntervalSince1970 + 0.001
        )
        defer { futureLoaded.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked(
            "Loaded model state timestamp is in the future; deletion was not attempted"
        )) {
            try await futureLoaded.service.delete("gpt-oss-20b")
        }

        #expect(await staleDaemon.runner.mutationArguments.isEmpty)
        #expect(await futureDaemon.runner.mutationArguments.isEmpty)
        #expect(await staleLoaded.runner.mutationArguments.isEmpty)
        #expect(await futureLoaded.runner.mutationArguments.isEmpty)
    }

    @Test("delete accepts residency evidence at the inclusive ten-second boundary")
    func deleteAcceptsTenSecondResidencyBoundary() async throws {
        let boundary = serviceNow.timeIntervalSince1970 - 10
        let harness = try ServiceHarness.make(
            daemonState: daemon(
                currentModel: "",
                inferenceActive: false,
                writtenAt: boundary
            ),
            loadedModels: [],
            loadedModelsUpdatedAt: boundary
        )
        defer { harness.cleanup() }

        try await harness.service.delete("gpt-oss-20b")

        #expect(await harness.runner.mutationArguments.first == [
            "models", "remove", "gpt-oss-20b", "--force",
        ])
    }

    @Test("delete residency cancellation propagates without removing and releases serialization")
    func deleteResidencyCancellationReleasesLock() async throws {
        let daemonCancellation = try ServiceHarness.make()
        defer { daemonCancellation.cleanup() }
        await daemonCancellation.telemetry.cancelNextDaemonRead()
        do {
            try await daemonCancellation.service.delete("gpt-oss-20b")
            Issue.record("Expected daemon-read cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let loadedCancellation = try ServiceHarness.make()
        defer { loadedCancellation.cleanup() }
        await loadedCancellation.telemetry.cancelNextLoadedModelsRead()
        do {
            try await loadedCancellation.service.delete("gpt-oss-20b")
            Issue.record("Expected loaded-model-read cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await daemonCancellation.runner.mutationArguments.isEmpty)
        #expect(await loadedCancellation.runner.mutationArguments.isEmpty)
        try await daemonCancellation.service.execute(.stop, enabledModels: [])
        try await loadedCancellation.service.execute(.stop, enabledModels: [])
    }

    @Test("delete rejects unmatched and ambiguous local identities")
    func deleteRejectsUnsafeIdentity() async throws {
        let unmatched = try ServiceHarness.make()
        defer { unmatched.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("The local model could not be matched safely")) {
            try await unmatched.service.delete("orphan-local-model")
        }

        let ambiguous = try ServiceHarness.make(catalog: duplicateCatalogIDJSON)
        defer { ambiguous.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("The local model identity is ambiguous")) {
            try await ambiguous.service.delete("gpt-oss-20b")
        }

        #expect(await unmatched.runner.mutationArguments.isEmpty)
        #expect(await ambiguous.runner.mutationArguments.isEmpty)
    }

    @Test("lifecycle commands use exact arguments and policy bounds")
    func lifecycleCommandsAreExact() async throws {
        let harness = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss"],
            preloaded: []
        ))
        defer { harness.cleanup() }

        try await harness.service.execute(.start, enabledModels: ["gemma-4-26b-qat-4bit", "gpt-oss"])
        try await harness.service.execute(.stop, enabledModels: [])
        try await harness.service.execute(.restart, enabledModels: [])

        let invocations = await harness.runner.lifecycleInvocations
        #expect(invocations.map(\.command.arguments) == [
            ["start", "--config", harness.configURL.path, "--model", "gemma-4-26b-qat-4bit", "--model", "gpt-oss-20b", "--local-endpoint"],
            ["stop"],
            ["start", "--config", harness.configURL.path, "--model", "gemma-4-26b-qat-4bit", "--model", "gpt-oss-20b", "--local-endpoint"],
        ])
        #expect(invocations.allSatisfy { $0.timeout == DarkbloomSourcePolicy.lifecycleTimeout })
        #expect(invocations.allSatisfy { $0.outputLimit == DarkbloomSourcePolicy.mutationOutputByteLimit })
        #expect(invocations.allSatisfy { !$0.command.arguments.contains("--uninstall") })
    }

    @Test("start rejects an empty saved enabled selection")
    func startRequiresEnabledModels() async throws {
        let harness = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: [],
            preloaded: []
        ))
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.noEnabledModels) {
            try await harness.service.execute(.start, enabledModels: ["stale-caller-model"])
        }

        #expect(await harness.runner.lifecycleInvocations.isEmpty)
    }

    @Test("start ignores stale caller selectors and uses the fresh saved selection")
    func startUsesFreshSavedSelection() async throws {
        let harness = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit"],
            preloaded: []
        ))
        defer { harness.cleanup() }

        try await harness.service.execute(
            .start,
            enabledModels: ["gpt-oss", "qwen3-8b"]
        )

        let invocation = try #require(await harness.runner.lifecycleInvocations.first)
        #expect(invocation.command.arguments == [
            "start", "--config", harness.configURL.path,
            "--model", "gemma-4-26b-qat-4bit",
            "--local-endpoint",
        ])
    }

    @Test("app restart reapplies the fresh saved selection and protected endpoint")
    func restartUsesFreshSavedSelection() async throws {
        let harness = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss"],
            preloaded: []
        ))
        defer { harness.cleanup() }

        try await harness.service.execute(
            .restart,
            enabledModels: ["stale-caller-model"]
        )

        let invocation = try #require(await harness.runner.lifecycleInvocations.first)
        #expect(invocation.command.arguments == [
            "start", "--config", harness.configURL.path,
            "--model", "gemma-4-26b-qat-4bit",
            "--model", "gpt-oss-20b",
            "--local-endpoint",
        ])
    }

    @Test("app restart rejects an empty saved enabled selection")
    func restartRequiresEnabledModels() async throws {
        let harness = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: [],
            preloaded: []
        ))
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.noEnabledModels) {
            try await harness.service.execute(.restart, enabledModels: ["stale-caller-model"])
        }

        #expect(await harness.runner.lifecycleInvocations.isEmpty)
    }

    @Test("start rejects a saved selector that cannot resolve to one downloaded model")
    func startRequiresResolvableDownloadedModels() async throws {
        let missing = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: ["missing-family"],
            preloaded: []
        ))
        defer { missing.cleanup() }

        await #expect(
            throws: ProviderControlError.inventoryUnavailable(
                "Saved model selection is not an unambiguous downloaded catalog model"
            )
        ) {
            try await missing.service.execute(.start, enabledModels: [])
        }

        #expect(await missing.runner.lifecycleInvocations.isEmpty)
    }

    @Test("activity maps fresh daemon telemetry directly")
    func mapsActivityRisk() async throws {
        let active = try ServiceHarness.make(
            daemonState: daemon(currentModel: "gpt-oss-20b", inferenceActive: true)
        )
        defer { active.cleanup() }
        #expect(await active.service.activityRisk() == .active)

        let idle = try ServiceHarness.make()
        defer { idle.cleanup() }
        #expect(await idle.service.activityRisk() == .idle)

        await idle.telemetry.failNextDaemonRead()
        #expect(await idle.service.activityRisk() == .unknown("Provider activity is unavailable"))
    }

    @Test("activity treats stale and future daemon telemetry as unknown")
    func activityRequiresCurrentTelemetry() async throws {
        let boundary = try ServiceHarness.make(daemonState: daemon(
            currentModel: "gpt-oss-20b",
            inferenceActive: true,
            writtenAt: serviceNow.timeIntervalSince1970 - 10
        ))
        defer { boundary.cleanup() }
        #expect(await boundary.service.activityRisk() == .active)

        let stale = try ServiceHarness.make(daemonState: daemon(
            currentModel: "gpt-oss-20b",
            inferenceActive: true,
            writtenAt: serviceNow.timeIntervalSince1970 - 10.001
        ))
        defer { stale.cleanup() }
        #expect(await stale.service.activityRisk() == .unknown("Provider activity is stale"))

        let future = try ServiceHarness.make(daemonState: daemon(
            currentModel: "",
            inferenceActive: false,
            writtenAt: serviceNow.timeIntervalSince1970 + 0.001
        ))
        defer { future.cleanup() }
        #expect(await future.service.activityRisk() == .unknown(
            "Provider activity timestamp is in the future"
        ))
    }

    @Test("an absent approved executable is a bounded service error")
    func rejectsMissingExecutable() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        try FileManager.default.removeItem(at: harness.executableURL)

        await #expect(throws: ProviderControlError.executableUnavailable) {
            try await harness.service.refresh()
        }

        #expect(await harness.runner.invocations.isEmpty)
    }

    @Test("model and lifecycle commands reject overlap while the actor is suspended")
    func rejectsOverlappingCommands() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        await harness.runner.blockNextMutation()
        let download = Task {
            try await harness.service.download("qwen3-8b", onOutput: nil)
        }
        await harness.runner.waitUntilBlocked()

        await #expect(throws: ProviderControlError.commandAlreadyRunning) {
            try await harness.service.delete("gpt-oss-20b")
        }
        await #expect(throws: ProviderControlError.commandAlreadyRunning) {
            try await harness.service.execute(.stop, enabledModels: [])
        }

        await harness.runner.releaseBlockedCommand()
        try await download.value
    }

    @Test("save participates in command serialization")
    func serializesSave() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let draft = try await harness.configStore.load()
        await harness.configStore.blockNextSave()
        let save = Task {
            try await harness.service.save(draft.withSelection(ProviderModelSelection(
                enabled: ["gpt-oss-20b"],
                preloaded: []
            )))
        }
        await harness.configStore.waitUntilSaveBlocked()

        await #expect(throws: ProviderControlError.commandAlreadyRunning) {
            try await harness.service.download("qwen3-8b", onOutput: nil)
        }

        await harness.configStore.releaseBlockedSave()
        let result = try await save.value
        #expect(result.restartRequired)
        #expect(result.draft.selection.enabled == ["gpt-oss-20b"])
    }

    @Test("save rejects selectors removed externally immediately before saving")
    func saveRejectsExternalRemoval() async throws {
        let harness = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: ["gpt-oss-20b"],
            preloaded: []
        ))
        defer { harness.cleanup() }
        let draft = try await harness.configStore.load()
        await harness.runner.useLocalByDefault(localGemmaOnlyJSON)

        await #expect(throws: ProviderControlError.inventoryUnavailable(
            "Saved model selection is not an unambiguous downloaded catalog model"
        )) {
            try await harness.service.save(draft)
        }

        #expect(await harness.configStore.saveCount == 0)
        #expect(await harness.runner.mutationArguments.isEmpty)
    }

    @Test("save rejects direct callers with missing or ambiguous family selectors")
    func saveRequiresUnambiguousDownloadedCatalogModels() async throws {
        let missing = try ServiceHarness.make()
        defer { missing.cleanup() }
        let missingDraft = try await missing.configStore.load().withSelection(
            ProviderModelSelection(enabled: ["not-in-catalog"], preloaded: [])
        )

        await #expect(throws: ProviderControlError.inventoryUnavailable(
            "Saved model selection is not an unambiguous downloaded catalog model"
        )) {
            try await missing.service.save(missingDraft)
        }

        let ambiguous = try ServiceHarness.make(
            catalog: ambiguousFamilyCatalogJSON,
            local: ambiguousFamilyLocalJSON,
            selection: ProviderModelSelection(enabled: [], preloaded: [])
        )
        defer { ambiguous.cleanup() }
        let ambiguousDraft = try await ambiguous.configStore.load().withSelection(
            ProviderModelSelection(enabled: ["gpt-oss"], preloaded: [])
        )

        await #expect(throws: ProviderControlError.inventoryUnavailable(
            "Saved model selection is not an unambiguous downloaded catalog model"
        )) {
            try await ambiguous.service.save(ambiguousDraft)
        }

        #expect(await missing.configStore.saveCount == 0)
        #expect(await ambiguous.configStore.saveCount == 0)
    }

    @Test("save aligns a preload alias with its independently resolved enabled selector")
    func saveNormalizesMixedSelectorIdentity() async throws {
        let original = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit"],
            preloaded: []
        )
        let staged = ProviderModelSelection(
            enabled: ["gpt-oss", "gemma-4-26b-qat-4bit"],
            preloaded: ["gpt-oss-20b", "gemma-4-26b-qat-4bit"]
        )
        let harness = try ServiceHarness.make(
            originalSelection: original,
            selection: staged
        )
        defer { harness.cleanup() }

        let draft = try await harness.configStore.load()
        let result = try await harness.service.save(draft)

        #expect(result.draft.selection == ProviderModelSelection(
            enabled: ["gpt-oss", "gemma-4-26b-qat-4bit"],
            preloaded: ["gpt-oss", "gemma-4-26b-qat-4bit"]
        ))
    }

    @Test("save rejects a preload whose catalog identity is not enabled")
    func saveRejectsCanonicalPreloadOutsideEnabledSelection() async throws {
        let harness = try ServiceHarness.make(
            originalSelection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit"],
                preloaded: []
            ),
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit"],
                preloaded: ["gpt-oss-20b"]
            )
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.inventoryUnavailable(
            "Saved model selection is not an unambiguous downloaded catalog model"
        )) {
            try await harness.service.save(try await harness.configStore.load())
        }
        #expect(await harness.configStore.saveCount == 0)
    }

    @Test("save does not use stale catalog or local fallback")
    func saveRequiresFreshModelSources() async throws {
        let catalogHarness = try ServiceHarness.make()
        defer { catalogHarness.cleanup() }
        _ = try await catalogHarness.service.refresh()
        await catalogHarness.runner.failNextCatalog()
        let catalogDraft = try await catalogHarness.configStore.load()

        await #expect(throws: ProviderControlError.inventoryUnavailable("Model catalog is unavailable")) {
            try await catalogHarness.service.save(catalogDraft)
        }

        let localHarness = try ServiceHarness.make()
        defer { localHarness.cleanup() }
        _ = try await localHarness.service.refresh()
        await localHarness.runner.failNextLocal()
        let localDraft = try await localHarness.configStore.load()

        await #expect(throws: ProviderControlError.inventoryUnavailable("Local model list is unavailable")) {
            try await localHarness.service.save(localDraft)
        }

        #expect(await catalogHarness.configStore.saveCount == 0)
        #expect(await localHarness.configStore.saveCount == 0)
    }

    @Test("save preflight cancellation propagates and releases serialization")
    func savePreflightCancellationReleasesLock() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let draft = try await harness.configStore.load()
        await harness.runner.cancelNextCatalog()

        do {
            _ = try await harness.service.save(draft)
            Issue.record("Expected save preflight cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await harness.configStore.saveCount == 0)
        try await harness.service.execute(.stop, enabledModels: [])
    }

    @Test("download requires an exact fresh available catalog entry")
    func downloadValidatesFreshAvailability() async throws {
        let missing = try ServiceHarness.make()
        defer { missing.cleanup() }
        await #expect(throws: ProviderControlError.inventoryUnavailable(
            "The requested model is not a fresh available catalog entry"
        )) {
            try await missing.service.download("gpt-oss", onOutput: nil)
        }

        let downloaded = try ServiceHarness.make()
        defer { downloaded.cleanup() }
        await #expect(throws: ProviderControlError.inventoryUnavailable(
            "The requested model is not a fresh available catalog entry"
        )) {
            try await downloaded.service.download("gpt-oss-20b", onOutput: nil)
        }

        let ambiguous = try ServiceHarness.make(catalog: duplicateCatalogIDJSON)
        defer { ambiguous.cleanup() }
        await #expect(throws: ProviderControlError.inventoryUnavailable(
            "The requested model is not a fresh available catalog entry"
        )) {
            try await ambiguous.service.download("gpt-oss-20b", onOutput: nil)
        }

        #expect(await missing.runner.mutationArguments.isEmpty)
        #expect(await downloaded.runner.mutationArguments.isEmpty)
        #expect(await ambiguous.runner.mutationArguments.isEmpty)
    }

    @Test("download does not use stale source fallback or ignore an external download")
    func downloadRequiresCurrentModelSources() async throws {
        let staleCatalog = try ServiceHarness.make()
        defer { staleCatalog.cleanup() }
        _ = try await staleCatalog.service.refresh()
        await staleCatalog.runner.failNextCatalog()
        await #expect(throws: ProviderControlError.inventoryUnavailable("Model catalog is unavailable")) {
            try await staleCatalog.service.download("qwen3-8b", onOutput: nil)
        }

        let externalDownload = try ServiceHarness.make()
        defer { externalDownload.cleanup() }
        await externalDownload.runner.useLocalByDefault(localWithQwenJSON)
        await #expect(throws: ProviderControlError.inventoryUnavailable(
            "The requested model is not a fresh available catalog entry"
        )) {
            try await externalDownload.service.download("qwen3-8b", onOutput: nil)
        }

        #expect(await staleCatalog.runner.mutationArguments.isEmpty)
        #expect(await externalDownload.runner.mutationArguments.isEmpty)
    }

    @Test("download preflight cancellation issues no mutation and releases serialization")
    func downloadPreflightCancellationReleasesLock() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        await harness.runner.cancelNextCatalog()

        do {
            try await harness.service.download("qwen3-8b", onOutput: nil)
            Issue.record("Expected download preflight cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await harness.runner.mutationArguments.isEmpty)
        try await harness.service.execute(.stop, enabledModels: [])
    }

    @Test("download forwards bounded output chunks")
    func forwardsDownloadOutput() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let recorder = ServiceOutputRecorder()

        try await harness.service.download("qwen3-8b", onOutput: recorder.record)

        #expect(recorder.data == Data("download 25%".utf8))
        let invocation = try #require(await harness.runner.mutationInvocations.first)
        #expect(invocation.timeout == DarkbloomSourcePolicy.downloadTimeout)
        #expect(invocation.outputLimit == DarkbloomSourcePolicy.mutationOutputByteLimit)
    }

    @Test("download runner cancellation after dispatch reconciles authoritative model state")
    func reconcilesDispatchedDownloadCancellation() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let phases = ServicePhaseRecorder()
        await harness.runner.blockNextMutation()
        let download = Task {
            try await harness.service.performDownload(
                "qwen3-8b",
                onOutput: nil,
                onPhase: { phase in await phases.record(phase) }
            )
        }
        await harness.runner.waitUntilBlocked()
        await harness.runner.useLocalByDefault(localWithQwenJSON)

        download.cancel()
        let completion = try await download.value

        #expect(completion.snapshot?.inventory.myCatalog.contains {
            $0.localID == "qwen3-8b"
        } == true)
        #expect(await phases.values == [.reconciling])
        #expect(await harness.runner.sourceArguments.count == 4)
        try await harness.service.execute(.stop, enabledModels: [])
    }

    @Test("delete runner cancellation after dispatch reconciles authoritative model state")
    func reconcilesDispatchedDeleteCancellation() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let phases = ServicePhaseRecorder()
        await harness.runner.blockNextMutation()
        let deletion = Task {
            try await harness.service.performDelete(
                "gpt-oss-20b",
                onPhase: { phase in await phases.record(phase) }
            )
        }
        await harness.runner.waitUntilBlocked()
        await harness.runner.useLocalByDefault(localGemmaOnlyJSON)

        deletion.cancel()
        let completion = try await deletion.value

        #expect(completion.snapshot?.inventory.myCatalog.contains {
            $0.localID == "gpt-oss-20b"
        } == false)
        #expect(await phases.values == [.reconciling])
        #expect(await harness.runner.sourceArguments.count == 4)
        try await harness.service.execute(.stop, enabledModels: [])
    }

    @Test("lifecycle runner cancellation after dispatch reconciles authoritative state")
    func reconcilesDispatchedLifecycleCancellation() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let phases = ServicePhaseRecorder()
        await harness.runner.blockNextMutation()
        let stop = Task {
            try await harness.service.performLifecycle(
                .stop,
                enabledModels: [],
                onPhase: { phase in await phases.record(phase) }
            )
        }
        await harness.runner.waitUntilBlocked()

        stop.cancel()
        let completion = try await stop.value

        #expect(completion.snapshot != nil)
        #expect(await phases.values == [.reconciling])
        #expect(await harness.runner.lifecycleInvocations.map(\.command.arguments) == [["stop"]])
        #expect(await harness.runner.sourceArguments.count == 2)
        try await harness.service.execute(.stop, enabledModels: [])
    }

    @Test(
        "cancellation before launch remains a no-op for every mutation",
        arguments: PreLaunchProviderMutation.allCases
    )
    func preservesPreLaunchCancellationBoundary(
        _ mutation: PreLaunchProviderMutation
    ) async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let phases = ServicePhaseRecorder()
        await harness.runner.blockNextMutationBeforeLaunch()
        let operation = Task { () throws -> ProviderMutationCompletion in
            switch mutation {
            case .download:
                return try await harness.service.performDownload(
                    "qwen3-8b",
                    onOutput: nil,
                    onPhase: { phase in await phases.record(phase) }
                )
            case .delete:
                return try await harness.service.performDelete(
                    "gpt-oss-20b",
                    onPhase: { phase in await phases.record(phase) }
                )
            case .lifecycle:
                return try await harness.service.performLifecycle(
                    .stop,
                    enabledModels: [],
                    onPhase: { phase in await phases.record(phase) }
                )
            }
        }
        await harness.runner.waitUntilBlocked()

        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Expected cancellation before process launch")
        } catch is CancellationError {
            // A command that never launched has no external outcome to reconcile.
        }

        #expect(await phases.values.isEmpty)
        #expect(await harness.runner.launchedMutationInvocations.isEmpty)
        #expect(await harness.runner.sourceArguments.count == mutation.preflightSourceReadCount)

        // Cancellation must also release command serialization.
        try await harness.service.execute(.stop, enabledModels: [])
    }

    @Test(
        "legacy executor cancellation after invocation is conservatively reconciled",
        arguments: PreLaunchProviderMutation.allCases
    )
    func reconcilesLegacyExecutorCancellation(
        _ mutation: PreLaunchProviderMutation
    ) async throws {
        let harness = try ServiceHarness.make(useLegacyExecutor: true)
        defer { harness.cleanup() }
        let phases = ServicePhaseRecorder()
        await harness.runner.blockNextMutation()
        let operation = Task { () throws -> ProviderMutationCompletion in
            switch mutation {
            case .download:
                return try await harness.service.performDownload(
                    "qwen3-8b",
                    onOutput: nil,
                    onPhase: { phase in await phases.record(phase) }
                )
            case .delete:
                return try await harness.service.performDelete(
                    "gpt-oss-20b",
                    onPhase: { phase in await phases.record(phase) }
                )
            case .lifecycle:
                return try await harness.service.performLifecycle(
                    .stop,
                    enabledModels: [],
                    onPhase: { phase in await phases.record(phase) }
                )
            }
        }
        await harness.runner.waitUntilBlocked()
        switch mutation {
        case .download:
            await harness.runner.useLocalByDefault(localWithQwenJSON)
        case .delete:
            await harness.runner.useLocalByDefault(localGemmaOnlyJSON)
        case .lifecycle:
            break
        }

        operation.cancel()
        let completion = try await operation.value

        #expect(completion.snapshot != nil)
        #expect(await phases.values == [.reconciling])
        #expect(await harness.runner.launchedMutationInvocations.count == 1)
        #expect(
            await harness.runner.sourceArguments.count
                == mutation.preflightSourceReadCount + 2
        )
    }

    @Test("refresh propagates cancellation from model and telemetry sources")
    func refreshPropagatesCancellation() async throws {
        let catalogSource = try ServiceHarness.make()
        defer { catalogSource.cleanup() }
        _ = try await catalogSource.service.refresh()
        await catalogSource.runner.cancelNextCatalog()
        do {
            _ = try await catalogSource.service.refresh()
            Issue.record("Expected catalog-source cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let modelSource = try ServiceHarness.make()
        defer { modelSource.cleanup() }
        _ = try await modelSource.service.refresh()
        await modelSource.runner.blockNextLocal(with: localJSON)
        let refresh = Task { try await modelSource.service.refresh() }
        await modelSource.runner.waitUntilLocalBlocked()
        refresh.cancel()
        do {
            _ = try await refresh.value
            Issue.record("Expected model-source cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let daemonSource = try ServiceHarness.make()
        defer { daemonSource.cleanup() }
        await daemonSource.telemetry.cancelNextDaemonRead()
        do {
            _ = try await daemonSource.service.refresh()
            Issue.record("Expected daemon-source cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let loadedSource = try ServiceHarness.make()
        defer { loadedSource.cleanup() }
        await loadedSource.telemetry.cancelNextLoadedModelsRead()
        do {
            _ = try await loadedSource.service.refresh()
            Issue.record("Expected loaded-model-source cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test("download completion shields its mandatory refresh from caller cancellation")
    func downloadCompletionShieldsRefreshCancellation() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        _ = try await harness.service.refresh()
        await harness.runner.blockLocal(afterSuccessfulReads: 1, with: localJSON)
        let download = Task {
            try await harness.service.download("qwen3-8b", onOutput: nil)
        }
        await harness.runner.waitUntilLocalBlocked()

        download.cancel()
        try await Task.sleep(for: .milliseconds(10))
        await harness.runner.releaseBlockedLocal()
        try await download.value

        #expect(await harness.runner.mutationArguments == [[
            "models", "download", "--config", harness.configURL.path, "qwen3-8b",
        ]])
        try await harness.service.execute(.stop, enabledModels: [])
    }

    @Test("a completed download reports refresh uncertainty instead of cancellation")
    func completedDownloadReportsRefreshUncertainty() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let phases = ServicePhaseRecorder()
        await harness.runner.blockNextMutation()
        let download = Task {
            try await harness.service.performDownload(
                "qwen3-8b",
                onOutput: nil,
                onPhase: { phase in await phases.record(phase) }
            )
        }
        await harness.runner.waitUntilBlocked()
        await harness.runner.cancelNextCatalog()
        await harness.runner.releaseBlockedCommand()

        let completion = try await download.value

        #expect(completion == .refreshUncertain)
        #expect(await phases.values == [.reconciling])
        #expect(await harness.runner.mutationArguments == [[
            "models", "download", "--config", harness.configURL.path, "qwen3-8b",
        ]])
    }

    @Test("delete completion shields its mandatory refresh from caller cancellation")
    func deleteCompletionShieldsRefreshCancellation() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        await harness.runner.blockLocal(afterSuccessfulReads: 1, with: localJSON)
        let deletion = Task {
            try await harness.service.delete("gpt-oss-20b")
        }
        await harness.runner.waitUntilLocalBlocked()

        deletion.cancel()
        try await Task.sleep(for: .milliseconds(10))
        await harness.runner.releaseBlockedLocal()
        try await deletion.value

        #expect(await harness.runner.mutationArguments == [[
            "models", "remove", "gpt-oss-20b", "--force",
        ]])
    }

    @Test("lifecycle completion shields its mandatory refresh from caller cancellation")
    func lifecycleCompletionShieldsRefreshCancellation() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        await harness.runner.blockNextLocal(with: localJSON)
        let stop = Task {
            try await harness.service.execute(.stop, enabledModels: [])
        }
        await harness.runner.waitUntilLocalBlocked()

        stop.cancel()
        try await Task.sleep(for: .milliseconds(10))
        await harness.runner.releaseBlockedLocal()
        try await stop.value

        #expect(await harness.runner.lifecycleInvocations.map(\.command.arguments) == [["stop"]])
    }

    @Test("two-slot warmup loads the target before retiring the prior idle model")
    func warmupStagesThenRetiresPriorModelWithoutEditingConfiguration() async throws {
        let selection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            preloaded: ["gemma-4-26b-qat-4bit"]
        )
        let harness = try ServiceHarness.make(selection: selection, maxModelSlots: 2)
        defer { harness.cleanup() }
        await harness.warmup.succeedAndLoad(
            ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            in: harness.telemetry
        )
        let phases = ServicePhaseRecorder()

        let completion = try await harness.service.performWarmup(
            "gpt-oss-20b",
            onPhase: { phase in await phases.record(phase) }
        )

        let refreshed = try #require(completion.snapshot)
        #expect(refreshed.inventory.myCatalog.first {
            $0.catalogID == "gemma-4-26b-qat-4bit"
        }?.liveState == .unloaded)
        #expect(refreshed.inventory.myCatalog.first {
            $0.catalogID == "gpt-oss-20b"
        }?.liveState == .loadedIdle)
        #expect(await harness.warmup.requestedModels == ["gpt-oss-20b"])
        #expect(await harness.warmup.retiredModels == ["gemma-4-26b-qat-4bit"])
        #expect(await harness.warmup.events == [
            "load:gpt-oss-20b",
            "retire:gemma-4-26b-qat-4bit",
        ])
        #expect(await phases.values == [
            .loadingModel,
            .retiringPreviousModels,
            .reconciling,
        ])
        #expect(await harness.discovery.readCount == 3)
        #expect(await harness.configStore.saveCount == 0)
        #expect(refreshed.draft.original == selection)
    }

    @Test("warmup resolves enabled and preload aliases independently")
    func warmupUsesEnabledSelectorWhenPreloadUsesAnotherSelector() async throws {
        let selection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            preloaded: ["gpt-oss"]
        )
        let harness = try ServiceHarness.make(selection: selection, maxModelSlots: 2)
        defer { harness.cleanup() }
        await harness.warmup.succeedAndLoad(
            ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            in: harness.telemetry
        )

        let completion = try await harness.service.performWarmup(
            "gpt-oss-20b",
            onPhase: nil
        )

        #expect(completion.snapshot != nil)
        #expect(await harness.warmup.requestedModels == ["gpt-oss-20b"])
    }

    @Test("two-slot warmup reports a safe partial state when retirement fails after loading")
    func warmupReportsRetirementFailureAfterTargetWarms() async throws {
        let selection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            preloaded: ["gemma-4-26b-qat-4bit"]
        )
        let harness = try ServiceHarness.make(selection: selection, maxModelSlots: 2)
        defer { harness.cleanup() }
        await harness.warmup.succeedAndLoad(
            ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            in: harness.telemetry
        )
        await harness.warmup.failRetirement(
            of: "gemma-4-26b-qat-4bit",
            with: .httpStatus(503)
        )

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Target warmed, but the previous model could not be retired safely"
        )) {
            try await harness.service.performWarmup(
                "gpt-oss-20b",
                onPhase: nil
            )
        }

        #expect(await harness.warmup.requestedModels == ["gpt-oss-20b"])
        #expect(await harness.warmup.retiredModels == ["gemma-4-26b-qat-4bit"])
    }

    @Test("one-slot warmup retires an idle model before loading its replacement")
    func oneSlotWarmupRetiresThenLoads() async throws {
        let selection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            preloaded: []
        )
        let harness = try ServiceHarness.make(selection: selection, maxModelSlots: 1)
        defer { harness.cleanup() }
        await harness.warmup.succeedAndLoad(
            ["gpt-oss-20b"],
            in: harness.telemetry
        )
        let phases = ServicePhaseRecorder()

        let completion = try await harness.service.performWarmup(
            "gpt-oss-20b",
            onPhase: { phase in await phases.record(phase) }
        )

        let refreshed = try #require(completion.snapshot)
        #expect(refreshed.inventory.myCatalog.first {
            $0.catalogID == "gemma-4-26b-qat-4bit"
        }?.liveState == .unloaded)
        #expect(refreshed.inventory.myCatalog.first {
            $0.catalogID == "gpt-oss-20b"
        }?.liveState == .loadedIdle)
        #expect(await harness.warmup.events == [
            "retire:gemma-4-26b-qat-4bit",
            "load:gpt-oss-20b",
        ])
        #expect(await phases.values == [
            .retiringPreviousModels,
            .loadingModel,
            .reconciling,
        ])
    }

    @Test("one-slot partial switch reconciles after retiring the old model")
    func oneSlotWarmupReconcilesPartialFailure() async throws {
        let selection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            preloaded: []
        )
        let harness = try ServiceHarness.make(selection: selection, maxModelSlots: 1)
        defer { harness.cleanup() }
        await harness.warmup.failAfterLoading(
            .httpStatus(503),
            models: [],
            in: harness.telemetry
        )
        let phases = ServicePhaseRecorder()

        await #expect(throws: ModelWarmupClientError.httpStatus(503)) {
            try await harness.service.performWarmup(
                "gpt-oss-20b",
                onPhase: { phase in await phases.record(phase) }
            )
        }

        #expect(await harness.warmup.events == [
            "retire:gemma-4-26b-qat-4bit",
            "load:gpt-oss-20b",
        ])
        #expect(await phases.values == [
            .retiringPreviousModels,
            .loadingModel,
            .reconciling,
        ])
    }

    @Test("two-model warmup waits when both coordinator-visible slots are occupied")
    func warmupRejectsOccupiedTwoModelCapacity() async throws {
        let harness = try ServiceHarness.make(
            local: localWithQwenJSON,
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "qwen3-8b", "gpt-oss-20b"],
                preloaded: []
            ),
            loadedModels: ["gemma-4-26b-qat-4bit", "qwen3-8b"],
            maxModelSlots: 2
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Both model slots are occupied; waiting avoids evicting another model"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
    }

    @Test("warmup freshness failures use warmup-specific diagnostics")
    func warmupFreshnessFailuresAreCategorizedCorrectly() async throws {
        let selection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            preloaded: []
        )
        let daemonFailure = try ServiceHarness.make(selection: selection)
        defer { daemonFailure.cleanup() }
        await daemonFailure.telemetry.failNextDaemonRead()

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Provider activity is unavailable; warmup was not attempted"
        )) {
            try await daemonFailure.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        let loadedFailure = try ServiceHarness.make(selection: selection)
        defer { loadedFailure.cleanup() }
        await loadedFailure.telemetry.failNextLoadedModelsRead()

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Loaded model state is unavailable; warmup was not attempted"
        )) {
            try await loadedFailure.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }
    }

    @Test("warmup is a no-op when the protected endpoint already reports the target resident")
    func warmupAcceptsProtectedEndpointResidentTarget() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            loadedModels: [],
            maxModelSlots: 1,
            protectedWarmupLoadedModels: ["gpt-oss-20b"]
        )
        defer { harness.cleanup() }

        let completion = try await harness.service.performWarmup(
            "gpt-oss-20b",
            onPhase: nil
        )

        #expect(completion.snapshot?.residentModelIDs.contains("gpt-oss-20b") == true)
        #expect(await harness.warmup.requestedModels.isEmpty)
        #expect(await harness.warmup.retiredModels.isEmpty)
    }

    @Test("unknown resident models still occupy protected staging capacity")
    func warmupCountsUnknownResidents() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            loadedModels: ["gemma-4-26b-qat-4bit", "external-model"],
            maxModelSlots: 2
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Both model slots are occupied; waiting avoids evicting another model"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
    }

    @Test("saved and live slot capacity must match before switching")
    func warmupRequiresAppliedCapacity() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            maxModelSlots: 2,
            protectedWarmupMaxModelSlots: 1
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Restart the provider to apply the saved model capacity"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
    }

    @Test("warmup requires complete protected runtime configuration proof")
    func warmupRequiresCompleteProtectedRuntimeProof() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            maxModelSlots: 2,
            protectedWarmupMaxModelSlots: 2,
            completeProtectedWarmupProof: false
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Protected warmup requires complete applied provider runtime proof"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
        #expect(await harness.warmup.retiredModels.isEmpty)
    }

    @Test("warmup rejects a protected runtime configuration mismatch")
    func warmupRejectsProtectedRuntimeConfigurationMismatch() async throws {
        let selection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            preloaded: []
        )
        let harness = try ServiceHarness.make(
            selection: selection,
            maxModelSlots: 2,
            protectedWarmupMaxModelSlots: 2,
            protectedWarmupLaunchModels: ["gemma-4-26b-qat-4bit"],
            protectedWarmupConfiguredMaxModelSlots: 2,
            protectedWarmupConfiguredEnabledModels: selection.enabled,
            protectedWarmupConfiguredPreloadModels: selection.preloaded
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Protected warmup requires complete applied provider runtime proof"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
        #expect(await harness.warmup.retiredModels.isEmpty)
    }

    @Test("one-model capacity refuses inconsistent multiple residents without retiring either")
    func oneSlotWarmupRejectsMultipleResidents() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            loadedModels: ["gemma-4-26b-qat-4bit", "external-model"],
            maxModelSlots: 1
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Loaded model state conflicts with one-model capacity; waiting for a clean refresh"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
        #expect(await harness.warmup.retiredModels.isEmpty)
    }

    @Test("two-model warmup requires configured memory headroom before using a free slot")
    func warmupRejectsInsufficientStagingHeadroom() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            daemonState: daemon(
                currentModel: "gemma-4-26b-qat-4bit",
                inferenceActive: false,
                capacity: MemoryCapacity(
                    totalMemoryGB: 32,
                    gpuMemoryActiveGB: 10,
                    gpuMemoryCacheGB: 5
                )
            ),
            maxModelSlots: 2,
            minimumHeadroomGB: 16
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Waiting for enough memory to stage this model without eviction"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
    }

    @Test("two-model warmup counts memory used by other applications")
    func warmupUsesWholeSystemHeadroom() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            daemonState: daemon(
                currentModel: "gemma-4-26b-qat-4bit",
                inferenceActive: false,
                capacity: MemoryCapacity(
                    totalMemoryGB: 64,
                    gpuMemoryActiveGB: 10,
                    gpuMemoryCacheGB: 5
                )
            ),
            maxModelSlots: 2,
            minimumHeadroomGB: 8,
            availableSystemMemoryGB: 12
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Waiting for enough memory to stage this model without eviction"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
    }

    @Test("two-model warmup refuses an endpoint that may evict a resident")
    func warmupRequiresProtectedProviderCapability() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            maxModelSlots: 2,
            protectedWarmupSupported: false
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Protected two-model staging requires a provider update"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
    }

    @Test("warmup fails closed while inference is active")
    func warmupRejectsActiveInference() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            daemonState: daemon(
                currentModel: "gemma-4-26b-qat-4bit",
                inferenceActive: true
            )
        )
        defer { harness.cleanup() }
        let phases = ServicePhaseRecorder()

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Waiting for the current customer job to finish"
        )) {
            try await harness.service.performWarmup(
                "gpt-oss-20b",
                onPhase: { phase in await phases.record(phase) }
            )
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
        #expect(await harness.discovery.readCount == 1)
        #expect(await phases.values.isEmpty)
    }

    @Test("two-slot warmup may stage beside an active job and leaves its model resident")
    func warmupStagesWithoutInterruptingActiveModel() async throws {
        let selection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            preloaded: []
        )
        let harness = try ServiceHarness.make(
            selection: selection,
            daemonState: daemon(
                currentModel: "gemma-4-26b-qat-4bit",
                inferenceActive: true,
                capacity: MemoryCapacity(
                    totalMemoryGB: 64,
                    gpuMemoryActiveGB: 16,
                    gpuMemoryCacheGB: 0
                )
            ),
            maxModelSlots: 2
        )
        defer { harness.cleanup() }
        await harness.warmup.succeedAndLoad(
            ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            in: harness.telemetry
        )
        await harness.warmup.blockRetirement(of: "gemma-4-26b-qat-4bit")

        let completion = try await harness.service.performWarmup(
            "gpt-oss-20b", onPhase: nil)

        let refreshed = try #require(completion.snapshot)
        #expect(refreshed.inventory.myCatalog.first {
            $0.catalogID == "gemma-4-26b-qat-4bit"
        }?.liveState == .active)
        #expect(refreshed.inventory.myCatalog.first {
            $0.catalogID == "gpt-oss-20b"
        }?.liveState == .loadedIdle)
        #expect(await harness.warmup.requestedModels == ["gpt-oss-20b"])
        #expect(await harness.warmup.retiredModels == ["gemma-4-26b-qat-4bit"])
    }

    @Test("warmup requires the target to be enabled in saved configuration")
    func warmupRejectsUnsavedEnable() async throws {
        let harness = try ServiceHarness.make(
            originalSelection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit"],
                preloaded: []
            ),
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            )
        )
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.warmupBlocked(
            "Enable and save this model first"
        )) {
            try await harness.service.performWarmup("gpt-oss-20b", onPhase: nil)
        }

        #expect(await harness.warmup.requestedModels.isEmpty)
        #expect(await harness.discovery.readCount == 1)
    }

    @Test("warmup is a no-op when fresh state already reports the target resident")
    func warmupSkipsAlreadyResidentTarget() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            ),
            loadedModels: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"]
        )
        defer { harness.cleanup() }

        let completion = try await harness.service.performWarmup(
            "gpt-oss-20b",
            onPhase: nil
        )

        #expect(completion.snapshot != nil)
        #expect(await harness.warmup.requestedModels.isEmpty)
        #expect(await harness.discovery.readCount == 1)
    }

    @Test("warmup reconciles an ambiguous request failure before reporting outcome")
    func warmupReconcilesRequestFailure() async throws {
        let harness = try ServiceHarness.make(
            selection: ProviderModelSelection(
                enabled: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
                preloaded: []
            )
        )
        defer { harness.cleanup() }
        await harness.warmup.failAfterLoading(
            ModelWarmupClientError.busy,
            models: ["gemma-4-26b-qat-4bit", "gpt-oss-20b"],
            in: harness.telemetry
        )

        let completion = try await harness.service.performWarmup(
            "gpt-oss-20b",
            onPhase: nil
        )

        #expect(completion.snapshot != nil)
        #expect(await harness.warmup.requestedModels == ["gpt-oss-20b"])
    }
}

enum PreLaunchProviderMutation: CaseIterable, Sendable {
    case download
    case delete
    case lifecycle

    var preflightSourceReadCount: Int {
        switch self {
        case .download, .delete: 2
        case .lifecycle: 0
        }
    }
}

private final class ServiceHarness: @unchecked Sendable {
    let directory: URL
    let configURL: URL
    let executableURL: URL
    let runner: ServiceRunnerFake
    let telemetry: ServiceTelemetryFake
    let configStore: ServiceConfigStoreFake
    let discovery: ServiceEndpointDiscoveryFake
    let warmup: ServiceWarmupFake
    let service: ProviderControlService
    let now = serviceNow

    static func make(
        catalog: Data = catalogJSON,
        local: Data = localJSON,
        originalSelection: ProviderModelSelection? = nil,
        selection: ProviderModelSelection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit"],
            preloaded: []
        ),
        daemonState: DaemonState = daemon(currentModel: "", inferenceActive: false),
        loadedModels: [String] = ["gemma-4-26b-qat-4bit"],
        loadedModelsUpdatedAt: TimeInterval = serviceNow.timeIntervalSince1970,
        useLegacyExecutor: Bool = false,
        maxModelSlots: Int = 1,
        minimumHeadroomGB: Double = 16,
        availableSystemMemoryGB: Double? = nil,
        protectedWarmupSupported: Bool = true,
        protectedWarmupMaxModelSlots: Int? = nil,
        protectedWarmupLoadedModels: [String]? = nil,
        protectedWarmupAdvertisedModels: [String]? = nil,
        protectedWarmupLaunchModels: [String]? = nil,
        protectedWarmupConfiguredMaxModelSlots: Int? = nil,
        protectedWarmupConfiguredEnabledModels: [String]? = nil,
        protectedWarmupConfiguredPreloadModels: [String]? = nil,
        completeProtectedWarmupProof: Bool = true
    ) throws -> ServiceHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-provider-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableURL = directory.appendingPathComponent("darkbloom")
        #expect(FileManager.default.createFile(atPath: executableURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        let configURL = directory.appendingPathComponent(".config/darkbloom/provider.toml")
        let runner = ServiceRunnerFake(catalog: catalog, local: local)
        let telemetry = ServiceTelemetryFake(
            daemon: daemonState,
            loadedModels: LoadedModelsState(
                schema: 1,
                models: loadedModels,
                updatedAt: loadedModelsUpdatedAt
            )
        )
        let configStore = ServiceConfigStoreFake(
            selection: selection,
            original: originalSelection ?? selection,
            maxModelSlots: maxModelSlots
        )
        let discovery = ServiceEndpointDiscoveryFake()
        let warmup = ServiceWarmupFake(
            loadSafety: protectedWarmupSupported ? .preservesResidents : .mayEvictResident,
            maxModelSlots: protectedWarmupMaxModelSlots ?? maxModelSlots,
            loadedModels: protectedWarmupLoadedModels ?? loadedModels,
            advertisedModels: protectedWarmupAdvertisedModels,
            launchModels: completeProtectedWarmupProof
                ? (protectedWarmupLaunchModels ?? selection.enabled.map {
                    $0 == "gpt-oss" ? "gpt-oss-20b" : $0
                })
                : protectedWarmupLaunchModels,
            configuredMaxModelSlots: completeProtectedWarmupProof
                ? protectedWarmupConfiguredMaxModelSlots ?? maxModelSlots
                : protectedWarmupConfiguredMaxModelSlots,
            configuredEnabledModels: completeProtectedWarmupProof
                ? protectedWarmupConfiguredEnabledModels ?? selection.enabled
                : protectedWarmupConfiguredEnabledModels,
            configuredPreloadModels: completeProtectedWarmupProof
                ? protectedWarmupConfiguredPreloadModels ?? selection.preloaded
                : protectedWarmupConfiguredPreloadModels
        )
        let policy = DarkbloomSourcePolicy(homeDirectory: directory, environmentPath: directory.path)
        return ServiceHarness(
            directory: directory,
            configURL: configURL,
            executableURL: executableURL,
            runner: runner,
            telemetry: telemetry,
            configStore: configStore,
            discovery: discovery,
            warmup: warmup,
            policy: policy,
            useLegacyExecutor: useLegacyExecutor,
            minimumHeadroomGB: minimumHeadroomGB,
            availableSystemMemoryGB: availableSystemMemoryGB
                ?? max(
                    0,
                    daemonState.capacity.totalMemoryGB
                        - daemonState.capacity.gpuMemoryActiveGB
                        - daemonState.capacity.gpuMemoryCacheGB
                )
        )
    }

    private init(
        directory: URL,
        configURL: URL,
        executableURL: URL,
        runner: ServiceRunnerFake,
        telemetry: ServiceTelemetryFake,
        configStore: ServiceConfigStoreFake,
        discovery: ServiceEndpointDiscoveryFake,
        warmup: ServiceWarmupFake,
        policy: DarkbloomSourcePolicy,
        useLegacyExecutor: Bool,
        minimumHeadroomGB: Double,
        availableSystemMemoryGB: Double
    ) {
        self.directory = directory
        self.configURL = configURL
        self.executableURL = executableURL
        self.runner = runner
        self.telemetry = telemetry
        self.configStore = configStore
        self.discovery = discovery
        self.warmup = warmup
        let executor: any ProcessExecuting = useLegacyExecutor
            ? LegacyServiceRunnerAdapter(base: runner)
            : runner
        service = ProviderControlService(
            policy: policy,
            telemetrySource: telemetry,
            configStore: configStore,
            runner: executor,
            endpointReader: discovery,
            warmupClient: warmup,
            minimumWarmupHeadroomGB: { minimumHeadroomGB },
            availableSystemMemoryGB: { availableSystemMemoryGB },
            now: { serviceNow }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Compatibility fixture: intentionally implements only the original public
/// four-argument `ProcessExecuting` requirement.
private struct LegacyServiceRunnerAdapter: ProcessExecuting {
    let base: ServiceRunnerFake

    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult {
        try await base.run(
            command,
            timeout: timeout,
            outputLimit: outputLimit,
            onOutput: onOutput
        )
    }
}

private actor ServiceRunnerFake: LaunchReportingProcessExecuting {
    private enum Response: Sendable {
        case data(Data)
        case failure
        case cancellation
    }

    struct Invocation: Sendable {
        let command: ProcessCommand
        let timeout: Duration
        let outputLimit: Int
    }

    private let catalog: Data
    private var local: Data
    private var nextCatalog: Response?
    private var nextLocal: Response?
    private(set) var invocations: [Invocation] = []
    private var blockedGate: ServiceAsyncGate?
    private var shouldBlockNextMutation = false
    private var shouldBlockNextMutationBeforeLaunch = false
    private var launchedMutations: [Invocation] = []
    private var blockedLocalGate: ServiceAsyncGate?
    private var blockedLocalData: Data?
    private var shouldBlockNextLocal = false
    private var successfulLocalReadsBeforeBlock = 0

    init(catalog: Data, local: Data) {
        self.catalog = catalog
        self.local = local
    }

    var mutationArguments: [[String]] {
        invocations.compactMap { invocation in
            let arguments = invocation.command.arguments
            guard arguments.count > 1, arguments[0] == "models",
                  arguments[1] == "download" || arguments[1] == "remove" else { return nil }
            return arguments
        }
    }

    var sourceArguments: [[String]] {
        invocations.compactMap { invocation in
            let arguments = invocation.command.arguments
            guard Array(arguments.prefix(2)) == ["models", "catalog"]
                    || Array(arguments.prefix(2)) == ["models", "list"] else { return nil }
            return arguments
        }
    }

    var lifecycleInvocations: [Invocation] {
        invocations.filter { ["start", "stop", "restart"].contains($0.command.arguments.first ?? "") }
    }

    var mutationInvocations: [Invocation] {
        invocations.filter {
            let arguments = $0.command.arguments
            return arguments.count > 1 && arguments[0] == "models"
                && (arguments[1] == "download" || arguments[1] == "remove")
        }
    }

    var launchedMutationInvocations: [Invocation] { launchedMutations }

    func blockNextMutation() {
        blockedGate = ServiceAsyncGate()
        shouldBlockNextMutation = true
    }

    func blockNextMutationBeforeLaunch() {
        blockedGate = ServiceAsyncGate()
        shouldBlockNextMutationBeforeLaunch = true
    }

    func waitUntilBlocked() async {
        await blockedGate?.waitUntilStarted()
    }

    func releaseBlockedCommand() async {
        await blockedGate?.release()
    }

    func blockNextLocal(with data: Data) {
        blockLocal(afterSuccessfulReads: 0, with: data)
    }

    func blockLocal(afterSuccessfulReads: Int, with data: Data) {
        blockedLocalGate = ServiceAsyncGate()
        blockedLocalData = data
        shouldBlockNextLocal = true
        successfulLocalReadsBeforeBlock = afterSuccessfulReads
    }

    func waitUntilLocalBlocked() async {
        await blockedLocalGate?.waitUntilStarted()
    }

    func releaseBlockedLocal() async {
        await blockedLocalGate?.release()
    }

    func useLocalByDefault(_ data: Data) { local = data }

    func failNextCatalog() { nextCatalog = .failure }
    func failNextLocal() { nextLocal = .failure }
    func cancelNextCatalog() { nextCatalog = .cancellation }
    func useNextCatalog(_ data: Data) { nextCatalog = .data(data) }
    func useNextLocal(_ data: Data) { nextLocal = .data(data) }

    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult {
        try await run(
            command,
            timeout: timeout,
            outputLimit: outputLimit,
            onOutput: onOutput,
            onLaunch: nil
        )
    }

    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?,
        onLaunch: (@Sendable () -> Void)?
    ) async throws -> CommandResult {
        invocations.append(Invocation(command: command, timeout: timeout, outputLimit: outputLimit))
        let isModelMutation = command.arguments.count > 1
            && command.arguments[0] == "models"
            && (command.arguments[1] == "download" || command.arguments[1] == "remove")
        let isLifecycleMutation = ["start", "stop", "restart"].contains(
            command.arguments.first ?? ""
        )
        if (isModelMutation || isLifecycleMutation), shouldBlockNextMutationBeforeLaunch {
            shouldBlockNextMutationBeforeLaunch = false
            if let blockedGate {
                try await blockedGate.wait()
            }
        }
        onLaunch?()
        if isModelMutation || isLifecycleMutation {
            launchedMutations.append(
                Invocation(command: command, timeout: timeout, outputLimit: outputLimit)
            )
        }
        if (isModelMutation || isLifecycleMutation), shouldBlockNextMutation {
            shouldBlockNextMutation = false
            if let blockedGate {
                try await blockedGate.wait()
            }
        }
        if Array(command.arguments.prefix(2)) == ["models", "download"] {
            onOutput?(ProcessOutputChunk(
                destination: .standardOutput,
                data: Data("download 25%".utf8)
            ))
        }
        let output: Data
        switch Array(command.arguments.prefix(2)) {
        case ["models", "catalog"]:
            output = try consume(&nextCatalog, fallback: catalog)
        case ["models", "list"]:
            if shouldBlockNextLocal, successfulLocalReadsBeforeBlock == 0 {
                shouldBlockNextLocal = false
                if let blockedLocalGate {
                    try await blockedLocalGate.wait()
                }
                output = blockedLocalData ?? local
            } else {
                if shouldBlockNextLocal {
                    successfulLocalReadsBeforeBlock -= 1
                }
                output = try consume(&nextLocal, fallback: local)
            }
        default: output = Data()
        }
        return CommandResult(exitCode: 0, standardOutput: output, standardError: Data())
    }

    private func consume(_ response: inout Response?, fallback: Data) throws -> Data {
        let selected = response ?? .data(fallback)
        response = nil
        switch selected {
        case .data(let data): return data
        case .failure: throw ServiceFakeError.sourceFailed
        case .cancellation: throw CancellationError()
        }
    }
}

private enum ServiceFakeError: Error { case sourceFailed }

private actor ServiceAsyncGate {
    private var started = false
    private var released = false
    private var cancelled = false
    private var waitContinuation: CheckedContinuation<Void, any Error>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        started = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if released {
                    continuation.resume()
                } else {
                    waitContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        waitContinuation?.resume()
        waitContinuation = nil
    }

    private func cancel() {
        cancelled = true
        waitContinuation?.resume(throwing: CancellationError())
        waitContinuation = nil
    }
}

private final class ServiceOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = Data()

    var data: Data { lock.withLock { recorded } }

    func record(_ chunk: ProcessOutputChunk) {
        lock.withLock { recorded.append(chunk.data) }
    }
}

private actor ServicePhaseRecorder {
    private(set) var values: [ProviderMutationPhase] = []

    func record(_ phase: ProviderMutationPhase) {
        values.append(phase)
    }
}

private actor ServiceConfigStoreFake: ProviderConfigManaging {
    private var draft: ProviderConfigDraft
    private(set) var saveCount = 0
    private var blockedSaveGate: ServiceAsyncGate?

    init(
        selection: ProviderModelSelection,
        original: ProviderModelSelection? = nil,
        maxModelSlots: Int = 1
    ) {
        draft = ProviderConfigDraft(
            sourceRevision: "fixture",
            original: original ?? selection,
            selection: selection,
            originalMaxModelSlots: maxModelSlots,
            maxModelSlots: maxModelSlots
        )
    }

    func load() async throws -> ProviderConfigDraft { draft }

    func blockNextSave() { blockedSaveGate = ServiceAsyncGate() }
    func waitUntilSaveBlocked() async { await blockedSaveGate?.waitUntilStarted() }
    func releaseBlockedSave() async { await blockedSaveGate?.release() }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        saveCount += 1
        if let blockedSaveGate {
            try await blockedSaveGate.wait()
        }
        self.draft = ProviderConfigDraft(
            sourceRevision: "saved",
            original: draft.selection,
            selection: draft.selection,
            originalMaxModelSlots: draft.maxModelSlots,
            maxModelSlots: draft.maxModelSlots
        )
        return ProviderConfigSaveResult(draft: self.draft, restartRequired: true)
    }
}

private actor ServiceTelemetryFake: TelemetrySource {
    private var daemon: DaemonState
    private var loadedModels: LoadedModelsState
    private var daemonReadShouldFail = false
    private var loadedModelsReadShouldFail = false
    private var daemonReadShouldCancel = false
    private var loadedModelsReadShouldCancel = false

    init(daemon: DaemonState, loadedModels: LoadedModelsState) {
        self.daemon = daemon
        self.loadedModels = loadedModels
    }

    func failNextDaemonRead() { daemonReadShouldFail = true }
    func failNextLoadedModelsRead() { loadedModelsReadShouldFail = true }
    func cancelNextDaemonRead() { daemonReadShouldCancel = true }
    func cancelNextLoadedModelsRead() { loadedModelsReadShouldCancel = true }

    func setLoadedModels(_ models: [String]) {
        loadedModels = LoadedModelsState(
            schema: 1,
            models: models,
            updatedAt: serviceNow.timeIntervalSince1970
        )
    }

    func readDaemonState() async throws -> DaemonState {
        if daemonReadShouldCancel {
            daemonReadShouldCancel = false
            throw CancellationError()
        }
        if daemonReadShouldFail {
            daemonReadShouldFail = false
            throw ServiceFakeError.sourceFailed
        }
        return daemon
    }
    func readLoadedModels() async throws -> LoadedModelsState {
        if loadedModelsReadShouldCancel {
            loadedModelsReadShouldCancel = false
            throw CancellationError()
        }
        if loadedModelsReadShouldFail {
            loadedModelsReadShouldFail = false
            throw ServiceFakeError.sourceFailed
        }
        return loadedModels
    }
    func readStatus() async throws -> StatusSnapshot { StatusSnapshot() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { [] }
}

private actor ServiceEndpointDiscoveryFake: LocalEndpointDiscoveryReading {
    private(set) var readCount = 0

    func read(for provider: DaemonState) async throws -> LocalEndpointDiscovery {
        readCount += 1
        return LocalEndpointDiscovery(
            baseURL: URL(string: "http://127.0.0.1:8100/v1")!,
            apiKey: "fixture-secret",
            evidenceAt: serviceNow
        )
    }
}

private actor ServiceWarmupFake: ModelWarmupRequesting {
    nonisolated let loadSafety: ModelWarmupLoadSafety
    nonisolated let maxModelSlots: Int
    private(set) var requestedModels: [String] = []
    private(set) var retiredModels: [String] = []
    private(set) var events: [String] = []
    private var loadedModels: [String]
    private var loadResultModels: [String]?
    private var telemetry: ServiceTelemetryFake?
    private var failure: ModelWarmupClientError?
    private var busyRetirements: Set<String> = []
    private var retirementFailures: [String: ModelWarmupClientError] = [:]
    private let advertisedModels: [String]?
    private let launchModels: [String]?
    private let configuredMaxModelSlots: Int?
    private let configuredEnabledModels: [String]?
    private let configuredPreloadModels: [String]?

    init(
        loadSafety: ModelWarmupLoadSafety = .preservesResidents,
        maxModelSlots: Int = 2,
        loadedModels: [String] = [],
        advertisedModels: [String]? = nil,
        launchModels: [String]? = nil,
        configuredMaxModelSlots: Int? = nil,
        configuredEnabledModels: [String]? = nil,
        configuredPreloadModels: [String]? = nil
    ) {
        self.loadSafety = loadSafety
        self.maxModelSlots = maxModelSlots
        self.loadedModels = loadedModels
        self.advertisedModels = advertisedModels
        self.launchModels = launchModels
        self.configuredMaxModelSlots = configuredMaxModelSlots
        self.configuredEnabledModels = configuredEnabledModels
        self.configuredPreloadModels = configuredPreloadModels
    }

    func succeedAndLoad(_ models: [String], in telemetry: ServiceTelemetryFake) {
        loadResultModels = models
        self.telemetry = telemetry
        failure = nil
    }

    func failAfterLoading(
        _ error: ModelWarmupClientError,
        models: [String],
        in telemetry: ServiceTelemetryFake
    ) {
        loadResultModels = models
        self.telemetry = telemetry
        failure = error
    }

    func blockRetirement(of modelID: String) {
        busyRetirements.insert(modelID)
    }

    func failRetirement(of modelID: String, with error: ModelWarmupClientError) {
        retirementFailures[modelID] = error
    }

    func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelWarmupResponseUsage? {
        try await warm(modelID: modelID, using: discovery, onLaunch: nil)
    }

    func warm(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws -> ModelWarmupResponseUsage? {
        onLaunch?()
        requestedModels.append(modelID)
        events.append("load:\(modelID)")
        if let loadResultModels {
            loadedModels = loadResultModels
        }
        if let telemetry {
            await telemetry.setLoadedModels(loadedModels)
        }
        if let failure { throw failure }
        return ModelWarmupResponseUsage(promptTokens: 4, completionTokens: 1)
    }

    func controlSnapshot(
        using discovery: LocalEndpointDiscovery
    ) async throws -> ModelControlSnapshot? {
        guard loadSafety == .preservesResidents else { return nil }
        return ModelControlSnapshot(
            apiVersion: 1,
            protectedLoad: true,
            idleRetire: true,
            maxModelSlots: maxModelSlots,
            loadedModels: loadedModels,
            advertisedModels: advertisedModels,
            launchModels: launchModels,
            configuredMaxModelSlots: configuredMaxModelSlots,
            configuredEnabledModels: configuredEnabledModels,
            configuredPreloadModels: configuredPreloadModels
        )
    }

    func retire(
        modelID: String,
        using discovery: LocalEndpointDiscovery
    ) async throws {
        try await retire(modelID: modelID, using: discovery, onLaunch: nil)
    }

    func retire(
        modelID: String,
        using discovery: LocalEndpointDiscovery,
        onLaunch: ModelWarmupRequestLaunchObserver?
    ) async throws {
        onLaunch?()
        retiredModels.append(modelID)
        events.append("retire:\(modelID)")
        if busyRetirements.contains(modelID) {
            throw ModelWarmupClientError.busy
        }
        if let error = retirementFailures[modelID] {
            throw error
        }
        loadedModels.removeAll { $0 == modelID }
        if let telemetry {
            await telemetry.setLoadedModels(loadedModels)
        }
    }
}

private func daemon(
    currentModel: String,
    inferenceActive: Bool,
    startedAt: TimeInterval = 0,
    writtenAt: TimeInterval = serviceNow.timeIntervalSince1970,
    capacity: MemoryCapacity = MemoryCapacity(
        totalMemoryGB: 32,
        gpuMemoryActiveGB: 0,
        gpuMemoryCacheGB: 0
    )
) -> DaemonState {
    DaemonState(
        schema: 1,
        version: "0.8.15",
        currentModel: currentModel,
        warmModels: [],
        stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
        trust: TrustState(level: "local", status: "online", reason: "", receivedAt: 0),
        capacity: capacity,
        slots: [],
        inferenceActive: inferenceActive,
        startedAt: startedAt,
        writtenAt: writtenAt,
        pid: 1,
        processIdentity: ProcessIdentity(pid: 1, startTimeMicros: 1)
    )
}

private let catalogJSON = Data(#"""
[
  {"id":"gpt-oss-20b","display_name":"GPT OSS 20B","family":"gpt-oss","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true},
  {"id":"gemma-4-26b-qat-4bit","display_name":"Gemma 4 26B","family":"gemma-4","model_type":"llm","capabilities":["text"],"size_gb":15.2,"min_ram_gb":24,"active":true},
  {"id":"qwen3-8b","display_name":"Qwen3 8B","family":"qwen3","model_type":"llm","capabilities":["text"],"size_gb":5.0,"min_ram_gb":8,"active":true}
]
"""#.utf8)

private let localJSON = Data(#"""
{
  "cache_directory":"/inert/cache",
  "filtered_by_config":false,
  "models":[
    {"id":"gpt-oss-20b","model_type":"llm","size_bytes":13421772800,"estimated_memory_gb":15.0},
    {"id":"gemma-4-26b-qat-4bit","model_type":"llm","size_bytes":16320875724,"estimated_memory_gb":18.5}
  ]
}
"""#.utf8)

private let localGemmaOnlyJSON = Data(#"""
{
  "cache_directory":"/inert/cache",
  "filtered_by_config":false,
  "models":[
    {"id":"gemma-4-26b-qat-4bit","model_type":"llm","size_bytes":16320875724,"estimated_memory_gb":18.5}
  ]
}
"""#.utf8)

private let localWithQwenJSON = Data(#"""
{
  "cache_directory":"/inert/cache",
  "filtered_by_config":false,
  "models":[
    {"id":"gpt-oss-20b","model_type":"llm","size_bytes":13421772800,"estimated_memory_gb":15.0},
    {"id":"gemma-4-26b-qat-4bit","model_type":"llm","size_bytes":16320875724,"estimated_memory_gb":18.5},
    {"id":"qwen3-8b","model_type":"llm","size_bytes":5368709120,"estimated_memory_gb":7.0}
  ]
}
"""#.utf8)

private let catalogWithExtraModelJSON = Data(#"""
[
  {"id":"gpt-oss-20b","display_name":"GPT OSS 20B","family":"gpt-oss","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true},
  {"id":"gemma-4-26b-qat-4bit","display_name":"Gemma 4 26B","family":"gemma-4","model_type":"llm","capabilities":["text"],"size_gb":15.2,"min_ram_gb":24,"active":true},
  {"id":"qwen3-8b","display_name":"Qwen3 8B","family":"qwen3","model_type":"llm","capabilities":["text"],"size_gb":5.0,"min_ram_gb":8,"active":true},
  {"id":"llama-3-8b","display_name":"Llama 3 8B","family":"llama-3","model_type":"llm","capabilities":["text"],"size_gb":5.0,"min_ram_gb":8,"active":true}
]
"""#.utf8)

private let duplicateCatalogIDJSON = Data(#"""
[
  {"id":"gpt-oss-20b","display_name":"GPT OSS Primary","family":"gpt-oss","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true},
  {"id":"gpt-oss-20b","display_name":"GPT OSS Duplicate","family":"gpt-oss-duplicate","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true}
]
"""#.utf8)

private let ambiguousFamilyCatalogJSON = Data(#"""
[
  {"id":"gpt-oss-20b","display_name":"GPT OSS 20B","family":"gpt-oss","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true},
  {"id":"gpt-oss-120b","display_name":"GPT OSS 120B","family":"gpt-oss","model_type":"llm","capabilities":["text"],"size_gb":60.0,"min_ram_gb":64,"active":true}
]
"""#.utf8)

private let ambiguousFamilyLocalJSON = Data(#"""
{
  "cache_directory":"/inert/cache",
  "filtered_by_config":false,
  "models":[
    {"id":"gpt-oss-20b","model_type":"llm","size_bytes":13421772800,"estimated_memory_gb":15.0},
    {"id":"gpt-oss-120b","model_type":"llm","size_bytes":64424509440,"estimated_memory_gb":70.0}
  ]
}
"""#.utf8)
