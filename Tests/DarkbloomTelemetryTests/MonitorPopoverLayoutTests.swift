import AppKit
import DarkbloomTelemetry
import SwiftUI
import Testing
@testable import DarkbloomMonitor

@Suite("Monitor popover layout")
@MainActor
struct MonitorPopoverLayoutTests {
    @Test("Darkbloom logo shape preserves the supplied mark proportions")
    func logoGeometry() {
        let bounds = DarkbloomLogoShape().path(in: CGRect(x: 0, y: 0, width: 32, height: 37)).boundingRect

        #expect(bounds == CGRect(x: 0, y: 0, width: 32, height: 37))
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

private struct UnusedTelemetrySource: TelemetrySource {
    func readDaemonState() async throws -> DaemonState { throw UnusedError() }
    func readLoadedModels() async throws -> LoadedModelsState { throw UnusedError() }
    func readStatus() async throws -> StatusSnapshot { throw UnusedError() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw UnusedError() }
}

private struct UnusedError: Error {}
