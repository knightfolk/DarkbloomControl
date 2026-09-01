import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Model inventory")
struct ModelInventoryTests {
    @Test("decodes catalog and local model JSON")
    func decodesSources() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json"))
        let local = try LocalModelListDecoder.decode(fixture("local-models.json"))
        #expect(catalog.map(\.id) == ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
        #expect(local.models.map(\.id) == ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
        #expect(catalog[0].displayName == "GPT OSS 20B")
        #expect(local.models[0].sizeBytes == 13_421_772_800)
    }

    @Test("matches a unique configured family alias without rewriting it")
    func matchesFamilyAlias() throws {
        let inventory = ModelInventoryBuilder.build(
            catalog: try ModelCatalogDecoder.decode(fixture("model-catalog.json")),
            local: try LocalModelListDecoder.decode(fixture("local-models.json")).models,
            selection: ProviderModelSelection(enabled: ["gpt-oss"], preloaded: []),
            daemon: nil,
            loadedModels: []
        )
        let item = try #require(inventory.myCatalog.first { $0.catalogID == "gpt-oss-20b" })
        #expect(item.configuredSelector == "gpt-oss")
        #expect(item.isEnabled)
    }

    @Test("keeps download enable preload and live states independent")
    func separatesStates() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json"))
        let local = try LocalModelListDecoder.decode(fixture("local-models.json")).models
        let inventory = ModelInventoryBuilder.build(
            catalog: catalog,
            local: local,
            selection: ProviderModelSelection(enabled: ["gpt-oss-20b"], preloaded: ["gemma-4-26b-qat-4bit"]),
            daemon: nil,
            loadedModels: ["gemma-4-26b-qat-4bit"]
        )
        let downloadedButDisabled = try #require(inventory.myCatalog.first { $0.catalogID == "gemma-4-26b-qat-4bit" })
        let enabledButUnloaded = try #require(inventory.myCatalog.first { $0.catalogID == "gpt-oss-20b" })
        #expect(downloadedButDisabled.isDownloaded && !downloadedButDisabled.isEnabled)
        #expect(enabledButUnloaded.isEnabled && enabledButUnloaded.liveState == .unloaded)
        #expect(downloadedButDisabled.isPreloaded && downloadedButDisabled.liveState == .loadedIdle)
        #expect(inventory.available.isEmpty)
    }

    @Test("marks active loaded models and leaves unavailable models unloaded")
    func derivesLiveStates() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json"))
        let local = try LocalModelListDecoder.decode(fixture("local-models.json")).models
        let daemon = DaemonState(
            schema: 1, version: "0.8.15", currentModel: "gpt-oss-20b", warmModels: ["gpt-oss-20b"],
            stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
            trust: TrustState(level: "local", status: "online", reason: "", receivedAt: 0),
            capacity: MemoryCapacity(totalMemoryGB: 32, gpuMemoryActiveGB: 0, gpuMemoryCacheGB: 0),
            slots: [], inferenceActive: true, startedAt: 0, writtenAt: 0, pid: 1,
            processIdentity: ProcessIdentity(pid: 1, startTimeMicros: 1)
        )
        let inventory = ModelInventoryBuilder.build(
            catalog: catalog, local: local,
            selection: ProviderModelSelection(enabled: [], preloaded: []),
            daemon: daemon, loadedModels: ["gpt-oss-20b"]
        )
        #expect(inventory.myCatalog.first { $0.catalogID == "gpt-oss-20b" }?.liveState == .active)
    }

    @Test("reports ambiguous selectors without guessing")
    func reportsAmbiguity() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json")) + [
            CatalogModel(id: "shared-a", displayName: "Shared A", family: "shared-family", modelType: "llm", capabilities: [], sizeGB: 1, minimumRAMGB: 2, active: true),
            CatalogModel(id: "shared-b", displayName: "Shared B", family: "shared-family", modelType: "llm", capabilities: [], sizeGB: 1, minimumRAMGB: 2, active: true)
        ]
        let inventory = ModelInventoryBuilder.build(
            catalog: catalog, local: [],
            selection: ProviderModelSelection(enabled: ["shared-family"], preloaded: []),
            daemon: nil, loadedModels: []
        )
        #expect(inventory.issues.contains("Configured selector 'shared-family' matches multiple catalog models"))
        #expect(inventory.myCatalog.isEmpty)
    }

    @Test("available contains only models that are not downloaded and sorts by display name")
    func availableAndSorting() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json"))
        let inventory = ModelInventoryBuilder.build(
            catalog: catalog, local: [LocalModel(id: "gpt-oss-20b", modelType: "llm", sizeBytes: 1, estimatedMemoryGB: nil)],
            selection: ProviderModelSelection(enabled: [], preloaded: []), daemon: nil, loadedModels: []
        )
        #expect(inventory.available.allSatisfy { !$0.isDownloaded })
        #expect(inventory.available.map(\.displayName) == ["Gemma 4 26B"])
    }

    @Test("exact configured IDs win over family aliases in either input order")
    func exactSelectorPrecedence() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json"))
        for enabled in [["gpt-oss-20b", "gpt-oss"], ["gpt-oss", "gpt-oss-20b"]] {
            let inventory = ModelInventoryBuilder.build(catalog: catalog, local: [], selection: ProviderModelSelection(enabled: enabled, preloaded: []), daemon: nil, loadedModels: [])
            #expect(inventory.available.first { $0.catalogID == "gpt-oss-20b" }?.configuredSelector == "gpt-oss-20b")
        }
    }

    @Test("idle current model is loaded-idle from daemon telemetry")
    func idleCurrentModelIsResident() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json"))
        let daemon = daemon(currentModel: "gpt-oss-20b", warmModels: [], slots: [], inferenceActive: false)
        let inventory = ModelInventoryBuilder.build(catalog: catalog, local: [], selection: ProviderModelSelection(enabled: [], preloaded: []), daemon: daemon, loadedModels: [])
        #expect(inventory.available.first { $0.catalogID == "gpt-oss-20b" }?.liveState == .loadedIdle)
    }

    @Test("warm and slot-only daemon models are loaded-idle")
    func warmAndSlotModelsAreResident() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json"))
        let daemon = daemon(currentModel: "", warmModels: ["gpt-oss-20b"], slots: [ModelSlot(model: "gemma-4-26b-qat-4bit", mtpEnabled: false, mtpActive: false, mtpReason: nil, kvBackend: "", requestedKVBackend: "")], inferenceActive: false)
        let inventory = ModelInventoryBuilder.build(catalog: catalog, local: [], selection: ProviderModelSelection(enabled: [], preloaded: []), daemon: daemon, loadedModels: [])
        #expect(inventory.available.allSatisfy { $0.liveState == .loadedIdle })
    }

    @Test("equal display names sort by catalog ID")
    func equalNameTieBreak() {
        let catalog = [
            CatalogModel(id: "z-model", displayName: "Same", family: "z", modelType: "llm", capabilities: [], sizeGB: 1, minimumRAMGB: 1, active: true),
            CatalogModel(id: "a-model", displayName: "Same", family: "a", modelType: "llm", capabilities: [], sizeGB: 1, minimumRAMGB: 1, active: true)
        ]
        let inventory = ModelInventoryBuilder.build(catalog: catalog, local: [], selection: ProviderModelSelection(enabled: [], preloaded: []), daemon: nil, loadedModels: [])
        #expect(inventory.available.map(\.catalogID) == ["a-model", "z-model"])
    }

    @Test("unmatched selectors are reported as issues")
    func unmatchedSelectorIssue() {
        let inventory = ModelInventoryBuilder.build(catalog: [], local: [], selection: ProviderModelSelection(enabled: ["missing"], preloaded: []), daemon: nil, loadedModels: [])
        #expect(inventory.issues == ["Configured selector 'missing' does not match a catalog model"])
    }

    @Test("ambiguous selector attaches the issue to every matching row")
    func ambiguousSelectorRows() {
        let catalog = [
            CatalogModel(id: "one", displayName: "One", family: "shared", modelType: "llm", capabilities: [], sizeGB: 1, minimumRAMGB: 1, active: true),
            CatalogModel(id: "two", displayName: "Two", family: "shared", modelType: "llm", capabilities: [], sizeGB: 1, minimumRAMGB: 1, active: true)
        ]
        let inventory = ModelInventoryBuilder.build(catalog: catalog, local: [], selection: ProviderModelSelection(enabled: ["shared"], preloaded: []), daemon: nil, loadedModels: [])
        let rows = inventory.available.filter { $0.issue != nil }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.issue == "Configured selector 'shared' matches multiple catalog models" })
        #expect(rows.allSatisfy { $0.configuredSelector == nil && !$0.isEnabled })
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func daemon(currentModel: String, warmModels: [String], slots: [ModelSlot], inferenceActive: Bool) -> DaemonState {
        DaemonState(schema: 1, version: "0.8.15", currentModel: currentModel, warmModels: warmModels,
                    stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
                    trust: TrustState(level: "local", status: "online", reason: "", receivedAt: 0),
                    capacity: MemoryCapacity(totalMemoryGB: 32, gpuMemoryActiveGB: 0, gpuMemoryCacheGB: 0), slots: slots,
                    inferenceActive: inferenceActive, startedAt: 0, writtenAt: 0, pid: 1,
                    processIdentity: ProcessIdentity(pid: 1, startTimeMicros: 1))
    }
}
