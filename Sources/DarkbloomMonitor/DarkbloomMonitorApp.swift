import AppKit
import DarkbloomTelemetry
import SwiftUI

@main
struct DarkbloomMonitorApp: App {
    @StateObject private var store: MonitorStore

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        let home = FileManager.default.homeDirectoryForCurrentUser
        let policy = DarkbloomSourcePolicy(
            homeDirectory: home,
            environmentPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        )
        let source = LocalTelemetrySource(
            policy: policy,
            runner: CappedProcessRunner()
        )
        let service = TelemetryService(
            source: source,
            unifiedEvents: UnifiedLogStreamer().events()
        )
        let monitorStore = MonitorStore(
            service: service,
            initial: .unavailable(now: Date())
        )
        _store = StateObject(wrappedValue: monitorStore)

        Task { @MainActor in
            monitorStore.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover(store: store)
        } label: {
            MenuBarLabel(status: store.snapshot.menuStatus)
        }
        .menuBarExtraStyle(.window)
    }
}
