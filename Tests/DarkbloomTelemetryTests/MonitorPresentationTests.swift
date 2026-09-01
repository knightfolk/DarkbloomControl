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

    @Test("slot reason is explicit when schema exposes none")
    func formatsSlotGap() {
        let slot = ModelSlot(
            model: "gemma",
            mtpEnabled: true,
            mtpActive: true,
            mtpReason: nil,
            kvBackend: "contiguous",
            requestedKVBackend: "auto"
        )

        #expect(slot.displayMTPReason == "Unavailable — not exposed by Darkbloom schema 1")
    }

    @Test("event empty states distinguish no events from source failure")
    func formatsEventEmptyStates() {
        let feed = EventFeed(
            events: [],
            legacyReadAt: Date(timeIntervalSince1970: 1),
            unifiedActivityAt: nil
        )
        #expect(feed.emptyMessage == "No qualifying events in the bounded window")

        let unavailable: SourceAvailability<EventFeed> = .unavailable(reason: "provider.log missing")
        #expect(unavailable.eventEmptyMessage == "Logs unavailable — provider.log missing")
    }

    @Test("advanced status rows include every observed status property")
    func includesAllStatusRows() {
        let rows = StatusSnapshot.completeFixture.advancedRows

        #expect(rows.map(\.label) == [
            "CLI version", "Provider", "Config path", "Coordinator", "Backend port",
            "Configured model", "Idle timeout", "Beta features", "Auto-restart",
            "Hardware", "Inference memory", "Local boot checks", "Schedule",
            "Enabled model filter", "Local MLX models", "Daemon", "CLI trust",
            "CLI trust reason", "CLI warm models", "Most recently used",
            "CLI requests", "CLI tokens", "CLI state age", "CLI slot posture",
        ])
    }

    private func unavailableReason<Value>(
        _ availability: SourceAvailability<Value>
    ) -> String? where Value: Equatable & Sendable {
        guard case .unavailable(let reason) = availability else { return nil }
        return reason
    }
}

private extension StatusSnapshot {
    static var completeFixture: Self {
        var status = StatusSnapshot()
        status.version = "0.8.15"
        status.providerName = "darkbloom-mac"
        status.configPath = "/Users/example/.config/darkbloom/provider.toml"
        status.coordinator = "https://coordinator.example"
        status.backendPort = 9332
        status.configuredModel = "auto-select"
        status.idleTimeout = "60m"
        status.betaFeatures = "enabled"
        status.autoRestart = "enabled"
        status.hardware = "Apple Silicon"
        status.inferenceMemory = "48 GiB"
        status.bootChecks = "passed"
        status.schedule = "always"
        status.enabledModelFilter = "all"
        status.localModelCount = 2
        status.daemon = "running"
        status.trust = "hardware / online"
        status.trustReason = "same_binary"
        status.warmModels = ["gemma", "gpt-oss"]
        status.mostRecentlyUsed = "gemma"
        status.requestCount = 12
        status.tokenCount = 3_456
        status.stateAge = "2s"
        status.slotPosture = ["gemma: kv=contiguous"]
        return status
    }
}
