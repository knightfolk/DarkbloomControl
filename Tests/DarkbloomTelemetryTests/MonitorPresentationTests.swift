import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Monitor presentation")
struct MonitorPresentationTests {
    @Test("Apple thermal states map one-to-one")
    func mapsAppleThermalStates() {
        #expect(SystemThermalState(ProcessInfo.ThermalState.nominal) == .nominal)
        #expect(SystemThermalState(ProcessInfo.ThermalState.fair) == .fair)
        #expect(SystemThermalState(ProcessInfo.ThermalState.serious) == .serious)
        #expect(SystemThermalState(ProcessInfo.ThermalState.critical) == .critical)
    }

    @Test(arguments: [
        (SystemThermalState.nominal, RoutingHealthColor.green),
        (SystemThermalState.fair, RoutingHealthColor.yellow),
        (SystemThermalState.serious, RoutingHealthColor.orange),
    ])
    func mapsRoutableThermalState(
        thermal: SystemThermalState,
        color: RoutingHealthColor
    ) {
        let presentation = MenuBarPresentation.make(
            snapshot: snapshot(menuStatus: .online, active: false),
            thermal: thermal,
            earnings: .available(microUSD: 125_000),
            mode: .automatic
        )

        #expect(presentation.health.color == color)
        #expect(presentation.health.isRoutable)
    }

    @Test("critical thermal pressure overrides online routing")
    func criticalThermalIsRed() {
        let presentation = MenuBarPresentation.make(
            snapshot: snapshot(menuStatus: .online, active: true),
            thermal: .critical,
            earnings: .unavailable(reason: "not loaded"),
            mode: .automatic
        )

        #expect(presentation.health.color == .red)
        #expect(!presentation.health.isRoutable)
        #expect(presentation.health.reason == "Critical thermal pressure")
    }

    @Test(arguments: [
        (MenuPresentationStatus.offline, "Provider is offline"),
        (MenuPresentationStatus.stale, "Provider routing state is stale"),
        (MenuPresentationStatus.unavailable, "Provider routing state is unavailable"),
    ])
    func nonRoutableProviderStateOverridesNominalThermals(
        status: MenuPresentationStatus,
        reason: String
    ) {
        let presentation = MenuBarPresentation.make(
            snapshot: snapshot(menuStatus: status, active: false),
            thermal: .nominal,
            earnings: .available(microUSD: 0),
            mode: .automatic
        )

        #expect(presentation.health.color == .red)
        #expect(presentation.health.reason == reason)
    }

    @Test("automatic mode shows token rate while active")
    func automaticModeUsesActiveThroughput() {
        let presentation = MenuBarPresentation.make(
            snapshot: snapshot(
                menuStatus: .online,
                active: true,
                tokenRate: .available(tokensPerSecond: 42.25, label: "derived")
            ),
            thermal: .nominal,
            earnings: .available(microUSD: 125_000),
            mode: .automatic
        )

        #expect(presentation.metricText == "42.3 tok/s")
        #expect(presentation.accessibilityLabel.contains("42.3 tokens per second"))
    }

