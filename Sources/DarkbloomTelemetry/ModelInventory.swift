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
    /// Provider features required by this catalog build. `nil` means the
    /// catalog source did not publish the field; an empty array means the
    /// source explicitly published no additional requirements.
    public let requiredProviderCapabilities: [String]?
    /// Weight quantization as published by the catalog (for example `fp4` or
    /// `2bit`). This is descriptive metadata, not proof of the local build.
    public let quantization: String?
    /// Architectural context limit published by the catalog, when available.
    public let maxContextLength: Int?
    /// Architectural output limit published by the catalog, when available.
    public let maxOutputLength: Int?

    public init(
        id: String,
        displayName: String,
        family: String,
        modelType: String,
        capabilities: [String],
        sizeGB: Double,
        minimumRAMGB: Int,
        active: Bool,
        requiredProviderCapabilities: [String]? = nil,
        quantization: String? = nil,
        maxContextLength: Int? = nil,
        maxOutputLength: Int? = nil
    ) {
        self.id = id; self.displayName = displayName; self.family = family; self.modelType = modelType
        self.capabilities = capabilities; self.sizeGB = sizeGB; self.minimumRAMGB = minimumRAMGB; self.active = active
        self.requiredProviderCapabilities = requiredProviderCapabilities
        self.quantization = quantization
        self.maxContextLength = maxContextLength
        self.maxOutputLength = maxOutputLength
    }

    enum CodingKeys: String, CodingKey {
        case id, family, capabilities, active
        case displayName = "display_name"
        case modelType = "model_type"
        case sizeGB = "size_gb"
        case minimumRAMGB = "min_ram_gb"
        case requiredProviderCapabilities = "required_provider_capabilities"
        case quantization
        case maxContextLength = "max_context_length"
        case maxOutputLength = "max_output_length"
    }
}

/// Bounds additive catalog metadata before it reaches model controls or text
/// rendering. Catalog data is remote input, so a malformed limit must not turn
/// into an unbounded UI value or an enormous requirement list.
enum CatalogModelMetadataValidation {
    static let maximumProviderCapabilityCount = 32
    static let maximumProviderCapabilityLength = 128
    static let maximumQuantizationLength = 64
    static let maximumTokenLimit = 10_000_000

    static func isValid(_ model: CatalogModel) -> Bool {
        guard let required = model.requiredProviderCapabilities else {
            return validQuantization(model.quantization)
                && validLimit(model.maxContextLength)
                && validLimit(model.maxOutputLength)
        }
        guard required.count <= maximumProviderCapabilityCount,
              Set(required).count == required.count,
              required.allSatisfy({ value in
                  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !trimmed.isEmpty && trimmed.utf8.count <= maximumProviderCapabilityLength
              }) else { return false }
        return validQuantization(model.quantization)
            && validLimit(model.maxContextLength)
            && validLimit(model.maxOutputLength)
    }

    private static func validQuantization(_ value: String?) -> Bool {
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= maximumQuantizationLength
    }

    private static func validLimit(_ value: Int?) -> Bool {
        guard let value else { return true }
        return (1...maximumTokenLimit).contains(value)
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
        let models = try JSONDecoder().decode([CatalogModel].self, from: data)
        guard models.count <= 128,
              models.allSatisfy(CatalogModelMetadataValidation.isValid) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Catalog model metadata is invalid"
            ))
        }
        return models
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
    public let requiredProviderCapabilities: [String]?
    public let quantization: String?
    public let maxContextLength: Int?
    public let maxOutputLength: Int?
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
        requiredProviderCapabilities: [String]? = nil,
        quantization: String? = nil,
        maxContextLength: Int? = nil,
        maxOutputLength: Int? = nil,
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
        self.requiredProviderCapabilities = requiredProviderCapabilities
        self.quantization = quantization
        self.maxContextLength = maxContextLength
        self.maxOutputLength = maxOutputLength
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
                requiredProviderCapabilities: model.requiredProviderCapabilities,
                quantization: model.quantization,
                maxContextLength: model.maxContextLength,
                maxOutputLength: model.maxOutputLength,
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
