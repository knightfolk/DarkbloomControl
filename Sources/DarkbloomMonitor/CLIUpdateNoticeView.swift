import DarkbloomTelemetry
import SwiftUI

/// Own this store with the monitor and call `start()`/`stop()` with the app
/// lifecycle. `start()` also performs the initial read-only check and then
/// polls infrequently; no update is installed or restarted automatically.
@MainActor
final class CLIUpdateStatusStore: ObservableObject {
    static let shared = CLIUpdateStatusStore()

    @Published private(set) var status: SourceAvailability<CLIUpdateStatus> = .unavailable(
        reason: "Darkbloom CLI update status has not been checked"
    )
    @Published private(set) var isRefreshing = false

    private let client: any CLIUpdateProviding
    private let pollingInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        policy: DarkbloomSourcePolicy = .currentUser,
        runner: any ProcessExecuting = CappedProcessRunner(),
        pollingInterval: Duration = .seconds(6 * 60 * 60)
    ) {
        self.client = CLIUpdateClient(policy: policy, runner: runner)
        self.pollingInterval = pollingInterval
    }

    init(
        client: any CLIUpdateProviding,
        pollingInterval: Duration = .seconds(6 * 60 * 60)
    ) {
        self.client = client
        self.pollingInterval = pollingInterval
    }

    func refresh() async {
        if let refreshTask {
            await withTaskCancellationHandler {
                await refreshTask.value
            } onCancel: {
                refreshTask.cancel()
            }
            return
        }

        isRefreshing = true
        generation &+= 1
        let refreshGeneration = generation
        let client = self.client
        let task = Task { @MainActor [weak self] in
            let refreshed = await client.checkForUpdate()
            guard let self,
                  !Task.isCancelled,
                  self.generation == refreshGeneration
            else {
                return
            }
            self.status = Self.merge(refreshed, with: self.status)
        }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == refreshGeneration {
            refreshTask = nil
            isRefreshing = false
        }
    }

    /// Start one immediate check, followed by read-only checks every six hours.
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.pollingInterval)
                } catch {
                    return
                }
                await self.refresh()
            }
        }
    }

    func stop() async {
        let polling = pollingTask
        polling?.cancel()
        let refresh = refreshTask
        refresh?.cancel()
        await polling?.value
        await refresh?.value
        pollingTask = nil
        refreshTask = nil
        isRefreshing = false
    }

    private static func merge(
        _ refreshed: SourceAvailability<CLIUpdateStatus>,
        with previous: SourceAvailability<CLIUpdateStatus>
    ) -> SourceAvailability<CLIUpdateStatus> {
        switch refreshed {
        case .available, .stale:
            return refreshed
        case .unavailable(let reason):
            switch previous {
            case .available(let value, let capturedAt), .stale(let value, let capturedAt, _):
                return .stale(value: value, capturedAt: capturedAt, reason: reason)
            case .unavailable:
                return refreshed
            }
        }
    }
}

/// Read-only CLI update information for inclusion as a section in a SwiftUI
/// Form. Parent app lifecycle code should start and stop the shared store; this
/// view starts it as a fallback when used on its own.
struct CLIUpdateNoticeView: View {
    @ObservedObject var store: CLIUpdateStatusStore

    init(store: CLIUpdateStatusStore = .shared) {
        self.store = store
    }

    var body: some View {
        Section("Darkbloom CLI · Update notices only") {
            statusContent
            Text("Control checks for newer CLI releases but never installs them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking for Darkbloom CLI updates")
                }
                Button(store.isRefreshing ? "Checking…" : "Check for updates") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)
                .accessibilityIdentifier("settings.cli-update.check")
            }
        }
        .task { store.start() }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch store.status {
        case .available(let value, let capturedAt):
            notice(for: value, checkedAt: capturedAt, isStale: false)
        case .stale(let value, let capturedAt, _):
            notice(for: value, checkedAt: capturedAt, isStale: true)
        case .unavailable:
            VStack(alignment: .leading, spacing: 4) {
                Label("Could not check for CLI updates", systemImage: "questionmark.circle")
                    .font(.headline)
                Text("No update status is available. Try checking again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func notice(
        for value: CLIUpdateStatus,
        checkedAt: Date,
        isStale: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch value {
            case .upToDate(let version):
                Label("Darkbloom CLI is up to date", systemImage: "checkmark.circle")
                    .font(.headline)
                Text("Version \(version) is current.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .updateAvailable(let current, let latest):
                Label("Darkbloom CLI update available", systemImage: "arrow.down.circle")
                    .font(.headline)
                Text("Version \(latest) is available; the current CLI reports \(current). Review the update in Darkbloom when ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .restartRequired(let current, let installed):
                Label("Darkbloom CLI restart required", systemImage: "arrow.clockwise.circle")
                    .font(.headline)
                Text("Version \(installed) is installed, while the current CLI process is \(current). Restart Darkbloom to activate it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .quarantined(let version):
                Label("Darkbloom release quarantined", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Darkbloom reports release \(version) is quarantined on this machine. No change was made.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if isStale {
                Text("The latest check failed. This status may have changed.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Last checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
