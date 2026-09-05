import AppKit
@testable import DarkbloomTelemetry
import SwiftUI

/// Standalone opt-in native dialog fixture; not part of the shipped monitor.
@main
struct LogExportFixtureApp: App {
    private let snapshot = try! LogExportSnapshot.make(events: [
        LogEvent(timestamp: Date(timeIntervalSince1970: 0), severity: .error,
                 category: "Authentication", message: "api_key=fixture-secret", source: .legacy,
                 processID: 42, processImage: "/Users/fixture-user/provider")
    ], sourceCapturedAt: Date(timeIntervalSince1970: 60), sourceIsStale: true,
       createdAt: Date(timeIntervalSince1970: 120))

    var body: some Scene {
        WindowGroup("Darkbloom Export Fixture") {
            if ProcessInfo.processInfo.arguments.contains("--logs-route") {
                LogsView(feed: .stale(value: EventFeed(events: [
                    LogEvent(timestamp: Date(timeIntervalSince1970: 0), severity: .warning,
                             category: "Inference", message: "Waiting for model memory headroom", source: .legacy,
                             processID: nil, processImage: nil),
                    LogEvent(timestamp: Date(timeIntervalSince1970: 30), severity: .error,
                             category: "Network", message: "Disconnected from coordinator", source: .unified,
                             processID: nil, processImage: nil)
                ], legacyReadAt: nil, unifiedActivityAt: nil),
                capturedAt: Date(timeIntervalSince1970: 60), reason: "Synthetic stale fixture"))
                    .padding(24)
                    .frame(width: 700, height: 650)
            } else {
                LogExportPreviewView(snapshot: snapshot)
            }
        }
    }
}
