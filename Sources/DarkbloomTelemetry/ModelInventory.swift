import Foundation

public struct CatalogModel: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let family: String
    public let modelType: String
    public let capabilities: [String]
    public let sizeGB: Double
    public let minimumRAMGB: Int
    public let active: Bool

    public init(id: String, displayName: String, family: String, modelType: String, capabilities: [String], sizeGB: Double, minimumRAMGB: Int, active: Bool) {
        self.id = id; self.displayName = displayName; self.family = family; self.modelType = modelType
        self.capabilities = capabilities; self.sizeGB = sizeGB; self.minimumRAMGB = minimumRAMGB; self.active = active
    }

    enum CodingKeys: String, CodingKey {
        case id, family, capabilities, active
        case displayName = "display_name"
        case modelType = "model_type"
        case sizeGB = "size_gb"
        case minimumRAMGB = "min_ram_gb"
    }
}

public struct LocalModel: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let modelType: String
    public let sizeBytes: Int64
    public let estimatedMemoryGB: Double?

    public init(id: String, modelType: String, sizeBytes: Int64, estimatedMemoryGB: Double?) {
        self.id = id; self.modelType = modelType; self.sizeBytes = sizeBytes; self.estimatedMemoryGB = estimatedMemoryGB
    }

    enum CodingKeys: String, CodingKey {
        case id
        case modelType = "model_type"
        case sizeBytes = "size_bytes"
        case estimatedMemoryGB = "estimated_memory_gb"
    }
}

public struct LocalModelList: Decodable, Equatable, Sendable {
    public let cacheDirectory: String
    public let filteredByConfig: Bool
    public let models: [LocalModel]

    enum CodingKeys: String, CodingKey {
        case cacheDirectory, filteredByConfig, models
    }

    enum LegacyCodingKeys: String, CodingKey {
        case cacheDirectory = "cache_directory"
        case filteredByConfig = "filtered_by_config"
    }

    public init(from decoder: Decoder) throws {
        let current = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        cacheDirectory = current.contains(.cacheDirectory)
            ? try current.decode(String.self, forKey: .cacheDirectory)
            : try legacy.decode(String.self, forKey: .cacheDirectory)
        filteredByConfig = current.contains(.filteredByConfig)
            ? try current.decode(Bool.self, forKey: .filteredByConfig)
            : try legacy.decode(Bool.self, forKey: .filteredByConfig)
        models = try current.decode([LocalModel].self, forKey: .models)
    }
}

public enum ModelCatalogDecoder {
    public static func decode(_ data: Data) throws -> [CatalogModel] {
        try JSONDecoder().decode([CatalogModel].self, from: data)
    }
}

public enum LocalModelListDecoder {
    public static func decode(_ data: Data) throws -> LocalModelList {
        try JSONDecoder().decode(LocalModelList.self, from: data)
    }
}

public struct ProviderModelSelection: Equatable, Sendable {
    public var enabled: [String]
    public var preloaded: [String]

    public init(enabled: [String], preloaded: [String]) {
        self.enabled = enabled; self.preloaded = preloaded
    }
}

public enum InventoryLiveState: Equatable, Sendable {
    case active
    case loadedIdle
    case unloaded
}

public struct ModelInventoryItem: Equatable, Identifiable, Sendable {
    public var id: String { catalogID }
    public let catalogID: String
    public let localID: String?
    /// Bytes reported by the local inventory, distinct from catalog size estimates.
    public let downloadedSizeBytes: Int64?
    /// The selector that enabled this catalog model, when one was configured.
    ///
    /// This is intentionally independent from `preloadSelector`: a provider
    /// configuration may use a family alias in one array and the exact
    /// catalog ID in the other. Keeping both values prevents the two controls
    /// from accidentally reading or writing the same selector.
    public let enabledSelector: String?
    /// The selector that preloaded this catalog model, when one was configured.
    public let preloadSelector: String?
    /// Backward-compatible view of the configured selector. New code should
    /// use `enabledSelector` or `preloadSelector` according to the control it
    /// is presenting.
    public var configuredSelector: String? {
        enabledSelector ?? preloadSelector
    }
    public let displayName: String
    public let modelType: String
    public let capabilities: [String]
    public let sizeGB: Double
    public let minimumRAMGB: Int
    public let isDownloaded: Bool
    public let isEnabled: Bool
    public let isPreloaded: Bool
    public let liveState: InventoryLiveState
    public let issue: String?

