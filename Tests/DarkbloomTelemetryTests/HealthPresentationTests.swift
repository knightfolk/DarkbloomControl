import Testing
import Foundation
@testable import DarkbloomTelemetry
@testable import DarkbloomMonitor

struct HealthPresentationTests {
    @Test("retained daemon details warn on failed refresh, expiry and future timestamps")
    func daemonFreshness() throws {
        let url = try #require(Bundle.module.url(forResource: "daemon-state-online", withExtension: "json", subdirectory: "Fixtures"))
        let state = try DaemonStateParser.parse(Data(contentsOf: url))
        let written = Date(timeIntervalSince1970: state.writtenAt)
        let source: SourceAvailability<DaemonState> = .available(value: state, capturedAt: written)
        #expect(HealthPresentation.daemonWarning(source, at: written.addingTimeInterval(10)) == nil)
        #expect(HealthPresentation.daemonWarning(source, at: written.addingTimeInterval(11)) != nil)
        #expect(HealthPresentation.daemonWarning(source, at: written.addingTimeInterval(-1)) != nil)
        #expect(HealthPresentation.daemonWarning(.stale(value: state, capturedAt: written, reason: "read failed"), at: written)?.contains("read failed") == true)
        #expect(HealthPresentation.daemonWarning(.unavailable(reason: "permission denied"), at: written)?.contains("permission denied") == true)
    }

    @Test("daemon summary remains available when CLI status is missing and invents no absent state")
    func daemonSummary() throws {
        let url = try #require(Bundle.module.url(forResource: "daemon-state-online", withExtension: "json", subdirectory: "Fixtures"))
        let state = try DaemonStateParser.parse(Data(contentsOf: url))
        let rows = HealthPresentation.daemonRows(state)
        #expect(rows.contains { $0.label == "Process PID" && $0.value == "10004" })
        #expect(rows.contains { $0.label == "Reported slots" && $0.value == "1" })
        #expect(rows.contains { $0.label == "Inference" && $0.value == "Idle" })
        #expect(HealthPresentation.daemonRows(nil).isEmpty)
    }

    @Test("one unavailable CLI source produces one diagnostic instead of a row per missing field")
    func unavailableStatus() {
        let rows = HealthPresentation.statusRows(.unavailable(reason: "timedOut"))
        #expect(rows.count == 1)
        #expect(rows.first?.value.contains("timedOut") == true)
    }
}
