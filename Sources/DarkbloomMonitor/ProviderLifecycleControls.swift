import DarkbloomTelemetry
import Foundation
import SwiftUI

struct ProviderLifecycleSourceInput: Equatable {
    let daemonState: SourceAvailability<DaemonState>
    let status: SourceAvailability<StatusSnapshot>
    let controlDaemonState: ProviderControlSourceState?
    let currentTime: Date

    var providerKnownRunning: Bool? {
        if case .available(let status, _) = status,
           let statusValue = Self.runningState(from: status.daemon) {
            return statusValue
        }
        if case .available = daemonState {
            return true
        }
        if hasCurrentControlDaemonEvidence {
            return true
        }
        return nil
    }

    private var hasCurrentControlDaemonEvidence: Bool {
        controlDaemonState?.evaluated(
            at: currentTime,
            invalidReason: "Provider activity timestamp is invalid",
            staleReason: "Provider activity is stale",
            futureReason: "Provider activity timestamp is in the future"
        ).isMarkedFresh == true
    }

    private static func runningState(from daemonStatus: String?) -> Bool? {
        guard let daemonStatus else { return nil }
        let normalized = daemonStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("running") { return true }
        if normalized.hasPrefix("stopped") || normalized.hasPrefix("not running") { return false }
        return nil
    }
}

struct ProviderLifecyclePresentation: Equatable {
    let canStart: Bool
    let canStop: Bool
    let canRestart: Bool
    let unavailableReason: String?

    static func make(
        sourceInput: ProviderLifecycleSourceInput,
        operation: ProviderOperation,
        enabledModels: [String]
    ) -> Self {
        make(
            providerKnownRunning: sourceInput.providerKnownRunning,
            operation: operation,
            enabledModels: enabledModels
        )
    }

    static func make(
        providerKnownRunning: Bool?,
        operation: ProviderOperation,
        enabledModels: [String]
    ) -> Self {
        guard operation == .idle else {
            return Self(
                canStart: false,
                canStop: false,
                canRestart: false,
                unavailableReason: "Another provider action is in progress"
            )
        }
        guard let providerKnownRunning else {
            return Self(
                canStart: false,
                canStop: false,
                canRestart: false,
                unavailableReason: "Provider state is unavailable"
            )
        }
        if providerKnownRunning {
            return Self(
                canStart: false,
                canStop: true,
                canRestart: true,
                unavailableReason: nil
            )
        }
        guard !enabledModels.isEmpty else {
            return Self(
                canStart: false,
                canStop: false,
                canRestart: false,
                unavailableReason: "Start requires at least one saved enabled model"
            )
        }
        return Self(
            canStart: true,
            canStop: false,
            canRestart: false,
            unavailableReason: nil
        )
    }

}

enum ProviderLifecycleControl: CaseIterable {
    case start
    case stop
    case restart

    var action: ProviderLifecycleAction {
        switch self {
        case .start: .start
        case .stop: .stop
        case .restart: .restart
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .start: "Start Darkbloom provider"
        case .stop: "Stop Darkbloom provider"
        case .restart: "Restart Darkbloom provider"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .start: "provider.start"
        case .stop: "provider.stop"
        case .restart: "provider.restart"
        }
    }

    func isActive(in operation: ProviderOperation) -> Bool {
        operation == .lifecycle(action)
    }

    func isEnabled(in presentation: ProviderLifecyclePresentation) -> Bool {
        switch self {
        case .start: presentation.canStart
        case .stop: presentation.canStop
        case .restart: presentation.canRestart
        }
    }
}

struct LifecycleConfirmationPresentation: Equatable {
    let title: String
    let body: String
    let confirmLabel: String

