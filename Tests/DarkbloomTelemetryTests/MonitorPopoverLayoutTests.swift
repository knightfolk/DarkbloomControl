import AppKit
import DarkbloomTelemetry
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomMonitor

private let layoutNow = Date()

@Suite("Monitor popover layout")
@MainActor
struct MonitorPopoverLayoutTests {
    @Test("network demand rows include enabled models only and rank urgent work first")
    func networkDemandRows() throws {
        let capacity = try NetworkCapacityParser.parse(
            Data(#"{"models":[{"id":"low","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":10,"running_providers":0,"cold_providers":0,"active_requests":0,"queued_requests":0,"queue_limit":8,"aggregate_tps":10,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1},{"id":"urgent","ready":true,"can_accept":true,"routable_providers":10,"warm_providers":4,"running_providers":2,"cold_providers":6,"active_requests":5,"queued_requests":1,"queue_limit":8,"aggregate_tps":120.5,"estimated_ttft_ms":300,"token_budget_remaining":900,"token_budget_total":1000},{"id":"disabled","ready":true,"can_accept":true,"routable_providers":1,"warm_providers":0,"running_providers":0,"cold_providers":1,"active_requests":3,"queued_requests":0,"queue_limit":8,"aggregate_tps":0,"estimated_ttft_ms":1,"token_budget_remaining":1,"token_budget_total":1}]}"#.utf8),
            capturedAt: layoutNow
        )

        let rows = PopupNetworkDemandPresentation.rows(
            capacity: capacity,
            enabledModelIDs: ["low", "urgent"]
        )

        #expect(rows.map(\.id) == ["urgent", "low"])
        #expect(rows.first?.band == .urgent)
        #expect(rows.first?.activeRequests == 5)
        #expect(rows.first?.queuedRequests == 1)
        #expect(rows.first?.warmProviders == 4)
    }

    @Test("network demand presentation ages an available sample without a refresh")
    func networkDemandFreshnessAgesWithTime() {
        let capturedAt = Date(timeIntervalSince1970: 2_000_000)
        let capacity = NetworkCapacitySnapshot(models: [], capturedAt: capturedAt)
        let available = SourceAvailability<NetworkCapacitySnapshot>.available(
            value: capacity,
            capturedAt: capturedAt
        )

        #expect(
            PopupNetworkDemandPresentation.freshness(
                of: available,
                at: capturedAt.addingTimeInterval(NetworkCapacitySnapshot.maximumAge)
            ) == .current
        )
        #expect(
            PopupNetworkDemandPresentation.freshness(
                of: available,
                at: capturedAt.addingTimeInterval(NetworkCapacitySnapshot.maximumAge + 1)
            ) == .stale
        )
    }

    @Test("network demand refresh failures remain visibly stale")
    func networkDemandRefreshFailureIsStale() {
        let capturedAt = Date(timeIntervalSince1970: 2_000_000)
        let capacity = NetworkCapacitySnapshot(models: [], capturedAt: capturedAt)
        let stale = SourceAvailability<NetworkCapacitySnapshot>.stale(
            value: capacity,
            capturedAt: capturedAt,
            reason: "Network demand refresh failed"
        )

        #expect(
            PopupNetworkDemandPresentation.freshness(
                of: stale,
                at: capturedAt
            ) == .stale
        )
    }

    @Test("popup earnings metrics share the same calendar-day observation")
    func popupEarningsMetrics() {
        let metrics = PopupEarningsMetrics.make(from: ObservedEarningsWindow(
            microUSD: 600_000,
            observedSeconds: 10_800
        ))

        #expect(metrics?.totalUSD == 0.6)
        #expect(abs((metrics?.perHourUSD ?? 0) - 0.2) < 0.000_001)
        #expect(PopupEarningsMetrics.make(from: nil) == nil)
    }

    @Test("weekly earnings label distinguishes complete and partial calendar coverage")
    func popupWeeklyEarningsMetric() {
        #expect(PopupWeekEarningsMetric.make(from: CalendarWeekEarningsSummary(
            microUSD: 4_250_000,
            isComplete: true
        )) == PopupWeekEarningsMetric(title: "This week", totalUSD: 4.25))
        #expect(PopupWeekEarningsMetric.make(from: CalendarWeekEarningsSummary(
            microUSD: 3_125_000,
            isComplete: false
        )) == PopupWeekEarningsMetric(title: "Observed this week", totalUSD: 3.125))
        #expect(PopupWeekEarningsMetric.make(from: nil) == nil)
    }

    @Test("each downloaded-model label stays visually grouped with its own switch")
    func modelOptionToggleGrouping() {
        #expect(ModelOptionToggle.order == .switchThenLabel)
        #expect(ModelOptionToggle.groupSpacing > ModelOptionToggle.labelSpacing * 3)
    }

    @Test("popup keeps enabled non-downloaded models separate from two warm models")
    func popupShowsAllEnabledModels() throws {
        let modelIDs = ["qwen-new-a", "qwen-new-b", "model-c", "model-d", "model-e", "model-f"]
        let selection = ProviderModelSelection(enabled: modelIDs, preloaded: Array(modelIDs.prefix(2)))
        let catalog = modelIDs.map {
            CatalogModel(
                id: $0,
                displayName: $0,
                family: $0,
                modelType: "llm",
                capabilities: ["text"],
                sizeGB: 1,
                minimumRAMGB: 4,
                active: true
            )
        }
        let inventory = ModelInventoryBuilder.build(
            catalog: catalog,
            local: modelIDs.prefix(5).map {
                LocalModel(id: $0, modelType: "llm", sizeBytes: 1, estimatedMemoryGB: 1)
            },
            selection: selection,
            daemon: nil,
            loadedModels: Array(modelIDs.prefix(2))
        )
        let draft = ProviderConfigDraft(
            sourceRevision: "six-enabled-two-warm",
            original: selection,
            selection: selection,
            originalMaxModelSlots: 2,
            maxModelSlots: 2
        )
        let control = ProviderControlSnapshot(
            inventory: inventory,
            draft: draft,
            residentModelIDs: Set(modelIDs.prefix(2)),
            capturedAt: layoutNow,
            sources: .allFresh
        )

        let presentation = PopupModelPresentation.make(
            input: PopupModelSourceInput(
                daemonState: .unavailable(reason: "unused"),
                loadedModels: .unavailable(reason: "unused"),
                status: .unavailable(reason: "unused"),
                controlSnapshot: control
            ),
            currentTime: layoutNow
        )
        guard case .models(let models) = presentation else {
            Issue.record("Expected popup model badges")
            return
        }

        #expect(Set(models.map(\.name)) == Set(modelIDs))
        #expect(models.filter { $0.state == .loadedIdle }.map(\.name) == Array(modelIDs.prefix(2)))
        #expect(models.filter { $0.state == .availableUnloaded }.count == 4)
    }

    @Test("official Darkbloom logo loads as a tintable vector asset")
    func officialLogoAsset() throws {
        let sourceImage = try #require(DarkbloomLogoAsset.sourceImage)
        let greenImage = try #require(DarkbloomLogoAsset.menuBarImage(tint: .systemGreen))
        let redImage = try #require(DarkbloomLogoAsset.menuBarImage(tint: .systemRed))
        let green = try #require(sampledMarkColor(in: greenImage))
        let red = try #require(sampledMarkColor(in: redImage))

        #expect(sourceImage.size == NSSize(width: 221, height: 253))
        #expect(!greenImage.isTemplate)
        #expect(greenImage.size == NSSize(width: 12.25, height: 14))
        #expect(green.greenComponent > green.redComponent)
        #expect(green.greenComponent > green.blueComponent)
        #expect(red.redComponent > red.greenComponent)
        #expect(red.redComponent > red.blueComponent)
    }

    @Test("model-family vectors render distinctly at menu-bar size")
    func modelFamilyAssets() throws {
        var rendered: [Data] = []
        let strip = NSImage(size: NSSize(width: 128, height: 24))
        strip.lockFocus()
        for (index, family) in [ModelFamilyIcon.darkbloom, .qwen, .openai, .google].enumerated() {
            let image = try #require(DarkbloomLogoAsset.menuBarImage(tint: .systemGreen, family: family))
            #expect(image.size.width > 0 && image.size.height > 0)
            let color = try #require(sampledMarkColor(in: image))
            #expect(color.greenComponent > color.redComponent)
            rendered.append(try #require(image.tiffRepresentation))
            image.draw(in: NSRect(x: index * 32 + 8, y: 3, width: 16, height: 18))
        }
        strip.unlockFocus()
        #expect(Set(rendered).count == 4)
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            let data = try #require(strip.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/darkbloom-model-icons.png"))
        }
    }

    @Test("menu bar label keeps the official logo within status-item bounds")
    func menuBarLogoSize() {
        let hostingController = NSHostingController(
            rootView: DarkbloomLogo(
                image: DarkbloomLogoAsset.menuBarImage(tint: .systemGreen),
                tint: .green
            )
            .frame(width: 12.25, height: 14)
        )
        let size = hostingController.sizeThatFits(in: NSSize(width: 500, height: 500))

        #expect(size.width <= 13)
        #expect(size.height <= 15)
    }

    @Test("single-line menu metric remains readable and stable across modes")
    func stableReadableMetric() {
        let throughput = NSHostingController(rootView: MenuBarMetric(text: "41.9 tok/s"))
        let earnings = NSHostingController(rootView: MenuBarMetric(text: "$2.90/24h"))
        let unavailable = NSHostingController(rootView: MenuBarMetric(text: nil))
        let proposed = NSSize(width: 500, height: 100)
        let expected = throughput.sizeThatFits(in: proposed)

        #expect(earnings.sizeThatFits(in: proposed) == expected)
        #expect(unavailable.sizeThatFits(in: proposed) == expected)
        #expect(expected.width == 72)
        #expect(expected.height <= 19)
    }

    @Test("calendar earnings keep the compact menu dimensions")
    func calendarMetricSize() async throws {
        let presentation = MenuBarPresentation.make(snapshot: .unavailable(now: layoutNow), thermal: .nominal,
            earnings: .day(microUSD: 2_640_000, complete: false), mode: .earnings)
        let host = NSHostingController(rootView: MenuBarLabel(presentation: presentation,
            uptime: .available(percent: 100, observedSeconds: 600)))
        #expect(host.sizeThatFits(in: NSSize(width: 500, height: 100)) == NSSize(width: 96, height: 18))
        #expect(presentation.metricText == "$2.64/d*")
        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 96, height: 18))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutSubtreeIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-calendar-menu.png"]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }

    @Test("menu bar label scales icon spacing and metric as one readable unit")
    func readableLabelScale() {
        let presentation = MenuBarPresentation.make(
            snapshot: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000)),
            thermal: .nominal,
            earnings: .available(microUSD: 2_640_000),
            mode: .automatic
        )
        let hostingController = NSHostingController(rootView: MenuBarLabel(
            presentation: presentation,
            uptime: .available(percent: 100, observedSeconds: 600)
        ))

        let size = hostingController.sizeThatFits(in: NSSize(width: 500, height: 100))

        #expect(size.width == 96)
        #expect(size.height == 18)
    }

    @Test("native status item owns one fixed width")
    func nativeStatusItemWidth() {
        let suite = "StatusNavigationTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TelemetryService(source: UnusedTelemetrySource())
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000))
        )
        let controller = StatusItemController(store: store, defaults: defaults)

        #expect(controller.statusItemLength == 104)
        #expect(controller.dashboardWindowController == nil)
        controller.showDashboard(activate: false)
        let firstWindow = controller.dashboardWindowController?.window
        controller.showSettings(activate: false)
        #expect(controller.dashboardWindowController?.window === firstWindow)
        #expect(controller.dashboardWindowController?.navigation.selected == .settings)
        controller.invalidate()
        #expect(controller.popoverContentSize == NSSize(width: 420, height: 430))
    }

    @Test("fresh and stale model settings fit without horizontal growth")
    func modelSettingsFitMinimumSize() async {
        let states: [(ProviderControlSourceStates, Bool, Bool, String)] = [
            (.allFresh, true, true, "Shows a confirmation before deleting Downloaded Model."),
            (ProviderControlSourceStates(
                catalog: .stale("Catalog refresh required"),
                localModels: .fresh(evidenceAt: layoutNow),
                daemon: .fresh(evidenceAt: layoutNow),
                loadedModels: .fresh(evidenceAt: layoutNow)
            ), false, false,
             "Catalog refresh required; Reload the model catalog before deleting this model."),
            (ProviderControlSourceStates(
                catalog: .fresh(evidenceAt: layoutNow),
                localModels: .stale("Local model refresh required"),
                daemon: .fresh(evidenceAt: layoutNow),
                loadedModels: .fresh(evidenceAt: layoutNow)
            ), false, false,
             "Local model refresh required; Reload local models before deleting this model."),
            (ProviderControlSourceStates(
                catalog: .fresh(evidenceAt: layoutNow),
                localModels: .fresh(evidenceAt: layoutNow),
                daemon: .stale("Provider activity refresh required"),
                loadedModels: .fresh(evidenceAt: layoutNow)
            ), true, false,
             "Provider activity refresh required; Refresh provider activity before deleting this model."),
            (ProviderControlSourceStates(
                catalog: .fresh(evidenceAt: layoutNow),
                localModels: .fresh(evidenceAt: layoutNow),
                daemon: .fresh(evidenceAt: layoutNow),
                loadedModels: .unavailable("Loaded model state unavailable")
            ), true, false,
             "Loaded model state unavailable; Refresh loaded model state before deleting this model."),
        ]
        let proposed = NSSize(width: 680, height: 560)

        for (sources, expectedCanDownload, expectedCanDelete, expectedDeleteHelp) in states {
            let controlStore = ProviderControlStore(
                controller: InertSettingsController(sources: sources)
            )
            await controlStore.refresh()
            let hostingController = NSHostingController(
                rootView: MonitorSettingsView()
                    .environmentObject(controlStore)
            )
            let fitted = hostingController.sizeThatFits(in: proposed)
            let availableItem = controlStore.snapshot?.inventory.available.first
            let row = availableItem.map {
                ModelManagerPresentation.availableRow(item: $0, store: controlStore)
            }
            let downloadedItem = controlStore.snapshot?.inventory.myCatalog.first
            let downloadedRow = downloadedItem.map {
                ModelRowPresentation.make(
                    item: $0,
                    draft: controlStore.draft,
                    operation: controlStore.operation,
                    sources: sources,
                    currentTime: layoutNow,
                    canDownload: false,
                    downloadUnavailableReason: nil,
                    sanitize: controlStore.sanitizedDiagnostic
                )
            }

            #expect(controlStore.canDownload("available-model") == expectedCanDownload)
            #expect(row?.downloadAction?.isEnabled == expectedCanDownload)
            #expect(row?.downloadAction?.accessibilityLabel == "Download Available Model")
            #expect(downloadedRow?.deleteAction?.isEnabled == expectedCanDelete)
            #expect(downloadedRow?.deleteAction?.accessibilityHint == expectedDeleteHelp)
            #expect(fitted.width == proposed.width)
            #expect(fitted.height == proposed.height)
        }
    }

    @Test("two-row lifecycle popover has a compact stable viewport")
    func hasCompactViewport() async throws {
        let service = TelemetryService(source: UnusedTelemetrySource())
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000))
        )
        let controlStore = ProviderControlStore(controller: InertSettingsController())
        await controlStore.refresh()
        let hostingController = NSHostingController(
            rootView: MonitorPopover(store: store)
                .environmentObject(controlStore)
        )
        let proposedSize = hostingController.sizeThatFits(
            in: NSSize(width: 400, height: 0)
        )

        #expect(proposedSize.width == 420)
        #expect(proposedSize.height < 200)
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            let window = NSWindow(contentViewController: hostingController)
            window.isReleasedWhenClosed = false
            window.setContentSize(proposedSize)
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            let view = hostingController.view
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/darkbloom-compact-popup.png"))
        }
    }

    @Test("lifecycle controls bind to an inert shared store and remain compact")
    func lifecycleControlsFit() async {
        let controlStore = ProviderControlStore(controller: InertSettingsController())
        await controlStore.refresh()
        let hostingController = NSHostingController(
            rootView: ProviderLifecycleControls(
                store: controlStore,
                snapshot: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000))
            )
        )

        let fitted = hostingController.sizeThatFits(in: NSSize(width: 220, height: 40))

        #expect(fitted.width <= 220)
        #expect(fitted.height <= 64)
    }

    @Test("disabled lifecycle controls keep their inline reason in a compact layout")
    func lifecycleControlsShowInlineReason() async {
        let controlStore = ProviderControlStore(
            controller: InertSettingsController(sources: .unknown)
        )
        await controlStore.refresh()
        let hostingController = NSHostingController(
            rootView: ProviderLifecycleControls(
                store: controlStore,
                snapshot: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000)),
                currentTime: Date(timeIntervalSince1970: 1_750_000_000)
            )
        )

        let fitted = hostingController.sizeThatFits(in: NSSize(width: 220, height: 64))

        #expect(
            ProviderLifecycleUnavailableReasonPresentation.make(
                from: .init(
                    canStart: false,
                    canStop: false,
                    canRestart: false,
                    unavailableReason: "Provider state is unavailable"
                )
            )?.message == "Provider state is unavailable"
        )
        #expect(fitted.width <= 220)
        #expect(fitted.height <= 64)
    }
}

