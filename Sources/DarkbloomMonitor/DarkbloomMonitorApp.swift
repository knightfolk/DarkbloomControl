import AppKit
import DarkbloomTelemetry
import SwiftUI

@main
struct DarkbloomMonitorApp: App {
    @NSApplicationDelegateAdaptor(DarkbloomMonitorAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class DarkbloomMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private var store: MonitorStore?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let observedUptimeDatabase = try? ObservedUptimeDatabase(
            url: applicationSupport.appendingPathComponent("observed-uptime.sqlite3")
        )
        let earningsClient = AuthenticatedEarningsClient(
            homeDirectory: home,
            database: earningsDatabase
        )
        let monitorStore = MonitorStore(
            service: service,
            initial: .unavailable(now: Date()),
            earningsClient: earningsClient,
            uptimeRecorder: observedUptimeDatabase
        )
        store = monitorStore
        statusItemController = StatusItemController(store: monitorStore)
        monitorStore.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.invalidate()
        guard let store else { return }
        Task { await store.stop() }
    }
}
