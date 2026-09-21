import Foundation

public struct EventFeed: Equatable, Sendable {
    public let events: [LogEvent]
    public let legacyReadAt: Date?
    public let unifiedActivityAt: Date?
}

public struct DisplayRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String

    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct AcquisitionDiagnostic: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let message: String
    public let occurredAt: Date
}

public enum MenuPresentationStatus: Equatable, Sendable {
    case online
    case stale
    case offline
    case unavailable
}

public extension MenuPresentationStatus {
    var symbolName: String { "circle.fill" }

    var accessibilityLabel: String {
        switch self {
        case .online:
            "Darkbloom online"
        case .stale:
            "Darkbloom state stale"
        case .offline:
            "Darkbloom offline"
        case .unavailable:
            "Darkbloom unavailable"
        }
    }
}

public struct TelemetrySnapshot: Equatable, Sendable {
    public let state: SourceAvailability<DaemonState>
    public let loadedModels: SourceAvailability<LoadedModelsState>
    public let status: SourceAvailability<StatusSnapshot>
    public let eventFeed: SourceAvailability<EventFeed>
    public let tokenRate: TokenRate
    public let diagnostics: [AcquisitionDiagnostic]
    public let capturedAt: Date
    public let menuStatus: MenuPresentationStatus
}

public extension TelemetrySnapshot {
    static func unavailable(now: Date) -> Self {
        TelemetrySnapshot(
            state: .unavailable(reason: "Waiting for daemon state"),
            loadedModels: .unavailable(reason: "Waiting for loaded models"),
            status: .unavailable(reason: "Waiting for Darkbloom status"),
            eventFeed: .unavailable(reason: "Waiting for event sources"),
            tokenRate: .unavailable(reason: "Waiting for a second telemetry sample"),
            diagnostics: [],
            capturedAt: now,
            menuStatus: .unavailable
        )
    }
}

extension MenuPresentationStatus {
    static func derive(
        state availability: SourceAvailability<DaemonState>,
        now: Date
    ) -> Self {
        guard let state = availability.value else { return .unavailable }
        if state.trust.status == "offline" { return .offline }

        let age = now.timeIntervalSince1970 - state.writtenAt
        if age < 0 || age > 10 { return .stale }
        if case .stale = availability { return .stale }
        return state.trust.status == "online" ? .online : .stale
    }
}

public extension ModelSlot {
    /// A bounded operator description for the MTP posture. Unknown provider
    /// codes remain safe and generic; no provider error prose is rendered.
    var mtpReasonDescription: String {
        guard let mtpReason else {
            return TelemetryFormatting.unavailable("not reported by this daemon")
        }
        switch mtpReason {
        case "config_disabled":
            return "Disabled by configuration"
        case "kill_switch_disabled":
            return "Disabled by provider policy"
        case "target_unsupported", "assistant_target_incompatible":
            return "Target model does not support drafting"
        case "assistant_memory_unavailable", "assistant_post_build_headroom":
            return "Insufficient memory for drafting"
        case "inert_kv_unsupported":
            return "Enabled but inactive for this KV backend"
        case "engine_inactive":
            return "Drafting engine inactive"
        case "unknown":
            return "Reason unavailable"
        default:
            return "Drafting unavailable (\(mtpReason.replacingOccurrences(of: "_", with: " ")))"
        }
    }

    /// Existing monitor views use this name; keep it as an alias while the
    /// description itself reflects a missing observation rather than claiming
    /// schema 1 cannot report the field.
    var displayMTPReason: String {
        mtpReasonDescription
    }

    var kvFallbackReasonDescription: String? {
        guard let kvFallbackReason else { return nil }
        switch kvFallbackReason {
        case "kill_switch": return "Provider policy"
        case "crash_loop_guard": return "Crash-loop protection"
        case "kernel_preflight": return "Kernel preflight"
        case "physical_capacity", "pool_construction_capacity": return "Physical capacity"
        case "ineligible": return "Runtime ineligible"
        case "invalid_dtype": return "Unsupported data type"
        default: return "Fallback reason unavailable"
        }
    }
}

public extension EventFeed {
    var emptyMessage: String {
        "No qualifying events in the bounded window"
    }
}

public extension SourceAvailability where Value == EventFeed {
    var eventEmptyMessage: String? {
        switch self {
        case .available(let feed, _):
            feed.events.isEmpty ? feed.emptyMessage : nil
        case .stale(let feed, _, _):
            feed.events.isEmpty ? feed.emptyMessage : nil
        case .unavailable(let reason):
            "Logs unavailable — \(reason)"
        }
    }
}

public extension StatusSnapshot {
    var advancedRows: [DisplayRow] {
        [
            DisplayRow(label: "CLI version", value: display(version)),
            DisplayRow(label: "Provider", value: display(providerName)),
            DisplayRow(label: "Config path", value: display(configPath)),
            DisplayRow(label: "Coordinator", value: display(coordinator)),
            DisplayRow(label: "Backend port", value: display(backendPort)),
            DisplayRow(label: "Configured model", value: display(configuredModel)),
            DisplayRow(label: "Idle timeout", value: display(idleTimeout)),
            DisplayRow(label: "Beta features", value: display(betaFeatures)),
            DisplayRow(label: "Auto-restart", value: display(autoRestart)),
            DisplayRow(label: "Hardware", value: display(hardware)),
            DisplayRow(label: "Inference memory", value: display(inferenceMemory)),
            DisplayRow(label: "Local boot checks", value: display(bootChecks)),
            DisplayRow(label: "Schedule", value: display(schedule)),
            DisplayRow(label: "Enabled model filter", value: display(enabledModelFilter)),
            DisplayRow(label: "Local MLX models", value: display(localModelCount)),
            DisplayRow(label: "Daemon", value: display(daemon)),
            DisplayRow(label: "CLI trust", value: display(trust)),
            DisplayRow(label: "CLI trust reason", value: display(trustReason)),
            DisplayRow(label: "CLI warm models", value: display(warmModels)),
            DisplayRow(label: "Most recently used", value: display(mostRecentlyUsed)),
            DisplayRow(label: "CLI requests", value: display(requestCount)),
            DisplayRow(label: "CLI tokens", value: display(tokenCount)),
            DisplayRow(label: "CLI state age", value: display(stateAge)),
            DisplayRow(label: "CLI slot posture", value: display(slotPosture)),
        ]
    }

    private func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return TelemetryFormatting.unavailable("not reported by Darkbloom status")
        }
        return value
    }

    private func display(_ value: Int?) -> String {
        value.map(String.init) ?? TelemetryFormatting.unavailable("not reported by Darkbloom status")
    }

    private func display(_ value: Int64?) -> String {
        value.map(TelemetryFormatting.integer) ?? TelemetryFormatting.unavailable("not reported by Darkbloom status")
    }

    private func display(_ value: [String]?) -> String {
        value.map(TelemetryFormatting.modelList)
            ?? TelemetryFormatting.unavailable("not reported by Darkbloom status")
    }
}
