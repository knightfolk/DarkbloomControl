import AppKit
import DarkbloomTelemetry
import SwiftUI
import Testing
@testable import DarkbloomMonitor

@Suite("Hosting settings view", .serialized)
@MainActor
struct HostingSettingsViewTests {
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
        let content = NSHostingController(
            rootView: Form { HostingSettingsView(store: store) }
                .formStyle(.grouped)
        )
        let window = NSWindow(contentViewController: content)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 900))
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        content.view.layoutSubtreeIfNeeded()

        #expect(content.view.frame.width == 1000)
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

private struct HostingViewTokenFileFake: LocalEndpointTokenProviding {
    func withBearerToken(_ action: (String) -> Void) -> Bool { false }
}
