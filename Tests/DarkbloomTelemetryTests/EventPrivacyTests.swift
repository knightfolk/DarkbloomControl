import Foundation
import Testing
@testable import DarkbloomTelemetry

struct EventPrivacyTests {
    @Test("buffer withholds credential and customer-payload fields before retention")
    func privateFields() {
        for message in [
            "Authorization: Bearer fixture-secret",
            "api_key=fixture-secret",
            "access_\u{200B}token=fixture-secret",
            "prompt: fixture-customer-content",
            "response=fixture-customer-content",
            #"{"messages":[{"content":"fixture-customer-content"}]}"#,
            "provider_id=fixture-provider"
        ] {
            var buffer = EventBuffer(capacity: 10)
            buffer.insert([event(message)])
            #expect(buffer.events.count == 1)
            #expect(buffer.events.first?.message.contains("fixture-") == false)
        }
    }

    @Test("URL secrets and home paths cannot survive in retained metadata")
    func metadata() throws {
        var buffer = EventBuffer(capacity: 10)
        buffer.insert([LogEvent(timestamp: nil, severity: .warning,
            category: "https://example.invalid/?token=fixture-secret",
            message: "Failed opening /Users/fixture-user/models; see https://example.invalid/private",
            source: .unified, processID: 42, processImage: "/Users/fixture-user/bin/provider")])
        let retained = try #require(buffer.events.first)
        #expect(!retained.category.contains("fixture-secret"))
        #expect(!retained.message.contains("fixture-user"))
        #expect(!retained.message.contains("example.invalid"))
        #expect(retained.processImage?.contains("fixture-user") == false)
        #expect(retained.processID == 42)
    }

    @Test("ordinary operational counters survive and sanitization is idempotent")
    func operationalEvents() {
        var buffer = EventBuffer(capacity: 10)
        let original = event("Loaded model; prompt_tokens=10 completion_tokens=20; retry in 5 seconds")
        buffer.insert([original])
        #expect(buffer.events == [original])
        buffer.insert(buffer.events)
        #expect(buffer.events == [original])
    }

    private func event(_ message: String) -> LogEvent {
        LogEvent(timestamp: nil, severity: .warning, category: "Inference", message: message,
                 source: .legacy, processID: nil, processImage: nil)
    }
}
