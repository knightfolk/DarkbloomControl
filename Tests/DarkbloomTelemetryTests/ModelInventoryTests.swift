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

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
