import Foundation
import SQLite3

public enum ObservedUptimeValue: Equatable, Sendable {
    case warming(observedSeconds: TimeInterval)
    case available(percent: Double, observedSeconds: TimeInterval)
    case unavailable(reason: String)

    public var accessibilityDescription: String {
        switch self {
        case .warming(let observedSeconds):
            "Monitor-observed uptime is warming up with \(Self.coverage(observedSeconds)) of classified coverage."
        case .available(let percent, let observedSeconds):
            "Monitor-observed rolling 24-hour uptime is \(Self.rounded(percent)) percent with \(Self.coverage(observedSeconds)) of classified coverage."
        case .unavailable(let reason):
            "Monitor-observed uptime unavailable: \(reason)."
        }
    }

    public var compactPercent: String? {
        guard case .available(let percent, _) = self else { return nil }
        return "\(Self.rounded(percent))%"
    }

    public var fraction: Double? {
        guard case .available(let percent, _) = self else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    private static func rounded(_ percent: Double) -> Int {
        Int(percent.rounded())
    }

    private static func coverage(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 {
            return String(format: "%.1f hours", locale: Locale(identifier: "en_US_POSIX"), seconds / 3_600)
        }
        return "\(Int(seconds / 60)) minutes"
    }
}

public enum ObservedUptimeDatabaseError: Error, LocalizedError, Sendable {
    case sqlite(message: String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Local observed-uptime database error — \(message)"
        }
    }
}

public protocol ObservedUptimeRecording: Sendable {
    func record(status: MenuPresentationStatus, at date: Date) async throws -> ObservedUptimeValue
}

public actor ObservedUptimeDatabase: ObservedUptimeRecording {
    public static let rollingWindow: TimeInterval = 24 * 60 * 60
    public static let freshnessCarry: TimeInterval = 10
    public static let warmupDuration: TimeInterval = 5 * 60

    private enum ObservationState: Int32 {
        case unknown = 0
        case online = 1
        case offline = 2

        init(_ status: MenuPresentationStatus) {
            switch status {
            case .online: self = .online
            case .offline: self = .offline
            case .stale, .unavailable: self = .unknown
            }
        }
    }

    private struct Observation {
        let timestamp: TimeInterval
        let state: ObservationState
    }

    private let connection: ObservedUptimeSQLiteConnection
    private let window: TimeInterval
    private let maximumCarry: TimeInterval
    private let minimumObservedDuration: TimeInterval

    public init(url: URL) throws {
        try self.init(
            url: url,
            window: Self.rollingWindow,
            maximumCarry: Self.freshnessCarry,
            minimumObservedDuration: Self.warmupDuration
        )
    }

    init(
        url: URL,
        window: TimeInterval,
        maximumCarry: TimeInterval,
        minimumObservedDuration: TimeInterval
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ObservedUptimeDatabaseError.sqlite(message: "could not open database")
        }
        connection = ObservedUptimeSQLiteConnection(pointer: database)
        self.window = window
        self.maximumCarry = maximumCarry
        self.minimumObservedDuration = minimumObservedDuration
        sqlite3_busy_timeout(database, 2_000)

        do {
            try Self.execute(database, sql: "PRAGMA journal_mode=WAL")
            try Self.execute(database, sql: "PRAGMA synchronous=NORMAL")
            try Self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS uptime_observations (
                    observed_at REAL PRIMARY KEY,
                    state INTEGER NOT NULL CHECK (state BETWEEN 0 AND 2)
                )
                """)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw error
        }
    }

    public func record(
        status: MenuPresentationStatus,
        at date: Date
    ) throws -> ObservedUptimeValue {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite else {
            throw ObservedUptimeDatabaseError.sqlite(message: "observation timestamp is not finite")
        }

        let database = connection.pointer
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT OR REPLACE INTO uptime_observations (observed_at, state) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, timestamp)
        sqlite3_bind_int(statement, 2, ObservationState(status).rawValue)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }

        try prune(at: timestamp)
        return try snapshot(at: date)
    }

    public func snapshot(at date: Date) throws -> ObservedUptimeValue {
        let now = date.timeIntervalSince1970
        guard now.isFinite else {
            throw ObservedUptimeDatabaseError.sqlite(message: "snapshot timestamp is not finite")
        }
        try prune(at: now)

        let cutoff = now - window
        let observations = try observations(from: cutoff - maximumCarry, through: now)
        var onlineSeconds: TimeInterval = 0
        var offlineSeconds: TimeInterval = 0

        for (index, observation) in observations.enumerated() {
            let nextTimestamp = index + 1 < observations.count
                ? observations[index + 1].timestamp
                : now
            let start = max(observation.timestamp, cutoff)
            let end = min(nextTimestamp, observation.timestamp + maximumCarry, now)
            guard end > start else { continue }

            switch observation.state {
            case .online: onlineSeconds += end - start
            case .offline: offlineSeconds += end - start
            case .unknown: break
            }
        }

        let observedSeconds = onlineSeconds + offlineSeconds
        guard observedSeconds >= minimumObservedDuration else {
            return .warming(observedSeconds: observedSeconds)
        }
        let percent = min(max(onlineSeconds / observedSeconds * 100, 0), 100)
        return .available(percent: percent, observedSeconds: observedSeconds)
    }

    private func observations(
        from start: TimeInterval,
        through end: TimeInterval
    ) throws -> [Observation] {
        let database = connection.pointer
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT observed_at, state FROM uptime_observations WHERE observed_at >= ? AND observed_at <= ? ORDER BY observed_at",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, end)

        var result: [Observation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let state = ObservationState(rawValue: sqlite3_column_int(statement, 1)) else {
                continue
            }
            result.append(Observation(
                timestamp: sqlite3_column_double(statement, 0),
                state: state
            ))
        }
        return result
    }

    private func prune(at now: TimeInterval) throws {
        let database = connection.pointer
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "DELETE FROM uptime_observations WHERE observed_at < ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now - window - maximumCarry)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func lastError() -> ObservedUptimeDatabaseError {
        .sqlite(message: String(cString: sqlite3_errmsg(connection.pointer)))
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite failure"
            sqlite3_free(errorMessage)
            throw ObservedUptimeDatabaseError.sqlite(message: message)
        }
    }
}

private final class ObservedUptimeSQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}
