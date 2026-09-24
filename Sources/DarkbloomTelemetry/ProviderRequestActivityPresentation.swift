import Foundation

public enum ProviderRequestActivityMode: Equatable, Sendable {
    case idle
    case active
    case draining
    case stopped
    case unavailable
}

/// Honest request-count copy for the provider panel. The serving daemon only
/// reports a Boolean inference signal, so an active value is a lower bound;
/// the native drain lifecycle reports an exact remaining count.
public struct ProviderRequestActivityPresentation: Equatable, Sendable {
    public let mode: ProviderRequestActivityMode
    public let value: String
    public let status: String
    public let detail: String

    public static func make(daemonState: DaemonState?) -> Self {
        guard let daemonState else {
            return Self(
                mode: .unavailable,
                value: "—",
                status: "Unavailable",
                detail: "Provider request activity is not available."
            )
        }

        if let lifecycle = daemonState.lifecycle, lifecycle.outcome == .draining {
            guard let remaining = lifecycle.remainingRequests else {
                return Self(
                    mode: .draining,
                    value: "—",
                    status: "Draining",
                    detail: "New requests are paused; waiting for a remaining-request count."
                )
            }
            if remaining == 0, lifecycle.coordinatorAcknowledged == false {
                return Self(
                    mode: .draining,
                    value: "0",
                    status: "Finishing",
                    detail: "Requests have finished; confirming usage before shutdown."
                )
            }
            return Self(
                mode: .draining,
                value: String(remaining),
                status: "Draining",
                detail: "Accepted requests remaining; new requests are paused."
            )
        }

        if let lifecycle = daemonState.lifecycle,
           lifecycle.outcome == .drained || lifecycle.outcome == .stopped {
            return Self(
                mode: .stopped,
                value: "0",
                status: "Stopped",
                detail: "No provider requests are running."
            )
        }

        if daemonState.inferenceActive {
            return Self(
                mode: .active,
                value: "1+",
                status: "Active",
                detail: "At least one request is active; an exact live count is not reported while serving."
            )
        }

        return Self(
            mode: .idle,
            value: "0",
            status: "Idle",
            detail: "No inference is currently active; queued requests are not reported."
        )
    }
}
