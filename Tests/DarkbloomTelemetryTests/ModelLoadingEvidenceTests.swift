import Foundation
import Testing
@testable import DarkbloomTelemetry

struct ModelLoadingEvidenceTests {
    @Test func loadingRequiresRecentMatchingProcessAndClearsAtCompletion() {
        let now = Date(timeIntervalSince1970: 1000)
        func event(_ message: String, at: Double = 995, pid: Int32 = 42,
                   source: LogSource = .unified, severity: LogSeverity = .info) -> LogEvent {
            LogEvent(timestamp: Date(timeIntervalSince1970: at), severity: severity,
                     category: "loop", message: message, source: source, processID: pid, processImage: nil)
        }
        func result(_ events: [LogEvent], warm: [String] = []) -> String? {
            ModelLoadingEvidence.model(events: events, pid: 42, startedAt: now.addingTimeInterval(-100),
                                       warmModels: warm, now: now)
        }
        let start = event("Loading model: Qwen3.8 from /cache/model")
        #expect(result([start]) == "Qwen3.8")
        #expect(result([start], warm: ["Qwen3.8"]) == nil)
        #expect(result([start, event("Model loaded: Qwen3.8 (1 model(s) in memory)", at: 996)]) == nil)
        #expect(result([start, event("Load failed", at: 996, severity: .error)]) == nil)
        #expect(result([event("Loading model: Qwen3.8 from /cache", pid: 43)]) == nil)
        #expect(result([event("Loading model: Qwen3.8 from /cache", source: .legacy)]) == nil)
        #expect(result([event("Loading model: Qwen3.8 from /cache", at: 939)]) == nil)
        #expect(result([event("Loading model: Qwen3.8 from /cache", at: 1001)]) == nil)
    }
}
