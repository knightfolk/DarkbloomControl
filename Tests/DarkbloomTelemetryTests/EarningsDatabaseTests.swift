import Foundation
import SQLite3
import Testing
@testable import DarkbloomTelemetry

@Suite("Local earnings database")
struct EarningsDatabaseTests {
    @Test("hourly model buckets stay compact while payout samples remain queryable")
    func persistsEarningsAndPayoutSamples() async throws {
        let databaseURL = temporaryDatabaseURL()
        let database = try EarningsDatabase(url: databaseURL)
        let capturedAt = Date(timeIntervalSince1970: 2_000_000)
        let response = AccountEarningsResponse(
            accountID: "account-never-persisted",
            earnings: [
                earning(id: 1, model: "gemma", microUSD: 125_000, at: capturedAt.addingTimeInterval(-60)),
                earning(id: 2, model: "gpt-oss", microUSD: 75_000, at: capturedAt.addingTimeInterval(-30)),
            ],
            count: 2,
            historyLimit: 1_000,
            recentCount: 2,
            totalMicroUSD: 500_000,
            availableBalanceMicroUSD: 400_000,
            withdrawableBalanceMicroUSD: 350_000
        )

        try await database.ingest(response, capturedAt: capturedAt)
        try await database.ingest(response, capturedAt: capturedAt)

        #expect(try await database.hourBucketCount() == 2)
        #expect(try await database.latestAccountSample() == AccountBalanceSample(
            capturedAt: capturedAt,
            lifetimeMicroUSD: 500_000,
            availableMicroUSD: 400_000,
            withdrawableMicroUSD: 350_000,
            lifetimeCount: 2
        ))
        #expect(try await database.earningsByModel(since: capturedAt.addingTimeInterval(-3_600)) == [
            ModelEarnings(model: "gemma", microUSD: 125_000, jobs: 1),
            ModelEarnings(model: "gpt-oss", microUSD: 75_000, jobs: 1),
        ])
        #expect(try await database.latestPayoutCalculation() == PayoutCalculation(
            withdrawableNowMicroUSD: 350_000,
            pendingSettlementMicroUSD: 50_000,
            paidOrDebitedMicroUSD: 100_000,
            withdrawableShare: 0.875
        ))

        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("base rewards are excluded from work jobs and stored in their own series")
    func separatesBaseRewardsFromWork() async throws {
        let database = try EarningsDatabase(url: temporaryDatabaseURL())
        let capturedAt = Date(timeIntervalSince1970: 2_000_000)
        let response = AccountEarningsResponse(
            accountID: "account-never-persisted",
            earnings: [
                earning(id: 1, model: "gemma", microUSD: 125_000, at: capturedAt),
                earning(
                    id: 2,
                    model: "base_reward",
                    microUSD: 25_000,
                    promptTokens: 0,
                    completionTokens: 0,
                    at: capturedAt
                ),
            ],
            count: 2,
            historyLimit: 1_000,
            recentCount: 2,
            totalMicroUSD: 150_000,
            availableBalanceMicroUSD: 150_000,
            withdrawableBalanceMicroUSD: 150_000
        )

        try await database.ingest(response, capturedAt: capturedAt)

        #expect(try await database.hourBucketCount() == 1)
        #expect(try await database.rewardBucketCount() == 1)
        #expect(try await database.earningsByModel(since: capturedAt.addingTimeInterval(-3_600)) == [
            ModelEarnings(model: "gemma", microUSD: 125_000, jobs: 1),
        ])
        #expect(try await database.rewardEarnings(since: capturedAt.addingTimeInterval(-3_600)) ==
            RewardEarnings(microUSD: 25_000, events: 1))
    }

    @Test("opening an existing database migrates base rewards out of work history")
    func migratesExistingBaseRewardBuckets() async throws {
        let databaseURL = temporaryDatabaseURL()
        try createLegacyDatabase(at: databaseURL)

        let database = try EarningsDatabase(url: databaseURL)

        #expect(try await database.earningsByModel(since: .distantPast) == [
            ModelEarnings(model: "gemma", microUSD: 100_000, jobs: 4),
        ])
        #expect(try await database.rewardEarnings(since: .distantPast) ==
            RewardEarnings(microUSD: 25_000, events: 12))
    }

    @Test("overlapping frequent polls add only previously unseen earnings")
    func incrementallyIngestsOverlappingPages() async throws {
        let database = try EarningsDatabase(url: temporaryDatabaseURL())
        let capturedAt = Date(timeIntervalSince1970: 2_000_000)
        let first = AccountEarningsResponse(
            accountID: "account-never-persisted",
            earnings: [
                earning(id: 10, model: "gemma", microUSD: 100, at: capturedAt.addingTimeInterval(-600)),
                earning(id: 11, model: "gemma", microUSD: 200, at: capturedAt.addingTimeInterval(-300)),
            ],
            count: 11,
            historyLimit: 1_000,
            recentCount: 2
        )
        let overlapping = AccountEarningsResponse(
            accountID: "account-never-persisted",
            earnings: [
                earning(id: 11, model: "gemma", microUSD: 200, at: capturedAt.addingTimeInterval(-300)),
                earning(id: 12, model: "gemma", microUSD: 300, at: capturedAt.addingTimeInterval(60)),
            ],
            count: 12,
            historyLimit: 1_000,
            recentCount: 2
        )

        try await database.ingest(first, capturedAt: capturedAt)
        try await database.ingest(overlapping, capturedAt: capturedAt.addingTimeInterval(300))
        try await database.ingest(overlapping, capturedAt: capturedAt.addingTimeInterval(600))

        #expect(try await database.hourBucketCount() == 1)
        #expect(try await database.earningsByModel(since: capturedAt.addingTimeInterval(-3_600)) == [
            ModelEarnings(model: "gemma", microUSD: 600, jobs: 3),
        ])
        #expect(try await database.lastIngestedEarningID() == 12)
    }

    @Test("unchanged polls do not rewrite hourly balance history")
    func ignoresUnchangedPolls() async throws {
        let database = try EarningsDatabase(url: temporaryDatabaseURL())
        let firstCapture = Date(timeIntervalSince1970: 2_000_000)
        let response = AccountEarningsResponse(
            accountID: "account-never-persisted",
            earnings: [earning(id: 1, model: "gemma", microUSD: 100, at: firstCapture)],
            count: 1,
            historyLimit: 1_000,
            recentCount: 1,
            totalMicroUSD: 100,
            availableBalanceMicroUSD: 100,
            withdrawableBalanceMicroUSD: 100
        )

        try await database.ingest(response, capturedAt: firstCapture)
        try await database.ingest(response, capturedAt: firstCapture.addingTimeInterval(600))

        #expect(try await database.accountSampleCount() == 1)
        #expect(try await database.latestAccountSample()?.capturedAt == firstCapture)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-earnings-tests-\(UUID().uuidString).sqlite3")
    }

    private func earning(
        id: Int64,
        model: String,
        microUSD: Int64,
        promptTokens: Int = 10,
        completionTokens: Int = 20,
        at date: Date
    ) -> AccountEarning {
        AccountEarning(
            id: id,
            providerID: "provider-not-persisted",
            providerKey: "secret-not-persisted",
            model: model,
            amountMicroUSD: microUSD,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            createdAt: date
        )
    }

    private func createLegacyDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw EarningsDatabaseError.sqlite(message: "could not create legacy fixture")
        }
        defer { sqlite3_close(database) }
        let sql = """
            CREATE TABLE earnings_hourly (
                hour_start REAL NOT NULL,
                model TEXT NOT NULL,
                amount_micro_usd INTEGER NOT NULL,
                jobs INTEGER NOT NULL,
                prompt_tokens INTEGER NOT NULL,
                completion_tokens INTEGER NOT NULL,
                PRIMARY KEY (hour_start, model)
            );
            INSERT INTO earnings_hourly VALUES (1998000, 'gemma', 100000, 4, 100, 40);
            INSERT INTO earnings_hourly VALUES (1998000, 'base_reward', 25000, 12, 0, 0);
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw EarningsDatabaseError.sqlite(message: "could not populate legacy fixture")
        }
    }
}
