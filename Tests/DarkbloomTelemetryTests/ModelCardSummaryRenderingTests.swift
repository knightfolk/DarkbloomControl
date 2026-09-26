import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Model card rendering", .serialized)
@MainActor
struct ModelCardSummaryRenderingTests {
    @Test("grid stays two bounded columns and never stretches cards")
    func columnCounts() {
        // Two columns begin exactly when two 300pt cards plus one gap fit.
        #expect(ModelCardLayout.columnCount(for: 613) == 1)
        #expect(ModelCardLayout.columnCount(for: 614) == 2)
        // Narrow popover through the 1280pt native window and wide windows
        // all stay two-column.
        #expect(ModelCardLayout.columnCount(for: 600) == 1)
        #expect(ModelCardLayout.columnCount(for: 680) == 2)
        #expect(ModelCardLayout.columnCount(for: 1060) == 2)
        #expect(ModelCardLayout.columnCount(for: 1240) == 2)
        #expect(ModelCardLayout.columnCount(for: 1440) == 2)
        #expect(ModelCardLayout.maximumColumns == 2)
        // Cards never exceed the 400pt ceiling and only shrink below the
        // 300pt floor when the container itself is narrower.
        #expect(ModelCardLayout.cardWidth(for: 680) == 333)
        #expect(ModelCardLayout.cardWidth(for: 1060) == 400)
        #expect(ModelCardLayout.cardWidth(for: 1240) == 400)
        #expect(ModelCardLayout.cardWidth(for: 600) == 400)
        #expect(ModelCardLayout.cardWidth(for: 260) == 260)
        // The compact card must stay far below its ~530pt predecessor while
        // still fitting the identity row, three stats, what-if slider, and
        // one controls row.
        #expect(ModelCardLayout.estimatedCardHeight > 150)
        #expect(ModelCardLayout.estimatedCardHeight < 300)
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

    @Test("compact downloaded card keeps the what-if slider and roughly halves the footprint", arguments: [300.0, 400.0])
    func rendersCompactCard(width: Double) throws {
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
        let calibrated = serving.activeHours >= 2 ? serving : nil
        let forecast = ModelRunForecast.calculate(runPercent: 50, serving: calibrated, tokenRate: rate)
        // Real hosting controls (checkbox toggles) and the real fixed-size
        // entry button, exactly as the compact card renders them.
        let view = VStack(alignment: .leading, spacing: 12) {
            ModelCardSummary(
                item: item,
                installedMemoryGB: 64,
                rate: rate,
                capacity: capacity,
                serving: serving,
                grade: "A",
                forecast: forecast,
                runPercent: 50,
                setRunPercent: { _ in }
            )
            Divider()
            HStack(alignment: .center, spacing: 12) {
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
                Spacer(minLength: 8)
                Button(ModelManagerPresentation.compactEntryActionLabel(for: item)) {}
                    .buttonStyle(.bordered).controlSize(.small).fixedSize()
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .background(Color(nsColor: .windowBackgroundColor))

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(representation)

        #expect(abs(image.size.width - width) < 0.1)
        // The predecessor card measured ~530pt of card face alone; the whole
        // compact card (face + divider + controls) must land well under that.
        #expect(image.size.height > 150)
        #expect(image.size.height < 330)
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/darkbloom-model-card-\(Int(width)).png"))
        }
    }

    @Test("grouped manager partitions the catalog and renders both disclosure groups responsively")
    func rendersGroupedManager() async throws {
        let store = ProviderControlStore(controller: EvidenceModelsController())
        await store.refresh()

        let myCatalog = try #require(store.snapshot?.inventory.myCatalog)
        let available = try #require(store.snapshot?.inventory.available)
        #expect(myCatalog.count == 3)
        #expect(available.count == 3)
        #expect(myCatalog.allSatisfy { $0.isDownloaded })
        #expect(available.allSatisfy { !$0.isDownloaded })

        // Every compact card keeps one clear entry to its details/forecast
        // sheet, and the controls row stays a single compact line.
        let manager = ModelManagerView(store: store, telemetry: ModelManagerTelemetry())
        let downloaded = try #require(myCatalog.first { $0.catalogID == "qwen/qwen3.8-27b" })
        let undownloaded = try #require(available.first { $0.catalogID == "eigenlabs/eigen-7b" })
        #expect(ModelManagerPresentation.compactEntryActionLabel(for: downloaded) == "Manage")
        #expect(ModelManagerPresentation.compactEntryActionLabel(for: undownloaded) == "Details")
        for controls in [
            manager.cardControls(item: downloaded, at: Date()),
            manager.cardControls(item: undownloaded, at: Date())
        ] {
            let host = NSHostingView(rootView: controls.frame(width: 360, alignment: .leading).padding(16))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 20)
            #expect(host.fittingSize.height < 90)
        }

        guard ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" else { return }
        let telemetry = ModelManagerTelemetry(
            tokenRates: [
                ModelTokenRateAverage(model: "qwen/qwen3.8-27b", tokensPerSecond: 24.7,
                    sampleCount: 116, queryPeriod: nil)
            ],
            servingAverages: [
                ModelServingProfitAverage(
                    model: "qwen/qwen3.8-27b",
                    grossUSDPerActiveHour: 1.20,
                    incrementalElectricityUSDPerActiveHour: 0.21,
                    profitUSDPerActiveHour: 0.99,
                    activeHours: 2.5,
                    coveredEarningHours: 3,
                    activePowerSamples: 900,
                    idlePowerSamples: 500
                ),
                ModelServingProfitAverage(
                    model: "google/gemma-4-27b",
                    grossUSDPerActiveHour: 0.35,
                    incrementalElectricityUSDPerActiveHour: nil,
                    profitUSDPerActiveHour: nil,
                    activeHours: 0.8,
                    coveredEarningHours: 1,
                    activePowerSamples: 40,
                    idlePowerSamples: 10
                )
            ],
            networkCapacity: NetworkCapacitySnapshot(
                models: [
                    NetworkModelCapacity(
                        id: "qwen/qwen3.8-27b", ready: true, canAccept: true,
                        routableProviders: 8, warmProviders: 3, runningProviders: 5,
                        coldProviders: 1, activeRequests: 4, queuedRequests: 2,
                        queueLimit: 8, aggregateTokensPerSecond: 125,
                        estimatedTimeToFirstTokenMS: 240, tokenBudgetRemaining: 750,
                        tokenBudgetTotal: 1_000
                    ),
                    NetworkModelCapacity(
                        id: "google/gemma-4-27b", ready: true, canAccept: true,
                        routableProviders: 6, warmProviders: 2, runningProviders: 3,
                        coldProviders: 0, activeRequests: 1, queuedRequests: 0,
                        queueLimit: 8, aggregateTokensPerSecond: 60,
                        estimatedTimeToFirstTokenMS: 380, tokenBudgetRemaining: 900,
                        tokenBudgetTotal: 1_000
                    ),
                    NetworkModelCapacity(
                        id: "openai/gpt-oss-20b", ready: true, canAccept: true,
                        routableProviders: 12, warmProviders: 7, runningProviders: 9,
                        coldProviders: 2, activeRequests: 14, queuedRequests: 9,
                        queueLimit: 16, aggregateTokensPerSecond: 240,
                        estimatedTimeToFirstTokenMS: 180, tokenBudgetRemaining: 1_500,
                        tokenBudgetTotal: 2_000
                    )
                ],
                capturedAt: Date(),
                isDraining: false
            )
        )

        for width in [640.0, 1280.0, 1480.0] {
            try writeGroupedSnapshot(
                ModelManagerView(store: store, telemetry: telemetry),
                width: width,
                to: URL(fileURLWithPath: "/tmp/darkbloom-models-grouped-\(Int(width)).png")
            )
        }

        // Dedicated 2×2 evidence: two enabled plus two available cards at the
        // native 1280pt window width.
        let compactStore = ProviderControlStore(controller: EvidenceFourModelsController())
        await compactStore.refresh()
        try writeGroupedSnapshot(
            ModelManagerView(store: compactStore, telemetry: telemetry),
            width: 1280,
            to: URL(fileURLWithPath: "/tmp/darkbloom-models-2x2-1280.png")
        )
    }

    /// Renders the full manager inside an offscreen window and lets
    /// TimelineView, GeometryReader, and the lazy grids settle before
    /// capturing; ImageRenderer alone leaves this view blank.
    @MainActor
    private func writeGroupedSnapshot(_ view: some View, width: Double, to url: URL) throws {
        let host = NSHostingView(
            rootView: view
                .frame(width: width, height: 1_000)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
        )
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1_000))
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        window.orderOut(nil)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(representation)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

/// Synthetic catalog for render evidence only; no provider files are read or
/// changed by this actor.
private actor EvidenceModelsController: ProviderControlling {
    func refresh() async throws -> ProviderControlSnapshot {
        let now = Date()
        let catalog = [
            CatalogModel(id: "qwen/qwen3.8-27b", displayName: "Qwen 3.8 27B · 4-bit MLX", family: "qwen",
                modelType: "llm", capabilities: ["chat", "tools"], sizeGB: 16.3, minimumRAMGB: 36, active: true),
            CatalogModel(id: "google/gemma-4-27b", displayName: "Gemma 4 27B Instruct", family: "gemma",
                modelType: "llm", capabilities: ["chat", "vision"], sizeGB: 18.2, minimumRAMGB: 32, active: true),
            CatalogModel(id: "mlx-community/Llama-4-8B", displayName: "Llama 4 8B", family: "llama",
                modelType: "llm", capabilities: ["chat"], sizeGB: 5.2, minimumRAMGB: 12, active: true),
            CatalogModel(id: "openai/gpt-oss-20b", displayName: "GPT-OSS 20B", family: "gpt-oss",
                modelType: "llm", capabilities: ["chat", "tools"], sizeGB: 12.1, minimumRAMGB: 24, active: true),
            CatalogModel(id: "nvidia/nemotron-9-8b", displayName: "Nemotron 9 8B", family: "nemotron",
                modelType: "llm", capabilities: ["chat"], sizeGB: 6.4, minimumRAMGB: 16, active: true),
            CatalogModel(id: "eigenlabs/eigen-7b", displayName: "Eigen 7B", family: "eigen",
                modelType: "llm", capabilities: ["chat"], sizeGB: 4.1, minimumRAMGB: 10, active: true),
        ]
        let downloadedIDs = ["qwen/qwen3.8-27b", "google/gemma-4-27b", "mlx-community/Llama-4-8B"]
        let local = downloadedIDs.map {
            LocalModel(id: $0, modelType: "llm", sizeBytes: 15_000_000_000, estimatedMemoryGB: nil)
        }
        let selection = ProviderModelSelection(
            enabled: ["qwen/qwen3.8-27b", "google/gemma-4-27b"],
            preloaded: ["qwen/qwen3.8-27b"]
        )
        return ProviderControlSnapshot(
            inventory: ModelInventoryBuilder.build(
                catalog: catalog,
                local: local,
                selection: selection,
                daemon: nil,
                loadedModels: ["qwen/qwen3.8-27b"]
            ),
            draft: ProviderConfigDraft(sourceRevision: "evidence", original: selection, selection: selection),
            capturedAt: now,
            sources: ProviderControlSourceStates(
                catalog: .fresh(evidenceAt: now),
                localModels: .fresh(evidenceAt: now),
                daemon: .fresh(evidenceAt: now),
                loadedModels: .fresh(evidenceAt: now)
            )
        )
    }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        throw EvidenceRenderUnsupportedError()
    }

