import AppKit
import DarkbloomTelemetry
import SwiftUI
import Testing
@testable import DarkbloomMonitor

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
        #expect(expected.width == MenuBarMetric.width)
        #expect(expected.height <= 15)
    }

    @Test("native status item owns one fixed width")
    func nativeStatusItemWidth() {
        let service = TelemetryService(source: UnusedTelemetrySource())
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000))
        )
        let controller = StatusItemController(store: store)

        #expect(controller.statusItemLength == StatusItemController.itemWidth)
    }

    @Test("all detailed sections start collapsed")
    func detailsStartCollapsed() {
        #expect(PopoverSection.allCases.count == 7)
        #expect(PopoverDisclosureDefaults.compact.expandedSections.isEmpty)
    }

    @Test("menu bar popover has a stable noncollapsed viewport")
    func hasStableViewport() {
        let service = TelemetryService(source: UnusedTelemetrySource())
        let store = MonitorStore(
            service: service,
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000))
        )
        let hostingController = NSHostingController(
            rootView: MonitorPopover(store: store)
        )
        let proposedSize = hostingController.sizeThatFits(
            in: NSSize(width: 420, height: 0)
        )

        #expect(proposedSize.width == 420)
        #expect(proposedSize.height == 680)
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