private func sampledMarkColor(in image: NSImage) -> NSColor? {
    let scale = 10
    let width = Int(image.size.width * CGFloat(scale))
    let height = Int(image.size.height * CGFloat(scale))
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    bitmap.size = image.size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()

    return bitmap.colorAt(x: width / 10, y: height / 2)?.usingColorSpace(.deviceRGB)
}

private struct UnusedTelemetrySource: TelemetrySource {
    func readDaemonState() async throws -> DaemonState { throw UnusedError() }
    func readLoadedModels() async throws -> LoadedModelsState { throw UnusedError() }
    func readStatus() async throws -> StatusSnapshot { throw UnusedError() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw UnusedError() }
}

private struct UnusedError: Error {}

private actor InertSettingsController: ProviderControlling {
    private let value: ProviderControlSnapshot

    init(sources: ProviderControlSourceStates = .allFresh) {
        let selection = ProviderModelSelection(enabled: [], preloaded: [])
        let draft = ProviderConfigDraft(
            sourceRevision: "layout-fixture",
            original: selection,
            selection: selection
        )
        let catalog = [
            CatalogModel(
                id: "downloaded-model",
                displayName: "Downloaded Model",
                family: "downloaded",
                modelType: "llm",
                capabilities: ["text", "code"],
                sizeGB: 8.5,
                minimumRAMGB: 16,
                active: true
            ),
            CatalogModel(
                id: "available-model",
                displayName: "Available Model",
                family: "available",
                modelType: "vision-language",
                capabilities: ["vision", "text"],
                sizeGB: 4,
                minimumRAMGB: 8,
                active: true
            ),
        ]
        let inventory = ModelInventoryBuilder.build(
            catalog: catalog,
            local: [LocalModel(
                id: "downloaded-model",
                modelType: "llm",
                sizeBytes: 8_500_000_000,
                estimatedMemoryGB: nil
            )],
            selection: selection,
            daemon: nil,
            loadedModels: []
        )
        value = ProviderControlSnapshot(
            inventory: inventory,
            draft: draft,
            capturedAt: layoutNow,
            sources: sources
        )
    }

    func refresh() async throws -> ProviderControlSnapshot { value }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        ProviderConfigSaveResult(draft: draft, restartRequired: draft.hasChanges)
    }

    func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {
        throw UnusedError()
    }

    func delete(_ localModelID: String) async throws { throw UnusedError() }
    func activityRisk() async -> ProviderActivityRisk { .idle }

    func execute(
        _ action: ProviderLifecycleAction,
        enabledModels: [String]
    ) async throws {
        throw UnusedError()
    }
}

private extension ProviderControlSourceStates {
    static let allFresh = ProviderControlSourceStates(
        catalog: .fresh(evidenceAt: layoutNow),
        localModels: .fresh(evidenceAt: layoutNow),
        daemon: .fresh(evidenceAt: layoutNow),
        loadedModels: .fresh(evidenceAt: layoutNow)
    )
}
