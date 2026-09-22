import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomTelemetry
@testable import DarkbloomMonitor

@Suite("Activity rendering", .serialized)
@MainActor
struct ActivityViewTests {
    @Test("populated local activity fits the dashboard detail column", arguments: [780.0, 570.0])
    func rendersActivity(width: Double) async throws {
        let store = MonitorStore(
            service: TelemetryService(source: ActivityUnusedSource()),
            initial: .unavailable(now: Date()), earningsClient: ActivityFixtureClient()
        )
        let host = NSHostingController(rootView: ActivityView(store: store))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: width, height: 650))
        window.orderBack(nil)
        defer { window.close() }
        // Allow the view's bounded local query and chart layout to complete.
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutSubtreeIfNeeded()
        let view = host.view
        #expect(view.frame.width <= width)
        #expect(view.frame.height >= 600)
        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/darkbloom-activity-fixture.png"))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-activity-window-\(Int(width)).png"]
        try capture.run()
        capture.waitUntilExit()
    }
}

private struct ActivityFixtureClient: AccountEarningsFetching {
    func fetch(now: Date) async throws -> EarningsPresentationValue { .unavailable(reason: "Render fixture") }
    func activityModels(in range: DateInterval) async throws -> [String] { ["gemma", "qwen"] }

    func activityByModel(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar) async throws -> [ModelActivityBucket]? {
        try ActivityCalendar.intervals(in: range, unit: unit, calendar: calendar).enumerated().flatMap { index, interval -> [ModelActivityBucket] in
            guard index != 3 else { return [] }
            let gemma = Int64((index % 5 + 1) * 25_000)
            let qwen = Int64((index % 3 + 1) * 15_000)
            return [
                ModelActivityBucket(interval: interval, model: "gemma", workMicroUSD: gemma),
                ModelActivityBucket(interval: interval, model: "qwen", workMicroUSD: qwen),
            ]
        }
    }

    func modelHourlyEarningsAverages(in range: DateInterval) async throws -> [ModelHourlyEarningsAverage]? {
        [
            ModelHourlyEarningsAverage(model: "gemma", workMicroUSD: 100_000, earningHours: 4),
            ModelHourlyEarningsAverage(model: "qwen", workMicroUSD: 120_000, earningHours: 3),
        ]
    }

    func modelActivity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar, model: String?) async throws -> [ActivityBucket]? {
        guard let model else { return try await activity(in: range, unit: unit, calendar: calendar) }
        return try ActivityCalendar.intervals(in: range, unit: unit, calendar: calendar).enumerated().map { index, interval in
            let work: Int64 = model == "gemma"
                ? Int64((index % 5 + 1) * 25_000)
                : Int64((index % 3 + 1) * 15_000)
            return ActivityBucket(interval: interval, totals: index == 3 ? nil : ActivityTotals(
                workMicroUSD: work, rewardMicroUSD: 0, jobs: 1, promptTokens: 100, completionTokens: 200
            ), coverage: index == 3 ? .unavailable : .recorded)
        }
    }

    func activity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar) async throws -> [ActivityBucket]? {
        try ActivityCalendar.intervals(in: range, unit: unit, calendar: calendar).enumerated().map { index, interval in
            let gemma = Int64((index % 5 + 1) * 25_000)
            let qwen = Int64((index % 3 + 1) * 15_000)
            return ActivityBucket(interval: interval, totals: index == 3 ? nil : ActivityTotals(
                workMicroUSD: gemma + qwen,
                rewardMicroUSD: 10_000, jobs: Int64(index + 1), promptTokens: 100, completionTokens: 200
            ), coverage: index == 3 ? .unavailable : .recorded)
        }
    }
}

private struct ActivityUnusedSource: TelemetrySource {
    struct Unused: Error {}
    func readDaemonState() async throws -> DaemonState { throw Unused() }
    func readLoadedModels() async throws -> LoadedModelsState { throw Unused() }
    func readStatus() async throws -> StatusSnapshot { throw Unused() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw Unused() }
}
