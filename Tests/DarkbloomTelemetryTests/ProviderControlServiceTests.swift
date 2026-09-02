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
        #expect(unknownResidency.sources.loadedModels == .stale(
            "Loaded model state is stale"
        ))
        #expect(unknownResidency.inventory.issues.contains("Provider activity is unavailable"))
        #expect(unknownResidency.inventory.issues.contains("Loaded model state is stale"))
    }

    @Test("refresh preserves embedded residency evidence timestamps")
    func preservesResidencyEvidenceTimestamps() async throws {
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
        #expect(snapshot.sources.loadedModels == .fresh(evidenceAt: loadedEvidence))
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

    @Test("delete rejects stale and future residency timestamps")
    func deleteRequiresCurrentResidencyTimestamps() async throws {
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
            loadedModelsUpdatedAt: serviceNow.timeIntervalSince1970 - 10.001
        )
        defer { staleLoaded.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked(
            "Loaded model state is stale; deletion was not attempted"
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
            ["start", "--config", harness.configURL.path, "--model", "gemma-4-26b-qat-4bit", "--model", "gpt-oss"],
            ["stop"],
            ["restart", "--config", harness.configURL.path],
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
        ])
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
}

private final class ServiceHarness: @unchecked Sendable {
    let directory: URL
    let configURL: URL
    let executableURL: URL
    let runner: ServiceRunnerFake
    let telemetry: ServiceTelemetryFake
    let configStore: ServiceConfigStoreFake
    let service: ProviderControlService
    let now = serviceNow

    static func make(
        catalog: Data = catalogJSON,
        local: Data = localJSON,
        selection: ProviderModelSelection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit"],
            preloaded: []
        ),
        daemonState: DaemonState = daemon(currentModel: "", inferenceActive: false),
        loadedModels: [String] = ["gemma-4-26b-qat-4bit"],
        loadedModelsUpdatedAt: TimeInterval = serviceNow.timeIntervalSince1970
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
        let configStore = ServiceConfigStoreFake(selection: selection)
        let policy = DarkbloomSourcePolicy(homeDirectory: directory, environmentPath: directory.path)
        return ServiceHarness(
            directory: directory,
            configURL: configURL,
            executableURL: executableURL,
            runner: runner,
            telemetry: telemetry,
            configStore: configStore,
            policy: policy
        )
    }

    private init(
        directory: URL,
        configURL: URL,
        executableURL: URL,
        runner: ServiceRunnerFake,
        telemetry: ServiceTelemetryFake,
        configStore: ServiceConfigStoreFake,
        policy: DarkbloomSourcePolicy
    ) {
        self.directory = directory
        self.configURL = configURL
        self.executableURL = executableURL
        self.runner = runner
        self.telemetry = telemetry
        self.configStore = configStore
        service = ProviderControlService(
            policy: policy,
            telemetrySource: telemetry,
            configStore: configStore,
            runner: runner,
            now: { serviceNow }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ServiceRunnerFake: ProcessExecuting {
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

    func blockNextMutation() {
        blockedGate = ServiceAsyncGate()
        shouldBlockNextMutation = true
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
        invocations.append(Invocation(command: command, timeout: timeout, outputLimit: outputLimit))
        let isModelMutation = command.arguments.count > 1
            && command.arguments[0] == "models"
            && (command.arguments[1] == "download" || command.arguments[1] == "remove")
        let isLifecycleMutation = ["start", "stop", "restart"].contains(
            command.arguments.first ?? ""
        )
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

    init(selection: ProviderModelSelection) {
        draft = ProviderConfigDraft(sourceRevision: "fixture", original: selection, selection: selection)
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
            selection: draft.selection
        )
        return ProviderConfigSaveResult(draft: self.draft, restartRequired: true)
    }
}

private actor ServiceTelemetryFake: TelemetrySource {
    private let daemon: DaemonState
    private let loadedModels: LoadedModelsState
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

private func daemon(
    currentModel: String,
    inferenceActive: Bool,
    writtenAt: TimeInterval = serviceNow.timeIntervalSince1970
) -> DaemonState {
    DaemonState(
        schema: 1,
        version: "0.8.15",
        currentModel: currentModel,
        warmModels: [],
        stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
        trust: TrustState(level: "local", status: "online", reason: "", receivedAt: 0),
        capacity: MemoryCapacity(totalMemoryGB: 32, gpuMemoryActiveGB: 0, gpuMemoryCacheGB: 0),
        slots: [],
        inferenceActive: inferenceActive,
        startedAt: 0,
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
