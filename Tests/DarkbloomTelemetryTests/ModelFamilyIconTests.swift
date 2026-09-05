import Testing
@testable import DarkbloomTelemetry

struct ModelFamilyIconTests {
    @Test func activeFamiliesAndSafeFallbacks() {
        #expect(ModelFamilyIcon.select(status: .online, activeModel: "EigenLabs/Qwen3.8-27B-4bit-mtp") == .qwen)
        #expect(ModelFamilyIcon.select(status: .online, activeModel: "gemma-4-26b-qat-4bit") == .google)
        #expect(ModelFamilyIcon.select(status: .online, activeModel: "openai/gpt-oss-20b") == .openai)
        #expect(ModelFamilyIcon.select(status: .online, activeModel: "unknown") == .darkbloom)
        #expect(ModelFamilyIcon.select(status: .online, activeModel: nil) == .darkbloom)
        for status in [MenuPresentationStatus.offline, .stale, .unavailable] {
            #expect(ModelFamilyIcon.select(status: status, activeModel: "Qwen3.8") == .darkbloom)
        }
    }
}
