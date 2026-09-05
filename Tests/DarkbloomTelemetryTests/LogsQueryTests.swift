import Testing
import AppKit
import SwiftUI
@testable import DarkbloomTelemetry
@testable import DarkbloomMonitor

struct LogsQueryTests {
    @Test("identical messages from distinct sources and processes survive retention and filtering")
    func retainsEventOrigins() {
        let at = Date(timeIntervalSince1970: 1000)
        func row(_ source: LogSource, _ pid: Int32?, _ image: String?) -> LogEvent {
            LogEvent(timestamp: at, severity: .error, category: "Inference", message: "Load failed",
                source: source, processID: pid, processImage: image)
        }
        let legacy = row(.legacy, nil, nil)
        let first = row(.unified, 10, "worker-a")
        let second = row(.unified, 11, "worker-a")
        let otherImage = row(.unified, 11, "worker-b")
        var buffer = EventBuffer(capacity: 100)
        buffer.insert([legacy, first, second, otherImage, first])
        #expect(buffer.events.count == 4)
        #expect(LogsQuery(source: .legacy).apply(buffer.events) == [legacy])
        let unified = LogsQuery(source: .unified).apply(buffer.events)
        #expect(unified.count == 3)
        #expect(unified.contains(first))
        #expect(unified.contains(second))
        #expect(unified.contains(otherImage))
    }
    @MainActor
    @Test("log rows render within a narrow dashboard detail column")
    func render() async throws {
        var buffer = EventBuffer(capacity: 100)
        buffer.insert([
            event(.warning, .unified, "Inference", "Example model load delayed; waiting for memory headroom."),
            event(.error, .legacy, "Authentication", "Authorization: Bearer fixture-secret")
        ])
        let feed = EventFeed(events: buffer.events, legacyReadAt: nil, unifiedActivityAt: Date())
        let host = NSHostingController(rootView: LogsView(feed: .available(value: feed, capturedAt: Date())))
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
            capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-dashboard-logs.png"]
            try capture.run()
            capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
        }
    }

    @Test("log filters intersect severity source and case-insensitive text without altering events")
    func filters() {
        let events = [
            event(.error, .unified, "Inference", "Qwen failed"),
            event(.warning, .unified, "Inference", "Qwen slow"),
            event(.error, .legacy, "Inference", "Qwen failed"),
            event(.error, .unified, "Memory", "Pressure")
        ]
        #expect(LogsQuery(severity: .error, source: .unified, text: " qWeN ").apply(events) == [events[0]])
        #expect(LogsQuery(text: "MEMORY").apply(events) == [events[3]])
        #expect(LogsQuery().apply(events) == events)
        #expect(LogsQuery(text: "missing").apply(events).isEmpty)
    }

    private func event(_ severity: LogSeverity, _ source: LogSource, _ category: String, _ message: String) -> LogEvent {
        LogEvent(timestamp: nil, severity: severity, category: category, message: message,
                 source: source, processID: nil, processImage: nil)
    }
}
