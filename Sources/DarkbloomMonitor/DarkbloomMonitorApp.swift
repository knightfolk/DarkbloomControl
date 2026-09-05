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
    private var automaticSwitchTask: Task<Void, Never>?
    private var automaticSwitchCoordinator = AutomaticModelSwitchCoordinator(
        lastAttemptAt: ModelWarmupPreferences.automaticSwitchLastAttemptAt()
    )

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
        UserDefaults.standard.register(defaults: [
            ModelWarmupPreferences.headroomKey:
                ModelWarmupPreferences.defaultHeadroomGB,
            ModelWarmupPreferences.automaticSwitchingKey: false,
        ])
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
            runner: runner,
            minimumWarmupHeadroomGB: {
                ModelWarmupPreferences.selectedHeadroomGB
            }
        )
        let providerControlStore = ProviderControlStore(
            controller: controlService,
            homeDirectory: home,
            refreshTelemetry: { [weak monitorStore] in
                await monitorStore?.refreshTelemetryImmediately()
            },
            restartRequirementPersistence:
                UserDefaultsProviderRestartRequirementPersistence()
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
        automaticSwitchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                await self?.evaluateAutomaticSwitch()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.invalidate()
        automaticSwitchTask?.cancel()
        automaticSwitchTask = nil
        controlStore?.cancelCurrentOperation()
        guard let store else { return }
        Task { await store.stop() }
    }

    private func evaluateAutomaticSwitch() async {
        guard ModelWarmupPreferences.automaticSwitchingEnabled else {
            // Turning automation off clears only the pending recommendation;
            // it must not let an off/on cycle bypass the safety cooldown.
            automaticSwitchCoordinator.clearCandidate()
            return
        }
        guard let store,
              let controlStore,
              controlStore.operation == .idle,
              controlStore.pendingConfirmation == nil,
              controlStore.draft?.hasChanges != true
        else {
            automaticSwitchCoordinator.clearCandidate()
            return
        }

        // Control-source freshness expires independently of network demand.
        // Refresh the read-only proof before evaluating a switch, while the
        // idle/no-staged-draft guards above keep this from disturbing edits or
        // an active operation.
        await controlStore.refreshPreservingDraft()
        guard controlStore.operation == .idle,
              controlStore.pendingConfirmation == nil,
              let controlSnapshot = controlStore.snapshot
        else {
            automaticSwitchCoordinator.clearCandidate()
            return
        }

        guard case .available(let capacity, let sampledAt) = store.networkCapacity
        else {
            automaticSwitchCoordinator.clearCandidate()
            return
        }

        let now = Date()
        let outcome = await automaticSwitchCoordinator.evaluate(
            enabled: true,
            capacity: capacity,
            sampledAt: sampledAt,
            operation: controlStore.operation,
            draftHasChanges: controlStore.draft?.hasChanges == true,
            restartRequired: controlStore.restartRequired,
            pendingConfirmation: controlStore.pendingConfirmation,
            controlSnapshot: controlSnapshot,
            earnings: store.modelWorkEarnings,
            tokenRates: store.modelTokenRateAverages,
            now: now,
            minimumHeadroomGB: ModelWarmupPreferences.selectedHeadroomGB,
            availableSystemMemoryGB: SystemMemoryAvailability.availableGB(),
            warm: { [weak controlStore] modelID in
                await controlStore?.warm(modelID) ?? false
            }
        )
        guard case .attempted(_, true) = outcome else {
            return
        }
        ModelWarmupPreferences.recordAutomaticSwitchAttempt(at: now)
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
