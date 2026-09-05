import AppKit
import SwiftUI
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Health rendering", .serialized)
@MainActor
struct HealthViewTests {
    @Test("thermal and retained slot diagnostics render without acquiring CLI data", arguments: [false, true])
    func render(hasDaemon: Bool) async throws {
        let now = Date()
        let url = try #require(Bundle.module.url(forResource: "daemon-state-online", withExtension: "json", subdirectory: "Fixtures"))
        let state = try DaemonStateParser.parse(Data(contentsOf: url))
        let initial = TelemetrySnapshot(
            state: hasDaemon ? .stale(value: state, capturedAt: now, reason: "Fixture read timeout") : .unavailable(reason: "Fixture permission denied"),
            loadedModels: .unavailable(reason: "Not acquired"), status: .unavailable(reason: "Not acquired"),
            eventFeed: .unavailable(reason: "Not acquired"), tokenRate: .unavailable(reason: "No interval"),
            diagnostics: [], capturedAt: now, menuStatus: hasDaemon ? .stale : .unavailable
        )
        let store = MonitorStore(service: TelemetryService(source: HealthUnusedSource()), initial: initial)
        let host = NSHostingController(rootView: HealthView(store: store))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 570, height: 1050))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutSubtreeIfNeeded()
        #expect(store.snapshot == initial)
        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-health-\(hasDaemon ? "slots" : "missing").png"]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }
}

private struct HealthUnusedSource: TelemetrySource {
    struct UnexpectedRead: Error {}
    func readDaemonState() async throws -> DaemonState { Issue.record("Health view started acquisition"); throw UnexpectedRead() }
    func readLoadedModels() async throws -> LoadedModelsState { Issue.record("Health view started acquisition"); throw UnexpectedRead() }
    func readStatus() async throws -> StatusSnapshot { Issue.record("Health view started acquisition"); throw UnexpectedRead() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { Issue.record("Health view started acquisition"); throw UnexpectedRead() }
}
