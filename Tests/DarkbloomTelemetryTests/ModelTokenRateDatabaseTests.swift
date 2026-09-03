import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Calendar-day model token-rate database")
struct ModelTokenRateDatabaseTests {
    @Test("groups valid unique samples by model")
    func groupsModelAverages() async throws {
        let url = temporaryDatabaseURL()
        let database = try ModelTokenRateDatabase(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 9_000)

        try await database.record(
            model: "gemma",
            tokensPerSecond: 20,
            capturedAt: now.addingTimeInterval(-100),
            processIdentity: identity,
            writtenAt: 1_900
        )
        try await database.record(
            model: "gemma",
            tokensPerSecond: 40,
            capturedAt: now.addingTimeInterval(-50),
            processIdentity: identity,
            writtenAt: 1_950
        )
        try await database.record(
            model: "qwen",
            tokensPerSecond: 10,
            capturedAt: now.addingTimeInterval(-20),
            processIdentity: identity,
            writtenAt: 1_980
        )
        try await database.record(
            model: "qwen",
            tokensPerSecond: 99,
            capturedAt: now,
            processIdentity: identity,
            writtenAt: 1_980
        )

        #expect(try await database.averages(
            from: now.addingTimeInterval(-86_400),
            through: now
        ) == [
            ModelTokenRateAverage(model: "gemma", tokensPerSecond: 30, sampleCount: 2),
            ModelTokenRateAverage(model: "qwen", tokensPerSecond: 10, sampleCount: 1),
        ])
    }

    @Test("the calendar-day range excludes prior and future observations")
    func boundsCalendarDay() async throws {
        let database = try ModelTokenRateDatabase(url: temporaryDatabaseURL())
        let now = Date(timeIntervalSince1970: 2_000_000)
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 9_000)
        for (rate, offset, writtenAt) in [(5.0, -86_401.0, 1.0), (20, -86_400, 2), (99, 1, 3)] {
            try await database.record(
                model: "gemma",
                tokensPerSecond: rate,
                capturedAt: now.addingTimeInterval(offset),
                processIdentity: identity,
                writtenAt: writtenAt
            )
        }

        #expect(try await database.averages(
            from: now.addingTimeInterval(-86_400),
            through: now
        ) == [
            ModelTokenRateAverage(model: "gemma", tokensPerSecond: 20, sampleCount: 1),
        ])
    }

    @Test("invalid model and rate samples are ignored")
    func ignoresInvalidSamples() async throws {
        let database = try ModelTokenRateDatabase(url: temporaryDatabaseURL())
        let now = Date(timeIntervalSince1970: 2_000_000)
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 9_000)
        for (model, rate, writtenAt) in [("", 10.0, 1.0), ("gemma", 0, 2), ("qwen", .infinity, 3)] {
            try await database.record(
                model: model,
                tokensPerSecond: rate,
                capturedAt: now,
                processIdentity: identity,
                writtenAt: writtenAt
            )
        }

        #expect(try await database.averages(
            from: now.addingTimeInterval(-86_400),
            through: now
        ).isEmpty)
    }

    @Test("the database is private to the current user")
    func usesPrivatePermissions() throws {
        let url = temporaryDatabaseURL()
        _ = try ModelTokenRateDatabase(url: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DarkbloomModelRateTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model-token-rates.sqlite3")
    }
}
