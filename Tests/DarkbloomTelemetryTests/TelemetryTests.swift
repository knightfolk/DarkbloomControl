import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Observed Darkbloom telemetry contract")
struct TelemetryTests {
    @Test("daemon-state schema maps every observed monitor field")
    func parsesDaemonState() throws {
        let data = try fixture("daemon-state-online", extension: "json")
        let state = try DaemonStateParser.parse(data)

        #expect(state.schema == 1)
        #expect(state.version == "0.8.15")
        #expect(state.currentModel == "gemma-4-26b-qat-4bit")
        #expect(state.warmModels == ["gemma-4-26b-qat-4bit"])
        #expect(state.stats == .init(tokensGenerated: 120, requestsServed: 3, usageGaps: 1))
        #expect(state.trust == .init(level: "hardware", status: "online", reason: "same_binary", receivedAt: 1_788_223_560.418243))
        #expect(state.capacity == .init(totalMemoryGB: 64, gpuMemoryActiveGB: 14.759410054422915, gpuMemoryCacheGB: 0.270594360306859))
        #expect(state.slots == [.init(model: "gemma-4-26b-qat-4bit", mtpEnabled: true, mtpActive: true, mtpReason: nil, kvBackend: "contiguous", requestedKVBackend: "auto")])
        #expect(state.processIdentity == .init(pid: 10004, startTimeMicros: 1_788_223_520_528_023))
        #expect(state.inferenceActive == false)
    }

    @Test("loaded models remain distinct from warm models")
    func parsesLoadedModels() throws {
        let data = try fixture("loaded-models", extension: "json")
        let loaded = try LoadedModelsParser.parse(data)

        #expect(loaded.schema == 1)
        #expect(loaded.models == ["gemma-4-26b-qat-4bit", "gpt-oss-20b"])
        #expect(loaded.updatedAt == 1_788_223_558.748022)
    }

    @Test("derived throughput uses token and state timestamp deltas")
    func derivesTokenRate() {
        let previous = sample(tokens: 100, writtenAt: 1_000, pid: 42, startMicros: 900_000_000)
        let current = sample(tokens: 160, writtenAt: 1_004, pid: 42, startMicros: 900_000_000)

        #expect(TelemetryDeriver.tokenRate(previous: previous, current: current) == .available(tokensPerSecond: 15, label: "derived"))
    }

    @Test("zero token progress has an explicit unavailable reason")
    func doesNotClaimIdleRate() {
        let previous = sample(tokens: 100, writtenAt: 1_000, pid: 42, startMicros: 900_000_000)
        let current = sample(tokens: 100, writtenAt: 1_004, pid: 42, startMicros: 900_000_000)

        #expect(TelemetryDeriver.tokenRate(previous: previous, current: current) == .unavailable(reason: "No token progress in the polling window"))
    }

    @Test("a provider restart prevents cross-process rate derivation")
    func doesNotDeriveAcrossRestart() {
        let previous = sample(tokens: 100, writtenAt: 1_000, pid: 42, startMicros: 900_000_000)
        let current = sample(tokens: 10, writtenAt: 1_004, pid: 43, startMicros: 904_000_000)

        #expect(TelemetryDeriver.tokenRate(previous: previous, current: current) == .unavailable(reason: "Provider process changed between samples"))
    }

    @Test("status text preserves observed configuration and slot posture")
    func parsesStatus() throws {
        let text = String(decoding: try fixture("status", extension: "txt"), as: UTF8.self)
        let status = StatusParser.parse(text)

        #expect(status.version == "0.8.15")
        #expect(status.providerName == "darkbloom-mac17-9")
        #expect(status.configuredModel == "auto-select")
        #expect(status.idleTimeout == "60m")
        #expect(status.hardware == "Apple M5 Pro, 64 GB RAM, 20 GPU cores")
        #expect(status.daemon == "running (pid 10004, up 3m)")
        #expect(status.trust == "hardware / online")
        #expect(status.trustReason == "same_binary")
        #expect(status.mostRecentlyUsed == "gemma-4-26b-qat-4bit")
        #expect(status.requestCount == 7)
        #expect(status.tokenCount == 420)
        #expect(status.slotPosture == ["gemma-4-26b-qat-4bit: kv=contiguous (requested auto) | mtp=enabled, active"])
    }

    @Test("legacy log parser retains only lifecycle, warning, and error events")
    func parsesBoundedEvents() throws {
        let text = String(decoding: try fixture("provider", extension: "log"), as: UTF8.self)
        let events = LegacyLogParser.parse(text, limit: 2)

        #expect(events.map(\.severity) == [.warning, .error])
        #expect(events.map(\.message) == ["Model load is taking longer than expected", "Model load failed"])
        #expect(events.map(\.source) == [.legacy, .legacy])
        #expect(events.allSatisfy { $0.processID == nil && $0.processImage == nil })
    }

    @Test("bounded tail discards a partial first line")
    func readsBoundedTail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("first\nsecond\nthird\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try BoundedFileTail.read(url: url, maxBytes: 12)

        #expect(String(decoding: data, as: UTF8.self) == "third\n")
    }

    private func fixture(_ name: String, extension ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private func sample(tokens: Int64, writtenAt: TimeInterval, pid: Int32, startMicros: Int64) -> DaemonState {
        DaemonState(
            schema: 1,
            version: "0.8.15",
            currentModel: "model",
            warmModels: ["model"],
            stats: .init(tokensGenerated: tokens, requestsServed: 1, usageGaps: 0),
            trust: .init(level: "hardware", status: "online", reason: "same_binary", receivedAt: writtenAt),
            capacity: .init(totalMemoryGB: 64, gpuMemoryActiveGB: 10, gpuMemoryCacheGB: 1),
            slots: [],
            inferenceActive: true,
            startedAt: writtenAt - 100,
            writtenAt: writtenAt,
            pid: pid,
            processIdentity: .init(pid: pid, startTimeMicros: startMicros)
        )
    }
}
