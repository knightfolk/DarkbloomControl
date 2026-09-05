import AppKit
import DarkbloomTelemetry
import Testing
@testable import DarkbloomMonitor

@Suite("Dashboard window", .serialized)
@MainActor
struct DashboardWindowTests {
    @Test("Settings navigation reuses the dashboard window")
    func settingsRoute() throws {
        let suite = "DashboardNavigationTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(service: TelemetryService(source: DashboardUnusedSource()), initial: .unavailable(now: Date()))
        let controller = DashboardWindowController(store: store, controlStore: nil, frameAutosaveName: nil, defaults: defaults)
        let first = controller.window
        controller.present(activate: false)
        controller.present(section: .settings, activate: false)
        #expect(controller.window === first)
        #expect(controller.navigation.selected == .settings)
        #expect(DashboardNavigation(defaults: defaults).selected == .settings)
        defaults.set("unknown future section", forKey: "dashboard.selectedSection")
        #expect(DashboardNavigation(defaults: defaults).selected == .overview)
        controller.close()
    }

    @Test("unified Settings renders at minimum dashboard size", arguments: ["light", "dark"])
    func settingsMinimumSize(appearance: String) async throws {
        let suite = "DashboardSettingsRender-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(service: TelemetryService(source: DashboardUnusedSource()), initial: .unavailable(now: Date()))
        let controller = DashboardWindowController(store: store, controlStore: nil, frameAutosaveName: nil, defaults: defaults)
        defer { controller.close() }
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.setContentSize(NSSize(width: 800, height: 560))
        controller.present(section: .settings, activate: false)
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentView?.frame.width == 800)
        #expect(controller.navigation.selected == .settings)
        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-unified-settings-\(appearance).png"]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }

    @Test("a new controller restores the last displayed frame after toolbar layout")
    func restoresFrame() throws {
        let name = "DashboardRestoreTest-\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: name) }
        let store = MonitorStore(service: TelemetryService(source: DashboardUnusedSource()), initial: .unavailable(now: Date()))
        var first: DashboardWindowController? = DashboardWindowController(
            store: store, controlStore: nil, frameAutosaveName: name
        )
        first?.present(activate: false)
        let window = try #require(first?.window)
        let target = NSRect(x: window.frame.minX + 30, y: window.frame.minY + 30, width: 900, height: 650)
        window.setFrame(target, display: true)
        window.saveFrame(usingName: name)
        first?.close()
        window.setFrameAutosaveName("")
        first = nil
        let second = DashboardWindowController(store: store, controlStore: nil, frameAutosaveName: name)
        second.present(activate: false)
        #expect(second.window?.frame == target)
        second.close()
    }

    @Test("closing and reopening retains the same visible dashboard window")
    func reusesWindow() {
        let store = MonitorStore(
            service: TelemetryService(source: DashboardUnusedSource()),
            initial: .unavailable(now: Date())
        )
        let controller = DashboardWindowController(
            store: store, controlStore: nil, frameAutosaveName: nil
        )
        let firstWindow = controller.window
        controller.present(activate: false)
        #expect(store.dashboardVisible)
        controller.close()
        #expect(!store.dashboardVisible)
        controller.present(activate: false)
        #expect(controller.window === firstWindow)
        #expect(controller.window?.isVisible == true)
        #expect(controller.window?.isReleasedWhenClosed == false)
        controller.close()
    }
}

private struct DashboardUnusedSource: TelemetrySource {
    func readDaemonState() async throws -> DaemonState { throw UnexpectedAcquisition() }
    func readLoadedModels() async throws -> LoadedModelsState { throw UnexpectedAcquisition() }
    func readStatus() async throws -> StatusSnapshot { throw UnexpectedAcquisition() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw UnexpectedAcquisition() }
}

private struct UnexpectedAcquisition: Error {}
