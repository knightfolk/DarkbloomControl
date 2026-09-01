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
    var displayMTPReason: String {
        mtpReason ?? TelemetryFormatting.unavailable("not exposed by Darkbloom schema 1")
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
        case .stale(let feed, _, let reason):
            feed.events.isEmpty ? "Logs unavailable — \(reason)" : nil
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
            DisplayRow(label: "CLI warm models", value: TelemetryFormatting.modelList(warmModels)),
            DisplayRow(label: "Most recently used", value: display(mostRecentlyUsed)),
            DisplayRow(label: "CLI requests", value: display(requestCount)),
            DisplayRow(label: "CLI tokens", value: display(tokenCount)),
            DisplayRow(label: "CLI state age", value: display(stateAge)),
            DisplayRow(label: "CLI slot posture", value: TelemetryFormatting.modelList(slotPosture)),
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
}
