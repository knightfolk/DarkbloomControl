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

public struct ObservedEarningsWindow: Equatable, Sendable {
    public let microUSD: Int64
    public let observedSeconds: TimeInterval
    public let calendarDayStart: Date?
    public let capturedAt: Date?
    public let coversDayToDate: Bool

    public init(microUSD: Int64, observedSeconds: TimeInterval,
                calendarDayStart: Date? = nil, capturedAt: Date? = nil,
                coversDayToDate: Bool = false) {
        self.microUSD = microUSD
        self.observedSeconds = observedSeconds
        self.calendarDayStart = calendarDayStart
        self.capturedAt = capturedAt
        self.coversDayToDate = coversDayToDate
    }
}

public struct CalendarWeekEarningsSummary: Equatable, Sendable {
    public let microUSD: Int64
    public let isComplete: Bool
    public let weekStart: Date?
    public let capturedAt: Date?

    public init(microUSD: Int64, isComplete: Bool, weekStart: Date? = nil, capturedAt: Date? = nil) {
        self.microUSD = microUSD
        self.isComplete = isComplete
        self.weekStart = weekStart
        self.capturedAt = capturedAt
    }

    public func isCurrent(at now: Date, calendar: Calendar) -> Bool {
        guard now.timeIntervalSince1970.isFinite, microUSD >= 0,
              let weekStart, let capturedAt, capturedAt >= weekStart,
              weekStart == calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return false }
        let age = now.timeIntervalSince(capturedAt)
        return age.isFinite && (0...600).contains(age)
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

public struct JobCompletionSummary: Equatable, Sendable {
    public let completedToday: Int64
    public let averagePerDay: Double?
    public let averagingDays: Int
    public let dayStart: Date?
    public let capturedAt: Date?

    public init(completedToday: Int64, averagePerDay: Double?, averagingDays: Int,
                dayStart: Date? = nil, capturedAt: Date? = nil) {
        self.completedToday = completedToday
        self.averagePerDay = averagePerDay
        self.averagingDays = averagingDays
        self.dayStart = dayStart
        self.capturedAt = capturedAt
    }

