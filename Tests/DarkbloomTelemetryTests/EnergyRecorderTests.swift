import Foundation
import Testing
@testable import DarkbloomTelemetry

struct EnergyRecorderTests {
    @Test func disablingBreaksContinuityAndDoesNotReadSensor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let recorder = EnergyRecorder(file: file) { now in
            #expect(now.timeIntervalSince1970 != 120)
            return .init(date: now, watts: 100, source: "test", estimated: true)
        }
        for time in [100.0, 110.0] {
            _ = await recorder.sample(enabled: true, rate: 0.15, now: Date(timeIntervalSince1970: time))
        }
        let disabled = await recorder.sample(enabled: false, rate: 0.15, now: Date(timeIntervalSince1970: 120))
        #expect(disabled.intervals.isEmpty)
        let resumed = await recorder.sample(enabled: true, rate: 0.15, now: Date(timeIntervalSince1970: 130))
        #expect(resumed.intervals.count == 1)
        #expect(try EnergyHistoryFile.read(from: file).intervals.count == 1)
    }
}
