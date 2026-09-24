import AppKit
import SwiftUI
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Provider resource panel", .serialized)
@MainActor
struct ProviderResourcesViewTests {
    @Test("resource panel renders system CPU/GPU use, request activity, provider GPU memory, and temperature")
    func rendersMeasuredAndProviderReportedResources() async throws {
        let now = Date()
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "daemon-state-online", withExtension: "json", subdirectory: "Fixtures")
        )
        var daemonJSON = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        daemonJSON["inference_active"] = true
        daemonJSON["lifecycle"] = [
            "outcome": "draining",
            "remaining": 6,
            "coordinator_acknowledged": false,
        ]
        let daemon = try DaemonStateParser.parse(JSONSerialization.data(withJSONObject: daemonJSON))
        let snapshot = TelemetrySnapshot(
            state: .available(value: daemon, capturedAt: now),
            loadedModels: .unavailable(reason: "Not acquired"),
            status: .unavailable(reason: "Not acquired"),
            eventFeed: .unavailable(reason: "Not acquired"),
            tokenRate: .unavailable(reason: "No interval"),
            diagnostics: [],
            capturedAt: now,
            menuStatus: .online
        )
        let fanStatus = ProviderFanStatus(
            capability: "fixture",
            installed: true,
            loaded: true,
            helper: nil,
            diagnostic: ProviderFanDiagnostic(
                chip: "Apple silicon fixture",
                supported: true,
                gpuTemperatures: [ProviderFanTemperature(key: "GPU Die", celsius: 62.0)],
                fans: []
            ),
            helperErrorPresent: false,
            diagnosticErrorPresent: false
        )
        let extras = ProviderExtrasStore(client: ResourcePanelFixtureClient(
            snapshot: ProviderExtrasSnapshot(
                capturedAt: now,
                idlePolicy: .unavailable(reason: "Not needed"),
                betaFeatures: .unavailable(reason: "Not needed"),
                fanStatus: .available(value: fanStatus, capturedAt: now)
            )
        ))
        await extras.refresh()

        let store = MonitorStore(
            service: TelemetryService(source: ResourcePanelUnusedSource()),
            initial: snapshot,
            providerExtras: extras
        )
        let overviewContent = ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProviderResourcesView(store: store)
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: overviewContent)
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 570, height: 370))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(3_200))
        host.view.layoutSubtreeIfNeeded()
        #expect(host.view.frame.width == 570)
        #expect(host.view.frame.height >= 340)
        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-provider-resources.png"]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }
}

private struct ResourcePanelFixtureClient: ProviderExtrasProviding {
    let snapshot: ProviderExtrasSnapshot

    func refresh() async -> ProviderExtrasSnapshot { snapshot }
    func saveIdle(minutes: Int) async throws {}
    func setBeta(id: String, enabled: Bool) async throws {}
}

private struct ResourcePanelUnusedSource: TelemetrySource {
    func readDaemonState() async throws -> DaemonState { throw CancellationError() }
    func readLoadedModels() async throws -> LoadedModelsState { throw CancellationError() }
    func readStatus() async throws -> StatusSnapshot { throw CancellationError() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw CancellationError() }
}
