import DarkbloomTelemetry
import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Model manager presentation")
@MainActor
struct ModelManagerPresentationTests {
    @Test("live switching is marked coming soon only when protected control is unavailable")
    func liveSwitchingAvailability() {
        #expect(ModelWarmupFeaturePresentation.make(
            supportsProtectedWarmup: false
        ) == ModelWarmupFeaturePresentation(
            isAvailable: false,
            badgeText: "Coming Soon",
            accessibilityHint: "Live model switching requires a future signed Darkbloom update."
        ))
        #expect(ModelWarmupFeaturePresentation.make(
            supportsProtectedWarmup: true
        ) == ModelWarmupFeaturePresentation(
            isAvailable: true,
            badgeText: nil,
            accessibilityHint: nil
        ))
    }

    @Test("capacity modes describe coordinator-visible one and two model limits honestly")
    func capacityModes() {
        #expect(ProviderCapacityMode(maxModelSlots: 1) == .memorySaver)
        #expect(ProviderCapacityMode(maxModelSlots: 2) == .twoModelCapacity)
        #expect(ProviderCapacityMode(maxModelSlots: 3) == nil)
        #expect(ProviderCapacityMode.memorySaver.detail.contains("unloads"))
        #expect(ProviderCapacityMode.twoModelCapacity.detail.contains("coordinator"))
        #expect(ProviderCapacityMode.twoModelCapacity.detail.contains("two"))
    }

    @Test("automatic switch cooldown timestamp round trips outside app memory")
    func persistsAutomaticSwitchAttempt() throws {
        let suiteName = "ModelWarmupPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let attemptedAt = Date(timeIntervalSince1970: 1_788_465_600.25)

        #expect(ModelWarmupPreferences.automaticSwitchLastAttemptAt(in: defaults) == nil)
        ModelWarmupPreferences.recordAutomaticSwitchAttempt(
            at: attemptedAt,
            in: defaults
        )

        #expect(
            ModelWarmupPreferences.automaticSwitchLastAttemptAt(in: defaults)
                == attemptedAt
        )
        defaults.set(Double.nan, forKey: ModelWarmupPreferences.automaticSwitchLastAttemptKey)
        #expect(ModelWarmupPreferences.automaticSwitchLastAttemptAt(in: defaults) == nil)
    }

    @Test("warmup presentation blocks unapplied slot settings before offering a switch")
    func warmupBlocksPendingRestart() throws {
        let fixture = try warmupFixture()

        #expect(ModelWarmupPresentation.blockReason(
            operation: .idle,
            draftHasChanges: false,
            restartRequired: true,
            pendingConfirmation: nil,
            item: fixture.item,
            snapshot: fixture.snapshot,
            currentTime: presentationNow,
            minimumHeadroomGB: 16,
            availableSystemMemoryGB: 64
        ) == "Restart the provider to apply saved model settings")
    }

    @Test("warmup presentation uses the same staging headroom gate as execution")
    func warmupBlocksInsufficientHeadroom() throws {
        let fixture = try warmupFixture(
            capacity: MemoryCapacity(
                totalMemoryGB: 32,
                gpuMemoryActiveGB: 10,
                gpuMemoryCacheGB: 5
            )
        )

        #expect(ModelWarmupPresentation.blockReason(
            operation: .idle,
            draftHasChanges: false,
            restartRequired: false,
            pendingConfirmation: nil,
            item: fixture.item,
            snapshot: fixture.snapshot,
            currentTime: presentationNow,
            minimumHeadroomGB: 16,
            availableSystemMemoryGB: 17
        ) == "Waiting for enough memory to stage this model without eviction")
    }

    @Test("warmup presentation blocks expired daemon evidence even when marked fresh")
    func warmupBlocksExpiredDaemonEvidence() throws {
        let fixture = try warmupFixture()
        let expired = presentationNow.addingTimeInterval(
            -(ProviderControlSourceState.maximumEvidenceAge + 1)
        )
        let snapshot = ProviderControlSnapshot(
            inventory: fixture.snapshot.inventory,
            draft: fixture.snapshot.draft,
            daemonState: fixture.snapshot.daemonState,
            supportsProtectedWarmup: fixture.snapshot.supportsProtectedWarmup,
            protectedWarmupMaxModelSlots: fixture.snapshot.protectedWarmupMaxModelSlots,
            residentModelIDs: fixture.snapshot.residentModelIDs,
            capturedAt: fixture.snapshot.capturedAt,
            sources: sources(
                daemon: .fresh(evidenceAt: expired)
            )
        )

        #expect(ModelWarmupPresentation.blockReason(
            operation: .idle,
            draftHasChanges: false,
            restartRequired: false,
            pendingConfirmation: nil,
            item: fixture.item,
            snapshot: snapshot,
            currentTime: presentationNow,
            minimumHeadroomGB: 16,
            availableSystemMemoryGB: 64
        ) == "Waiting for fresh provider and loaded-model state")
    }

    @Test("warmup presentation blocks expired loaded-model evidence even when marked fresh")
    func warmupBlocksExpiredLoadedModelEvidence() throws {
        let fixture = try warmupFixture()
        let expired = presentationNow.addingTimeInterval(
            -(ProviderControlSourceState.maximumEvidenceAge + 1)
        )
        let snapshot = ProviderControlSnapshot(
            inventory: fixture.snapshot.inventory,
            draft: fixture.snapshot.draft,
            daemonState: fixture.snapshot.daemonState,
            supportsProtectedWarmup: fixture.snapshot.supportsProtectedWarmup,
            protectedWarmupMaxModelSlots: fixture.snapshot.protectedWarmupMaxModelSlots,
            residentModelIDs: fixture.snapshot.residentModelIDs,
            capturedAt: fixture.snapshot.capturedAt,
            sources: sources(
                loadedModels: .fresh(evidenceAt: expired)
            )
        )

        #expect(ModelWarmupPresentation.blockReason(
            operation: .idle,
            draftHasChanges: false,
            restartRequired: false,
            pendingConfirmation: nil,
            item: fixture.item,
            snapshot: snapshot,
            currentTime: presentationNow,
            minimumHeadroomGB: 16,
            availableSystemMemoryGB: 64
        ) == "Waiting for fresh provider and loaded-model state")
    }

    @Test("warmup presentation blocks stale catalog and local-model evidence")
    func warmupBlocksStaleInventoryEvidence() throws {
        let fixture = try warmupFixture()
        for staleSources in [
            sources(catalog: .stale("Model catalog is stale")),
            sources(localModels: .stale("Local model list is stale")),
        ] {
            let snapshot = ProviderControlSnapshot(
                inventory: fixture.snapshot.inventory,
                draft: fixture.snapshot.draft,
                daemonState: fixture.snapshot.daemonState,
                supportsProtectedWarmup: fixture.snapshot.supportsProtectedWarmup,
                protectedWarmupMaxModelSlots: fixture.snapshot.protectedWarmupMaxModelSlots,
                residentModelIDs: fixture.snapshot.residentModelIDs,
                capturedAt: fixture.snapshot.capturedAt,
                sources: staleSources
            )

            #expect(ModelWarmupPresentation.blockReason(
                operation: .idle,
                draftHasChanges: false,
                restartRequired: false,
                pendingConfirmation: nil,
                item: fixture.item,
                snapshot: snapshot,
                currentTime: presentationNow,
                minimumHeadroomGB: 16,
                availableSystemMemoryGB: 64
            ) == "Waiting for fresh model catalog and local-model state")
        }
    }

    @Test("warmup presentation blocks while lifecycle confirmation is pending")
    func warmupBlocksPendingConfirmation() throws {
        let fixture = try warmupFixture()

        #expect(ModelWarmupPresentation.blockReason(
            operation: .idle,
            draftHasChanges: false,
            restartRequired: false,
            pendingConfirmation: .restart(.active),
            item: fixture.item,
            snapshot: fixture.snapshot,
            currentTime: presentationNow,
            minimumHeadroomGB: 16,
            availableSystemMemoryGB: 64
        ) == "Another provider action is awaiting confirmation")
    }

    @Test("download enable preload and delete stay independent")
    func separatesActions() {
        let row = ModelRowPresentation.make(
            item: item(isDownloaded: true),
            draft: draft(),
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        )

        #expect(row.showsDownload == false)
        #expect(row.showsEnableToggle)
        #expect(row.showsPreloadToggle)
        #expect(row.showsDelete)
        #expect(row.deleteBlockReason == nil)
        #expect(row.availableMetadataText == nil)
        #expect(row.enableAction?.accessibilityLabel == "Enable Model Name")
        #expect(row.preloadAction?.accessibilityLabel == "Preload Model Name")
        #expect(row.deleteAction?.accessibilityLabel == "Delete Model Name")
        var confirmationRequests = 0
        row.requestDeletion(of: item(isDownloaded: true)) { _ in
            confirmationRequests += 1
        }
        #expect(confirmationRequests == 1)
    }

    @Test("enable and preload presentation use their own configured selectors")
    func independentSelectorPresentation() throws {
        let catalog = [CatalogModel(
            id: "gpt-oss-20b",
            displayName: "GPT OSS 20B",
            family: "gpt-oss",
            modelType: "llm",
            capabilities: ["text"],
            sizeGB: 12,
            minimumRAMGB: 16,
            active: true
        )]
        let local = [LocalModel(
            id: "gpt-oss-20b",
            modelType: "llm",
            sizeBytes: 12_000_000_000,
            estimatedMemoryGB: nil
        )]

        for selection in [
            ProviderModelSelection(
                enabled: ["gpt-oss"],
                preloaded: ["gpt-oss-20b"]
            ),
            ProviderModelSelection(
                enabled: ["gpt-oss-20b"],
                preloaded: ["gpt-oss"]
            ),
        ] {
            let inventory = ModelInventoryBuilder.build(
                catalog: catalog,
                local: local,
                selection: selection,
                daemon: nil,
                loadedModels: []
            )
            let item = try #require(inventory.myCatalog.first)
            let draft = ProviderConfigDraft(
                sourceRevision: "fixture-revision",
                original: selection,
                selection: selection
            )
            let row = ModelRowPresentation.make(
                item: item,
                draft: draft,
                operation: .idle,
                sources: sources(),
                currentTime: presentationNow,
                canDownload: false,
                downloadUnavailableReason: nil,
                sanitize: { $0 }
            )

            #expect(row.enableAction?.accessibilityLabel == "Disable GPT OSS 20B")
            #expect(row.preloadAction?.accessibilityLabel == "Remove preload GPT OSS 20B")
        }
    }

    @Test("available models offer only download")
    func availableActions() {
        let row = ModelRowPresentation.make(
            item: item(isDownloaded: false),
            draft: draft(),
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: true,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        )

        #expect(row.showsDownload)
        #expect(row.showsEnableToggle == false)
        #expect(row.showsPreloadToggle == false)
        #expect(row.showsDelete == false)
        #expect(row.deleteBlockReason == nil)
        #expect(row.availableMetadataText == "LLM · Text · 4.5 GB · 8 GB minimum RAM")
        #expect(row.downloadAction?.isEnabled == true)
        #expect(row.downloadAction?.accessibilityLabel == "Download Model Name")
    }

    @Test("delete explains active and loaded blockers")
    func blocksLiveModels() {
        #expect(presentation(liveState: .active).deleteBlockReason == "Model is currently active")
        #expect(presentation(liveState: .loadedIdle).deleteBlockReason == "Model is currently loaded")
        #expect(presentation(liveState: .active).deleteAction?.accessibilityHint ==
            "Model is currently active")
        #expect(presentation(liveState: .active).deleteAction?.isEnabled == false)
    }

    @Test("delete checks saved enable and preload instead of staged state")
    func blocksSavedConfiguration() {
        let enabledDraft = draft(
            original: ProviderModelSelection(enabled: ["model-id"], preloaded: []),
            selection: ProviderModelSelection(enabled: [], preloaded: [])
        )
        let preloadedDraft = draft(
            original: ProviderModelSelection(
                enabled: ["model-id"],
                preloaded: ["model-id"]
            ),
            selection: ProviderModelSelection(enabled: [], preloaded: [])
        )

        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true, isEnabled: true),
            draft: enabledDraft,
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        ).deleteBlockReason == "Disable and save this model before deleting it")
        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true, isEnabled: true, isPreloaded: true),
            draft: preloadedDraft,
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        ).deleteBlockReason == "Remove preload and save before deleting this model")
    }

    @Test("delete explains unsaved ambiguous unavailable and operation blockers")
    func blocksUncertainDeletion() {
        let changedDraft = draft(
            original: ProviderModelSelection(enabled: [], preloaded: []),
            selection: ProviderModelSelection(enabled: ["other-model"], preloaded: [])
        )
        let ambiguity = "Configured selector 'shared-family' matches multiple catalog models"

        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true),
            draft: changedDraft,
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        ).deleteBlockReason == "Save or reload pending changes before deleting it")
        let ambiguousRow = ModelRowPresentation.make(
            item: item(isDownloaded: true, issue: ambiguity),
            draft: draft(),
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        )
        #expect(ambiguousRow.deleteBlockReason == ambiguity)
        #expect(ambiguousRow.enableAction?.accessibilityHint == ambiguity)
        #expect(ambiguousRow.preloadAction?.accessibilityHint == ambiguity)
        #expect(ambiguousRow.deleteAction?.accessibilityHint == ambiguity)
        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true),
            draft: nil,
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        ).deleteBlockReason == "Provider configuration is unavailable")
        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true),
            draft: draft(),
            operation: .refreshing,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        ).deleteBlockReason == "Another model action is in progress")
    }

    @Test("delete fails closed for every stale or unavailable inventory source")
    func blocksDeletionWithoutFreshInventory() {
        let store = ProviderControlStore(controller: DiagnosticOnlyProviderController())
        let cases: [(ProviderControlSourceStates, String)] = [
            (sources(catalog: .stale("Catalog credential token=catalog-secret")),
             "Catalog credential token=<redacted>; Reload the model catalog before deleting this model."),
            (sources(catalog: .unavailable("Catalog credential token=catalog-secret")),
             "Catalog credential token=<redacted>; Reload the model catalog before deleting this model."),
            (sources(localModels: .stale("Local credential token=local-secret")),
             "Local credential token=<redacted>; Reload local models before deleting this model."),
            (sources(localModels: .unavailable("Local credential token=local-secret")),
             "Local credential token=<redacted>; Reload local models before deleting this model."),
            (sources(daemon: .stale("Activity credential token=daemon-secret")),
             "Activity credential token=<redacted>; Refresh provider activity before deleting this model."),
            (sources(daemon: .unavailable("Activity credential token=daemon-secret")),
             "Activity credential token=<redacted>; Refresh provider activity before deleting this model."),
            (sources(loadedModels: .stale("Residency credential token=loaded-secret")),
             "Residency credential token=<redacted>; Refresh loaded model state before deleting this model."),
            (sources(loadedModels: .unavailable("Residency credential token=loaded-secret")),
             "Residency credential token=<redacted>; Refresh loaded model state before deleting this model."),
        ]

        for (sourceStates, expectedReason) in cases {
            let row = ModelRowPresentation.make(
                item: item(isDownloaded: true),
                draft: draft(),
                operation: .idle,
                sources: sourceStates,
                currentTime: presentationNow,
                canDownload: false,
                downloadUnavailableReason: nil,
                sanitize: store.sanitizedDiagnostic
            )

            #expect(row.deleteBlockReason == expectedReason)
            #expect(row.deleteAction?.isEnabled == false)
            #expect(row.deleteAction?.accessibilityHint == expectedReason)
            var confirmationRequests = 0
            row.requestDeletion(of: item(isDownloaded: true)) { _ in
                confirmationRequests += 1
            }
            #expect(confirmationRequests == 0)
        }
    }

    @Test("Settings does not manufacture stale model errors from an unchanged snapshot")
    func unchangedSnapshotDoesNotBecomeAFalseStaleError() {
        let evidenceAt = presentationNow.addingTimeInterval(-9)
        let sourceCases: [(ProviderControlSourceStates, String)] = [
            (
                sources(daemon: .fresh(evidenceAt: evidenceAt)),
                "Provider activity is stale; Refresh provider activity before deleting this model."
            ),
            (
                sources(loadedModels: .fresh(evidenceAt: evidenceAt)),
                "Loaded model state is stale; Refresh loaded model state before deleting this model."
            ),
        ]

        for (sourceStates, _) in sourceCases {
            let initial = ModelRowPresentation.make(
                item: item(isDownloaded: true),
                draft: draft(),
                operation: .idle,
                sources: sourceStates,
                currentTime: presentationNow,
                canDownload: false,
                downloadUnavailableReason: nil,
                sanitize: { $0 }
            )
            let boundary = ModelRowPresentation.make(
                item: item(isDownloaded: true),
                draft: draft(),
                operation: .idle,
                sources: sourceStates,
                currentTime: presentationNow.addingTimeInterval(1),
                canDownload: false,
                downloadUnavailableReason: nil,
                sanitize: { $0 }
            )
            let expired = ModelRowPresentation.make(
                item: item(isDownloaded: true),
                draft: draft(),
                operation: .idle,
                sources: sourceStates,
                currentTime: presentationNow.addingTimeInterval(1.001),
                canDownload: false,
                downloadUnavailableReason: nil,
                sanitize: { $0 }
            )

            #expect(initial.deleteAction?.isEnabled == true)
            #expect(boundary.deleteAction?.isEnabled == true)
            #expect(expired.deleteAction?.isEnabled == true)
            #expect(expired.deleteBlockReason == nil)
            var confirmationRequests = 0
            expired.requestDeletion(of: item(isDownloaded: true)) { _ in
                confirmationRequests += 1
            }
            #expect(confirmationRequests == 1)
        }
    }

    @Test("future and non-finite fresh evidence fail closed before delete confirmation")
    func invalidDeleteEvidenceFailsClosed() {
        let cases: [(ProviderControlSourceState, String)] = [
            (
                .fresh(evidenceAt: presentationNow.addingTimeInterval(0.001)),
                "Provider activity timestamp is in the future; Refresh provider activity before deleting this model."
            ),
            (
                .fresh(evidenceAt: Date(timeIntervalSince1970: .infinity)),
                "Provider activity timestamp is invalid; Refresh provider activity before deleting this model."
            ),
        ]

        for (daemonState, expectedReason) in cases {
            let row = ModelRowPresentation.make(
                item: item(isDownloaded: true),
                draft: draft(),
                operation: .idle,
                sources: sources(daemon: daemonState),
                currentTime: presentationNow,
                canDownload: false,
                downloadUnavailableReason: nil,
                sanitize: { $0 }
            )

            #expect(row.deleteAction?.isEnabled == false)
            #expect(row.deleteBlockReason == expectedReason)
            var confirmationRequests = 0
            row.requestDeletion(of: item(isDownloaded: true)) { _ in
                confirmationRequests += 1
            }
            #expect(confirmationRequests == 0)
        }
    }

    @Test("action accessibility labels follow the staged target state")
    func targetSpecificActionLabels() {
        let selected = draft(
            original: ProviderModelSelection(enabled: [], preloaded: []),
            selection: ProviderModelSelection(
                enabled: ["model-id"],
                preloaded: ["model-id"]
            )
        )
        let row = ModelRowPresentation.make(
            item: item(isDownloaded: true),
            draft: selected,
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        )

        #expect(row.enableAction?.accessibilityLabel == "Disable Model Name")
        #expect(row.preloadAction?.accessibilityLabel == "Remove preload Model Name")
        #expect(row.deleteAction?.accessibilityLabel == "Delete Model Name")
    }

    @Test("freshness disables download with an accessible reason")
    func freshnessGatesDownload() {
        let row = ModelRowPresentation.make(
            item: item(isDownloaded: false),
            draft: draft(),
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: "Refresh the model catalog before downloading",
            sanitize: { "sanitized: \($0)" }
        )

        #expect(row.downloadAction?.isEnabled == false)
        #expect(row.downloadAction?.accessibilityLabel == "Download Model Name")
        #expect(row.downloadAction?.accessibilityHint ==
            "sanitized: Refresh the model catalog before downloading")
    }

    @Test("cancel download names its target and explains its effect")
    func cancelDownloadAccessibility() {
        let row = ModelRowPresentation.make(
            item: item(isDownloaded: false),
            draft: draft(),
            operation: .downloading("model-id"),
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        )

        #expect(row.downloadAction?.isEnabled == true)
        #expect(row.downloadAction?.accessibilityLabel == "Cancel download Model Name")
        #expect(row.downloadAction?.accessibilityHint == "Stops the download for Model Name.")
    }

    @Test("post-download reconciliation no longer exposes a Cancel action")
    func reconciliationHidesDownloadCancellation() {
        let row = ModelRowPresentation.make(
            item: item(isDownloaded: false),
            draft: draft(),
            operation: .downloading("model-id"),
            mutationPhase: .reconciling,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        )

        #expect(row.downloadAction == nil)
    }

    @Test("credential-shaped unmatched selectors cross the store sanitizer")
    func sanitizesUnmatchedSelector() {
        let store = ProviderControlStore(
            controller: DiagnosticOnlyProviderController(),
            homeDirectory: URL(
                fileURLWithPath: "/Volumes/Network Homes/kevin",
                isDirectory: true
            )
        )
        let issue = "Configured selector 'access_token=selector-secret /Volumes/Network Homes/kevin/models' does not match a catalog model"

        let rendered = ModelManagerPresentation.diagnostic(
            issue,
            sanitize: store.sanitizedDiagnostic
        )

        #expect(rendered.contains("access_token=<redacted>"))
        #expect(rendered.contains("~/models"))
        #expect(!rendered.contains("selector-secret"))
        #expect(!rendered.contains("/Volumes/Network Homes/kevin"))
    }

    private func presentation(liveState: InventoryLiveState) -> ModelRowPresentation {
        ModelRowPresentation.make(
            item: item(isDownloaded: true, liveState: liveState),
            draft: draft(),
            operation: .idle,
            sources: sources(),
            currentTime: presentationNow,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: { $0 }
        )
    }

    private func item(
        isDownloaded: Bool,
        isEnabled: Bool = false,
        isPreloaded: Bool = false,
        liveState: InventoryLiveState = .unloaded,
        issue: String? = nil
    ) -> ModelInventoryItem {
        let configuredID = issue == nil ? "model-id" : "shared-family"
        let selection = ProviderModelSelection(
            enabled: isEnabled || issue != nil ? [configuredID] : [],
            preloaded: isPreloaded ? [configuredID] : []
        )
        var catalog = [CatalogModel(
            id: "model-id",
            displayName: "Model Name",
            family: issue == nil ? "model-family" : "shared-family",
            modelType: "llm",
            capabilities: ["text"],
            sizeGB: 4.5,
            minimumRAMGB: 8,
            active: true
        )]
        if issue != nil {
            catalog.append(CatalogModel(
                id: "other-model",
                displayName: "Other Model",
                family: "shared-family",
                modelType: "llm",
                capabilities: ["text"],
                sizeGB: 3,
                minimumRAMGB: 8,
                active: true
            ))
        }
        let inventory = ModelInventoryBuilder.build(
            catalog: catalog,
            local: isDownloaded
                ? [LocalModel(
                    id: "model-id",
                    modelType: "llm",
                    sizeBytes: 4_500_000_000,
                    estimatedMemoryGB: nil
                )]
                : [],
            selection: selection,
            daemon: daemon(for: liveState),
            loadedModels: liveState == .loadedIdle ? ["model-id"] : []
        )
        return (inventory.myCatalog + inventory.available).first {
            $0.catalogID == "model-id"
        }!
    }

    private func draft(
        original: ProviderModelSelection = ProviderModelSelection(enabled: [], preloaded: []),
        selection: ProviderModelSelection = ProviderModelSelection(enabled: [], preloaded: [])
    ) -> ProviderConfigDraft {
        ProviderConfigDraft(
            sourceRevision: "fixture-revision",
            original: original,
            selection: selection
        )
    }

    private func sources(
        catalog: ProviderControlSourceState = .fresh(evidenceAt: presentationNow),
        localModels: ProviderControlSourceState = .fresh(evidenceAt: presentationNow),
        daemon: ProviderControlSourceState = .fresh(evidenceAt: presentationNow),
        loadedModels: ProviderControlSourceState = .fresh(evidenceAt: presentationNow)
    ) -> ProviderControlSourceStates {
        ProviderControlSourceStates(
            catalog: catalog,
            localModels: localModels,
            daemon: daemon,
            loadedModels: loadedModels
        )
    }

    private func daemon(for liveState: InventoryLiveState) -> DaemonState? {
        guard liveState == .active else { return nil }
        return DaemonState(
            schema: 1,
            version: "fixture",
            currentModel: "model-id",
            warmModels: [],
            stats: ProviderStats(tokensGenerated: 0, requestsServed: 1, usageGaps: 0),
            trust: TrustState(level: "trusted", status: "online", reason: "", receivedAt: 1),
            capacity: MemoryCapacity(totalMemoryGB: 32, gpuMemoryActiveGB: 0, gpuMemoryCacheGB: 0),
            slots: [],
            inferenceActive: true,
            startedAt: 1,
            writtenAt: 1,
            pid: 1,
            processIdentity: ProcessIdentity(pid: 1, startTimeMicros: 1)
        )
    }

    private func warmupFixture(
        capacity: MemoryCapacity = MemoryCapacity(
            totalMemoryGB: 64,
            gpuMemoryActiveGB: 10,
            gpuMemoryCacheGB: 5
        )
    ) throws -> (item: ModelInventoryItem, snapshot: ProviderControlSnapshot) {
        let selection = ProviderModelSelection(
            enabled: ["model-id"],
            preloaded: []
        )
        let daemon = DaemonState(
            schema: 1,
            version: "fixture",
            currentModel: "resident-model",
            warmModels: ["resident-model"],
            stats: ProviderStats(tokensGenerated: 0, requestsServed: 1, usageGaps: 0),
            trust: TrustState(level: "trusted", status: "online", reason: "", receivedAt: 1),
            capacity: capacity,
            slots: [],
            inferenceActive: false,
            startedAt: 1,
            writtenAt: 1,
            pid: 1,
            processIdentity: ProcessIdentity(pid: 1, startTimeMicros: 1)
        )
        let inventory = ModelInventoryBuilder.build(
            catalog: [CatalogModel(
                id: "model-id",
                displayName: "Model Name",
                family: "model-family",
                modelType: "llm",
                capabilities: ["text"],
                sizeGB: 4.5,
                minimumRAMGB: 8,
                active: true
            )],
            local: [LocalModel(
                id: "model-id",
                modelType: "llm",
                sizeBytes: 4_500_000_000,
                estimatedMemoryGB: nil
            )],
            selection: selection,
            daemon: daemon,
            loadedModels: ["resident-model"]
        )
        let item = try #require(inventory.myCatalog.first)
        let draft = ProviderConfigDraft(
            sourceRevision: "fixture-revision",
            original: selection,
            selection: selection,
            originalMaxModelSlots: 2,
            maxModelSlots: 2
        )
        let snapshot = ProviderControlSnapshot(
            inventory: inventory,
            draft: draft,
            daemonState: daemon,
            supportsProtectedWarmup: true,
            protectedWarmupMaxModelSlots: 2,
            protectedWarmupLaunchModelIDs: ["model-id"],
            protectedWarmupConfiguredMaxModelSlots: 2,
            protectedWarmupConfiguredEnabledModels: ["model-id"],
            protectedWarmupConfiguredPreloadModels: [],
            residentModelIDs: ["resident-model"],
            capturedAt: presentationNow,
            sources: sources()
        )
        return (item, snapshot)
    }
}

private let presentationNow = Date(timeIntervalSince1970: 1_788_282_000)

private actor DiagnosticOnlyProviderController: ProviderControlling {
    func refresh() async throws -> ProviderControlSnapshot { throw DiagnosticOnlyError() }
    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        throw DiagnosticOnlyError()
    }
    func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {
        throw DiagnosticOnlyError()
    }
    func delete(_ localModelID: String) async throws { throw DiagnosticOnlyError() }
    func activityRisk() async -> ProviderActivityRisk { .unknown("unused") }
    func execute(
        _ action: ProviderLifecycleAction,
        enabledModels: [String]
    ) async throws {
        throw DiagnosticOnlyError()
    }
}

private struct DiagnosticOnlyError: Error {}
