import Foundation

public struct EventFeed: Equatable, Sendable {
    public let events: [LogEvent]
    public let legacyReadAt: Date?
    public let unifiedActivityAt: Date?
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
