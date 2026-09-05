import Foundation
import Testing
@testable import DarkbloomTelemetry

struct OpportunityEvidenceTests {
    @Test("recommendation ignores stale and duplicate payout evidence")
    func evidence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 10000)
        let capacity = try NetworkCapacityParser.parse(Data(#"{"models":[{"id":"a","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":10,"running_providers":1,"cold_providers":0,"active_requests":5,"queued_requests":0,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1},{"id":"b","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":10,"running_providers":1,"cold_providers":0,"active_requests":5,"queued_requests":0,"queue_limit":8,"aggregate_tps":20,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1}]}"#.utf8), capturedAt: now)
        func work(_ captured: Date) -> ModelWorkEarnings {
            ModelWorkEarnings(model: "b", queryPeriod: DateInterval(start: Date(timeIntervalSince1970: 0), end: captured),
                sourceCapturedAt: captured, workMicroUSD: 300, jobs: 2, recordedHours: 1, unknownHours: 1, uncertainBoundaryHours: 1)
        }
        func result(_ values: [ModelWorkEarnings], at date: Date = Date(timeIntervalSince1970: 10000)) -> ModelOpportunityRecommendation? {
            ModelOpportunityRanker.recommend(capacity: capacity, enabledModelIDs: ["a", "b"],
                observedWork: values, tokenRates: [], now: date, calendar: calendar)
        }
        #expect(result([work(now)])?.modelID == "b")
        #expect(result([work(now)])?.observedMicroUSDPerJob == 150)
        #expect(result([work(now.addingTimeInterval(-601))])?.modelID == "a")
        #expect(result([work(now), work(now)])?.modelID == "a")
        #expect(result([work(now)], at: now.addingTimeInterval(121)) == nil)
    }
}
