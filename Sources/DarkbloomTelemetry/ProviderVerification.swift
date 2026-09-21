import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Read-only verification guidance derived from one daemon snapshot. It does
/// not grant serving access; the coordinator remains authoritative for every
/// request. The result deliberately exposes booleans and bounded text so a UI
/// can explain why an observation is not currently trustworthy without
/// printing session, machine, or coordinator prose.
public struct ProviderVerification: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case verified
        case legacy
        case unconfirmed
        case stale
        case wrongProcess
        case wrongCoordinator
        case offline
        case unsupportedProtocol
        case expired
        case incomplete
    }

    public let state: State
    public let title: String
    public let detail: String
    public let processMatches: Bool
    public let coordinatorMatches: Bool
    public let snapshotFresh: Bool
    public let trustFresh: Bool
    public let receivedAfterStarted: Bool
    public let online: Bool
    public let protocolSupported: Bool
    public let appAttestUnexpired: Bool
    public let sessionIDPresent: Bool
    public let machineIDPresent: Bool

    public var isVerified: Bool { state == .verified || state == .legacy }
    public var hasSessionID: Bool { sessionIDPresent }
    public var hasMachineID: Bool { machineIDPresent }

    public static let snapshotMaxAge: TimeInterval = 10
    public static let allowedFutureSkew: TimeInterval = 2

    /// Evaluates only bounded, locally observable facts. When the caller does
    /// not provide a live identity, this method reads the kernel's process
    /// record for `state.pid`; it never treats PID existence as sufficient.
    public static func evaluate(
        state: DaemonState,
        expectedCoordinator: String?,
        now: Date,
        liveProcessIdentity: ProcessIdentity? = nil
    ) -> Self {
        let nowSeconds = now.timeIntervalSince1970
        let snapshotFresh = isFresh(state.writtenAt, now: nowSeconds)
        let trustFresh = isFresh(state.trust.receivedAt, now: nowSeconds)
        let receivedAfterStarted = state.trust.receivedAt.isFinite
            && state.startedAt.isFinite
            && state.trust.receivedAt >= state.startedAt
        let online = state.trust.status.lowercased() == "online"

        let liveIdentity = liveProcessIdentity ?? ProcessIdentity.read(pid: state.pid)
        let processMatches = liveIdentity == state.processIdentity
            && liveIdentity?.pid == state.pid
        let coordinatorMatches = matches(
            observed: state.coordinatorURL,
            expected: expectedCoordinator
        )

        let authorization = state.trust.authorization
        let protocolSupported = authorization?.protocolVersion == 1
        let appAttestPath = authorization?.path.lowercased() == "app_attest"
        let appAttestUnexpired: Bool
        if let expiresAt = authorization?.expiresAt,
           expiresAt.isFinite,
           nowSeconds.isFinite {
            appAttestUnexpired = expiresAt > nowSeconds
        } else {
            appAttestUnexpired = false
        }
        let sessionIDPresent = authorization?.sessionIDPresent == true
        let machineIDPresent = authorization?.machineIDPresent == true

        var resultState: State
        var title: String
        var detail: String

        if !processMatches {
            resultState = .wrongProcess
            title = "Verification unavailable"
            detail = "The state snapshot does not match the provider process currently running."
        } else if !coordinatorMatches {
            resultState = .wrongCoordinator
            title = "Verification unavailable"
            detail = "The state snapshot belongs to a different or unconfirmed coordinator."
        } else if !snapshotFresh || !trustFresh {
            resultState = .stale
            title = "Verification needs refresh"
            detail = "Daemon or coordinator trust telemetry is older than 10 seconds."
        } else if !receivedAfterStarted {
            resultState = .incomplete
            title = "Verification unavailable"
            detail = "Coordinator trust predates this provider start."
        } else if !online {
            resultState = .offline
            title = "Provider offline"
            detail = "The latest coordinator trust status is not online."
        } else if authorization == nil {
            // Pre-App-Attest snapshots can still carry the legacy hardware
            // trust path. Do not call an arbitrary online snapshot verified.
            if ["hardware", "mda_verified"].contains(state.trust.level.lowercased()) {
                resultState = .legacy
                title = "Legacy verification"
                detail = "Fresh legacy verification is present; keep the Darkbloom management profile installed."
            } else {
                resultState = .unconfirmed
                title = "Verification unconfirmed"
                detail = "Fresh coordinator authorization diagnostics are not present."
            }
        } else if !protocolSupported {
            resultState = .unsupportedProtocol
            title = "App Attest unavailable"
            detail = "The coordinator authorization protocol is not supported by this monitor."
        } else if authorization?.path.lowercased() == "legacy" {
            resultState = .legacy
            title = "Legacy verification"
            detail = "Fresh legacy verification is present; keep the Darkbloom management profile installed."
        } else if !appAttestPath {
            resultState = .unconfirmed
            title = "App Attest unconfirmed"
            detail = "The coordinator did not report a recognized App Attest authorization path."
        } else if !appAttestUnexpired {
            resultState = .expired
            title = "App Attest expired"
            detail = "The App Attest authorization lease is missing or expired."
        } else if !sessionIDPresent || !machineIDPresent {
            resultState = .incomplete
            title = "App Attest unconfirmed"
            detail = "App Attest telemetry is missing a required lease identity."
        } else {
            resultState = .verified
            title = "App Attest verified"
            detail = "Fresh coordinator authorization is present for this provider process."
        }

        return Self(
            state: resultState,
            title: title,
            detail: detail,
            processMatches: processMatches,
            coordinatorMatches: coordinatorMatches,
            snapshotFresh: snapshotFresh,
            trustFresh: trustFresh,
            receivedAfterStarted: receivedAfterStarted,
            online: online,
            protocolSupported: protocolSupported,
            appAttestUnexpired: appAttestUnexpired,
            sessionIDPresent: sessionIDPresent,
            machineIDPresent: machineIDPresent
        )
    }

    private static func isFresh(_ timestamp: TimeInterval, now: TimeInterval) -> Bool {
        guard timestamp.isFinite, now.isFinite else { return false }
        return timestamp <= now + allowedFutureSkew
            && now - timestamp <= snapshotMaxAge
    }

    private static func matches(observed: String?, expected: String?) -> Bool {
        guard let observed = normalizeCoordinator(observed),
              let expected = normalizeCoordinator(expected) else {
            return false
        }
        return observed == expected
    }

    private static func normalizeCoordinator(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let scheme: String
        switch rawScheme {
        case "wss", "https": scheme = "https"
        case "ws", "http": scheme = "http"
        default: return nil
        }

        let suppliedPort = components.port
        let defaultPort = (scheme == "https" ? 443 : 80)
        let port = suppliedPort.map { $0 == defaultPort ? "" : ":\($0)" } ?? ""
        var path = components.path
        if path == "/ws/provider" { path = "" }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(scheme)://\(host.lowercased())\(port)"
            + (path.isEmpty ? "" : "/\(path)")
    }
}

public extension ProcessIdentity {
    /// Reads a PID and its kernel-recorded start time. A missing or reused PID
    /// returns nil, allowing verification to fail closed.
    static func read(pid: Int32) -> ProcessIdentity? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let size = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, expectedSize)
        }
        guard size == expectedSize else { return nil }

        let seconds = Int64(info.pbi_start_tvsec)
        let micros = Int64(info.pbi_start_tvusec)
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000_000)
        let base = multiplied.partialValue
        guard !multiplied.overflow,
              seconds >= 0, micros >= 0, micros < 1_000_000,
              base <= Int64.max - micros else {
            return nil
        }
        return ProcessIdentity(pid: pid, startTimeMicros: base + micros)
        #else
        return nil
        #endif
    }

    static func current() -> ProcessIdentity? {
        #if canImport(Darwin)
        return read(pid: getpid())
        #else
        return nil
        #endif
    }

    func isCurrent() -> Bool {
        Self.read(pid: pid) == self
    }
}
