import Foundation
import Testing
@testable import DarkbloomTelemetry
@testable import DarkbloomMonitor

struct PublicCatalogTests {
    @MainActor
    @Test("a failed catalog refresh retains explicitly stale metadata without changing demand")
    func retainsLastGood() async throws {
        let client = CatalogSequence(data: Data("{\"models\":[\(model)]}".utf8))
        let store = MonitorStore(service: TelemetryService(source: CatalogUnusedSource()),
                                 initial: .unavailable(now: Date()), publicCatalogClient: client)
        await store.refreshPublicCatalog()
        #expect(store.publicCatalog.value?.models.first?.id == "Example/Model")
        let demand = store.networkCapacity
        await store.refreshPublicCatalog()
        guard case .stale(let retained, _, _) = store.publicCatalog else {
            Issue.record("Expected retained stale catalog"); return
        }
        #expect(retained.models.first?.id == "Example/Model")
        #expect(store.networkCapacity == demand)
    }
    let model = #"{"id":"Example/Model","display_name":"Example","family":"Example","model_type":"text","capabilities":["chat"],"size_gb":6.1,"min_ram_gb":24,"active":true,"future_field":true}"#

    @Test("public envelope preserves canonical identifiers and ignores unrelated fields")
    func parsesEnvelope() throws {
        let result = try PublicCatalogSnapshot.parse(Data("{\"models\":[\(model)]}".utf8), capturedAt: Date(timeIntervalSince1970: 100))
        #expect(result.models.first?.id == "Example/Model")
        #expect(result.models.first?.minimumRAMGB == 24)
        #expect(result.capturedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("invalid public metadata never becomes a usable catalog")
    func rejectsInvalid() {
        for body in ["[\(model)]", "{\"models\":[\(model),\(model)]}",
                     "{\"models\":[\(model.replacingOccurrences(of: "6.1", with: "-1"))]}"] {
            #expect(throws: (any Error).self) {
                try PublicCatalogSnapshot.parse(Data(body.utf8), capturedAt: Date())
            }
        }
    }
}

private actor CatalogSequence: PublicCatalogFetching {
    let data: Data
    var fetched = false
    init(data: Data) { self.data = data }
    func fetch(at capturedAt: Date) async throws -> PublicCatalogSnapshot {
        guard !fetched else { throw PublicCatalogError.httpStatus(429) }
        fetched = true
        return try PublicCatalogSnapshot.parse(data, capturedAt: capturedAt)
    }
}

private struct CatalogUnusedSource: TelemetrySource {
    struct Unused: Error {}
    func readDaemonState() async throws -> DaemonState { throw Unused() }
    func readLoadedModels() async throws -> LoadedModelsState { throw Unused() }
    func readStatus() async throws -> StatusSnapshot { throw Unused() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw Unused() }
}
