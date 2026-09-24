// Local-only native review. This actor never reads or changes provider files.
import SwiftUI
import DarkbloomTelemetry

private actor ModelsFixtureController: ProviderControlling {
    var selection = ProviderModelSelection(enabled: ["qwen", "gemma"], preloaded: [])
    var concurrent = 4
    var slots = 3
    var busy = true
    var stopped = false
    func refresh() async throws -> ProviderControlSnapshot {
        let now = Date()
        let catalog = [
            CatalogModel(id: "qwen", displayName: "Qwen 3.8 27B", family: "qwen", modelType: "text", capabilities: ["chat", "tools"], sizeGB: 16.3, minimumRAMGB: 36, active: true),
            CatalogModel(id: "gemma", displayName: "Gemma 4 26B", family: "gemma", modelType: "text", capabilities: ["chat"], sizeGB: 15.6, minimumRAMGB: 32, active: true),
            CatalogModel(id: "gpt", displayName: "GPT-OSS 20B", family: "gpt", modelType: "text", capabilities: ["chat"], sizeGB: 12.1, minimumRAMGB: 24, active: true),
            CatalogModel(id: "bonsai", displayName: "PrismML Bonsai 2 27B", family: "bonsai", modelType: "text", capabilities: ["chat"], sizeGB: 8.6, minimumRAMGB: 16, active: true)
        ]
        let local = catalog.prefix(3).map { LocalModel(id: $0.id, modelType: "text", sizeBytes: Int64($0.sizeGB * 1e9), estimatedMemoryGB: nil) }
        return ProviderControlSnapshot(inventory: ModelInventoryBuilder.build(catalog: catalog, local: local,
            selection: selection, daemon: nil, loadedModels: stopped ? [] : ["qwen", "gemma"]),
            draft: ProviderConfigDraft(sourceRevision: "synthetic", original: selection, selection: selection,
                originalMaxModelSlots: slots, maxModelSlots: slots,
                originalEngineV2MaxConcurrent: concurrent, engineV2MaxConcurrent: concurrent),
            capturedAt: now, sources: ProviderControlSourceStates(catalog: .fresh(evidenceAt: now), localModels: .fresh(evidenceAt: now), daemon: .fresh(evidenceAt: now), loadedModels: .fresh(evidenceAt: now)))
    }
    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        selection = draft.selection; concurrent = draft.engineV2MaxConcurrent ?? 4; slots = draft.maxModelSlots ?? 3
        return ProviderConfigSaveResult(draft: try await refresh().draft, restartRequired: true)
    }
    func download(_ modelID: String, onOutput: (@Sendable (ProcessOutputChunk) -> Void)?) async throws {}
    func delete(_ localModelID: String) async throws {}
    func activityRisk() async -> ProviderActivityRisk { busy ? .active : .idle }
    func execute(_ action: ProviderLifecycleAction, enabledModels: [String]) async throws { if action == .stop { stopped = true } }
    func finishWork() { busy = false }
}

@main struct ModelsFixture: App {
    private let controller: ModelsFixtureController
    @StateObject private var store: ProviderControlStore
    init() {
        let controller = ModelsFixtureController()
        self.controller = controller
        _store = StateObject(wrappedValue: ProviderControlStore(controller: controller))
    }
    var body: some Scene {
        WindowGroup("Models — Synthetic Review") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Synthetic review · no provider changes").font(.headline).padding(.horizontal, 24).padding(.top, 16)
                ModelManagerView(store: store)
                Button("Finish simulated work") { Task { await controller.finishWork() } }
                    .padding()
            }.frame(minWidth: 650, minHeight: 700).task { await store.refresh() }
        }
    }
}
