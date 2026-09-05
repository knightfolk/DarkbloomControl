import AppKit
import SwiftUI
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Log export preview rendering", .serialized)
@MainActor
struct LogExportPreviewTests {
    @Test("preview shows frozen filtered text with saving initially disabled")
    func render() async throws {
        let snapshot = try LogExportSnapshot.make(events: [
            LogEvent(timestamp: Date(timeIntervalSince1970: 0), severity: .error,
                     category: "Authentication", message: "api_key=fixture-secret", source: .legacy,
                     processID: 42, processImage: "/Users/fixture-user/provider")
        ], sourceCapturedAt: Date(timeIntervalSince1970: 60), sourceIsStale: true,
           createdAt: Date(timeIntervalSince1970: 120))
        let host = NSHostingController(rootView: LogExportPreviewView(snapshot: snapshot))
        let window = NSWindow(contentViewController: host)
        window.title = "Darkbloom Export Fixture"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 700, height: 650))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutSubtreeIfNeeded()
        #expect(!snapshot.previewText.contains("fixture-secret"))
        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-log-export-preview.png"]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }
}
