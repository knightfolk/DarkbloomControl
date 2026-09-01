import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Monitor-observed rolling uptime")
struct ObservedUptimeTests {
    @Test("unknown and unobserved gaps are excluded from uptime")
    func excludesUnknownAndLongGaps() async throws {
        let database = try ObservedUptimeDatabase(
            url: temporaryDatabaseURL(),
            window: 86_400,
            maximumCarry: 10,
            minimumObservedDuration: 0
        )

        _ = try await database.record(status: .online, at: date(0))
        _ = try await database.record(status: .online, at: date(10))
        _ = try await database.record(status: .unavailable, at: date(20))
        _ = try await database.record(status: .offline, at: date(100))
        let result = try await database.record(status: .offline, at: date(110))

        guard case .available(let percent, let observedSeconds) = result else {
            Issue.record("Expected an available uptime value, got \(result)")
            return
        }
        #expect(abs(percent - (200.0 / 3.0)) < 0.0001)
        #expect(observedSeconds == 30)
    }

    @Test("the rolling boundary clips a carried observation")
    func clipsAtRollingBoundary() async throws {
        let database = try ObservedUptimeDatabase(
            url: temporaryDatabaseURL(),
            window: 86_400,
            maximumCarry: 10,
            minimumObservedDuration: 0
        )

        _ = try await database.record(status: .online, at: date(13_595))
        _ = try await database.record(status: .offline, at: date(13_605))
        _ = try await database.record(status: .offline, at: date(13_615))
        let result = try await database.snapshot(at: date(100_000))

        #expect(result == .available(percent: 20, observedSeconds: 25))
    }

    @Test("initial coverage remains warming until five observed minutes")
    func warmsUpBeforePublishingPercent() async throws {
        let database = try ObservedUptimeDatabase(
            url: temporaryDatabaseURL(),
            window: 86_400,
            maximumCarry: 10,
            minimumObservedDuration: 300
        )

        for second in stride(from: 0, through: 290, by: 10) {
            _ = try await database.record(status: .online, at: date(second))
        }
        let warming = try await database.snapshot(at: date(299))
        let available = try await database.record(status: .online, at: date(300))

        #expect(warming == .warming(observedSeconds: 299))
        #expect(available == .available(percent: 100, observedSeconds: 300))
    }

    @Test("timestamped observations survive a database restart")
    func persistsAcrossRestart() async throws {
        let url = temporaryDatabaseURL()
        do {
            let database = try ObservedUptimeDatabase(
                url: url,
                window: 86_400,
                maximumCarry: 10,
                minimumObservedDuration: 300
            )
            for second in stride(from: 0, through: 300, by: 10) {
                _ = try await database.record(status: .online, at: date(second))
            }
        }

        let reopened = try ObservedUptimeDatabase(
            url: url,
            window: 86_400,
            maximumCarry: 10,
            minimumObservedDuration: 300
        )
        let result = try await reopened.snapshot(at: date(300))

        #expect(result == .available(percent: 100, observedSeconds: 300))
    }

    @Test("the local uptime database is private to the user")
    func databasePermissionsArePrivate() throws {
        let url = temporaryDatabaseURL()
        _ = try ObservedUptimeDatabase(url: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-uptime-tests-\(UUID().uuidString).sqlite3")
    }

    private func date(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
