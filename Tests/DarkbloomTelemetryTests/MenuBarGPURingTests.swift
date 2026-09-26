import AppKit
import SwiftUI
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Menu-bar GPU ring")
@MainActor
struct MenuBarGPURingTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: utilization

    @Test("ring fills an empty track at 0, half at 50, and completes at 100")
    func utilizationSpan() {
        for (utilization, progress) in [(0.0, 0.0), (50.0, 0.5), (100.0, 1.0)] {
            let ring = MenuBarGPURing.make(
                utilization: utilization,
                sampledAt: Self.fixedNow.addingTimeInterval(-3),
                fanStatus: nil,
                now: Self.fixedNow
            )
            #expect(ring != nil)
            #expect(ring?.progress == progress)
        }
    }

    @Test("nonfinite, out-of-range, or absent utilization renders no ring")
    func rejectsBadUtilization() {
        for utilization in [Double.nan, .infinity, -.infinity, -0.5, 100.5, -1.0, 101.0] {
            #expect(MenuBarGPURing.make(
                utilization: utilization,
                sampledAt: Self.fixedNow.addingTimeInterval(-3),
                fanStatus: nil,
                now: Self.fixedNow
            ) == nil)
        }
        #expect(MenuBarGPURing.make(utilization: 42, sampledAt: nil, fanStatus: nil, now: Self.fixedNow) == nil)
        #expect(MenuBarGPURing.make(utilization: nil, sampledAt: Self.fixedNow, fanStatus: nil, now: Self.fixedNow) == nil)
    }

    @Test("stale or future-dated utilization renders no ring instead of a fabricated arc")
    func utilizationFreshness() {
        let available = Self.availableFan(helperTemperature: 61, sensors: [])
        #expect(MenuBarGPURing.make(
            utilization: 42,
            sampledAt: Self.fixedNow.addingTimeInterval(-10),
            fanStatus: available,
            now: Self.fixedNow
        ) != nil)
        #expect(MenuBarGPURing.make(
            utilization: 42,
            sampledAt: Self.fixedNow.addingTimeInterval(-10.01),
            fanStatus: available,
            now: Self.fixedNow
        ) == nil)
        #expect(MenuBarGPURing.make(
            utilization: 0,
            sampledAt: Self.fixedNow.addingTimeInterval(2),
            fanStatus: available,
            now: Self.fixedNow
        ) == nil)
    }

    // MARK: temperature tint

    @Test("tint crosses the configurable green/yellow/red boundaries exactly")
    func tintBoundaries() {
        let expectations: [(Double, MenuBarGPURing.Tint)] = [
            (10, .green), (69.9, .green),
            (70, .yellow), (84.9, .yellow),
            (85, .red), (125, .red),
        ]
        for (temperature, tint) in expectations {
            let ring = Self.makeRing(helperTemperature: temperature)
            #expect(ring?.tint == tint)
        }

        let custom = MenuBarGPURing.Thresholds(yellowAtCelsius: 60, redAtCelsius: 75)
        let customExpectations: [(Double, MenuBarGPURing.Tint)] = [
            (59.9, .green), (60, .yellow), (74.9, .yellow), (75, .red),
        ]
        for (temperature, tint) in customExpectations {
            let ring = MenuBarGPURing.make(
                utilization: 40,
                sampledAt: Self.fixedNow.addingTimeInterval(-1),
                fanStatus: Self.availableFan(helperTemperature: temperature, sensors: []),
                now: Self.fixedNow,
                thresholds: custom
            )
            #expect(ring?.tint == tint)
        }
    }

    @Test("missing, stale, or implausible temperature keeps the ring neutral")
    func neutralWithoutFreshTemperature() {
        #expect(Self.makeRing()?.tint == .neutral)
        #expect(Self.makeRing(fanStatus: .unavailable(reason: "fixture"))?.tint == .neutral)
        let status = Self.makeFanStatus(helperTemperature: 61, sensors: [61])
        #expect(Self.makeRing(fanStatus: .stale(
            value: status, capturedAt: Self.fixedNow, reason: "fixture"
        ))?.tint == .neutral)
        // The whole fan source is past its 45-second window.
        #expect(Self.makeRing(fanStatus: .available(
            value: status, capturedAt: Self.fixedNow.addingTimeInterval(-45.01)
        ))?.tint == .neutral)
        // Outside the CLI's 10...125 C plausible sensor range, both extremes.
        #expect(Self.makeRing(helperTemperature: 9.9)?.tint == .neutral)
        #expect(Self.makeRing(helperTemperature: 125.1)?.tint == .neutral)
        #expect(Self.makeRing(helperTemperature: .nan)?.tint == .neutral)
        // Implausible sensors are dropped; the remaining valid one still tints.
        let mixed = Self.makeRing(sensors: [9.9, 71, 130])
        #expect(mixed?.temperatureCelsius == 71)
        #expect(mixed?.tint == .yellow)
    }

    @Test("a fresh helper reading wins; otherwise the hottest diagnostic sensor tints")
    func hottestAndFreshestSelection() {
        // Fresh helper journal is preferred even when a diagnostic sensor is hotter.
        #expect(Self.makeRing(helperTemperature: 58, sensors: [72])?.temperatureCelsius == 58)
        // A helper journal older than 15 seconds is dropped in favor of the
        // same-command diagnostic, colored by its hottest sensor—not the first.
        let ring = MenuBarGPURing.make(
            utilization: 30,
            sampledAt: Self.fixedNow.addingTimeInterval(-1),
            fanStatus: .available(
                value: Self.makeFanStatus(
                    helperTemperature: 58,
                    helperUpdatedAt: Self.fixedNow.addingTimeInterval(-15.01),
                    sensors: [50, 72]
                ),
                capturedAt: Self.fixedNow
            ),
            now: Self.fixedNow
        )
        #expect(ring?.temperatureCelsius == 72)
        #expect(ring?.tint == .yellow)
        // Stale helper with no usable sensors stays neutral.
        #expect(MenuBarGPURing.make(
            utilization: 30,
            sampledAt: Self.fixedNow.addingTimeInterval(-1),
            fanStatus: .available(
                value: Self.makeFanStatus(
                    helperTemperature: 58,
                    helperUpdatedAt: Self.fixedNow.addingTimeInterval(-16),
                    sensors: []
                ),
                capturedAt: Self.fixedNow
            ),
            now: Self.fixedNow
        )?.tint == .neutral)
    }

    // MARK: accessibility text

    @Test("accessibility text names whole-Mac scope, percent, and temperature")
    func accessibilityDetail() {
        let ring = Self.makeRing(utilization: 42.4, helperTemperature: 61.2)
        #expect(ring?.accessibilityDetail == "Whole-Mac GPU use 42 percent, GPU 61 degrees Celsius.")
        #expect(ring?.accessibilityDetail.contains("Whole-Mac") == true)

        let noTemperature = Self.makeRing(utilization: 42)
        #expect(noTemperature?.accessibilityDetail == "Whole-Mac GPU use 42 percent.")
        #expect(noTemperature?.accessibilityDetail.contains("degrees") == false)
    }

    // MARK: store composition

    @Test("menu store composes the ring from the shared sampler and fan status")
    func monitorStoreComposition() async {
        // One wall-clock fixture: the store's ring reads both the sampler's
        // own sample timestamps and the extras snapshot's capturedAt, so the
        // whole scenario must share a single time base.
        let capturedAt = Date()
        let sample = GPURingReadingBox(value: 55)
        let fanStatus = Self.makeFanStatus(
            helperTemperature: 62,
            helperUpdatedAt: capturedAt,
            sensors: []
        )
        let extras = ProviderExtrasStore(client: GPURingFixtureClient(snapshot: ProviderExtrasSnapshot(
            capturedAt: capturedAt,
            idlePolicy: .unavailable(reason: "fixture"),
            betaFeatures: .unavailable(reason: "fixture"),
            fanStatus: .available(value: fanStatus, capturedAt: capturedAt)
        )))
        await extras.refresh()
        let store = MonitorStore(
            service: TelemetryService(source: GPURingUnusedSource()),
            initial: .unavailable(now: capturedAt),
            providerExtras: extras,
            gpuUsage: SystemGPUUsageStore(read: { sample.value })
        )

        #expect(store.gpuUsage.percentage == nil)
        #expect(store.menuGPURing() == nil)

        sample.value = 55
        store.gpuUsage.refresh()
        let ring = store.menuGPURing()
        #expect(ring?.utilization == 55)
        #expect(ring?.temperatureCelsius == 62)
        #expect(ring?.tint == .green)

        // The dashboard GPU panel reads the same lifecycle-owned sampler.
        #expect(store.gpuUsage.sampledAt != nil)

        sample.value = nil
        store.gpuUsage.refresh()
        #expect(store.menuGPURing() == nil)
    }

    @Test("monitor store lifecycle drives one shared sampler without a dashboard")
    func samplerLifecycleOwnedByStore() async throws {
        // start() spins the store's earnings/energy loops too, so isolate
        // them: a synthetic earnings client (never the live default), an
        // isolated preferences suite for the electricity settings, and an
        // EnergyRecorder pointed at a throwaway file.
        let suiteName = "GPURingEnergyPrefs-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.set(false, forKey: "electricity.enabled")
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let energyFile = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("darkbloom-gpu-ring-energy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: energyFile) }

        let reads = GPURingReadCounter(value: 42)
        // A long interval keeps the periodic cadence out of the test window,
        // so every observed read is attributable to start/stop semantics.
        let store = MonitorStore(
            service: TelemetryService(source: GPURingUnusedSource()),
            initial: .unavailable(now: Date()),
            earningsClient: GPURingUnusedEarningsClient(),
            energyPreferences: preferences,
            energyRecorder: EnergyRecorder(file: energyFile, readPower: { _ in nil }),
            gpuUsage: SystemGPUUsageStore(interval: .seconds(3_600), read: { reads.next() })
        )
        #expect(reads.count == 0)

        // Starting the store samples immediately with no dashboard, window,
        // or status item involved anywhere in this test.
        store.start()
        for _ in 0..<40 where reads.count == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(reads.count == 1)
        #expect(store.gpuUsage.percentage == 42)
        #expect(store.menuGPURing()?.utilization == 42)
        #expect(store.dashboardVisible == false)

        // A repeated start neither duplicates nor restarts the sampler task:
        // a second immediate read would prove a duplicate lifecycle.
        store.start()
        try await Task.sleep(for: .milliseconds(250))
        #expect(reads.count == 1)

        // Stop clears the published sample and performs no further reads.
        await store.stop()
        #expect(store.gpuUsage.percentage == nil)
        #expect(store.gpuUsage.sampledAt == nil)
        #expect(store.menuGPURing() == nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(reads.count == 1)
    }

    // MARK: rendering footprint

    @Test("menu-bar label footprint is identical with and without the ring")
    func labelFootprintStable() {
        let presentation = MenuBarPresentation.make(
            snapshot: .unavailable(now: Self.fixedNow),
            thermal: .nominal,
            earnings: .available(microUSD: 2_640_000),
            mode: .automatic
        )
        let proposed = NSSize(width: 500, height: 100)
        let rings: [MenuBarGPURing?] = [
            nil,
            Self.makeRing(utilization: 0, helperTemperature: 61),
            Self.makeRing(utilization: 50, helperTemperature: 75),
            Self.makeRing(utilization: 100, helperTemperature: 90),
        ]
        for ring in rings {
            let host = NSHostingController(rootView: MenuBarLabel(
                presentation: presentation,
                uptime: .available(percent: 100, observedSeconds: 600),
                family: .qwen,
                ring: ring
            ))
            let size = host.sizeThatFits(in: proposed)
            #expect(size == NSSize(width: 96, height: 18))
        }
    }

    @Test("status item keeps its fixed width while the ring is live")
    func statusItemFootprintStable() {
        let sample = GPURingReadingBox(value: 50)
        let store = MonitorStore(
            service: TelemetryService(source: GPURingUnusedSource()),
            initial: .unavailable(now: Date()),
            gpuUsage: SystemGPUUsageStore(read: { sample.value })
        )
        sample.value = 50
        store.gpuUsage.refresh()
        #expect(store.menuGPURing() != nil)

        let suite = "GPURingStatusItem-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = StatusItemController(store: store, defaults: defaults)
        #expect(controller.statusItemLength == 104)
        controller.invalidate()
    }

    @Test("native render shows arc geometry and temperature tint at 0, 50, 100, and neutral")
    func nativeArcRender() async throws {
        // The arc starts at 12 o'clock and sweeps clockwise, so a half ring
        // covers north and east, and leaves west as bare track.
        let full = try Self.renderRing(try #require(Self.makeRing(utilization: 100, helperTemperature: 90)))
        #expect(Self.colorClasses(in: full, dx: 9, dy: 0).contains("red"))
        #expect(Self.colorClasses(in: full, dx: -9, dy: 0).contains("red"))

        let half = try Self.renderRing(try #require(Self.makeRing(utilization: 50, helperTemperature: 75)))
        #expect(Self.colorClasses(in: half, dx: 9, dy: 0).contains("yellow"))
        #expect(Self.colorClasses(in: half, dx: -9, dy: 0).contains("grayArc"))
        #expect(!Self.colorClasses(in: half, dx: -9, dy: 0).contains("yellow"))

        let zero = try Self.renderRing(try #require(Self.makeRing(utilization: 0, helperTemperature: 61)))
        #expect(Self.colorClasses(in: zero, dx: 9, dy: 0).contains("grayArc"))
        #expect(Self.colorClasses(in: zero, dx: 0, dy: -9).contains("grayArc"))
        #expect(!Self.colorClasses(in: zero, dx: 9, dy: 0).contains("green"))

        let neutral = try Self.renderRing(try #require(Self.makeRing(utilization: 42)))
        #expect(Self.colorClasses(in: neutral, dx: 9, dy: 0).contains("grayArc"))
        #expect(!Self.colorClasses(in: neutral, dx: 9, dy: 0).contains("green"))

        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let presentation = MenuBarPresentation.make(
            snapshot: .unavailable(now: Self.fixedNow),
            thermal: .nominal,
            earnings: .available(microUSD: 2_640_000),
            mode: .automatic
        )
        let cases: [(String, MenuBarGPURing?)] = [
            ("missing (no sampler data)", nil),
            ("0% green", Self.makeRing(utilization: 0, helperTemperature: 61)),
            ("50% yellow", Self.makeRing(utilization: 50, helperTemperature: 75)),
            ("100% red", Self.makeRing(utilization: 100, helperTemperature: 90)),
            ("42% neutral (no fresh temperature)", Self.makeRing(utilization: 42)),
        ]
        let strip = VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(cases.enumerated()), id: \.offset) { entry in
                HStack(spacing: 16) {
                    MenuBarLabel(
                        presentation: presentation,
                        uptime: .available(percent: 100, observedSeconds: 600),
                        family: .qwen,
                        ring: entry.element.1
                    )
                    Text(entry.element.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: strip)
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 360, height: 190))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutSubtreeIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-gpu-ring.png"]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }

    /// Renders one ring view centered in a 40x40 box and returns its bitmap.
    private static func renderRing(_ ring: MenuBarGPURing) throws -> NSBitmapImageRep {
        let host = NSHostingController(rootView: MenuBarGPURingView(
            ring: ring,
            family: .qwen,
            statusNSColor: .systemGreen
        )
        .frame(width: 40, height: 40)
        .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 40, height: 40))
        window.orderBack(nil)
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        return bitmap
    }

    /// Classifies the colors found in a 3-point neighborhood of the ring
    /// position `(20 + dx, 20 + dy)` in the 40x40 render.
    private static func colorClasses(in bitmap: NSBitmapImageRep, dx: Double, dy: Double) -> Set<String> {
        let scale = Double(bitmap.pixelsWide) / 40.0
        var classes = Set<String>()
        for probe in [0.0, 0.5, -0.5] {
            let x = Int(((20 + dx + probe * (dx == 0 ? 1 : 0)) * scale).rounded())
            let y = Int(((20 + dy + probe * (dy == 0 ? 1 : 0)) * scale).rounded())
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            classes.insert(Self.classify(color))
        }
        return classes
    }

    private static func classify(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "other" }
        let hue = rgb.hueComponent
        let saturation = rgb.saturationComponent
        let brightness = rgb.brightnessComponent
        guard saturation > 0.25, brightness > 0.2 else {
            return (0.05...0.85).contains(brightness) ? "grayArc" : "other"
        }
        if hue < 0.09 || hue > 0.91 { return "red" }
        if hue < 0.19 { return "yellow" }
        if hue < 0.45 { return "green" }
        return "other"
    }

    // MARK: fixtures

    private static func makeRing(
        utilization: Double = 40,
        helperTemperature: Double? = nil,
        sensors: [Double] = [],
        fanStatus: SourceAvailability<ProviderFanStatus>? = nil
    ) -> MenuBarGPURing? {
        MenuBarGPURing.make(
            utilization: utilization,
            sampledAt: fixedNow.addingTimeInterval(-2),
            fanStatus: fanStatus ?? availableFan(helperTemperature: helperTemperature, sensors: sensors),
            now: fixedNow
        )
    }

    private static func availableFan(
        helperTemperature: Double?,
        sensors: [Double]
    ) -> SourceAvailability<ProviderFanStatus> {
        .available(
            value: makeFanStatus(helperTemperature: helperTemperature, sensors: sensors),
            capturedAt: fixedNow
        )
    }

    private static func makeFanStatus(
        helperTemperature: Double?,
        helperUpdatedAt: Date = fixedNow,
        sensors: [Double]
    ) -> ProviderFanStatus {
        ProviderFanStatus(
            capability: "fixture",
            installed: true,
            loaded: true,
            helper: ProviderFanHelperStatus(
                enabled: true,
                providerActive: false,
                mode: "standby",
                chip: "fixture",
                gpuTemperatureCelsius: helperTemperature,
                triggerTemperatureCelsius: 45,
                releaseTemperatureCelsius: 40,
                speedPercent: 80,
                fans: [],
                updatedAt: helperUpdatedAt
            ),
            diagnostic: ProviderFanDiagnostic(
                chip: "fixture",
                supported: true,
                gpuTemperatures: sensors.enumerated().map {
                    ProviderFanTemperature(key: "G\($0.offset)", celsius: $0.element)
                },
                fans: []
            ),
            helperErrorPresent: false,
            diagnosticErrorPresent: false
        )
    }
}

@MainActor
private final class GPURingReadingBox {
    var value: Double?

    init(value: Double?) {
        self.value = value
    }
}

/// Counts reads and yields a fixed value, to observe sampler task lifecycle.
@MainActor
private final class GPURingReadCounter {
    private(set) var count = 0
    let value: Double

    init(value: Double) {
        self.value = value
    }

    func next() -> Double? {
        count += 1
        return value
    }
}

private struct GPURingFixtureClient: ProviderExtrasProviding {
    let snapshot: ProviderExtrasSnapshot

    func refresh() async -> ProviderExtrasSnapshot { snapshot }
    func saveIdle(minutes: Int) async throws {}
    func setBeta(id: String, enabled: Bool) async throws {}
}

/// Never touches real credentials or account APIs; every member that lacks a
/// protocol default stays unreachable in these tests.
private struct GPURingUnusedEarningsClient: AccountEarningsFetching {
    func fetch(now: Date) async throws -> EarningsPresentationValue {
        .unavailable(reason: "unused")
    }
}

private struct GPURingUnusedSource: TelemetrySource {
    func readDaemonState() async throws -> DaemonState { throw CancellationError() }
    func readLoadedModels() async throws -> LoadedModelsState { throw CancellationError() }
    func readStatus() async throws -> StatusSnapshot { throw CancellationError() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw CancellationError() }
}
