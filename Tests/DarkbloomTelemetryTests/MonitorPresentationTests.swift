import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Monitor presentation")
struct MonitorPresentationTests {
    @Test("menu status has inspectable symbol and accessibility label")
    func mapsMenuStatus() {
        #expect(MenuPresentationStatus.online.symbolName == "circle.fill")
        #expect(MenuPresentationStatus.stale.symbolName == "circle.fill")
        #expect(MenuPresentationStatus.offline.symbolName == "circle.fill")
        #expect(MenuPresentationStatus.unavailable.symbolName == "circle.fill")

        #expect(MenuPresentationStatus.online.accessibilityLabel == "Darkbloom online")
        #expect(MenuPresentationStatus.stale.accessibilityLabel == "Darkbloom state stale")
        #expect(MenuPresentationStatus.offline.accessibilityLabel == "Darkbloom offline")
        #expect(MenuPresentationStatus.unavailable.accessibilityLabel == "Darkbloom unavailable")
    }

    @Test("initial snapshot explains every unavailable telemetry group")
    func unavailableSnapshotExplainsAllGroups() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let snapshot = TelemetrySnapshot.unavailable(now: now)

        #expect(unavailableReason(snapshot.state) == "Waiting for daemon state")
        #expect(unavailableReason(snapshot.loadedModels) == "Waiting for loaded models")
        #expect(unavailableReason(snapshot.status) == "Waiting for Darkbloom status")
        #expect(unavailableReason(snapshot.eventFeed) == "Waiting for event sources")
        #expect(snapshot.tokenRate == .unavailable(reason: "Waiting for a second telemetry sample"))
        #expect(snapshot.capturedAt == now)
        #expect(snapshot.menuStatus == .unavailable)
        #expect(snapshot.diagnostics.isEmpty)
    }

    private func unavailableReason<Value>(
        _ availability: SourceAvailability<Value>
    ) -> String? where Value: Equatable & Sendable {
        guard case .unavailable(let reason) = availability else { return nil }
        return reason
    }
}
