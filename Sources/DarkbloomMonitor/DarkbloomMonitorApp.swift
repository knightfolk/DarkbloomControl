import AppKit
import DarkbloomTelemetry
import SwiftUI

@main
struct DarkbloomMonitorApp: App {
    @NSApplicationDelegateAdaptor(DarkbloomMonitorAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                ControlAppUpdateMenuItem()
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                Button("Open Dashboard") { appDelegate.showDashboard() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class DarkbloomMonitorAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let instanceGuard: SingleInstanceGuard
    private var store: MonitorStore?
    @Published private(set) var controlStore: ProviderControlStore?
    private var statusItemController: StatusItemController?

    override init() {
        self.instanceGuard = SingleInstanceGuard()
        super.init()
    }

    init(instanceGuard: SingleInstanceGuard) {
        self.instanceGuard = instanceGuard
        super.init()
    }

    func showSettings() {
        statusItemController?.showSettings()
    }

    func showDashboard() {
        statusItemController?.showDashboard()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard DarkbloomMonitorStartupGate.acquireOrTerminate(
            instanceGuard: instanceGuard,
            terminate: { NSApplication.shared.terminate(nil) }
        ) else {
            // Do not construct MonitorStore, StatusItemController, or any
            // other UI for a duplicate or unverifiable launch.
            return
        }

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
        let applicationSupport = MonitorApplicationIdentity.applicationSupportDirectory()
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
            providerExtras: ProviderExtrasStore(),
            earningsClient: earningsClient,
            uptimeRecorder: observedUptimeDatabase,
            tokenRateRecorder: tokenRateDatabase,
            networkCapacityClient: PublicNetworkCapacityClient(),
            publicCatalogClient: PublicCatalogClient(),
            publicPricingClient: PublicPricingClient(),
            networkSeriesClient: NetworkSeriesClient()
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
        let localEndpointClient = LocalEndpointClient(policy: policy, runner: runner)
        let localEndpointTokenFile = LocalEndpointTokenFile(fileURL: policy.localEndpointToken)
        let hostingSettingsStore = HostingSettingsStore(
            controlStore: nil,
            endpointClient: localEndpointClient,
            tokenFile: localEndpointTokenFile,
            cliVersionProvider: { [weak monitorStore] in
                monitorStore?.snapshot.status.value?.version
            }
        )
        let providerControlStore = ProviderControlStore(
            controller: controlService,
            homeDirectory: home,
            refreshTelemetry: { [weak monitorStore] in
                await monitorStore?.refreshTelemetryImmediately()
            },
            awaitStartup: { [weak monitorStore] requestedAt in
                for _ in 0..<45 {
                    try Task.checkCancellation()
                    guard let monitorStore else { throw CancellationError() }
                    await monitorStore.refreshTelemetryImmediately()
                    if case .available(let daemon, _) = monitorStore.snapshot.state,
                       daemon.writtenAt >= requestedAt.timeIntervalSince1970 {
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                throw ProviderStartupTimeout()
            },
            hostingOptions: { [weak hostingSettingsStore] in
                hostingSettingsStore?.options ?? HostingSettingsStore.loadOptions(from: .standard)
            }
        )
        hostingSettingsStore.attachControlStore(providerControlStore)
        store = monitorStore
        controlStore = providerControlStore
        statusItemController = StatusItemController(
            store: monitorStore,
            controlStore: providerControlStore,
            hostingStore: hostingSettingsStore
        )
        ControlAppUpdater.shared.canRelaunch = { [weak providerControlStore] in
            guard let control = providerControlStore else { return true }
            return control.operation == .idle && control.draft?.hasChanges != true
                && control.pendingConfirmation == nil
        }
        ControlAppUpdater.shared.start()
        CLIUpdateStatusStore.shared.start()
        monitorStore.start()
        Task { @MainActor [weak providerControlStore] in
            await providerControlStore?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.invalidate()
        controlStore?.cancelCurrentOperation()
        guard let store else { return }
        Task {
            await CLIUpdateStatusStore.shared.stop()
            await store.stop()
        }
    }
}

struct AppSettingsSceneRoot: View {
    let controlStore: ProviderControlStore?

    @ViewBuilder
    var body: some View {
        if let controlStore {
            ProviderSettingsRoot(controlStore: controlStore)
        } else {
            ProgressView("Starting \(MonitorApplicationIdentity.displayName)…")
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

private struct ControlAppUpdateMenuItem: View {
    @ObservedObject var updater = ControlAppUpdater.shared
    var body: some View {
        Button("Check for Updates…", action: updater.check).disabled(!updater.canCheck)
    }
}

private struct ProviderStartupTimeout: Error {}
