import Foundation
import AppKit
import SwiftUI
import Testing
@testable import DarkbloomTelemetry
@testable import DarkbloomMonitor

struct NetworkSeriesTests {
    @MainActor
    @Test("network chart and exact-value table fit a narrow detail column")
    func rendersHistory() async throws {
        let largeRow = row.replacingOccurrences(of: "\"requests\":2", with: "\"requests\":20000000")
        let data = body(largeRow + "," + largeRow.replacingOccurrences(of: "00:00:00Z", with: "01:00:00Z"))
        let series = try NetworkSeriesSnapshot.parse(data, capturedAt: Date())
        let host = NSHostingController(rootView: NetworkHistoryView(source: .available(value: series, capturedAt: Date())))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 570, height: 650))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        #expect(host.view.frame.width <= 570)
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-network-history.png"]
            try capture.run()
            capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
        }
    }

    @MainActor
    @Test("series is suspended while closed and retains stale history after a failed refresh")
    func storeLifecycle() async throws {
        let clock = try Date.ISO8601FormatStyle().parse("2026-09-05T00:02:00Z")
        let store = MonitorStore(service: TelemetryService(source: SeriesUnusedSource()), initial: .unavailable(now: clock), networkSeriesClient: SeriesSequence(data: body(row)), now: { clock })
        await store.refreshNetworkSeries()
        #expect(store.networkSeries.value == nil)
        store.setDashboardVisible(true)
        await store.refreshNetworkSeries()
        #expect(store.networkSeries.value?.buckets.count == 1)
        await store.refreshNetworkSeries()
        guard case .stale = store.networkSeries else { Issue.record("Expected stale history"); return }
        store.setDashboardVisible(false)
        #expect(store.networkSeries.value?.buckets.count == 1)
    }
    let row = #"{"timestamp":"2026-09-04T00:00:00Z","requests":2,"prompt_tokens":30,"completion_tokens":10}"#
    func body(_ rows: String) -> Data {
        Data("{\"window\":\"24h\",\"bucket_seconds\":1800,\"start_at\":\"2026-09-04T00:00:00Z\",\"end_at\":\"2026-09-05T00:00:00Z\",\"updated_at\":\"2026-09-05T00:01:00Z\",\"time_series\":[\(rows)]}".utf8)
    }

    @Test("network series preserves reported counts without filling missing buckets")
    func preservesGaps() throws {
        let snapshot = try NetworkSeriesSnapshot.parse(body(row), capturedAt: Date())
        #expect(snapshot.buckets.count == 1)
        #expect(snapshot.buckets.first?.requests == 2)
        #expect(snapshot.buckets.first?.promptTokens == 30)
        #expect(snapshot.buckets.first?.completionTokens == 10)
        #expect(snapshot.bucketSeconds == 1800)
    }

    @Test("duplicates negative counts and off-grid timestamps are invalid")
    func invalidBuckets() {
        for rows in [row + "," + row, row.replacingOccurrences(of: ":2,", with: ":-2,"), row.replacingOccurrences(of: "00:00:00Z", with: "00:00:01Z")] {
            #expect(throws: (any Error).self) {
                try NetworkSeriesSnapshot.parse(body(rows), capturedAt: Date())
            }
        }
    }

    @Test("a bucket cannot extend beyond the window and the source update cannot precede its window end")
    func rejectsInconsistentWindow() {
        let crossing = String(decoding: body(row.replacingOccurrences(of: "00:00:00Z", with: "23:53:20Z")), as: UTF8.self)
            .replacingOccurrences(of: "\"bucket_seconds\":1800", with: "\"bucket_seconds\":500")
        let earlyUpdate = String(decoding: body(row), as: UTF8.self)
            .replacingOccurrences(of: "2026-09-05T00:01:00Z", with: "2026-09-04T23:59:00Z")
        for invalid in [crossing, earlyUpdate] {
            #expect(throws: (any Error).self) {
                try NetworkSeriesSnapshot.parse(Data(invalid.utf8), capturedAt: Date())
            }
        }
    }
}

private actor SeriesSequence: NetworkSeriesFetching {
    let data: Data
    var fetched = false
    init(data: Data) { self.data = data }
    func fetch(at capturedAt: Date) async throws -> NetworkSeriesSnapshot {
        guard !fetched else { throw NetworkSeriesError.httpStatus(429) }
        fetched = true
        return try NetworkSeriesSnapshot.parse(data, capturedAt: capturedAt)
    }
}

private struct SeriesUnusedSource: TelemetrySource {
    struct Unused: Error {}
    func readDaemonState() async throws -> DaemonState { throw Unused() }
    func readLoadedModels() async throws -> LoadedModelsState { throw Unused() }
    func readStatus() async throws -> StatusSnapshot { throw Unused() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw Unused() }
}
