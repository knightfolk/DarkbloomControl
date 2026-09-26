import DarkbloomTelemetry
import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Model grouping")
@MainActor
struct ModelGroupingTests {
    @Test("catalog partitions into enabled and available with no third section")
    func partitionsCatalog() {
        let enabledModel = item("vendor/enabled", downloaded: true)
        let disabledModel = item("vendor/disabled", downloaded: true)
        let undownloadedA = item("vendor/undownloaded-a", downloaded: false)
        let undownloadedB = item("vendor/undownloaded-b", downloaded: false)
        let staged: Set<String> = ["vendor/enabled"]

        let grouping = ModelGrouping.partition(
            myCatalog: [enabledModel, disabledModel],
            available: [undownloadedA, undownloadedB],
            search: "",
            isEnabled: { staged.contains($0.catalogID) }
        )

        #expect(grouping.enabled.map(\.catalogID) == ["vendor/enabled"])
        // Downloaded-but-disabled and undownloaded models share Available;
        // there is no separate not-downloaded group.
        #expect(grouping.available.map(\.catalogID) == ["vendor/disabled", "vendor/undownloaded-a", "vendor/undownloaded-b"])
        #expect(!grouping.isEmpty)
    }

    @Test("unsaved staged enable changes move cards between groups immediately")
    func stagedDraftMovesCards() {
        let downloaded = item("vendor/model", downloaded: true)
        var staged: Set<String> = []

        var grouping = ModelGrouping.partition(
            myCatalog: [downloaded], available: [], search: "",
            isEnabled: { staged.contains($0.catalogID) }
        )
        #expect(grouping.enabled.isEmpty)
        #expect(grouping.available.map(\.catalogID) == ["vendor/model"])

        staged.insert("vendor/model")
        grouping = ModelGrouping.partition(
            myCatalog: [downloaded], available: [], search: "",
            isEnabled: { staged.contains($0.catalogID) }
        )
        #expect(grouping.enabled.map(\.catalogID) == ["vendor/model"])
        #expect(grouping.available.isEmpty)
    }

    @Test("an undownloaded model staged enabled stays honest in Enabled")
    func undownloadedStagedEnabled() {
        let undownloaded = item("vendor/remote", downloaded: false)

        let grouping = ModelGrouping.partition(
            myCatalog: [], available: [undownloaded], search: "",
            isEnabled: { $0.catalogID == "vendor/remote" }
        )

        #expect(grouping.enabled.map(\.catalogID) == ["vendor/remote"])
        #expect(grouping.available.isEmpty)
    }

    @Test("search applies to both groups by name and canonical id")
    func searchFiltersBothGroups() {
        let enabledQwen = item("qwen/qwen3.8", name: "Qwen 3.8", downloaded: true)
        let enabledGemma = item("google/gemma-4", name: "Gemma 4", downloaded: true)
        let availableNemotron = item("nvidia/nemotron-9", name: "Nemotron 9", downloaded: false)

        func partition(_ search: String) -> ModelGrouping {
            ModelGrouping.partition(
                myCatalog: [enabledQwen, enabledGemma],
                available: [availableNemotron],
                search: search,
                isEnabled: { $0.catalogID != "nvidia/nemotron-9" }
            )
        }

        let byName = partition("qwen")
        #expect(byName.enabled.map(\.catalogID) == ["qwen/qwen3.8"])
        #expect(byName.available.isEmpty)

        let byID = partition("nemotron-9")
        #expect(byID.enabled.isEmpty)
        #expect(byID.available.map(\.catalogID) == ["nvidia/nemotron-9"])

        #expect(partition("no-such-model").isEmpty)
    }

    @Test("duplicate catalog ids render once")
    func deduplicatesCatalogEntries() {
        let first = item("vendor/model", name: "First", downloaded: true)
        let duplicate = item("vendor/model", name: "Duplicate", downloaded: false)

        let grouping = ModelGrouping.partition(
            myCatalog: [first], available: [duplicate], search: "",
            isEnabled: { _ in false }
        )

        #expect(grouping.available.map(\.catalogID) == ["vendor/model"])
        #expect(grouping.available.count == 1)
    }

    @Test("available lists downloaded models before undownloaded models")
    func availableOrdersDownloadedFirst() {
        let undownloadedA = item("vendor/aaa-undownloaded", downloaded: false)
        let downloaded = item("vendor/zzz-downloaded", downloaded: true)
        let undownloadedB = item("vendor/bbb-undownloaded", downloaded: false)

        let grouping = ModelGrouping.partition(
            myCatalog: [downloaded],
            available: [undownloadedA, undownloadedB],
            search: "",
            isEnabled: { _ in false }
        )

        #expect(grouping.available.map(\.catalogID) == ["vendor/zzz-downloaded", "vendor/aaa-undownloaded", "vendor/bbb-undownloaded"])
    }

    @Test("group collapse persists through app-scoped defaults keys")
    func collapsePersistenceKeys() {
        let modelScopes: [ModelGroupScope] = [.enabled, .available]
        #expect(ModelGroupScope.allCases.count == 3)
        #expect(ModelGroupScope.enabled.defaultsKey == "models.group-collapse.v2.enabled")
        #expect(ModelGroupScope.available.defaultsKey == "models.group-collapse.v2.available")
        #expect(ModelGroupScope.capacity.defaultsKey == "models.group-collapse.v2.capacity")
        #expect(Set(modelScopes.map(\.defaultsKey)).count == modelScopes.count)
    }

    @Test("what-if runtime restore sanitizes stored values")
    func runtimeRestoreSanitizes() {
        #expect(ModelManagerView.decodeRuntime("") == [:])
        #expect(ModelManagerView.decodeRuntime("not json") == [:])

        let valid = #"{"vendor\/model":50,"vendor\/other":100}"#
        #expect(ModelManagerView.decodeRuntime(valid) == ["vendor/model": 50, "vendor/other": 100])

        let outOfRange = #"{"negative":-1,"too-big":101,"zero":0,"hundred":100}"#
        #expect(ModelManagerView.decodeRuntime(outOfRange) == ["zero": 0, "hundred": 100])

        let longKey = String(repeating: "a", count: 513)
        let invalidIDs = "{\"\":30,\"\(longKey)\":40,\"ok\":20}"
        #expect(ModelManagerView.decodeRuntime(invalidIDs) == ["ok": 20])

        var many = "{"
        for index in 0..<200 { many += index == 0 ? "" : ","; many += "\"id-\(index)\":10" }
        many += "}"
        #expect(ModelManagerView.decodeRuntime(many).count == 128)
    }

    private func item(
        _ id: String,
        name: String? = nil,
        downloaded: Bool
    ) -> ModelInventoryItem {
        ModelInventoryItem(
            catalogID: id,
            localID: downloaded ? id : nil,
            displayName: name ?? id,
            modelType: "llm",
            capabilities: ["chat"],
            sizeGB: 4.5,
            minimumRAMGB: 8,
            isDownloaded: downloaded,
            isEnabled: false,
            isPreloaded: false,
            liveState: .unloaded,
            issue: nil
        )
    }
}
