import Foundation
import SQLite3

public struct AccountBalanceSample: Equatable, Sendable {
    public let capturedAt: Date
    public let lifetimeMicroUSD: Int64
    public let availableMicroUSD: Int64
    public let withdrawableMicroUSD: Int64
    public let lifetimeCount: Int64

    public init(
        capturedAt: Date,
        lifetimeMicroUSD: Int64,
        availableMicroUSD: Int64,
        withdrawableMicroUSD: Int64,
        lifetimeCount: Int64
    ) {
        self.capturedAt = capturedAt
        self.lifetimeMicroUSD = lifetimeMicroUSD
        self.availableMicroUSD = availableMicroUSD
        self.withdrawableMicroUSD = withdrawableMicroUSD
        self.lifetimeCount = lifetimeCount
    }
}

public struct ModelEarnings: Equatable, Sendable {
    public let model: String
    public let microUSD: Int64
    public let jobs: Int64

    public init(model: String, microUSD: Int64, jobs: Int64) {
        self.model = model
        self.microUSD = microUSD
        self.jobs = jobs
    }
}

public struct RewardEarnings: Equatable, Sendable {
    public let microUSD: Int64
    public let events: Int64

    public init(microUSD: Int64, events: Int64) {
        self.microUSD = microUSD
        self.events = events
    }
}

public struct PayoutCalculation: Equatable, Sendable {
    public let withdrawableNowMicroUSD: Int64
    public let pendingSettlementMicroUSD: Int64
    public let paidOrDebitedMicroUSD: Int64
    public let withdrawableShare: Double

    public init(
        withdrawableNowMicroUSD: Int64,
        pendingSettlementMicroUSD: Int64,
        paidOrDebitedMicroUSD: Int64,
        withdrawableShare: Double
    ) {
        self.withdrawableNowMicroUSD = withdrawableNowMicroUSD
        self.pendingSettlementMicroUSD = pendingSettlementMicroUSD
        self.paidOrDebitedMicroUSD = paidOrDebitedMicroUSD
        self.withdrawableShare = withdrawableShare
    }
}

public enum EarningsDatabaseError: Error, LocalizedError, Sendable {
    case sqlite(message: String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Local earnings database error — \(message)"
        }
    }
}

