import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Network maintenance and cache health")
struct NetworkMaintenanceTests {
    @Test func maintenanceIsNotEmptyDemand() throws {
        let draining = try NetworkCapacityParser.parse(Data(#"{"models":[],"draining":true}"#.utf8), capturedAt: .now)
        #expect(draining.isDraining)
        let old = try NetworkCapacityParser.parse(Data(#"{"models":[]}"#.utf8), capturedAt: .now)
        #expect(!old.isDraining)
    }

    @Test func cacheReportsOnlyNetworkHealth() throws {
        let data = Data(#"{"routing_mode":"on","sidecar":{"enabled":true,"running":true,"ready":true},"providers":{"v2_ready_models":7},"ignored_private_field":"never retained"}"#.utf8)
        let result = try NetworkCacheSnapshot.parse(data, capturedAt: .now)
        #expect(result.routingMode == .on)
        #expect(result.plannerReady == true)
        #expect(result.isFresh(at: result.capturedAt.addingTimeInterval(120)))
        #expect(!result.isFresh(at: result.capturedAt.addingTimeInterval(121)))
        #expect(!result.isFresh(at: result.capturedAt.addingTimeInterval(-1)))
    }

    @Test func unknownCacheStateIsNotHealthy() throws {
        let value = try NetworkCacheSnapshot.parse(Data(#"{"routing_mode":"new_future_mode"}"#.utf8), capturedAt: .now)
        #expect(value.routingMode == .unknown)
        #expect(value.plannerReady == nil)
        #expect(throws: NetworkCapacityError.responseTooLarge) {
            try NetworkCacheSnapshot.parse(Data(repeating: 32, count: 262_145), capturedAt: .now)
        }
    }
}