    @Test("automatic mode shows rolling earnings while idle")
    func automaticModeUsesIdleEarnings() {
        let presentation = MenuBarPresentation.make(
            snapshot: snapshot(menuStatus: .online, active: false),
            thermal: .fair,
            earnings: .available(microUSD: 125_000),
            mode: .automatic
        )

        #expect(presentation.metricText == "$0.13/24h")
        #expect(presentation.accessibilityLabel ==
            "Darkbloom routable, thermal fair. 0.13 dollars earned in the last 24 hours.")
    }

    @Test("automatic mode shows the truthful locally observed earnings window while warming")
    func automaticModeUsesObservedIdleEarnings() {
        let presentation = MenuBarPresentation.make(
            snapshot: snapshot(menuStatus: .online, active: false),
            thermal: .nominal,
            earnings: .observed(microUSD: 1_100_000, observedSeconds: 43_200),
            mode: .automatic
        )

        #expect(presentation.metricText == "$1.10/12h")
        #expect(presentation.accessibilityLabel ==
            "Darkbloom routable, thermal nominal. 1.10 dollars observed over 12 hours.")
    }

    @Test("missing measured rate falls back to real earnings")
    func unavailableRateUsesEarnings() {
        let presentation = MenuBarPresentation.make(
            snapshot: snapshot(menuStatus: .online, active: true),
            thermal: .nominal,
            earnings: .available(microUSD: 2_900_000),
            mode: .automatic
        )

        #expect(presentation.metricText == "$2.90/24h")
        #expect(presentation.metricUnavailableReason == nil)
    }

    @Test("missing rate and earnings omit metric text")
    func unavailableMetricsAreOmitted() {
        let presentation = MenuBarPresentation.make(
            snapshot: snapshot(menuStatus: .online, active: false),
            thermal: .nominal,
            earnings: .unavailable(reason: "Not logged in"),
            mode: .automatic
        )

        #expect(presentation.metricText == nil)
        #expect(presentation.metricUnavailableReason == "Not logged in")
    }

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

        let stale: SourceAvailability<EventFeed> = .stale(
            value: feed,
            capturedAt: Date(timeIntervalSince1970: 1),
            reason: "unified stream ended"
        )
        #expect(stale.eventEmptyMessage == "No qualifying events in the bounded window")
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

    @Test("advanced status lists distinguish missing from explicitly empty output")
    func formatsStatusListPresence() {
        let missing = StatusParser.parse("darkbloom 0.8.15\nProvider: test")
        let exposedEmpty = StatusParser.parse("""
            darkbloom 0.8.15
            Warm models: none
            Slot posture: state written 0s ago
            """)

        #expect(value("CLI warm models", in: missing) ==
            "Unavailable — not reported by Darkbloom status")
        #expect(value("CLI slot posture", in: missing) ==
            "Unavailable — not reported by Darkbloom status")
        #expect(value("CLI warm models", in: exposedEmpty) == "None reported")
        #expect(value("CLI slot posture", in: exposedEmpty) == "None reported")
    }

    private func unavailableReason<Value>(
        _ availability: SourceAvailability<Value>
    ) -> String? where Value: Equatable & Sendable {
        guard case .unavailable(let reason) = availability else { return nil }
        return reason
    }

    private func value(_ label: String, in status: StatusSnapshot) -> String? {
        status.advancedRows.first(where: { $0.label == label })?.value
    }

    private func snapshot(
        menuStatus: MenuPresentationStatus,
        active: Bool,
        tokenRate: TokenRate = .unavailable(reason: "Waiting for activity")
    ) -> TelemetrySnapshot {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let daemon = DaemonState(
            schema: 1,
            version: "1.0",
            currentModel: "gemma-4-26b",
            warmModels: ["gemma-4-26b"],
            stats: ProviderStats(tokensGenerated: 1_000, requestsServed: 2, usageGaps: 0),
            trust: TrustState(level: "hardware", status: "online", reason: "ok", receivedAt: now.timeIntervalSince1970),
            capacity: MemoryCapacity(totalMemoryGB: 64, gpuMemoryActiveGB: 8, gpuMemoryCacheGB: 2),
            slots: [],
            inferenceActive: active,
            startedAt: now.timeIntervalSince1970 - 60,
            writtenAt: now.timeIntervalSince1970,
            pid: 42,
            processIdentity: ProcessIdentity(pid: 42, startTimeMicros: 1)
        )
        return TelemetrySnapshot(
            state: .available(value: daemon, capturedAt: now),
            loadedModels: .unavailable(reason: "unused"),
            status: .unavailable(reason: "unused"),
            eventFeed: .unavailable(reason: "unused"),
            tokenRate: tokenRate,
            diagnostics: [],
            capturedAt: now,
            menuStatus: menuStatus
        )
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
