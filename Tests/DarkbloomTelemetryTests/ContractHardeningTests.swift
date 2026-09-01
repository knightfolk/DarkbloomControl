import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Contract hardening")
struct ContractHardeningTests {
    @Test("schema 2 state is rejected instead of partially decoded")
    func rejectsUnknownStateSchema() throws {
        let data = Data("{\"schema\":2}".utf8)
        #expect(throws: TelemetryContractError.unsupportedSchema(
            source: "daemon-state.json", found: 2, supported: 1
        )) {
            try DaemonStateParser.parse(data)
        }
    }

    @Test("loaded-model schema mismatch names its source")
    func rejectsUnknownLoadedModelsSchema() throws {
        let data = Data("{\"schema\":7}".utf8)
        #expect(throws: TelemetryContractError.unsupportedSchema(
            source: "loaded-models.json", found: 7, supported: 1
        )) {
            try LoadedModelsParser.parse(data)
        }
    }

    @Test(arguments: [
        (1_000.0, 1_000.0, TokenRate.unavailable(reason: "State timestamp did not advance")),
        (1_000.0, 999.0, TokenRate.unavailable(reason: "State timestamp did not advance")),
    ])
    func rejectsNonAdvancingStateTime(previous: Double, current: Double, expected: TokenRate) {
        #expect(TelemetryDeriver.tokenRate(
            previous: sample(tokens: 10, writtenAt: previous),
            current: sample(tokens: 20, writtenAt: current)
        ) == expected)
    }

    @Test("backwards token counter is unavailable")
    func rejectsBackwardsCounter() {
        #expect(TelemetryDeriver.tokenRate(
            previous: sample(tokens: 20, writtenAt: 1_000),
            current: sample(tokens: 10, writtenAt: 1_004)
        ) == .unavailable(reason: "Token counter moved backwards"))
    }

    @Test("first sample is unavailable")
    func waitsForSecondSample() {
        #expect(TelemetryDeriver.tokenRate(
            previous: nil,
            current: sample(tokens: 10, writtenAt: 1_004)
        ) == .unavailable(reason: "Waiting for a second telemetry sample"))
    }

    @Test("clock skew never becomes a zero duration")
    func rejectsClockSkew() {
        let state = sample(tokens: 10, writtenAt: 2_000, startedAt: 2_100, trustAt: 2_200)
        #expect(TelemetryDeriver.uptime(state: state, now: 2_050) ==
            .unavailable(reason: "Provider start time is in the future"))
        #expect(TelemetryDeriver.snapshotAge(state: state, now: 1_999) ==
            .unavailable(reason: "State write time is in the future"))
        #expect(TelemetryDeriver.trustAge(state: state, now: 2_199) ==
            .unavailable(reason: "Trust receipt time is in the future"))
    }

    @Test("one malformed status value does not erase unrelated fields")
    func isolatesMalformedStatusField() throws {
        let url = try #require(Bundle.module.url(
            forResource: "status-partial", withExtension: "txt", subdirectory: "Fixtures"
        ))
        let data = try Data(contentsOf: url)
        let status = StatusParser.parse(String(decoding: data, as: UTF8.self))
        #expect(status.providerName == "darkbloom-test")
        #expect(status.backendPort == nil)
        #expect(status.trust == "hardware / online")
    }
}

private extension ContractHardeningTests {
    func sample(
        tokens: Int64,
        writtenAt: TimeInterval,
        startedAt: TimeInterval? = nil,
        trustAt: TimeInterval? = nil
    ) -> DaemonState {
        DaemonState(
            schema: 1,
            version: "0.8.15",
            currentModel: "model",
            warmModels: ["model"],
            stats: .init(tokensGenerated: tokens, requestsServed: 1, usageGaps: 0),
            trust: .init(
                level: "hardware",
                status: "online",
                reason: "same_binary",
                receivedAt: trustAt ?? writtenAt
            ),
            capacity: .init(totalMemoryGB: 64, gpuMemoryActiveGB: 10, gpuMemoryCacheGB: 1),
            slots: [],
            inferenceActive: true,
            startedAt: startedAt ?? (writtenAt - 100),
            writtenAt: writtenAt,
            pid: 42,
            processIdentity: .init(pid: 42, startTimeMicros: 900_000_000)
        )
    }
}
