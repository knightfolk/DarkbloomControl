import Foundation
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

struct ModelNetworkContextTests {
    @Test("work earnings context identifies partial calendar coverage and rejects another day")
    func workContext() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 9000)
        let value = ModelWorkEarnings(model: "model", queryPeriod: DateInterval(start: Date(timeIntervalSince1970: 0), end: now),
            sourceCapturedAt: now, workMicroUSD: 125_000, jobs: 2, recordedHours: 1, unknownHours: 1, uncertainBoundaryHours: 1)
        let label = ModelNetworkContext.workLabel(modelID: "model", values: [value], now: now, calendar: calendar)
        #expect(label?.contains("$0.125") == true)
        #expect(label?.contains("partial") == true)
        #expect(label?.contains("1 recorded") == true)
        #expect(label?.contains("1 unknown") == true)
        #expect(ModelNetworkContext.workLabel(modelID: "Model", values: [value], now: now, calendar: calendar) == nil)
        #expect(ModelNetworkContext.workLabel(modelID: "model", values: [value, value], now: now, calendar: calendar) == nil)
        #expect(ModelNetworkContext.workLabel(modelID: "model", values: [value], now: Date(timeIntervalSince1970: 86400), calendar: calendar) == nil)
        #expect(ModelNetworkContext.workLabel(modelID: "model", values: [value], now: now.addingTimeInterval(601), calendar: calendar)?.contains("stale") == true)
    }
    @Test("performance context requires exact unique attributed samples and a valid period")
    func performanceContext() {
        let now = Date(timeIntervalSince1970: 1000)
        let period = DateInterval(start: now.addingTimeInterval(-60), end: now)
        let good = ModelTokenRateAverage(model: "model", tokensPerSecond: 25, sampleCount: 2, queryPeriod: period)
        #expect(ModelNetworkContext.performanceLabel(modelID: "model", averages: [good], now: now)?.contains("2 samples") == true)
        #expect(ModelNetworkContext.performanceLabel(modelID: "Model", averages: [good], now: now) == nil)
        #expect(ModelNetworkContext.performanceLabel(modelID: "model", averages: [good, good], now: now) == nil)
        #expect(ModelNetworkContext.performanceLabel(modelID: "model", averages: [good], now: now.addingTimeInterval(-1)) == nil)
        let unknown = ModelTokenRateAverage(model: "model", tokensPerSecond: 25, sampleCount: 2)
        #expect(ModelNetworkContext.performanceLabel(modelID: "model", averages: [unknown], now: now) == nil)
    }

    @Test("demand context ages independently and never matches a different model")
    func demandContext() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let data = Data(#"{"models":[{"id":"saved-model","ready":true,"can_accept":true,"routable_providers":4,"warm_providers":2,"running_providers":1,"cold_providers":2,"active_requests":3,"queued_requests":1,"queue_limit":8,"aggregate_tps":40,"estimated_ttft_ms":300,"token_budget_remaining":9,"token_budget_total":10}]}"#.utf8)
        let snapshot = try NetworkCapacityParser.parse(data, capturedAt: now)
        let source: SourceAvailability<NetworkCapacitySnapshot> = .available(value: snapshot, capturedAt: now)
        let missing: SourceAvailability<PublicPricingSnapshot> = .unavailable(reason: "No pricing")
        #expect(ModelNetworkContext.labels(modelID: "saved-model", capacity: source, pricing: missing, now: now) == ["Network: 3 active · 1 queued · current · 0s ago"])
        #expect(ModelNetworkContext.labels(modelID: "saved-model", capacity: source, pricing: missing, now: now.addingTimeInterval(121)) == ["Network: 3 active · 1 queued · stale · 2m ago"])
        #expect(ModelNetworkContext.labels(modelID: "other-model", capacity: source, pricing: missing, now: now).isEmpty)
    }

    @Test("model pricing context uses exact IDs and preserves stale attribution")
    func pricingContext() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let price = try PublicPricingSnapshot.parse(Data(#"{"prices":[{"model":"Example/Model","input_price":220000,"output_price":2420000}]}"#.utf8), capturedAt: now)
        let stale: SourceAvailability<PublicPricingSnapshot> = .stale(value: price, capturedAt: now, reason: "Failed")
        let missing: SourceAvailability<NetworkCapacitySnapshot> = .unavailable(reason: "Missing")
        #expect(ModelNetworkContext.labels(modelID: "example/model", capacity: missing, pricing: stale, now: now).isEmpty)
        let labels = ModelNetworkContext.labels(modelID: "Example/Model", capacity: missing, pricing: stale, now: now)
        #expect(labels == ["Customer /1M tokens: $0.22 in · $2.42 out · stale · 0s ago"])
        let later = ModelNetworkContext.labels(modelID: "Example/Model", capacity: missing, pricing: .available(value: price, capturedAt: now), now: now.addingTimeInterval(901))
        #expect(later.first?.contains("stale · 15m ago") == true)
        let future = ModelNetworkContext.labels(modelID: "Example/Model", capacity: missing, pricing: stale, now: now.addingTimeInterval(-1))
        #expect(future.first?.contains("future timestamp") == true)
    }
}