public actor EarningsDatabase {
    private let url: URL
    private var connection: SQLiteConnection?

    public init(url: URL) throws {
        self.url = url
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
            throw EarningsDatabaseError.sqlite(message: "could not open database")
        }
        connection = SQLiteConnection(pointer: database)
        sqlite3_busy_timeout(database, 2_000)

        do {
            try Self.execute(database, sql: "PRAGMA journal_mode=WAL")
            try Self.execute(database, sql: "PRAGMA synchronous=NORMAL")
            try Self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS earnings_hourly (
                    hour_start REAL NOT NULL,
                    model TEXT NOT NULL,
                    amount_micro_usd INTEGER NOT NULL,
                    jobs INTEGER NOT NULL,
                    prompt_tokens INTEGER NOT NULL,
                    completion_tokens INTEGER NOT NULL,
                    PRIMARY KEY (hour_start, model)
                )
                """)
            try Self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS account_hourly (
                    hour_start REAL PRIMARY KEY,
                    captured_at REAL NOT NULL,
                    lifetime_micro_usd INTEGER NOT NULL,
                    available_micro_usd INTEGER NOT NULL,
                    withdrawable_micro_usd INTEGER NOT NULL,
                    lifetime_count INTEGER NOT NULL
                )
                """)
            try Self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS rewards_hourly (
                    hour_start REAL PRIMARY KEY,
                    amount_micro_usd INTEGER NOT NULL,
                    events INTEGER NOT NULL
                )
                """)
            try Self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS collection_state (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    last_earning_id INTEGER NOT NULL
                )
                """)
            try Self.execute(database, sql: """
                BEGIN IMMEDIATE;
                INSERT INTO rewards_hourly (hour_start, amount_micro_usd, events)
                SELECT hour_start, amount_micro_usd, jobs
                FROM earnings_hourly
                WHERE model = 'base_reward'
                ON CONFLICT(hour_start) DO UPDATE SET
                    amount_micro_usd = amount_micro_usd + excluded.amount_micro_usd,
                    events = events + excluded.events;
                DELETE FROM earnings_hourly WHERE model = 'base_reward';
                COMMIT;
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

    public func ingest(
        _ response: AccountEarningsResponse,
        capturedAt: Date
    ) throws {
        let database = try requireConnection()
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            try upsertHourlyEarnings(response, database: database)
            try upsertAccountSample(response, capturedAt: capturedAt, database: database)
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    public func hourBucketCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM earnings_hourly")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func accountSampleCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM account_hourly")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func rewardBucketCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM rewards_hourly")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func lastIngestedEarningID() throws -> Int64? {
        let statement = try prepare(
            "SELECT last_earning_id FROM collection_state WHERE singleton = 1"
        )
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw lastError()
        }
        return sqlite3_column_int64(statement, 0)
    }

    public func latestAccountSample() throws -> AccountBalanceSample? {
        let statement = try prepare("""
            SELECT captured_at, lifetime_micro_usd, available_micro_usd,
                   withdrawable_micro_usd, lifetime_count
            FROM account_hourly
            ORDER BY hour_start DESC
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw lastError()
        }
        return AccountBalanceSample(
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
            lifetimeMicroUSD: sqlite3_column_int64(statement, 1),
            availableMicroUSD: sqlite3_column_int64(statement, 2),
            withdrawableMicroUSD: sqlite3_column_int64(statement, 3),
            lifetimeCount: sqlite3_column_int64(statement, 4)
        )
    }

    public func earningsByModel(since: Date) throws -> [ModelEarnings] {
        let statement = try prepare("""
            SELECT model, SUM(amount_micro_usd), SUM(jobs)
            FROM earnings_hourly
            WHERE hour_start >= ?
            GROUP BY model
            ORDER BY model ASC
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)

        var values: [ModelEarnings] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let modelCString = sqlite3_column_text(statement, 0) else { continue }
            values.append(ModelEarnings(
                model: String(cString: modelCString),
                microUSD: sqlite3_column_int64(statement, 1),
                jobs: sqlite3_column_int64(statement, 2)
            ))
        }
        return values
    }

    public func rewardEarnings(since: Date) throws -> RewardEarnings {
        let statement = try prepare("""
            SELECT COALESCE(SUM(amount_micro_usd), 0), COALESCE(SUM(events), 0)
            FROM rewards_hourly
            WHERE hour_start >= ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return RewardEarnings(
            microUSD: sqlite3_column_int64(statement, 0),
            events: sqlite3_column_int64(statement, 1)
        )
    }

    public func latestPayoutCalculation() throws -> PayoutCalculation? {
        guard let sample = try latestAccountSample() else { return nil }
        let pending = max(sample.availableMicroUSD - sample.withdrawableMicroUSD, 0)
        let paidOrDebited = max(sample.lifetimeMicroUSD - sample.availableMicroUSD, 0)
        let share = sample.availableMicroUSD > 0
            ? Double(sample.withdrawableMicroUSD) / Double(sample.availableMicroUSD)
            : 0
        return PayoutCalculation(
            withdrawableNowMicroUSD: sample.withdrawableMicroUSD,
            pendingSettlementMicroUSD: pending,
            paidOrDebitedMicroUSD: paidOrDebited,
            withdrawableShare: share
        )
    }

    private struct BucketKey: Hashable {
        let hourStart: TimeInterval
        let model: String
    }

    private struct BucketValue {
        var amountMicroUSD: Int64 = 0
        var jobs: Int64 = 0
        var promptTokens: Int64 = 0
        var completionTokens: Int64 = 0
    }

    private struct RewardBucketValue {
        var amountMicroUSD: Int64 = 0
        var events: Int64 = 0
    }

    private func upsertHourlyEarnings(
        _ response: AccountEarningsResponse,
        database: OpaquePointer
    ) throws {
        guard !response.earnings.isEmpty else { return }
        let priorID = try lastIngestedEarningID()
        let existingBuckets = try hourBucketCount() + rewardBucketCount()
        let earnings: [AccountEarning]
        if let priorID {
            earnings = response.earnings.filter { $0.id > priorID }
        } else if existingBuckets > 0 {
            // A database created by the pre-incremental build already contains
            // this page. Establish the watermark without adding it twice.
            earnings = []
        } else {
            earnings = response.earnings
        }
        var buckets: [BucketKey: BucketValue] = [:]
        var rewardBuckets: [TimeInterval: RewardBucketValue] = [:]

        for earning in earnings {
            let hourStart = floor(earning.createdAt.timeIntervalSince1970 / 3_600) * 3_600
            if earning.model == "base_reward" {
                var reward = rewardBuckets[hourStart, default: RewardBucketValue()]
                reward.amountMicroUSD += earning.amountMicroUSD
                reward.events += 1
                rewardBuckets[hourStart] = reward
                continue
            }
            let key = BucketKey(hourStart: hourStart, model: earning.model)
            var value = buckets[key, default: BucketValue()]
            value.amountMicroUSD += earning.amountMicroUSD
            value.jobs += 1
            value.promptTokens += Int64(earning.promptTokens)
            value.completionTokens += Int64(earning.completionTokens)
            buckets[key] = value
        }

        let statement = try prepare("""
            INSERT INTO earnings_hourly
                (hour_start, model, amount_micro_usd, jobs, prompt_tokens, completion_tokens)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(hour_start, model) DO UPDATE SET
                amount_micro_usd = amount_micro_usd + excluded.amount_micro_usd,
                jobs = jobs + excluded.jobs,
                prompt_tokens = prompt_tokens + excluded.prompt_tokens,
                completion_tokens = completion_tokens + excluded.completion_tokens
            """)
        defer { sqlite3_finalize(statement) }
        for (key, value) in buckets {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_double(statement, 1, key.hourStart)
            sqlite3_bind_text(statement, 2, key.model, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 3, value.amountMicroUSD)
            sqlite3_bind_int64(statement, 4, value.jobs)
            sqlite3_bind_int64(statement, 5, value.promptTokens)
            sqlite3_bind_int64(statement, 6, value.completionTokens)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }

        let rewardStatement = try prepare("""
            INSERT INTO rewards_hourly (hour_start, amount_micro_usd, events)
            VALUES (?, ?, ?)
            ON CONFLICT(hour_start) DO UPDATE SET
                amount_micro_usd = amount_micro_usd + excluded.amount_micro_usd,
                events = events + excluded.events
            """)
        defer { sqlite3_finalize(rewardStatement) }
        for (hourStart, value) in rewardBuckets {
            sqlite3_reset(rewardStatement)
            sqlite3_clear_bindings(rewardStatement)
            sqlite3_bind_double(rewardStatement, 1, hourStart)
            sqlite3_bind_int64(rewardStatement, 2, value.amountMicroUSD)
            sqlite3_bind_int64(rewardStatement, 3, value.events)
            guard sqlite3_step(rewardStatement) == SQLITE_DONE else { throw lastError() }
        }

        if let newestID = response.earnings.map(\.id).max() {
            let watermark = max(priorID ?? newestID, newestID)
            let state = try prepare("""
                INSERT INTO collection_state (singleton, last_earning_id)
                VALUES (1, ?)
                ON CONFLICT(singleton) DO UPDATE SET last_earning_id = excluded.last_earning_id
                """)
            defer { sqlite3_finalize(state) }
            sqlite3_bind_int64(state, 1, watermark)
            guard sqlite3_step(state) == SQLITE_DONE else { throw lastError() }
        }
    }

    private func upsertAccountSample(
        _ response: AccountEarningsResponse,
        capturedAt: Date,
        database: OpaquePointer
    ) throws {
        if let latest = try latestAccountSample(),
           latest.lifetimeMicroUSD == response.totalMicroUSD,
           latest.availableMicroUSD == response.availableBalanceMicroUSD,
           latest.withdrawableMicroUSD == response.withdrawableBalanceMicroUSD,
           latest.lifetimeCount == response.count {
            return
        }
        let hourStart = floor(capturedAt.timeIntervalSince1970 / 3_600) * 3_600
        let statement = try prepare("""
            INSERT OR REPLACE INTO account_hourly
                (hour_start, captured_at, lifetime_micro_usd, available_micro_usd,
                 withdrawable_micro_usd, lifetime_count)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, hourStart)
        sqlite3_bind_double(statement, 2, capturedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, response.totalMicroUSD)
        sqlite3_bind_int64(statement, 4, response.availableBalanceMicroUSD)
        sqlite3_bind_int64(statement, 5, response.withdrawableBalanceMicroUSD)
        sqlite3_bind_int64(statement, 6, response.count)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
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
            throw EarningsDatabaseError.sqlite(message: "database is closed")
        }
        return connection.pointer
    }

    private func lastError() -> EarningsDatabaseError {
        let message = connection.map(\.pointer).flatMap(sqlite3_errmsg).map(String.init(cString:))
            ?? "unknown SQLite failure"
        return .sqlite(message: message)
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite failure"
            sqlite3_free(errorMessage)
            throw EarningsDatabaseError.sqlite(message: message)
        }
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
