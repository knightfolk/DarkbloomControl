import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomTelemetry
@testable import DarkbloomMonitor

@MainActor
struct EnergySummaryViewTests {
    @Test func waitingStateIsVisibleWithoutReadingsOrEarnings() throws {
        let view = EnergySummaryView(reading: nil, earnings: nil, now: Date())
            .padding(12).frame(width: 396, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.height > 50)
        #expect(image.size.height < 130)
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/darkbloom-energy-waiting.png"))
        }
    }

    @Test func populatedEnergyFitsCompactPopup() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let view = EnergySummaryView(
            reading: EnergyReading(date: now, watts: 38.2, source: "adapter", estimated: true),
            earnings: EnergyEarnings(earningsUSD: 1.25, electricityUSD: 0.024,
                                     coveredSeconds: 3600, estimated: true), now: now)
            .padding(12).frame(width: 420)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 420)
        #expect(image.size.height <= 110)
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/darkbloom-energy-summary.png"))
        }
    }
}
