import Foundation

public enum TelemetryDeriver {
    public static func tokenRate(previous: DaemonState?, current: DaemonState) -> TokenRate {
        guard let previous else {
            return .unavailable(reason: "Waiting for a second telemetry sample")
        }
        guard previous.processIdentity == current.processIdentity else {
            return .unavailable(reason: "Provider process changed between samples")
        }

        let elapsed = current.writtenAt - previous.writtenAt
        guard elapsed.isFinite else {
            return .unavailable(reason: "State timestamp delta is not finite")
        }
        guard elapsed > 0 else {
            return .unavailable(reason: "State timestamp did not advance")
        }

        let (generated, overflow) = current.stats.tokensGenerated
            .subtractingReportingOverflow(previous.stats.tokensGenerated)
        guard !overflow else {
            return .unavailable(reason: "Token counter overflowed")
        }
        guard generated >= 0 else {
            return .unavailable(reason: "Token counter moved backwards")
        }
        guard generated > 0 else {
            return .unavailable(reason: "No token progress in the polling window")
        }

        let tokensPerSecond = Double(generated) / elapsed
        guard tokensPerSecond.isFinite else {
            return .unavailable(reason: "Derived token rate is not finite")
        }
        return .available(tokensPerSecond: tokensPerSecond, label: "derived")
    }

    public static func uptime(state: DaemonState, now: TimeInterval) -> DerivedDuration {
        let value = now - state.startedAt
        return value >= 0
            ? .available(seconds: value, label: "derived")
            : .unavailable(reason: "Provider start time is in the future")
    }

    public static func snapshotAge(state: DaemonState, now: TimeInterval) -> DerivedDuration {
        let value = now - state.writtenAt
        return value >= 0
            ? .available(seconds: value, label: "derived")
            : .unavailable(reason: "State write time is in the future")
    }

    public static func trustAge(state: DaemonState, now: TimeInterval) -> DerivedDuration {
        let value = now - state.trust.receivedAt
        return value >= 0
            ? .available(seconds: value, label: "derived")
            : .unavailable(reason: "Trust receipt time is in the future")
    }
}
