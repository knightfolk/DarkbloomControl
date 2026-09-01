import DarkbloomTelemetry
import Testing
@testable import DarkbloomMonitor

@Suite("Model manager presentation")
struct ModelManagerPresentationTests {
    @Test("download enable preload and delete stay independent")
    func separatesActions() {
        let row = ModelRowPresentation.make(
            item: item(isDownloaded: true),
            draft: draft(),
            operation: .idle
        )

        #expect(row.showsDownload == false)
        #expect(row.showsEnableToggle)
        #expect(row.showsPreloadToggle)
        #expect(row.showsDelete)
        #expect(row.deleteBlockReason == nil)
    }

    @Test("available models offer only download")
    func availableActions() {
        let row = ModelRowPresentation.make(
            item: item(isDownloaded: false),
            draft: draft(),
            operation: .idle
        )

        #expect(row.showsDownload)
        #expect(row.showsEnableToggle == false)
        #expect(row.showsPreloadToggle == false)
        #expect(row.showsDelete == false)
        #expect(row.deleteBlockReason == nil)
    }

    @Test("delete explains active and loaded blockers")
    func blocksLiveModels() {
        #expect(presentation(liveState: .active).deleteBlockReason == "Model is currently active")
        #expect(presentation(liveState: .loadedIdle).deleteBlockReason == "Model is currently loaded")
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
            operation: .idle
        ).deleteBlockReason == "Disable and save this model before deleting it")
        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true, isEnabled: true, isPreloaded: true),
            draft: preloadedDraft,
            operation: .idle
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
            operation: .idle
        ).deleteBlockReason == "Save or reload pending changes before deleting it")
        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true, issue: ambiguity),
            draft: draft(),
            operation: .idle
        ).deleteBlockReason == ambiguity)
        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true),
            draft: nil,
            operation: .idle
        ).deleteBlockReason == "Provider configuration is unavailable")
        #expect(ModelRowPresentation.make(
            item: item(isDownloaded: true),
            draft: draft(),
            operation: .refreshing
        ).deleteBlockReason == "Another model action is in progress")
    }

    private func presentation(liveState: InventoryLiveState) -> ModelRowPresentation {
        ModelRowPresentation.make(
            item: item(isDownloaded: true, liveState: liveState),
            draft: draft(),
            operation: .idle
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
}
