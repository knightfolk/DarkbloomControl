import Foundation
import Testing
@testable import DarkbloomTelemetry

struct EventBufferByteTests {
    @Test("long log churn stays bounded and preserves the newest sanitized events")
    func sustainedChurn() {
        var buffer = EventBuffer(capacity: 100)
        let start = ContinuousClock.now
        for index in 0..<1000 {
            buffer.insert([LogEvent(timestamp: Date(timeIntervalSince1970: Double(index) * 1800),
                severity: .warning, category: "Inference", message: "Load delayed \(index) https://example.invalid/private",
                source: .legacy, processID: nil, processImage: nil)])
            #expect(buffer.events.count <= 100)
            #expect(buffer.retainedPayloadBytes <= 128 * 1024)
        }
        #expect(buffer.events.count == 100)
        #expect(buffer.events.first?.message == "Load delayed 999 [URL withheld]")
        #expect(buffer.events.last?.message == "Load delayed 900 [URL withheld]")
        if ProcessInfo.processInfo.environment["DARKBLOOM_BENCHMARK"] == "1" {
            print("EventBuffer 1000 inserts: \(start.duration(to: .now))")
        }
    }
    @Test("zero budgets retain nothing and oversized requested budgets cannot bypass the global cap")
    func clampsBudget() {
        let large = LogEvent(timestamp: nil, severity: .info, category: "a", message: String(repeating: "x", count: 128 * 1_024), source: .legacy, processID: nil, processImage: nil)
        for budget in [0, -1, Int.max] {
            var buffer = EventBuffer(capacity: 100, maximumPayloadBytes: budget)
            buffer.insert([large])
            #expect(buffer.events.isEmpty)
            #expect(buffer.retainedPayloadBytes == 0)
        }
    }

    @Test("retention counts UTF-8 payload bytes and keeps the newest fitting complete events")
    func boundsPayload() {
        var buffer = EventBuffer(capacity: 100, maximumPayloadBytes: 10)
        let events = (1...3).map { index in
            LogEvent(timestamp: Date(timeIntervalSince1970: Double(index)), severity: .info,
                     category: "a", message: "🙂", source: .legacy, processID: nil, processImage: nil)
        }
        buffer.insert(events)
        #expect(buffer.events == [events[2], events[1]])
        #expect(buffer.retainedPayloadBytes == 10)
        _ = buffer.popFirst()
        #expect(buffer.retainedPayloadBytes == 5)
    }

    @Test("oversized metadata is dropped whole and cannot evict a useful small event")
    func dropsOversized() {
        var buffer = EventBuffer(capacity: 100, maximumPayloadBytes: 10)
        let small = LogEvent(timestamp: nil, severity: .info, category: "a", message: "ok", source: .legacy, processID: nil, processImage: nil)
        let large = LogEvent(timestamp: Date(), severity: .error, category: "a", message: "ok", source: .unified, processID: nil, processImage: String(repeating: "x", count: 11))
        buffer.insert([small, large])
        #expect(buffer.events == [small])
        #expect(buffer.retainedPayloadBytes == 3)
    }
}
