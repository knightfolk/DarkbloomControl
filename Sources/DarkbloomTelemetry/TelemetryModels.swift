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
    /// The daemon's post-filter serving set. This is deliberately distinct
    /// from the saved model selection and from `warmModels` (resident models).
    public let advertisedModels: [String]?
    /// The coordinator associated with this state snapshot. It is used only
    /// to correlate a trust observation with the selected configuration.
    public let coordinatorURL: String?
    /// Load failures are retained as bounded codes; provider error prose is
    /// never exposed by the telemetry model.
    public let modelLoadFailures: [ModelLoadFailure]

    public var loadFailures: [ModelLoadFailure] { modelLoadFailures }

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
        processIdentity: ProcessIdentity,
        advertisedModels: [String]? = nil,
        coordinatorURL: String? = nil,
        modelLoadFailures: [ModelLoadFailure] = []
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
        self.advertisedModels = advertisedModels
        self.coordinatorURL = coordinatorURL
        self.modelLoadFailures = modelLoadFailures
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
    public let authorization: ProviderAuthorizationStatus?

    public init(
        level: String,
        status: String,
        reason: String,
        receivedAt: TimeInterval,
        authorization: ProviderAuthorizationStatus? = nil
    ) {
        self.level = level
        self.status = status
        self.reason = reason
        self.receivedAt = receivedAt
        self.authorization = authorization
    }
}

/// Coordinator-issued authorization diagnostics. This is an observation of
/// the current connection, not a local serving credential. Session and
/// machine identifiers are intentionally reduced to presence flags so UI and
/// logs cannot accidentally render or persist the identifiers themselves.
public struct ProviderAuthorizationStatus: Equatable, Sendable {
    public let protocolVersion: Int
    public let appAttestAvailable: Bool
    public let path: String
    public let expiresAt: TimeInterval?
    public let mdmRemovalReady: Bool
    /// A bounded coordinator reason code. Unknown or prose values become
    /// `unknown` and are never returned verbatim.
    public let reason: String?
    public let sessionIDPresent: Bool
    public let machineIDPresent: Bool

    public init(
        protocolVersion: Int = 1,
        appAttestAvailable: Bool = false,
        path: String,
        expiresAt: TimeInterval? = nil,
        mdmRemovalReady: Bool = false,
        reason: String? = nil,
        sessionIDPresent: Bool = false,
        machineIDPresent: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.appAttestAvailable = appAttestAvailable
        self.path = path
        self.expiresAt = expiresAt
        self.mdmRemovalReady = mdmRemovalReady
        self.reason = Self.safeReason(reason)
        self.sessionIDPresent = sessionIDPresent
        self.machineIDPresent = machineIDPresent
    }

    public var hasSessionID: Bool { sessionIDPresent }
    public var hasMachineID: Bool { machineIDPresent }

    private static func safeReason(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let known: Set<String> = [
            "authorized", "app_attest", "legacy", "pending", "expired",
            "revoked", "unavailable", "not_eligible", "unsupported",
            "same_binary", "unknown"
        ]
        return known.contains(normalized) ? normalized : "unknown"
    }
}

/// Compatibility aliases for callers that describe this nested state as an
/// authorization state rather than using the upstream wire type name.
public typealias ProviderAuthorizationState = ProviderAuthorizationStatus
public typealias TrustAuthorization = ProviderAuthorizationStatus

public enum ModelLoadFailureCode: String, Equatable, Sendable {
    case insufficientMemory = "insufficient_memory"
    case modelUnavailable = "model_unavailable"
    case unsupported = "unsupported"
    case integrityFailure = "integrity_failure"
    case timedOut = "timed_out"
    case backendUnavailable = "backend_unavailable"
    case unknown
}

/// A safe, bounded representation of a model load failure. The CLI's load
/// message can include paths, model metadata, or customer-controlled prose;
/// only the model selector, closed reason code, and optional timestamp leave
/// the parser.
public struct ModelLoadFailure: Equatable, Sendable {
    public let model: String
    public let code: ModelLoadFailureCode
    public let occurredAt: TimeInterval?

    public init(
        model: String,
        code: ModelLoadFailureCode = .unknown,
        occurredAt: TimeInterval? = nil
    ) {
        self.model = Self.safeModel(model) ?? "Unknown model"
        self.code = code
        self.occurredAt = occurredAt.flatMap { $0.isFinite ? $0 : nil }
    }

    public var reasonCode: ModelLoadFailureCode { code }

    private static func safeModel(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200,
              !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
              !trimmed.contains("..") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/@:+-~"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
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
    public let kvFallbackReason: String?

    public init(
        model: String,
        mtpEnabled: Bool,
        mtpActive: Bool,
        mtpReason: String?,
        kvBackend: String,
        requestedKVBackend: String,
        kvFallbackReason: String? = nil
    ) {
        self.model = model
        self.mtpEnabled = mtpEnabled
        self.mtpActive = mtpActive
        self.mtpReason = mtpReason
        self.kvBackend = kvBackend
        self.requestedKVBackend = requestedKVBackend
        self.kvFallbackReason = kvFallbackReason
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
    public var warmModels: [String]?
    public var mostRecentlyUsed: String?
    public var requestCount: Int64?
    public var tokenCount: Int64?
    public var stateAge: String?
    public var slotPosture: [String]?
    public var memoryWhenIdle: String?
    public var authorization: String?
    public var authorizationAdvice: [String]?

    /// Short alias for consumers that treat the status block as generic
    /// operator advice. The parser still keeps the values bounded to lines
    /// beginning with the CLI's arrow marker.
    public var advice: [String]? {
        get { authorizationAdvice }
        set { authorizationAdvice = newValue }
    }

    public var adviceLines: [String]? {
        get { authorizationAdvice }
        set { authorizationAdvice = newValue }
    }

    public init() {}
}

public enum LogSeverity: String, Equatable, Sendable {
    case info
    case notice
    case warning
    case error
}

public enum LogSource: String, Equatable, Sendable {
    case legacy
    case unified
}

public struct LogEvent: Equatable, Sendable {
    public let timestamp: Date?
    public let severity: LogSeverity
    public let category: String
    public let message: String
    public let source: LogSource
    public let processID: Int32?
    public let processImage: String?

    public init(
        timestamp: Date?,
        severity: LogSeverity,
        category: String,
        message: String,
        source: LogSource,
        processID: Int32?,
        processImage: String?
    ) {
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.message = message
        self.source = source
        self.processID = processID
        self.processImage = processImage
    }
}
