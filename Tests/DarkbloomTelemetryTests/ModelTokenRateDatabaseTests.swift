import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Calendar-day model token-rate database")
struct ModelTokenRateDatabaseTests {
    @Test("model history preserves sampled peaks and gaps without mixing other models")
    func modelHistory() async throws {
        let database = try ModelTokenRateDatabase(url: temporaryDatabaseURL())
        let start = Date(timeIntervalSince1970: 1_987_200)
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 9000)
        for (index, sample) in [("qwen", 10.0), ("qwen", 30.0), ("gemma", 100.0)].enumerated() {
            try await database.record(model: sample.0, tokensPerSecond: sample.1, capturedAt: start.addingTimeInterval(Double(index)), processIdentity: identity, writtenAt: Double(index))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let series = try #require(await database.history(in: DateInterval(start: start, duration: 7200), unit: .hour, calendar: calendar, model: "qwen"))
        #expect(series.count == 2)
        #expect(series[0].average == 20)
        #expect(series[0].minimum == 10)
        #expect(series[0].maximum == 30)
        #expect(series[0].sampleCount == 2)
        #expect(series[1].average == nil)
        #expect(series[1].sampleCount == 0)
        let recorder: any ModelTokenRateRecording = database
        #expect(try await recorder.history(in: DateInterval(start: start, duration: 7200), unit: .hour, calendar: calendar, model: "qwen") == series)
    }

    @Test("reading today does not erase yesterday's throughput samples")
    func historicalReadsAreNonDestructive() async throws {
        let database = try ModelTokenRateDatabase(url: temporaryDatabaseURL())
        let midnight = Date(timeIntervalSince1970: 1_987_200)
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 9000)
        try await database.record(model: "qwen", tokensPerSecond: 25, capturedAt: midnight.addingTimeInterval(-3600), processIdentity: identity, writtenAt: 1)
        _ = try await database.averages(from: midnight, through: midnight.addingTimeInterval(3600))
        #expect(try await database.averages(from: midnight.addingTimeInterval(-86400), through: midnight) == [
            ModelTokenRateAverage(model: "qwen", tokensPerSecond: 25, sampleCount: 1, queryPeriod: DateInterval(start: midnight.addingTimeInterval(-86400), end: midnight))
        ])
    }

    @Test("recording retains recent history while pruning samples older than 31 days")
    func writeTimeRetention() async throws {
        let database = try ModelTokenRateDatabase(url: temporaryDatabaseURL())
        let now = Date(timeIntervalSince1970: 5_000_000)
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 9000)
        for (day, value) in [(-32, 5.0), (-2, 20.0), (0, 40.0)] {
            try await database.record(model: "qwen", tokensPerSecond: value, capturedAt: now.addingTimeInterval(Double(day) * 86400), processIdentity: identity, writtenAt: Double(day))
        }
        #expect(try await database.averages(from: now.addingTimeInterval(-40 * 86400), through: now) == [
            ModelTokenRateAverage(model: "qwen", tokensPerSecond: 30, sampleCount: 2, queryPeriod: DateInterval(start: now.addingTimeInterval(-40 * 86400), end: now))
        ])
    }

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
            ModelTokenRateAverage(model: "gemma", tokensPerSecond: 30, sampleCount: 2, queryPeriod: DateInterval(start: now.addingTimeInterval(-86400), end: now)),
            ModelTokenRateAverage(model: "qwen", tokensPerSecond: 10, sampleCount: 1, queryPeriod: DateInterval(start: now.addingTimeInterval(-86400), end: now)),
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
            ModelTokenRateAverage(model: "gemma", tokensPerSecond: 20, sampleCount: 1, queryPeriod: DateInterval(start: now.addingTimeInterval(-86400), end: now)),
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
