import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Model card rendering", .serialized)
@MainActor
struct ModelCardSummaryRenderingTests {
    @Test("grid preserves minimum readable width and caps at three columns")
    func columnCounts() {
        #expect(ModelCardLayout.columnCount(for: 700) == 1)
        #expect(ModelCardLayout.columnCount(for: 720) == 2)
        #expect(ModelCardLayout.columnCount(for: 1100) == 3)
        #expect(ModelCardLayout.columnCount(for: 1480) == 3)
        #expect(ModelCardLayout.columnCount(for: 2200) == 3)
        #expect(ModelCardLayout.maximumVisibleRows == 2)
    }

    @Test("enabled models lead the catalog without reordering the remaining results")
    func enabledModelsLead() {
        func item(_ id: String) -> ModelInventoryItem {
            ModelInventoryItem(
                catalogID: id, localID: nil, displayName: id, modelType: "text",
                capabilities: [], sizeGB: 1, minimumRAMGB: 1, isDownloaded: true,
                isEnabled: false, isPreloaded: false, liveState: .unloaded, issue: nil
            )
        }
        let catalog = [item("vendor/first"), item("vendor/enabled-a"), item("vendor/last"), item("vendor/enabled-b")]
        let enabledIDs: Set<String> = ["vendor/enabled-a", "vendor/enabled-b"]

        let sorted = ModelManagerPresentation.enabledFirst(catalog) {
            enabledIDs.contains($0.catalogID)
        }

        #expect(sorted.map(\.catalogID) == ["vendor/enabled-a", "vendor/enabled-b", "vendor/first", "vendor/last"])
    }

    @Test("model metrics and schedule render at compact and roomy card widths", arguments: [350.0, 440.0])
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
        let view = VStack(alignment: .leading, spacing: 14) {
        ModelCardSummary(
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
        Divider()
        DownloadedModelRow(item: item,
            draft: ProviderConfigDraft(sourceRevision: "fixture",
                original: ProviderModelSelection(enabled: [item.catalogID], preloaded: []),
                selection: ProviderModelSelection(enabled: [item.catalogID], preloaded: [])),
            operation: .idle,
            sources: ProviderControlSourceStates(catalog: .fresh(evidenceAt: Date()),
                localModels: .fresh(evidenceAt: Date()), daemon: .fresh(evidenceAt: Date()),
                loadedModels: .fresh(evidenceAt: Date())),
            currentTime: Date(), sanitize: { $0 }, setEnabled: { _, _ in },
            setPreloaded: { _, _ in }, requestDelete: { _ in }, compact: true)
        Button("Manage & forecast") {}
            .buttonStyle(.bordered).controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(22)
        .frame(width: width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))

        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            for gridWidth in [720.0, 1100.0, 1480.0] {
                let grid = LazyVGrid(columns: ModelCardLayout.columns(for: gridWidth), spacing: ModelCardLayout.rowSpacing) {
                    ForEach(0..<9) { index in
                        let cardItem = ModelInventoryItem(
                            catalogID: ["qwen/qwen3.8", "google/gemma-4", "openai/gpt-oss-20b"][index % 3],
                            localID: nil,
                            displayName: ["Qwen 3.8 27B", "Gemma 4 · 27B Instruct · 4-bit MLX", "GPT-OSS 20B"][index % 3],
                            modelType: "text", capabilities: [], sizeGB: 18.2, minimumRAMGB: 32,
                            isDownloaded: true, isEnabled: index == 0, isPreloaded: false,
                            liveState: index == 0 ? .loadedIdle : .unloaded, issue: nil
                        )
                        VStack(alignment: .leading, spacing: 14) {
                            ModelCardSummary(item: cardItem, installedMemoryGB: 64,
                                rate: index == 1 ? nil : rate, capacity: capacity,
                                serving: index == 2 ? nil : serving, grade: index == 2 ? nil : "A",
                                forecast: forecast, runPercent: 50, isScheduleEnabled: index == 0,
                                maximumRunPercent: 50, setRunPercent: { _ in })
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Enabled", isOn: .constant(index == 0)).controlSize(.small)
                                Toggle("Load at startup", isOn: .constant(index == 0)).controlSize(.small)
                            }
                            .frame(height: 66, alignment: .topLeading)
                            Button("Manage & forecast") {}
                                .buttonStyle(.bordered).controlSize(.large)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(22)
                        .frame(height: ModelCardLayout.estimatedCardHeight, alignment: .top)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .frame(width: gridWidth, height: ModelCardLayout.maximumVisibleHeight, alignment: .top)
                .clipped()
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
                let gridRenderer = ImageRenderer(content: grid)
                gridRenderer.scale = 1
                let gridImage = try #require(gridRenderer.nsImage)
                let tiff = try #require(gridImage.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiff))
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/tmp/darkbloom-grid-\(Int(gridWidth)).png"))
            }
        }

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(representation)

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
