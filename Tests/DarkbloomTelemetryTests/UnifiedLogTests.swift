import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Unified and bounded events")
struct UnifiedLogTests {
    @Test("privacy-redacted unified message keeps real metadata")
    func parsesPrivateMessage() throws {
        let line = try fixtureLine("unified-log-private")
        let event = try #require(UnifiedLogParser.parse(line: line))
        #expect(event.severity == .error)
        #expect(event.category == "loop")
        #expect(event.message == "Message unavailable (privacy redacted)")
        #expect(event.processID == 10004)
        #expect(event.processImage == "/Users/example/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom")
        #expect(event.source == .unified)
    }

    @Test("exposed lifecycle info retains its message")
    func parsesExposedMessage() throws {
        let line = try fixtureLine("unified-log-message")
        let event = try #require(UnifiedLogParser.parse(line: line))
        #expect(event.severity == .info)
        #expect(event.category == "coordinator")
        #expect(event.message == "Connected to coordinator")
        #expect(event.processID == 10004)
        #expect(event.source == .unified)
    }

    @Test("non-lifecycle info is filtered")
    func filtersNoise() throws {
        let line = Data("{\"timestamp\":\"2026-08-31 17:45:00.000000-0700\",\"messageType\":\"Info\",\"category\":\"metrics\",\"eventMessage\":\"heartbeat\"}".utf8)
        #expect(UnifiedLogParser.parse(line: line) == nil)
    }

    @Test("buffer deduplicates and retains newest 100")
    func boundsBuffer() {
        var buffer = EventBuffer(capacity: 100)
        let events = (0..<110).map { index in
            LogEvent(timestamp: Date(timeIntervalSince1970: Double(index)), severity: .warning,
                     category: "test", message: "event \(index)", source: .legacy,
                     processID: nil, processImage: nil)
        }
        buffer.insert(events + [events[109]])
        #expect(buffer.events.count == 100)
        #expect(buffer.events.first?.message == "event 109")
        #expect(buffer.events.last?.message == "event 10")
    }

    @Test("stream yields normalized qualifying lines")
    func streamsEvents() async throws {
        let privateLine = String(decoding: try fixtureLine("unified-log-private"), as: UTF8.self)
        let messageLine = String(decoding: try fixtureLine("unified-log-message"), as: UTF8.self)
        let streamer = UnifiedLogStreamer(testOnlyCommand: .testOnly(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: [privateLine + messageLine]
        ))

        var events: [LogEvent] = []
        for try await event in streamer.events() {
            events.append(event)
        }

        #expect(events.map(\.message) == [
            "Message unavailable (privacy redacted)",
            "Connected to coordinator",
        ])
    }

    private func fixtureLine(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }
}