    func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {
        throw EvidenceRenderUnsupportedError()
    }

    func delete(_ localModelID: String) async throws { throw EvidenceRenderUnsupportedError() }
    func activityRisk() async -> ProviderActivityRisk { .unknown("render fixture") }
    func execute(
        _ action: ProviderLifecycleAction,
        enabledModels: [String]
    ) async throws {
        throw EvidenceRenderUnsupportedError()
    }
}

private struct EvidenceRenderUnsupportedError: Error {}

/// Four-model catalog (two enabled, one disabled download, one undownloaded)
/// for the dedicated 2×2 render; no provider files are read or changed.
private actor EvidenceFourModelsController: ProviderControlling {
    func refresh() async throws -> ProviderControlSnapshot {
        let now = Date()
        let catalog = [
            CatalogModel(id: "qwen/qwen3.8-27b", displayName: "Qwen 3.8 27B · 4-bit MLX", family: "qwen",
                modelType: "llm", capabilities: ["chat", "tools"], sizeGB: 16.3, minimumRAMGB: 36, active: true),
            CatalogModel(id: "google/gemma-4-27b", displayName: "Gemma 4 27B Instruct", family: "gemma",
                modelType: "llm", capabilities: ["chat", "vision"], sizeGB: 18.2, minimumRAMGB: 32, active: true),
            CatalogModel(id: "mlx-community/Llama-4-8B", displayName: "Llama 4 8B", family: "llama",
                modelType: "llm", capabilities: ["chat"], sizeGB: 5.2, minimumRAMGB: 12, active: true),
            CatalogModel(id: "openai/gpt-oss-20b", displayName: "GPT-OSS 20B", family: "gpt-oss",
                modelType: "llm", capabilities: ["chat", "tools"], sizeGB: 12.1, minimumRAMGB: 24, active: true)
        ]
        let local = ["qwen/qwen3.8-27b", "google/gemma-4-27b", "mlx-community/Llama-4-8B"].map {
            LocalModel(id: $0, modelType: "llm", sizeBytes: 15_000_000_000, estimatedMemoryGB: nil)
        }
        let selection = ProviderModelSelection(
            enabled: ["qwen/qwen3.8-27b", "google/gemma-4-27b"],
            preloaded: ["qwen/qwen3.8-27b"]
        )
        return ProviderControlSnapshot(
            inventory: ModelInventoryBuilder.build(
                catalog: catalog, local: local, selection: selection,
                daemon: nil, loadedModels: ["qwen/qwen3.8-27b"]
            ),
            draft: ProviderConfigDraft(sourceRevision: "evidence-2x2", original: selection, selection: selection),
            capturedAt: now,
            sources: ProviderControlSourceStates(
                catalog: .fresh(evidenceAt: now), localModels: .fresh(evidenceAt: now),
                daemon: .fresh(evidenceAt: now), loadedModels: .fresh(evidenceAt: now)
            )
        )
    }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        throw EvidenceRenderUnsupportedError()
    }

    func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {
        throw EvidenceRenderUnsupportedError()
    }

    func delete(_ localModelID: String) async throws { throw EvidenceRenderUnsupportedError() }
    func activityRisk() async -> ProviderActivityRisk { .unknown("render fixture") }
    func execute(
        _ action: ProviderLifecycleAction,
        enabledModels: [String]
    ) async throws {
        throw EvidenceRenderUnsupportedError()
    }
}
