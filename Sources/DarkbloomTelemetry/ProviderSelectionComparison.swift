import Foundation

/// Compare canonical IDs, not display names or unresolved config selectors.
public struct ProviderSelectionComparison: Equatable, Sendable {
    public let saved: [String]
    public let advertised: [String]?
    public var differs: Bool { advertised.map { Set($0) != Set(saved) } ?? false }

    public init(saved: [String], advertised: [String]?) {
        self.saved = Array(Set(saved)).sorted()
        self.advertised = advertised.map { Array(Set($0)).sorted() }
    }

    public static func make(snapshot: ProviderControlSnapshot, now: Date) -> Self {
        let saved = snapshot.inventory.myCatalog.filter(\.isEnabled).map(\.catalogID)
        let advertised: [String]?
        if snapshot.sources.daemon.isMarkedFresh, let state = snapshot.daemonState,
           state.writtenAt.isFinite,
           (0...10).contains(now.timeIntervalSince1970 - state.writtenAt) {
            advertised = state.advertisedModels
        } else { advertised = nil }
        return Self(saved: saved, advertised: advertised)
    }
}