    public func isCurrent(at now: Date, calendar: Calendar) -> Bool {
        guard now.timeIntervalSince1970.isFinite, completedToday >= 0,
              let dayStart, let capturedAt, capturedAt >= dayStart,
              dayStart == calendar.startOfDay(for: now) else { return false }
        let age = now.timeIntervalSince(capturedAt)
        return age.isFinite && (0...600).contains(age)
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
                CREATE TABLE IF NOT EXISTS earnings_coverage (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    coverage_start REAL NOT NULL
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
            try upsertHistoryCoverage(response)
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

    public func observedEarningsWindow(
        endingAt end: Date,
        maximumSeconds: TimeInterval = 86_400
    ) throws -> ObservedEarningsWindow? {
        let latestStatement = try prepare("""
            SELECT captured_at, lifetime_micro_usd
            FROM account_hourly
            WHERE captured_at <= ?
            ORDER BY captured_at DESC
            LIMIT 1
            """)
        defer { sqlite3_finalize(latestStatement) }
        sqlite3_bind_double(latestStatement, 1, end.timeIntervalSince1970)
        guard sqlite3_step(latestStatement) == SQLITE_ROW else { return nil }
        let latestAt = sqlite3_column_double(latestStatement, 0)
        let latestTotal = sqlite3_column_int64(latestStatement, 1)

        let earliestStatement = try prepare("""
            SELECT captured_at, lifetime_micro_usd
            FROM account_hourly
            WHERE captured_at >= ? AND captured_at < ?
            ORDER BY captured_at ASC
            LIMIT 1
            """)
        defer { sqlite3_finalize(earliestStatement) }
        sqlite3_bind_double(earliestStatement, 1, latestAt - maximumSeconds)
        sqlite3_bind_double(earliestStatement, 2, latestAt)
        guard sqlite3_step(earliestStatement) == SQLITE_ROW else { return nil }
        let earliestAt = sqlite3_column_double(earliestStatement, 0)
        let earliestTotal = sqlite3_column_int64(earliestStatement, 1)
        guard latestTotal >= earliestTotal, latestAt > earliestAt else { return nil }

        return ObservedEarningsWindow(
            microUSD: latestTotal - earliestTotal,
            observedSeconds: latestAt - earliestAt
        )
    }

    public func todayEarningsSummary(
        now: Date,
        calendar: Calendar
    ) throws -> ObservedEarningsWindow? {
        let startDate = calendar.startOfDay(for: now)
        let start = startDate.timeIntervalSince1970
        let end = now.timeIntervalSince1970
        guard end >= start else { return nil }

        if end > start, try historyCovers(since: startDate) {
            let currentHour = floor(end / 3_600) * 3_600
            let statement = try prepare("""
                SELECT COALESCE(SUM(amount_micro_usd), 0)
                FROM (
                    SELECT amount_micro_usd
                    FROM earnings_hourly
                    WHERE hour_start >= ? AND hour_start <= ?
                    UNION ALL
                    SELECT amount_micro_usd
                    FROM rewards_hourly
                    WHERE hour_start >= ? AND hour_start <= ?
                )
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, start)
            sqlite3_bind_double(statement, 2, currentHour)
            sqlite3_bind_double(statement, 3, start)
            sqlite3_bind_double(statement, 4, currentHour)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            return ObservedEarningsWindow(
                microUSD: sqlite3_column_int64(statement, 0),
                observedSeconds: end - start,
                calendarDayStart: startDate, capturedAt: now, coversDayToDate: true
            )
        }

        let latestStatement = try prepare("""
            SELECT captured_at, lifetime_micro_usd
            FROM account_hourly
            WHERE captured_at >= ? AND captured_at <= ?
            ORDER BY captured_at DESC
            LIMIT 1
            """)
        defer { sqlite3_finalize(latestStatement) }
        sqlite3_bind_double(latestStatement, 1, start)
        sqlite3_bind_double(latestStatement, 2, end)
        guard sqlite3_step(latestStatement) == SQLITE_ROW else { return nil }
        let latestAt = sqlite3_column_double(latestStatement, 0)
        let latestTotal = sqlite3_column_int64(latestStatement, 1)

        let earliestStatement = try prepare("""
            SELECT captured_at, lifetime_micro_usd
            FROM account_hourly
            WHERE captured_at >= ? AND captured_at < ?
            ORDER BY captured_at ASC
            LIMIT 1
            """)
        defer { sqlite3_finalize(earliestStatement) }
        sqlite3_bind_double(earliestStatement, 1, start)
        sqlite3_bind_double(earliestStatement, 2, latestAt)
        guard sqlite3_step(earliestStatement) == SQLITE_ROW else { return nil }
        let earliestAt = sqlite3_column_double(earliestStatement, 0)
        let earliestTotal = sqlite3_column_int64(earliestStatement, 1)
        guard latestTotal >= earliestTotal, latestAt > earliestAt else { return nil }

        return ObservedEarningsWindow(
            microUSD: latestTotal - earliestTotal,
            observedSeconds: latestAt - earliestAt,
            calendarDayStart: startDate, capturedAt: now, coversDayToDate: false
        )
    }

    public func weekEarningsSummary(
        now: Date,
        calendar: Calendar
    ) throws -> CalendarWeekEarningsSummary? {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              now >= weekStart
        else { return nil }
        let start = weekStart.timeIntervalSince1970
        let currentHour = floor(now.timeIntervalSince1970 / 3_600) * 3_600
        let statement = try prepare("""
            SELECT COALESCE(SUM(amount_micro_usd), 0), COUNT(*)
            FROM (
                SELECT amount_micro_usd
                FROM earnings_hourly
                WHERE hour_start >= ? AND hour_start <= ?
                UNION ALL
                SELECT amount_micro_usd
                FROM rewards_hourly
                WHERE hour_start >= ? AND hour_start <= ?
            )
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, currentHour)
        sqlite3_bind_double(statement, 3, start)
        sqlite3_bind_double(statement, 4, currentHour)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }

        let isComplete = try historyCovers(since: weekStart)
        let bucketCount = sqlite3_column_int64(statement, 1)
        guard isComplete || bucketCount > 0 else { return nil }
        return CalendarWeekEarningsSummary(
            microUSD: sqlite3_column_int64(statement, 0),
            isComplete: isComplete,
            weekStart: weekStart,
            capturedAt: now
        )
    }

    /// Reads existing ledger aggregates only; never fetches network data.
    /// Missing rows remain unknown because historical coverage metadata cannot
    /// prove that every intervening refresh succeeded.
    public func activity(
        in range: DateInterval,
        unit: ActivityCalendarUnit,
        calendar: Calendar,
        model: String? = nil
    ) throws -> [ActivityBucket] {
        let intervals = try ActivityCalendar.intervals(in: range, unit: unit, calendar: calendar)
        let statement = try prepare("""
            SELECT COALESCE(SUM(work), 0), COALESCE(SUM(reward), 0),
                   COALESCE(SUM(jobs), 0), COALESCE(SUM(prompt), 0),
                   COALESCE(SUM(completion), 0), COUNT(*)
            FROM (
                SELECT hour_start, amount_micro_usd AS work, 0 AS reward,
                       jobs, prompt_tokens AS prompt, completion_tokens AS completion
                FROM earnings_hourly
                WHERE (? IS NULL OR model = ?)
                UNION ALL
                SELECT hour_start, 0 AS work, amount_micro_usd AS reward,
                       0 AS jobs, 0 AS prompt, 0 AS completion
                FROM rewards_hourly
                WHERE ? IS NULL
            )
            WHERE hour_start >= ? AND hour_start < ?
            """)
        defer { sqlite3_finalize(statement) }
        return try intervals.map { interval in
            let start = interval.start.timeIntervalSince1970
            let end = interval.end.timeIntervalSince1970
            guard start.truncatingRemainder(dividingBy: 3600) == 0,
                  end.truncatingRemainder(dividingBy: 3600) == 0 else {
                return ActivityBucket(interval: interval, totals: nil, coverage: .boundaryUncertain)
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            if let model {
                sqlite3_bind_text(statement, 1, model, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, model, -1, sqliteTransient)
                sqlite3_bind_text(statement, 3, model, -1, sqliteTransient)
            }
            sqlite3_bind_double(statement, 4, start)
            sqlite3_bind_double(statement, 5, end)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            guard sqlite3_column_int64(statement, 5) > 0 else {
                return ActivityBucket(interval: interval, totals: nil, coverage: .unavailable)
            }
            return ActivityBucket(interval: interval, totals: ActivityTotals(
                workMicroUSD: sqlite3_column_int64(statement, 0),
                rewardMicroUSD: sqlite3_column_int64(statement, 1),
                jobs: sqlite3_column_int64(statement, 2),
                promptTokens: sqlite3_column_int64(statement, 3),
                completionTokens: sqlite3_column_int64(statement, 4)
            ), coverage: .recorded)
        }
    }

    public func modelWorkEarnings(
        model: String, in range: DateInterval, calendar: Calendar
    ) throws -> ModelWorkEarnings {
        let buckets = try activity(in: range, unit: .hour, calendar: calendar, model: model)
        let recorded = buckets.filter { $0.coverage == .recorded }.compactMap(\.totals)
        var amount: Int64 = 0
        var jobs: Int64 = 0
        for value in recorded {
            let nextAmount = amount.addingReportingOverflow(value.workMicroUSD)
            let nextJobs = jobs.addingReportingOverflow(value.jobs)
            guard !nextAmount.overflow, !nextJobs.overflow else {
                throw ActivityCalendarError.invalidInterval
            }
            amount = nextAmount.partialValue
            jobs = nextJobs.partialValue
        }
        return ModelWorkEarnings(model: model, queryPeriod: range,
            sourceCapturedAt: try latestAccountSample()?.capturedAt,
            workMicroUSD: recorded.isEmpty ? nil : amount,
            jobs: recorded.isEmpty ? nil : jobs,
            recordedHours: recorded.count,
            unknownHours: buckets.filter { $0.coverage == .unavailable }.count,
            uncertainBoundaryHours: buckets.filter { $0.coverage == .boundaryUncertain }.count)
    }

    public func activityModels(in range: DateInterval) throws -> [String] {
        let statement = try prepare("""
            SELECT DISTINCT model FROM earnings_hourly
            WHERE hour_start >= ? AND hour_start < ?
            ORDER BY model LIMIT 129
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, floor(range.start.timeIntervalSince1970 / 3600) * 3600)
        sqlite3_bind_double(statement, 2, range.end.timeIntervalSince1970)
        var models: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { models.append(String(cString: value)) }
            guard models.count <= 128 else { throw ActivityCalendarError.tooManyBuckets }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return models
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

    public func jobCompletionSummary(
        now: Date,
        calendar: Calendar,
        averageDayCount: Int = 7
    ) throws -> JobCompletionSummary {
        precondition(averageDayCount > 0)
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(
            byAdding: .day,
            value: 1,
            to: todayStart
        )!
        let historyStart = calendar.date(
            byAdding: .day,
            value: -averageDayCount,
            to: todayStart
        )!
        let completedToday = try jobCount(from: todayStart, to: tomorrowStart)
        let completedInHistory = try jobCount(from: historyStart, to: todayStart)
        let averagePerDay = try historyCovers(since: historyStart)
            ? Double(completedInHistory) / Double(averageDayCount)
            : nil

        return JobCompletionSummary(
            completedToday: completedToday,
            averagePerDay: averagePerDay,
            averagingDays: averageDayCount,
            dayStart: todayStart,
            capturedAt: now
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

    private func jobCount(from start: Date, to end: Date) throws -> Int64 {
        let statement = try prepare("""
            SELECT COALESCE(SUM(jobs), 0)
            FROM earnings_hourly
            WHERE hour_start >= ? AND hour_start < ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return sqlite3_column_int64(statement, 0)
    }

    private func historyCovers(since start: Date) throws -> Bool {
        let statement = try prepare("""
            SELECT coverage_start
            FROM earnings_coverage
            WHERE singleton = 1
            """)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return false }
            throw lastError()
        }
        return sqlite3_column_double(statement, 0) <= start.timeIntervalSince1970
    }

    private func upsertHistoryCoverage(_ response: AccountEarningsResponse) throws {
        let coverageStart: TimeInterval?
        if response.count <= Int64(response.earnings.count) {
            coverageStart = 0
        } else {
            coverageStart = response.earnings.map(\.createdAt.timeIntervalSince1970).min()
        }
        guard let coverageStart else { return }

        let statement = try prepare("""
            INSERT INTO earnings_coverage (singleton, coverage_start)
            VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET
                coverage_start = MIN(coverage_start, excluded.coverage_start)
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, coverageStart)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
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
