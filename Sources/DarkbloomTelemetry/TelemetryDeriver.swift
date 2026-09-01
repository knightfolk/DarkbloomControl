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
        guard elapsed > 0 else {
            return .unavailable(reason: "State timestamp did not advance")
        }

        let generated = current.stats.tokensGenerated - previous.stats.tokensGenerated
        guard generated >= 0 else {
            return .unavailable(reason: "Token counter moved backwards")
        }
        guard generated > 0 else {
            return .unavailable(reason: "No token progress in the polling window")
        }

        return .available(tokensPerSecond: Double(generated) / elapsed, label: "derived")
    }

    public static func uptime(state: DaemonState, now: TimeInterval) -> TimeInterval? {
        let value = now - state.startedAt
        return value >= 0 ? value : nil
    }

    public static func snapshotAge(state: DaemonState, now: TimeInterval) -> TimeInterval? {
        let value = now - state.writtenAt
        return value >= 0 ? value : nil
    }
}
