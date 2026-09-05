import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Opportunity rendering", .serialized)
@MainActor
struct OpportunityViewTests {
    @Test("network cards fit a narrow dashboard with fresh and failed-refresh data", arguments: [false, true])
    func render(stale: Bool) async throws {
        let store = MonitorStore(service: TelemetryService(source: OpportunityUnusedSource()),
                                 initial: .unavailable(now: Date()), networkCapacityClient: OpportunityFixture(),
                                 publicCatalogClient: OpportunityMetadataFixture())
        await store.refreshNetworkCapacity()
        await store.refreshPublicCatalog()
        if stale {
            await store.refreshNetworkCapacity()
            await store.refreshPublicCatalog()
        }
        #expect(PopupNetworkDemandPresentation.freshness(of: store.networkCapacity, at: Date()) == (stale ? .stale : .current))
        let host = NSHostingController(rootView: OpportunityView(store: store, controlStore: nil))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 570, height: 650))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutSubtreeIfNeeded()
        #expect(host.view.frame.width <= 570)
        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-opportunity-\(stale ? "stale" : "fresh").png"]
        try capture.run()
        capture.waitUntilExit()
    }
}

private actor OpportunityFixture: NetworkCapacityFetching {
    var fetched = false
    func fetch(at capturedAt: Date) async throws -> NetworkCapacitySnapshot {
        guard !fetched else { throw NetworkCapacityError.httpStatus(429) }
        fetched = true
        return NetworkCapacitySnapshot(models: [NetworkModelCapacity(
            id: "Example/Attributed-Model", ready: true, canAccept: true, routableProviders: 12,
            warmProviders: 4, runningProviders: 2, coldProviders: 8, activeRequests: 3,
            queuedRequests: 1, queueLimit: 16, aggregateTokensPerSecond: 120,
            estimatedTimeToFirstTokenMS: 100, tokenBudgetRemaining: 500, tokenBudgetTotal: 1000
        )], capturedAt: capturedAt)
    }
}

private actor OpportunityMetadataFixture: PublicCatalogFetching {
    var fetched = false
    func fetch(at capturedAt: Date) async throws -> PublicCatalogSnapshot {
        guard !fetched else { throw PublicCatalogError.httpStatus(429) }
        fetched = true
        return try PublicCatalogSnapshot.parse(Data(#"{"models":[{"id":"Example/Attributed-Model","display_name":"Example","family":"example","model_type":"llm","capabilities":["text"],"size_gb":20,"min_ram_gb":32,"active":true}]}"#.utf8), capturedAt: capturedAt)
    }
}

private struct OpportunityUnusedSource: TelemetrySource {
    struct Unused: Error {}
    func readDaemonState() async throws -> DaemonState { throw Unused() }
    func readLoadedModels() async throws -> LoadedModelsState { throw Unused() }
    func readStatus() async throws -> StatusSnapshot { throw Unused() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw Unused() }
}