    public init(
        catalogID: String,
        localID: String?,
        configuredSelector: String? = nil,
        displayName: String,
        modelType: String,
        capabilities: [String],
        sizeGB: Double,
        minimumRAMGB: Int,
        isDownloaded: Bool,
        isEnabled: Bool,
        isPreloaded: Bool,
        liveState: InventoryLiveState,
        issue: String?,
        enabledSelector: String? = nil,
        preloadSelector: String? = nil,
        downloadedSizeBytes: Int64? = nil
    ) {
        self.catalogID = catalogID
        self.localID = localID
        self.downloadedSizeBytes = downloadedSizeBytes
        self.enabledSelector = enabledSelector
            ?? (isEnabled ? configuredSelector : nil)
        self.preloadSelector = preloadSelector
            ?? (isPreloaded ? configuredSelector : nil)
        self.displayName = displayName
        self.modelType = modelType
        self.capabilities = capabilities
        self.sizeGB = sizeGB
        self.minimumRAMGB = minimumRAMGB
        self.isDownloaded = isDownloaded
        self.isEnabled = isEnabled
        self.isPreloaded = isPreloaded
        self.liveState = liveState
        self.issue = issue
    }
}

public struct ModelInventory: Equatable, Sendable {
    public let myCatalog: [ModelInventoryItem]
    public let available: [ModelInventoryItem]
    public let issues: [String]
}

public enum ModelInventoryBuilder {
    public static func build(catalog: [CatalogModel], local: [LocalModel], selection: ProviderModelSelection, daemon: DaemonState?, loadedModels: [String]) -> ModelInventory {
        let localIDs = Set(local.map(\.id))
        var issues: [String] = []
        var itemIssues: [String: String] = [:]
        var resolvedEnabled: [String: String] = [:]
        var resolvedPreloaded: [String: String] = [:]

        func resolve(_ selectors: [String], into result: inout [String: String]) {
            // Resolve all exact IDs first so aliases cannot override them regardless
            // of the order in which selectors appeared in the TOML array.
            for selector in selectors {
                if let exact = catalog.first(where: { $0.id == selector }) {
                    result[exact.id] = selector
                }
            }
            for selector in selectors where catalog.allSatisfy({ $0.id != selector }) {
                let matches = catalog.filter { $0.family == selector }
                if matches.count == 1 {
                    if result[matches[0].id] == nil {
                        result[matches[0].id] = selector
                    }
                } else if matches.count > 1 {
                    let issue = "Configured selector '\(selector)' matches multiple catalog models"
                    issues.append(issue)
                    matches.forEach { itemIssues[$0.id] = issue }
                } else {
                    issues.append("Configured selector '\(selector)' does not match a catalog model")
                }
            }
        }
        resolve(selection.enabled, into: &resolvedEnabled)
        resolve(selection.preloaded, into: &resolvedPreloaded)

        var loaded = Set(loadedModels)
        if let daemon {
            loaded.formUnion(daemon.warmModels)
            loaded.formUnion(daemon.slots.map(\.model))
            if !daemon.currentModel.isEmpty { loaded.insert(daemon.currentModel) }
        }
        let activeID = daemon.flatMap { $0.inferenceActive ? $0.currentModel : nil }
        let localRecords = Dictionary(grouping: local, by: \.id)
        let items = catalog.map { model in
            let downloaded = localIDs.contains(model.id)
            let records = localRecords[model.id] ?? []
            let downloadedSize = records.count == 1 && records[0].sizeBytes >= 0
                ? records[0].sizeBytes : nil
            let live: InventoryLiveState = activeID == model.id ? .active : (loaded.contains(model.id) ? .loadedIdle : .unloaded)
            return ModelInventoryItem(
                catalogID: model.id, localID: downloaded ? model.id : nil,
                displayName: model.displayName, modelType: model.modelType,
                capabilities: model.capabilities,
                sizeGB: model.sizeGB, minimumRAMGB: model.minimumRAMGB,
                isDownloaded: downloaded, isEnabled: resolvedEnabled[model.id] != nil,
                isPreloaded: resolvedPreloaded[model.id] != nil, liveState: live, issue: itemIssues[model.id],
                enabledSelector: resolvedEnabled[model.id],
                preloadSelector: resolvedPreloaded[model.id],
                downloadedSizeBytes: downloadedSize
            )
        }
        let sorted = items.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedAscending || (comparison == .orderedSame && $0.catalogID < $1.catalogID)
        }
        return ModelInventory(myCatalog: sorted.filter(\.isDownloaded), available: sorted.filter { !$0.isDownloaded }, issues: issues)
    }
}
