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
