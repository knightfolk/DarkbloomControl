import AppKit
import DarkbloomTelemetry
import SwiftUI
import Testing
@testable import DarkbloomMonitor

@Suite("Hosting settings view", .serialized)
@MainActor
struct HostingSettingsViewTests {
    @Test("bind preset selection follows reachability scope, not the fallback address")
    func bindPresetSelection() {
        let defaults = HostingOptions.default
        #expect(HostingBindPreset.loopback.isSelected(for: defaults))
        #expect(!HostingBindPreset.specificInterface.isSelected(for: defaults))
        #expect(!HostingBindPreset.allInterfaces.isSelected(for: defaults))

        let lan = HostingOptions(mode: .unified, bindAddress: "192.168.1.20")
        #expect(!HostingBindPreset.loopback.isSelected(for: lan))
        #expect(HostingBindPreset.specificInterface.isSelected(for: lan))
        #expect(!HostingBindPreset.allInterfaces.isSelected(for: lan))
    }

    @Test("specific bind preset chooses an active address without inventing one")
    func specificPresetAddress() {
        let loopback = HostingOptions.default
        #expect(HostingBindPreset.specificInterface.address(for: loopback, activeAddresses: []) == nil)
        #expect(HostingBindPreset.specificInterface.address(for: loopback, activeAddresses: ["192.168.1.20"]) == "192.168.1.20")

        let selected = HostingOptions(mode: .unified, bindAddress: "100.90.10.2")
        #expect(HostingBindPreset.specificInterface.address(for: selected, activeAddresses: ["192.168.1.20"]) == "100.90.10.2")
    }

    @Test("hosting settings render at compact and readable window sizes", arguments: ["light", "dark"])
    func renders(appearance: String) async throws {
        let suite = "HostingSettingsView-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HostingSettingsStore(
            controlStore: nil,
            endpointClient: HostingNoEndpoint(),
            tokenFile: HostingViewTokenFileFake(),
            cliVersionProvider: { "0.9.7" },
            defaults: defaults,
            lanScanner: { ["192.168.1.20"] }
        )
        store.setMode(.unified)
        let content = NSHostingController(rootView: HostingSettingsView(store: store))
        let window = NSWindow(contentViewController: content)
        defer { window.close() }
        window.setContentSize(NSSize(width: 800, height: 620))
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        content.view.layoutSubtreeIfNeeded()

        #expect(content.view.frame.width == 800)
        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-hosting-settings-\(appearance).png"]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }
}

private struct HostingNoEndpoint: LocalEndpointFetching {
    func fetch() async -> LocalEndpointAvailability {
        .none(LocalEndpointClient.noLiveEndpointReason)
    }
}

private struct HostingViewTokenFileFake: LocalEndpointTokenManaging {
    func withBearerToken(_ action: (String) -> Void) -> Bool { false }
    func saveBearerToken(_ token: String) throws {}
}
