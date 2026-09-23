import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Model card rendering", .serialized)
@MainActor
struct ModelCardSummaryRenderingTests {
    @Test("model metrics and schedule render at compact and roomy card widths", arguments: [300.0, 440.0])
    func rendersSummary(width: Double) throws {
        let item = ModelInventoryItem(
            catalogID: "google/gemma-4",
            localID: "google/gemma-4",
            displayName: "Gemma 4 · 27B Instruct · 4-bit MLX",
            modelType: "llm",
            capabilities: ["chat", "tools", "vision"],
            sizeGB: 18.2,
            minimumRAMGB: 32,
            isDownloaded: true,
            isEnabled: true,
            isPreloaded: false,
            liveState: .loadedIdle,
            issue: nil
        )
        let serving = ModelServingProfitAverage(
            model: item.catalogID,
            grossUSDPerActiveHour: 1.20,
            incrementalElectricityUSDPerActiveHour: 0.21,
            profitUSDPerActiveHour: 0.99,
            activeHours: 2.5,
            coveredEarningHours: 3,
            activePowerSamples: 900,
            idlePowerSamples: 500
        )
        let rate = ModelTokenRateAverage(model: item.catalogID, tokensPerSecond: 24.7,
            sampleCount: 116, queryPeriod: nil)
        let capacity = NetworkModelCapacity(
            id: item.catalogID,
            ready: true,
            canAccept: true,
            routableProviders: 8,
            warmProviders: 3,
            runningProviders: 5,
            coldProviders: 1,
            activeRequests: 4,
            queuedRequests: 1,
            queueLimit: 8,
            aggregateTokensPerSecond: 125,
            estimatedTimeToFirstTokenMS: 240,
            tokenBudgetRemaining: 750,
            tokenBudgetTotal: 1_000
        )
        let forecast = ModelRunForecast.calculate(runPercent: 50, serving: serving, tokenRate: rate)
        let view = ModelCardSummary(
            item: item,
            installedMemoryGB: 64,
            rate: rate,
            capacity: capacity,
            serving: serving,
            grade: "A",
            forecast: forecast,
            runPercent: 50,
            isScheduleEnabled: true,
            maximumRunPercent: 50,
            setRunPercent: { _ in }
        )
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)

        #expect(abs(image.size.width - width) < 0.1)
        #expect(image.size.height > 300)
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/darkbloom-model-card-\(Int(width)).png"))
        }
    }
}
