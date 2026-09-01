import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Telemetry formatting")
struct TelemetryFormattingTests {
    @Test("rate includes provenance")
    func formatsRate() {
        #expect(TelemetryFormatting.tokenRate(.available(tokensPerSecond: 15.04, label: "derived")) == "15.0 tok/s · derived")
        #expect(TelemetryFormatting.tokenRate(.unavailable(reason: "No token progress in the polling window")) == "Unavailable — No token progress in the polling window")
    }

    @Test("durations stay compact and derived")
    func formatsDuration() {
        #expect(TelemetryFormatting.duration(.available(seconds: 3_661, label: "derived")) == "1h 1m · derived")
        #expect(TelemetryFormatting.duration(.unavailable(reason: "State write time is in the future")) == "Unavailable — State write time is in the future")
    }

    @Test("memory uses gibibyte precision without summing cache")
    func formatsMemory() {
        #expect(TelemetryFormatting.gibibytes(14.7594) == "14.76 GiB")
        #expect(TelemetryFormatting.memoryFraction(active: 14.75, total: 64) == 0.23046875)
    }

    @Test("empty exposed models differ from an unavailable source")
    func formatsModelLists() {
        #expect(TelemetryFormatting.modelList([]) == "None reported")
        #expect(TelemetryFormatting.unavailable("loaded-models.json missing") == "Unavailable — loaded-models.json missing")
    }

    @Test("non-finite values and oversized durations are unavailable")
    func rejectsInvalidNumbers() {
        #expect(TelemetryFormatting.tokenRate(.available(tokensPerSecond: .nan, label: "derived")) == "Unavailable — Token rate is not finite")
        #expect(TelemetryFormatting.tokenRate(.available(tokensPerSecond: .infinity, label: "derived")) == "Unavailable — Token rate is not finite")
        #expect(TelemetryFormatting.gibibytes(.nan) == "Unavailable — Memory value is not finite")
        #expect(TelemetryFormatting.gibibytes(.infinity) == "Unavailable — Memory value is not finite")
        #expect(TelemetryFormatting.duration(.available(seconds: .nan, label: "derived")) == "Unavailable — Duration is not finite")
        #expect(TelemetryFormatting.duration(.available(seconds: .infinity, label: "derived")) == "Unavailable — Duration is not finite")
        #expect(TelemetryFormatting.duration(.available(seconds: Double.greatestFiniteMagnitude, label: "derived")) == "Unavailable — Duration is out of range")
    }
}