    static func make(_ confirmation: LifecycleConfirmation) -> Self {
        let body = switch confirmation.risk {
        case .active:
            "A customer job is currently running. Continuing will interrupt it."
        case .unknown:
            "Darkbloom Monitor cannot confirm whether a customer job is running. Continuing may interrupt customer work."
        case .idle:
            "Darkbloom reports no active customer job."
        }
        let confirmLabel = switch confirmation.risk {
        case .unknown:
            "Continue Anyway"
        case .active, .idle:
            confirmation.action == .stop ? "Stop Anyway" : "Restart Anyway"
        }
        return Self(
            title: "Customer work may be interrupted",
            body: body,
            confirmLabel: confirmLabel
        )
    }
}

extension LifecycleConfirmation: Identifiable {
    var id: ProviderLifecycleAction { action }
}

@MainActor
final class LifecycleConfirmationDismissalCoordinator {
    private var generation: UInt64 = 0
    private var confirmationInProgress = false

    func beginConfirmation() {
        generation &+= 1
        confirmationInProgress = true
    }

    func endConfirmation() {
        confirmationInProgress = false
    }

    func scheduleCancellation(
        isPending: @escaping @MainActor () -> Bool,
        cancel: @escaping @MainActor () -> Void
    ) {
        generation &+= 1
        let scheduledGeneration = generation
        Task { @MainActor in
            await Task.yield()
            guard generation == scheduledGeneration,
                  !confirmationInProgress,
                  isPending()
            else { return }
            cancel()
        }
    }
}

@MainActor
struct ProviderLifecycleControls: View {
    @ObservedObject var store: ProviderControlStore
    @State private var dismissalCoordinator = LifecycleConfirmationDismissalCoordinator()
    let snapshot: TelemetrySnapshot
    let currentTime: Date?

    init(
        store: ProviderControlStore,
        snapshot: TelemetrySnapshot,
        currentTime: Date? = nil
    ) {
        self.store = store
        self.snapshot = snapshot
        self.currentTime = currentTime
    }

    private func presentation(currentTime: Date) -> ProviderLifecyclePresentation {
        .make(
            sourceInput: ProviderLifecycleSourceInput(
                daemonState: snapshot.state,
                status: snapshot.status,
                controlDaemonState: store.snapshot?.sources.daemon,
                currentTime: currentTime
            ),
            operation: store.operation,
            enabledModels: store.draft?.original.enabled
                ?? store.snapshot?.draft.original.enabled
                ?? []
        )
    }

    var body: some View {
        Group {
            if let currentTime {
                controls(currentTime: currentTime)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    controls(currentTime: context.date)
                }
            }
        }
        .alert(item: confirmation) { confirmation in
            let alert = LifecycleConfirmationPresentation.make(confirmation)
            return Alert(
                title: Text(alert.title),
                message: Text(alert.body),
                primaryButton: .destructive(Text(alert.confirmLabel)) {
                    dismissalCoordinator.beginConfirmation()
                    Task {
                        defer { dismissalCoordinator.endConfirmation() }
                        await store.confirmPendingLifecycle()
                    }
                },
                secondaryButton: .cancel {
                    store.cancelPendingLifecycle()
                }
            )
        }
    }

    private func controls(currentTime: Date) -> some View {
        let presentation = presentation(currentTime: currentTime)
        return HStack(spacing: 6) {
            if let unavailableReason = presentation.unavailableReason {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(unavailableReason)
                    .accessibilityLabel(unavailableReason)
            }

            ForEach(ProviderLifecycleControl.allCases, id: \.self) { control in
                Button {
                    Task { await store.request(control.action) }
                } label: {
                    Group {
                        if control.isActive(in: store.operation) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: control.systemImage)
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!control.isEnabled(in: presentation))
                .help(control.accessibilityLabel)
                .accessibilityLabel(control.accessibilityLabel)
                .accessibilityIdentifier(control.accessibilityIdentifier)
            }
        }
    }

    private var confirmation: Binding<LifecycleConfirmation?> {
        Binding(
            get: { store.pendingConfirmation },
            set: { confirmation in
                guard confirmation == nil else { return }
                dismissalCoordinator.scheduleCancellation(
                    isPending: { store.pendingConfirmation != nil },
                    cancel: { store.cancelPendingLifecycle() }
                )
            }
        )
    }
}
