import DarkbloomTelemetry
import Foundation
import SwiftUI

/// The activity evidence last observed by a queued stop. This deliberately
/// contains no source diagnostics: provider state can include paths, command
/// output, or other data that should never reach the UI.
enum ProviderQueuedStopObservation: Equatable, Sendable {
    case active
    case unknown
    case idle

    init(_ risk: ProviderActivityRisk) {
        switch risk {
        case .active: self = .active
        case .idle: self = .idle
        case .unknown: self = .unknown
        }
    }
}

enum ProviderQueuedStopPhase: Equatable, Sendable {
    case waiting
    case stopping
}

struct ProviderQueuedStopState: Equatable, Sendable {
    let phase: ProviderQueuedStopPhase
    let requestedAt: Date
    let lastCheckedAt: Date?
    let lastObservation: ProviderQueuedStopObservation?

    init(
        phase: ProviderQueuedStopPhase = .waiting,
        requestedAt: Date,
        lastCheckedAt: Date? = nil,
        lastObservation: ProviderQueuedStopObservation? = nil
    ) {
        self.phase = phase
        self.requestedAt = requestedAt
        self.lastCheckedAt = lastCheckedAt
        self.lastObservation = lastObservation
    }
}

struct ProviderQueuedStopPresentation: Equatable {
    let title: String
    let detail: String
    let actionLabel: String
    let canCancel: Bool

    static func make(
        state: ProviderQueuedStopState,
        now: Date = Date()
    ) -> Self {
        switch state.phase {
        case .stopping:
            return Self(
                title: "Stopping provider…",
                detail: "Darkbloom is completing its native graceful shutdown.",
                actionLabel: "Stopping…",
                canCancel: false
            )
        case .waiting:
            let detail: String
            switch state.lastObservation {
            case .active, .none:
                detail = ""
            case .unknown:
                detail = "Waiting for fresh provider activity before stopping."
            case .idle:
                detail = "Rechecking provider activity before stopping."
            }
            let ageDetail: String
            if let age = state.lastCheckedAt.map({ max(0, now.timeIntervalSince($0)) }),
               age.isFinite, age <= 60 {
                ageDetail = "Last activity check \(Int(age.rounded()))s ago."
            } else {
                ageDetail = "Activity has not produced a fresh check yet."
            }
            return Self(
                title: "Waiting for current work to finish",
                detail: [detail, ageDetail].filter { !$0.isEmpty }.joined(separator: " ")
                    + " Keep Darkbloom Control open while this is queued.",
                actionLabel: "Cancel queued stop",
                canCancel: true
            )
        }
    }
}

/// Compact lifecycle UI for a stop that waits for a fresh idle observation.
/// The queue itself lives in `ProviderControlStore`, so closing the popover or
/// dashboard does not discard it. It is intentionally in-memory and therefore
/// ends when the app process exits.
@MainActor
struct ProviderQueuedStopView: View {
    @ObservedObject var store: ProviderControlStore
    let providerIsRunning: Bool
    let currentTime: Date

    init(
        store: ProviderControlStore,
        providerIsRunning: Bool,
        currentTime: Date = Date()
    ) {
        self.store = store
        self.providerIsRunning = providerIsRunning
        self.currentTime = currentTime
    }

    var body: some View {
        if let state = store.queuedStopState {
            let presentation = ProviderQueuedStopPresentation.make(
                state: state,
                now: currentTime
            )
            VStack(alignment: .trailing, spacing: 3) {
                Label(presentation.title, systemImage: state.phase == .stopping
                    ? "stop.fill" : "stopwatch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("provider.queued-stop.pending")
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: ProviderLifecycleUnavailableReasonPresentation.maxWidth,
                           alignment: .trailing)
                if presentation.canCancel {
                    Button(presentation.actionLabel) {
                        store.cancelQueuedStop()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("provider.queued-stop.cancel")
                }
            }
            .frame(maxWidth: ProviderLifecycleUnavailableReasonPresentation.maxWidth,
                   alignment: .trailing)
        } else if providerIsRunning {
            Button {
                store.queueStopWhenIdle()
            } label: {
                Label("Stop when idle", systemImage: "stopwatch")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.canQueueStop)
            .help("Queue a stop after fresh provider activity reports no current work")
            .accessibilityLabel("Stop provider when idle")
            .accessibilityIdentifier("provider.queued-stop")
        }
    }
}
