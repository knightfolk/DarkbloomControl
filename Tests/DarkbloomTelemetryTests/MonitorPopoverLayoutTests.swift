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
        let service = TelemetryService(source: UnusedTelemetrySource())
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000))
        )
        let controller = StatusItemController(store: store)

        #expect(controller.statusItemLength == 104)
        #expect(controller.settingsWindowTitle == "Darkbloom Monitor Settings")
        #expect(controller.settingsWindowIsReleasedWhenClosed == false)
        #expect(controller.settingsWindowIsResizable)
        #expect(controller.settingsWindowContentSize == NSSize(width: 720, height: 620))
        #expect(controller.popoverContentSize == NSSize(width: 400, height: 600))
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
    func hasCompactViewport() async {
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

        #expect(proposedSize.width == 400)
        #expect(proposedSize.height == 600)
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
        #expect(fitted.height <= 40)
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
