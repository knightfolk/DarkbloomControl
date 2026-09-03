import AppKit
import DarkbloomTelemetry
import SwiftUI

@main
struct DarkbloomMonitorApp: App {
    @NSApplicationDelegateAdaptor(DarkbloomMonitorAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AppSettingsSceneRoot(controlStore: appDelegate.controlStore)
        }
    }
}

@MainActor
final class DarkbloomMonitorAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var store: MonitorStore?
    @Published private(set) var controlStore: ProviderControlStore?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let policy = DarkbloomSourcePolicy(
            homeDirectory: home,
            environmentPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        )
        let runner = CappedProcessRunner()
        let source = LocalTelemetrySource(policy: policy, runner: runner)
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
        let tokenRateDatabase = try? ModelTokenRateDatabase(
            url: applicationSupport.appendingPathComponent("model-token-rates.sqlite3")
        )
        let earningsClient = AuthenticatedEarningsClient(
            homeDirectory: home,
            database: earningsDatabase
        )
        let monitorStore = MonitorStore(
            service: service,
            initial: .unavailable(now: Date()),
            earningsClient: earningsClient,
            uptimeRecorder: observedUptimeDatabase,
            tokenRateRecorder: tokenRateDatabase
        )
        let configExecutable = policy.cliCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) ?? policy.cliCandidates[0]
        let configStore = LocalProviderConfigStore(
            configURL: policy.providerConfig,
            executable: configExecutable,
            runner: runner
        )
        let controlService = ProviderControlService(
            policy: policy,
            telemetrySource: source,
            configStore: configStore,
            runner: runner
        )
        let providerControlStore = ProviderControlStore(
            controller: controlService,
            homeDirectory: home,
            refreshTelemetry: { [weak monitorStore] in
                await monitorStore?.refreshTelemetryImmediately()
            }
        )
        store = monitorStore
        controlStore = providerControlStore
        statusItemController = StatusItemController(
            store: monitorStore,
            controlStore: providerControlStore
        )
        monitorStore.start()
        Task { @MainActor [weak providerControlStore] in
            await providerControlStore?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.invalidate()
        controlStore?.cancelCurrentOperation()
        guard let store else { return }
        Task { await store.stop() }
    }
}

struct AppSettingsSceneRoot: View {
    let controlStore: ProviderControlStore?

    @ViewBuilder
    var body: some View {
        if let controlStore {
            ProviderSettingsRoot(controlStore: controlStore)
        } else {
            ProgressView("Starting Darkbloom Monitor…")
                .frame(width: 420, height: 180)
        }
    }
}

struct ProviderSettingsRoot: View {
    @ObservedObject var controlStore: ProviderControlStore

    var body: some View {
        MonitorSettingsView()
            .environmentObject(controlStore)
    }
}
