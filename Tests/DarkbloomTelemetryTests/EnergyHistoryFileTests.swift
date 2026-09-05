import Foundation
import Testing
@testable import DarkbloomTelemetry

struct EnergyHistoryFileTests {
    @Test func persistenceDoesNotBridgeRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("energy.json")
        var history = try EnergyHistoryFile.read(from: file)
        func sample(_ t: Double) -> EnergyReading {
            .init(date: Date(timeIntervalSince1970: t), watts: 100, source: "adapter", estimated: true)
        }
        history.append(sample(100), usdPerKWh: 0.15)
        history.append(sample(110), usdPerKWh: 0.15)
        try EnergyHistoryFile.write(history, to: file)
        var restored = try EnergyHistoryFile.read(from: file)
        #expect(restored.intervals == history.intervals)
        restored.append(sample(120), usdPerKWh: 0.15)
        #expect(restored.intervals.count == 1)
        restored.append(sample(130), usdPerKWh: 0.15)
        #expect(restored.intervals.count == 2)
        try Data("corrupt".utf8).write(to: file)
        #expect(throws: (any Error).self) { try EnergyHistoryFile.read(from: file) }
    }

    @Test func rejectsOverlappingIntervals() {
        let interval = EnergyInterval(start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 110), kWh: 0.001, usdPerKWh: 0.1,
            source: "adapter", estimated: true)
        #expect(throws: EnergyHistoryError.self) {
            try EnergyHistory(restoring: [interval, interval])
        }
    }
}
