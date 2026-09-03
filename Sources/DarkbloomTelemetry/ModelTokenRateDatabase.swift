import Foundation
import SQLite3

public protocol ModelTokenRateRecording: Sendable {
    func record(
        model: String,
        tokensPerSecond: Double,
        capturedAt: Date,
        processIdentity: ProcessIdentity,
        writtenAt: TimeInterval
    ) async throws

    func averages(
        from start: Date,
        through end: Date
    ) async throws -> [ModelTokenRateAverage]
}

public enum ModelTokenRateDatabaseError: Error, LocalizedError, Sendable {
    case sqlite(message: String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Local token-rate database error — \(message)"
        }
    }
}

public actor ModelTokenRateDatabase: ModelTokenRateRecording {
    private var connection: ModelRateSQLiteConnection?

    public init(url: URL) throws {
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
            throw ModelTokenRateDatabaseError.sqlite(message: "could not open database")
        }
        connection = ModelRateSQLiteConnection(pointer: database)
        sqlite3_busy_timeout(database, 2_000)

        do {
            try Self.execute(database, sql: "PRAGMA journal_mode=WAL")
            try Self.execute(database, sql: "PRAGMA synchronous=NORMAL")
            try Self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS token_rate_samples (
                    captured_at REAL NOT NULL,
                    model TEXT NOT NULL,
                    tokens_per_second REAL NOT NULL,
                    pid INTEGER NOT NULL,
                    start_time_micros INTEGER NOT NULL,
                    written_at REAL NOT NULL,
                    PRIMARY KEY (pid, start_time_micros, written_at)
                )
                """)
            try Self.execute(database, sql: """
                CREATE INDEX IF NOT EXISTS token_rate_samples_captured_at
                ON token_rate_samples (captured_at)
                """)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            connection = nil
            throw error
        }
    }

    public func record(
        model: String,
        tokensPerSecond: Double,
        capturedAt: Date,
        processIdentity: ProcessIdentity,
        writtenAt: TimeInterval
    ) throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              tokensPerSecond.isFinite,
              tokensPerSecond > 0,
              capturedAt.timeIntervalSince1970.isFinite,
              writtenAt.isFinite
        else { return }

        let statement = try prepare("""
            INSERT OR IGNORE INTO token_rate_samples
                (captured_at, model, tokens_per_second, pid, start_time_micros, written_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, capturedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, model, -1, modelRateSQLiteTransient)
        sqlite3_bind_double(statement, 3, tokensPerSecond)
        sqlite3_bind_int64(statement, 4, Int64(processIdentity.pid))
        sqlite3_bind_int64(statement, 5, processIdentity.startTimeMicros)
        sqlite3_bind_double(statement, 6, writtenAt)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    public func averages(
        from start: Date,
        through end: Date
    ) throws -> [ModelTokenRateAverage] {
        guard start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite,
              end >= start
        else { return [] }

        let prune = try prepare("DELETE FROM token_rate_samples WHERE captured_at < ?")
        sqlite3_bind_double(prune, 1, start.timeIntervalSince1970)
        defer { sqlite3_finalize(prune) }
        guard sqlite3_step(prune) == SQLITE_DONE else { throw lastError() }

        let statement = try prepare("""
            SELECT model, AVG(tokens_per_second), COUNT(*)
            FROM token_rate_samples
            WHERE captured_at >= ? AND captured_at <= ?
            GROUP BY model
            ORDER BY model ASC
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)

        var values: [ModelTokenRateAverage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let modelCString = sqlite3_column_text(statement, 0) else { continue }
            values.append(ModelTokenRateAverage(
                model: String(cString: modelCString),
                tokensPerSecond: sqlite3_column_double(statement, 1),
                sampleCount: Int(sqlite3_column_int64(statement, 2))
            ))
        }
        return values
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = try requireConnection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw lastError() }
        return statement
    }

    private func requireConnection() throws -> OpaquePointer {
        guard let connection else {
            throw ModelTokenRateDatabaseError.sqlite(message: "database is closed")
        }
        return connection.pointer
    }

    private func lastError() -> ModelTokenRateDatabaseError {
        let message = connection.map(\.pointer).flatMap(sqlite3_errmsg).map(String.init(cString:))
            ?? "unknown SQLite failure"
        return .sqlite(message: message)
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite failure"
            sqlite3_free(errorMessage)
            throw ModelTokenRateDatabaseError.sqlite(message: message)
        }
    }
}

private final class ModelRateSQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

private let modelRateSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
