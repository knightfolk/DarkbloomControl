import Foundation

public enum DaemonStateParser {
    public static func parse(_ data: Data) throws -> DaemonState {
        try SchemaValidation.requireSchema1(data, source: "daemon-state.json")
        let raw = try JSONDecoder().decode(RawDaemonState.self, from: data)
        return DaemonState(
            schema: raw.schema,
            version: raw.version,
            currentModel: raw.currentModel ?? "",
            warmModels: raw.warmModels,
            stats: .init(
                tokensGenerated: raw.stats.tokensGenerated,
                requestsServed: raw.stats.requestsServed,
                usageGaps: raw.stats.usageGaps
            ),
            trust: .init(
                level: raw.trust.level,
                status: raw.trust.status,
                reason: raw.trust.reason,
                receivedAt: raw.trust.receivedAt
            ),
            capacity: .init(
                totalMemoryGB: raw.capacity.totalMemoryGB,
                gpuMemoryActiveGB: raw.capacity.gpuMemoryActiveGB,
                gpuMemoryCacheGB: raw.capacity.gpuMemoryCacheGB
            ),
            slots: raw.slots.filter { $0.loadError == nil }.map {
                ModelSlot(
                    model: $0.model,
                    mtpEnabled: $0.mtpEnabled,
                    mtpActive: $0.mtpActive,
                    mtpReason: nil,
                    kvBackend: $0.kvBackend,
                    requestedKVBackend: $0.requestedKVBackend
                )
            },
            inferenceActive: raw.inferenceActive,
            startedAt: raw.startedAt,
            writtenAt: raw.writtenAt,
            pid: raw.pid,
            processIdentity: .init(
                pid: raw.processIdentity.pid,
                startTimeMicros: raw.processIdentity.startTimeMicros
            )
        )
    }
}

public enum LoadedModelsParser {
    public static func parse(_ data: Data) throws -> LoadedModelsState {
        try SchemaValidation.requireSchema1(data, source: "loaded-models.json")
        let raw = try JSONDecoder().decode(RawLoadedModels.self, from: data)
        return LoadedModelsState(schema: raw.schema, models: raw.models, updatedAt: raw.updatedAt)
    }
}

private struct SchemaEnvelope: Decodable {
    let schema: Int
}

private enum SchemaValidation {
    static func requireSchema1(_ data: Data, source: String) throws {
        let found = try JSONDecoder().decode(SchemaEnvelope.self, from: data).schema
        guard found == 1 else {
            throw TelemetryContractError.unsupportedSchema(
                source: source,
                found: found,
                supported: 1
            )
        }
    }
}

private struct RawDaemonState: Decodable {
    let schema: Int
    let stats: RawStats
    let version: String
    let currentModel: String?
    let trust: RawTrust
    let warmModels: [String]
    let pid: Int32
    let capacity: RawCapacity
    let slots: [RawSlot]
    let inferenceActive: Bool
    let startedAt: TimeInterval
    let writtenAt: TimeInterval
    let processIdentity: RawProcessIdentity

    enum CodingKeys: String, CodingKey {
        case schema, stats, version, trust, pid, capacity, slots
        case currentModel = "current_model"
        case warmModels = "warm_models"
        case inferenceActive = "inference_active"
        case startedAt = "started_at"
        case writtenAt = "written_at"
        case processIdentity = "process_identity"
    }
}

private struct RawStats: Decodable {
    let tokensGenerated: Int64
    let requestsServed: Int64
    let usageGaps: Int64

    enum CodingKeys: String, CodingKey {
        case tokensGenerated = "tokens_generated"
        case requestsServed = "requests_served"
        case usageGaps = "usage_gaps"
    }
}

private struct RawTrust: Decodable {
    let level: String
    let status: String
    let reason: String
    let receivedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case level = "trust_level"
        case status, reason
        case receivedAt = "received_at"
    }
}

private struct RawCapacity: Decodable {
    let totalMemoryGB: Double
    let gpuMemoryActiveGB: Double
    let gpuMemoryCacheGB: Double

    enum CodingKeys: String, CodingKey {
        case totalMemoryGB = "total_memory_gb"
        case gpuMemoryActiveGB = "gpu_memory_active_gb"
        case gpuMemoryCacheGB = "gpu_memory_cache_gb"
    }
}

private struct RawSlot: Decodable {
    let loadError: String?
    let model: String
    let mtpActive: Bool
    let kvBackend: String
    let requestedKVBackend: String
    let mtpEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case loadError = "load_error"
        case model
        case mtpActive = "mtp_active"
        case kvBackend = "kv_backend"
        case requestedKVBackend = "kv_backend_requested"
        case mtpEnabled = "mtp_enabled"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decode(String.self, forKey: .model)
        loadError = try values.decodeIfPresent(String.self, forKey: .loadError)
        mtpActive = try values.decode(Bool.self, forKey: .mtpActive)
        mtpEnabled = try values.decode(Bool.self, forKey: .mtpEnabled)
        requestedKVBackend = try values.decode(String.self, forKey: .requestedKVBackend)
        if loadError != nil {
            kvBackend = try values.decodeIfPresent(String.self, forKey: .kvBackend) ?? ""
        } else {
            kvBackend = try values.decode(String.self, forKey: .kvBackend)
        }
    }
}

private struct RawProcessIdentity: Decodable {
    let pid: Int32
    let startTimeMicros: Int64

    enum CodingKeys: String, CodingKey {
        case pid
        case startTimeMicros = "start_time_micros"
    }
}

private struct RawLoadedModels: Decodable {
    let models: [String]
    let schema: Int
    let updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case models, schema
        case updatedAt = "updated_at"
    }
}
