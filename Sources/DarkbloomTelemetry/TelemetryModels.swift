import Foundation

public struct DaemonState: Equatable, Sendable {
    public let schema: Int
    public let version: String
    public let currentModel: String
    public let warmModels: [String]
    public let stats: ProviderStats
    public let trust: TrustState
    public let capacity: MemoryCapacity
    public let slots: [ModelSlot]
    public let inferenceActive: Bool
    public let startedAt: TimeInterval
    public let writtenAt: TimeInterval
    public let pid: Int32
    public let processIdentity: ProcessIdentity

    public init(
        schema: Int,
        version: String,
        currentModel: String,
        warmModels: [String],
        stats: ProviderStats,
        trust: TrustState,
        capacity: MemoryCapacity,
        slots: [ModelSlot],
        inferenceActive: Bool,
        startedAt: TimeInterval,
        writtenAt: TimeInterval,
        pid: Int32,
        processIdentity: ProcessIdentity
    ) {
        self.schema = schema
        self.version = version
        self.currentModel = currentModel
        self.warmModels = warmModels
        self.stats = stats
        self.trust = trust
        self.capacity = capacity
        self.slots = slots
        self.inferenceActive = inferenceActive
        self.startedAt = startedAt
        self.writtenAt = writtenAt
        self.pid = pid
        self.processIdentity = processIdentity
    }
}

public struct ProviderStats: Equatable, Sendable {
    public let tokensGenerated: Int64
    public let requestsServed: Int64
    public let usageGaps: Int64

    public init(tokensGenerated: Int64, requestsServed: Int64, usageGaps: Int64) {
        self.tokensGenerated = tokensGenerated
        self.requestsServed = requestsServed
        self.usageGaps = usageGaps
    }
}

public struct TrustState: Equatable, Sendable {
    public let level: String
    public let status: String
    public let reason: String
    public let receivedAt: TimeInterval

    public init(level: String, status: String, reason: String, receivedAt: TimeInterval) {
        self.level = level
        self.status = status
        self.reason = reason
        self.receivedAt = receivedAt
    }
}

public struct MemoryCapacity: Equatable, Sendable {
    public let totalMemoryGB: Double
    public let gpuMemoryActiveGB: Double
    public let gpuMemoryCacheGB: Double

    public init(totalMemoryGB: Double, gpuMemoryActiveGB: Double, gpuMemoryCacheGB: Double) {
        self.totalMemoryGB = totalMemoryGB
        self.gpuMemoryActiveGB = gpuMemoryActiveGB
        self.gpuMemoryCacheGB = gpuMemoryCacheGB
    }
}

public struct ModelSlot: Equatable, Sendable {
    public let model: String
    public let mtpEnabled: Bool
    public let mtpActive: Bool
    public let mtpReason: String?
    public let kvBackend: String
    public let requestedKVBackend: String

    public init(
        model: String,
        mtpEnabled: Bool,
        mtpActive: Bool,
        mtpReason: String?,
        kvBackend: String,
        requestedKVBackend: String
    ) {
        self.model = model
        self.mtpEnabled = mtpEnabled
        self.mtpActive = mtpActive
        self.mtpReason = mtpReason
        self.kvBackend = kvBackend
        self.requestedKVBackend = requestedKVBackend
    }
}

public struct ProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let startTimeMicros: Int64

    public init(pid: Int32, startTimeMicros: Int64) {
        self.pid = pid
        self.startTimeMicros = startTimeMicros
    }
}

public struct LoadedModelsState: Equatable, Sendable {
    public let schema: Int
    public let models: [String]
    public let updatedAt: TimeInterval

    public init(schema: Int, models: [String], updatedAt: TimeInterval) {
        self.schema = schema
        self.models = models
        self.updatedAt = updatedAt
    }
}

public enum TokenRate: Equatable, Sendable {
    case available(tokensPerSecond: Double, label: String)
    case unavailable(reason: String)
}

public struct StatusSnapshot: Equatable, Sendable {
    public var version: String?
    public var providerName: String?
    public var configPath: String?
    public var coordinator: String?
    public var backendPort: Int?
    public var configuredModel: String?
    public var idleTimeout: String?
    public var betaFeatures: String?
    public var autoRestart: String?
    public var hardware: String?
    public var inferenceMemory: String?
    public var bootChecks: String?
    public var schedule: String?
    public var enabledModelFilter: String?
    public var localModelCount: Int?
    public var daemon: String?
    public var trust: String?
    public var trustReason: String?
    public var warmModels: [String] = []
    public var mostRecentlyUsed: String?
    public var requestCount: Int64?
    public var tokenCount: Int64?
    public var stateAge: String?
    public var slotPosture: [String] = []

    public init() {}
}

public enum LogSeverity: String, Equatable, Sendable {
    case info
    case notice
    case warning
    case error
}

public struct LogEvent: Equatable, Sendable {
    public let timestamp: Date?
    public let severity: LogSeverity
    public let category: String
    public let message: String

    public init(timestamp: Date?, severity: LogSeverity, category: String, message: String) {
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.message = message
    }
}
