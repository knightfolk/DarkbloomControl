import AppKit
import DarkbloomTelemetry
import SwiftUI

@main
struct DarkbloomMonitorApp: App {
    @StateObject private var store: MonitorStore
    @AppStorage("menuBarDisplayMode") private var displayModeRaw = MenuBarDisplayMode.automatic.rawValue

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
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Darkbloom Monitor", isDirectory: true)
        let earningsDatabase = try? EarningsDatabase(
            url: applicationSupport.appendingPathComponent("earnings.sqlite3")
        )
        let earningsClient = AuthenticatedEarningsClient(
            homeDirectory: home,
            database: earningsDatabase
        )
        let monitorStore = MonitorStore(
            service: service,
            initial: .unavailable(now: Date()),
            earningsClient: earningsClient
        )
        _store = StateObject(wrappedValue: monitorStore)

        Task { @MainActor in
            monitorStore.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover(store: store, displayMode: displayModeBinding)
        } label: {
            MenuBarLabel(presentation: store.menuPresentation(mode: displayMode))
        }
        .menuBarExtraStyle(.window)
    }

    private var displayMode: MenuBarDisplayMode {
        MenuBarDisplayMode(rawValue: displayModeRaw) ?? .automatic
    }

    private var displayModeBinding: Binding<MenuBarDisplayMode> {
        Binding(
            get: { displayMode },
            set: { displayModeRaw = $0.rawValue }
        )
    }
}
