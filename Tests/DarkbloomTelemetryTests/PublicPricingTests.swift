import Foundation
import Testing
@testable import DarkbloomTelemetry
@testable import DarkbloomMonitor

struct PublicPricingTests {
    @Test("missing, null and noninteger prices cannot silently become zero", arguments: [
        #"{"model":"model","output_price":2}"#,
        #"{"model":"model","input_price":null,"output_price":2}"#,
        #"{"model":"model","input_price":"1","output_price":2}"#,
        #"{"model":"model","input_price":1.5,"output_price":2}"#,
        #"{"model":"model","input_price":9223372036854775808,"output_price":2}"#,
        #"{"model":null,"input_price":1,"output_price":2}"#
    ])
    func rejectsMalformedRequiredPrice(_ row: String) {
        #expect(throws: (any Error).self) {
            try PublicPricingSnapshot.parse(Data("{\"prices\":[\(row)]}".utf8), capturedAt: Date())
        }
    }

    @Test("explicit zero customer prices remain valid")
    func zeroIsNotMissing() throws {
        let snapshot = try PublicPricingSnapshot.parse(
            Data(#"{"prices":[{"model":"free","input_price":0,"output_price":0}]}"#.utf8),
            capturedAt: Date())
        #expect(snapshot.price(for: "free")?.inputUSDPerMillion == 0)
        #expect(snapshot.price(for: "free")?.outputUSDPerMillion == 0)
    }

    @MainActor
    @Test("pricing failure retains stale customer rates without changing realized earnings")
    func retainsStale() async {
        let store = MonitorStore(service: TelemetryService(source: PricingUnusedSource()), initial: .unavailable(now: Date()), publicPricingClient: PricingSequence())
        let earnings = store.earnings
        await store.refreshPublicPricing()
        #expect(store.publicPricing.value?.price(for: "model")?.inputMicroUSDPerMillion == 1)
        await store.refreshPublicPricing()
        guard case .stale = store.publicPricing else { Issue.record("Expected stale prices"); return }
        #expect(store.earnings == earnings)
    }
    @Test("customer price decoding converts micro-USD exactly and does not assign fallback to an unknown model")
    func exactRates() throws {
        let body = #"{"fallback_input_price":50000,"fallback_output_price":200000,"prices":[{"model":"Example/Model","input_price":220000,"output_price":2420000,"input_usd":"$0.2200","output_usd":"$2.4200"}]}"#
        let snapshot = try PublicPricingSnapshot.parse(Data(body.utf8), capturedAt: Date())
        #expect(snapshot.prices.first?.inputUSDPerMillion == Decimal(string: "0.22"))
        #expect(snapshot.prices.first?.outputUSDPerMillion == Decimal(string: "2.42"))
        #expect(snapshot.price(for: "unknown") == nil)
        #expect(snapshot.price(for: "example/model") == nil)
    }

    @Test("negative and duplicate customer prices are rejected")
    func invalidRates() {
        let row = #"{"model":"model","input_price":1,"output_price":2}"#
        for body in ["{\"prices\":[\(row),\(row)]}", "{\"prices\":[\(row.replacingOccurrences(of: ":1", with: ":-1"))]}"] {
            #expect(throws: (any Error).self) {
                try PublicPricingSnapshot.parse(Data(body.utf8), capturedAt: Date())
            }
        }
    }
}

private actor PricingSequence: PublicPricingFetching {
    var fetched = false
    func fetch(at capturedAt: Date) async throws -> PublicPricingSnapshot {
        guard !fetched else { throw PublicPricingError.httpStatus(429) }
        fetched = true
        return try PublicPricingSnapshot.parse(Data(#"{"prices":[{"model":"model","input_price":1,"output_price":2}]}"#.utf8), capturedAt: capturedAt)
    }
}

private struct PricingUnusedSource: TelemetrySource {
    struct Unused: Error {}
    func readDaemonState() async throws -> DaemonState { throw Unused() }
    func readLoadedModels() async throws -> LoadedModelsState { throw Unused() }
    func readStatus() async throws -> StatusSnapshot { throw Unused() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw Unused() }
}
