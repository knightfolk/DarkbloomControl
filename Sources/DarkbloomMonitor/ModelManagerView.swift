import DarkbloomTelemetry
import Foundation
import SwiftUI

struct ModelActionPresentation: Equatable {
    let accessibilityLabel: String
    let accessibilityHint: String
    let isEnabled: Bool
}

struct ModelOpportunitySignal: Equatable {
    let modelID: String
    let tokensPerSecond: Double?
    let activeHours: Double
    let demand: NetworkDemandBand?
    let netProfitUSDPerActiveHour: Double?
}

enum ModelCompany: Equatable {
    case google, qwen, openai, nvidia, meta, mistral, deepseek, microsoft, ibm, cohere, xai, prismml, other
}

@MainActor
enum ModelManagerPresentation {
    static func vendor(for modelID: String) -> ModelCompany {
        let normalized = modelID.lowercased()
        let namespace = normalized.split(separator: "/").first.map(String.init) ?? ""
        let slug = normalized.split(separator: "/").last.map(String.init) ?? normalized
        if namespace == "google" || slug.hasPrefix("gemma") { return .google }
        if namespace == "qwen" || slug.hasPrefix("qwen") { return .qwen }
        if namespace == "openai" || slug.hasPrefix("gpt-oss") { return .openai }
        if namespace == "nvidia" || slug.contains("nemotron") { return .nvidia }
        if namespace == "meta" || slug.hasPrefix("llama") { return .meta }
        if namespace == "mistralai" || slug.hasPrefix("mistral") || slug.hasPrefix("mixtral") { return .mistral }
        if namespace == "deepseek-ai" || slug.hasPrefix("deepseek") { return .deepseek }
        if namespace == "microsoft" || slug.hasPrefix("phi-") { return .microsoft }
        if namespace == "ibm" || slug.hasPrefix("granite") { return .ibm }
        if namespace == "cohere" || slug.hasPrefix("command-") { return .cohere }
        if namespace == "xai" || slug.hasPrefix("grok") { return .xai }
        if namespace == "prismml" || slug.contains("bonsai") { return .prismml }
        return .other
    }

    static func hardwareFit(_ item: ModelInventoryItem, installedMemoryGB: Double) -> String {
        let ramFit: String
        if item.minimumRAMGB <= 0 || !installedMemoryGB.isFinite || installedMemoryGB <= 0 {
            ramFit = "RAM requirement unavailable"
        } else if installedMemoryGB >= Double(item.minimumRAMGB) {
            ramFit = "Meets catalog minimum"
        } else {
            ramFit = "Below catalog minimum"
        }
        guard let requirements = item.requiredProviderCapabilities, !requirements.isEmpty else {
            return ramFit
        }
        return ramFit == "RAM requirement unavailable"
            ? "RAM and provider requirements unverified"
            : "\(ramFit) · provider features unverified"
    }

    static func maximumRunPercent(modelID: String, selected: [String: Int]) -> Int {
        let assignedElsewhere = selected.reduce(into: 0) { total, item in
            guard item.key != modelID else { return }
            total += min(100, max(0, item.value))
        }
        return max(0, 100 - assignedElsewhere)
    }

    static func totalRunPercent(_ selected: [String: Int]) -> Int {
        min(100, selected.values.reduce(0) { $0 + min(100, max(0, $1)) })
    }

    static func runHoursPerDay(percent: Int) -> Double {
        24 * Double(min(100, max(0, percent))) / 100
    }

    static func opportunityGrade(modelID: String, peers: [ModelOpportunitySignal]) -> String? {
        let calibrated = peers.filter { signal in
            guard signal.activeHours >= 2,
                  let speed = signal.tokensPerSecond, speed.isFinite, speed > 0,
                  let demand = signal.demand,
                  let profit = signal.netProfitUSDPerActiveHour, profit.isFinite else { return false }
            return demandScore(demand) > 0
        }
        guard let target = calibrated.first(where: { $0.modelID == modelID }),
              let targetSpeed = target.tokensPerSecond,
              let targetDemand = target.demand,
              let targetProfit = target.netProfitUSDPerActiveHour,
              let fastest = calibrated.compactMap(\.tokensPerSecond).max(), fastest > 0 else { return nil }
        guard targetProfit > 0 else { return "F" }
        let bestProfit = calibrated.compactMap(\.netProfitUSDPerActiveHour).filter({ $0 > 0 }).max() ?? 0

        let speedPoints = targetSpeed / fastest * 40
        let demandPoints = demandScore(targetDemand) * 30
        let profitPoints = targetProfit == 0 || bestProfit == 0 ? 0 : targetProfit / bestProfit * 30
        let score = speedPoints + demandPoints + min(30, profitPoints)
        switch score {
        case 90...: return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        case 60..<70: return "D"
        default: return "F"
        }
    }

    private static func demandScore(_ band: NetworkDemandBand) -> Double {
        switch band {
        case .low: 0.25
        case .moderate: 0.5
        case .high: 0.75
        case .urgent: 1
        }
    }

    static func effectiveLimit(_ value: Int, maximum: Int? = nil) -> Int {
        min(maximum ?? Int.max, max(1, value))
    }

    static func filtered(_ items: [ModelInventoryItem], search: String) -> [ModelInventoryItem] {
        return items.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
            || $0.catalogID.localizedCaseInsensitiveContains(search) }.sorted {
                func rank(_ item: ModelInventoryItem) -> Int {
                    switch item.liveState { case .active: 0; case .loadedIdle: 1; case .unloaded: 2 }
                }
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                let names = $0.displayName.localizedStandardCompare($1.displayName)
                return names == .orderedSame ? $0.catalogID < $1.catalogID : names == .orderedAscending
            }
    }

    static func enabledFirst(
        _ items: [ModelInventoryItem],
        isEnabled: (ModelInventoryItem) -> Bool
    ) -> [ModelInventoryItem] {
        items.enumerated().sorted { lhs, rhs in
            let lhsEnabled = isEnabled(lhs.element)
            let rhsEnabled = isEnabled(rhs.element)
            if lhsEnabled != rhsEnabled { return lhsEnabled }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func diagnostic(
        _ value: String,
        sanitize: (String) -> String
    ) -> String {
        sanitize(value)
    }

    static func availableRow(
        item: ModelInventoryItem,
        store: ProviderControlStore
    ) -> ModelRowPresentation {
        ModelRowPresentation.make(
            item: item,
            draft: store.draft,
            operation: store.operation,
            mutationPhase: store.operationPhase,
            sources: store.snapshot?.sources ?? .unknown,
            currentTime: Date(),
            canDownload: store.canDownload(item.catalogID),
            downloadUnavailableReason: store.draftValidationMessage,
            sanitize: store.sanitizedDiagnostic
        )
    }
}

struct ModelManagerTelemetry {
    var tokenRates: [ModelTokenRateAverage] = []
    var servingAverages: [ModelServingProfitAverage] = []
    var networkCapacity: NetworkCapacitySnapshot?
}

struct ModelRowPresentation: Equatable {
    let showsDownload: Bool
    let showsEnableToggle: Bool
    let showsPreloadToggle: Bool
    let showsDelete: Bool
    let deleteBlockReason: String?
    let availableMetadataText: String?
    let displayedIssue: String?
    let enableAction: ModelActionPresentation?
    let preloadAction: ModelActionPresentation?
    let deleteAction: ModelActionPresentation?
    let downloadAction: ModelActionPresentation?

    @MainActor
    static func make(
        item: ModelInventoryItem,
        draft: ProviderConfigDraft?,
        operation: ProviderOperation,
        mutationPhase: ProviderMutationPhase? = nil,
        sources: ProviderControlSourceStates,
        currentTime: Date,
        canDownload: Bool,
        downloadUnavailableReason: String?,
        sanitize: (String) -> String
    ) -> Self {
        let isDownloaded = item.isDownloaded
        let displayedIssue = item.issue.map(sanitize)
        let controlsBlockReason = controlBlockReason(
            displayedIssue: displayedIssue,
            draft: draft,
            operation: operation
        )
        let deleteBlockReason = isDownloaded
            ? deleteBlockReason(
                item: item,
                displayedIssue: displayedIssue,
                draft: draft,
                operation: operation,
                sources: sources,
                currentTime: currentTime,
                sanitize: sanitize
            )
            : nil
        let isEnabled = draft.map {
            contains(
                item,
                in: $0.selection.enabled,
                selector: item.enabledSelector
            )
        } ?? item.isEnabled
        let isPreloaded = draft.map {
            contains(
                item,
                in: $0.selection.preloaded,
                selector: item.preloadSelector
            )
        } ?? item.isPreloaded
        return Self(
            showsDownload: !isDownloaded,
            showsEnableToggle: isDownloaded,
            showsPreloadToggle: isDownloaded,
            showsDelete: isDownloaded,
            deleteBlockReason: deleteBlockReason,
            availableMetadataText: isDownloaded
                ? nil
                : ModelFormatting.availableDetails(item),
            displayedIssue: displayedIssue,
            enableAction: isDownloaded
                ? toggleAction(
                    isSelected: isEnabled,
                    selectedVerb: "Disable",
                    unselectedVerb: "Enable",
                    item: item,
                    blockReason: controlsBlockReason
                )
                : nil,
            preloadAction: isDownloaded
                ? toggleAction(
                    isSelected: isPreloaded,
                    selectedVerb: "Remove preload",
                    unselectedVerb: "Preload",
                    item: item,
                    blockReason: controlsBlockReason
                )
                : nil,
            deleteAction: isDownloaded
                ? ModelActionPresentation(
                    accessibilityLabel: "Delete \(item.displayName)",
                    accessibilityHint: deleteBlockReason
                        ?? "Shows a confirmation before deleting \(item.displayName).",
                    isEnabled: deleteBlockReason == nil
                )
                : nil,
            downloadAction: isDownloaded
                ? nil
                : downloadAction(
                    item: item,
                    displayedIssue: displayedIssue,
                    operation: operation,
                    mutationPhase: mutationPhase,
                    canDownload: canDownload,
                    unavailableReason: downloadUnavailableReason.map(sanitize)
                )
        )
    }

    private static func deleteBlockReason(
        item: ModelInventoryItem,
        displayedIssue: String?,
        draft: ProviderConfigDraft?,
        operation: ProviderOperation,
        sources: ProviderControlSourceStates,
        currentTime: Date,
        sanitize: (String) -> String
    ) -> String? {
        guard operation == .idle else { return "Another model action is in progress" }
        switch item.liveState {
        case .active:
            return "Model is currently active"
        case .loadedIdle:
            return "Model is currently loaded"
        case .unloaded:
            break
        }
        if let sourceReason = deletionFreshnessBlockReason(
            sources: sources,
            currentTime: currentTime,
            sanitize: sanitize
        ) {
            return sourceReason
        }
        if let displayedIssue { return displayedIssue }
        guard let draft else { return "Provider configuration is unavailable" }
        if contains(
            item,
            in: draft.original.preloaded,
            selector: item.preloadSelector
        ) {
            return "Remove preload and save before deleting this model"
        }
        if contains(
            item,
            in: draft.original.enabled,
            selector: item.enabledSelector
        ) {
            return "Disable and save this model before deleting it"
        }
        guard !draft.hasChanges else {
            return "Save or reload pending changes before deleting it"
        }
        return nil
    }

    private static func deletionFreshnessBlockReason(
        sources: ProviderControlSourceStates,
        currentTime: Date,
        sanitize: (String) -> String
    ) -> String? {
        let checks: [(ProviderControlSourceState, String, String, String, String)] = [
            (
                sources.catalog,
                "Model catalog timestamp is invalid",
                "Model catalog is stale",
                "Model catalog timestamp is in the future",
                "Reload the model catalog before deleting this model."
            ),
            (
                sources.localModels,
                "Local model list timestamp is invalid",
                "Local model list is stale",
                "Local model list timestamp is in the future",
                "Reload local models before deleting this model."
            ),
            (
                sources.daemon,
                "Provider activity timestamp is invalid",
                "Provider activity is stale",
                "Provider activity timestamp is in the future",
                "Refresh provider activity before deleting this model."
            ),
            (
                sources.loadedModels,
                "Loaded model state timestamp is invalid",
                "Loaded model state is stale",
                "Loaded model state timestamp is in the future",
                "Refresh loaded model state before deleting this model."
            ),
        ]
        for (state, invalid, _, future, recovery) in checks {
            switch state {
            case .fresh(let evidenceAt):
                guard evidenceAt.timeIntervalSince1970.isFinite,
                      currentTime.timeIntervalSince1970.isFinite
                else { return sanitize("\(invalid); \(recovery)") }
                if evidenceAt > currentTime {
                    return sanitize("\(future); \(recovery)")
                }
                continue
            case .stale(let issue), .unavailable(let issue):
                return sanitize("\(issue); \(recovery)")
            }
        }
        return nil
    }

    private static func controlBlockReason(
        displayedIssue: String?,
        draft: ProviderConfigDraft?,
        operation: ProviderOperation
    ) -> String? {
        guard operation == .idle else { return "Another model action is in progress" }
        if let displayedIssue { return displayedIssue }
        guard draft != nil else { return "Provider configuration is unavailable" }
        return nil
    }

    private static func toggleAction(
        isSelected: Bool,
        selectedVerb: String,
        unselectedVerb: String,
        item: ModelInventoryItem,
        blockReason: String?
    ) -> ModelActionPresentation {
        let verb = isSelected ? selectedVerb : unselectedVerb
        return ModelActionPresentation(
            accessibilityLabel: "\(verb) \(item.displayName)",
            accessibilityHint: blockReason
                ?? "Stages this change for \(item.displayName) until settings are saved.",
            isEnabled: blockReason == nil
        )
    }

    private static func downloadAction(
        item: ModelInventoryItem,
        displayedIssue: String?,
        operation: ProviderOperation,
        mutationPhase: ProviderMutationPhase?,
        canDownload: Bool,
        unavailableReason: String?
    ) -> ModelActionPresentation? {
        if operation == .downloading(item.catalogID) {
            guard mutationPhase != .reconciling else { return nil }
            return ModelActionPresentation(
                accessibilityLabel: "Cancel download \(item.displayName)",
                accessibilityHint: "Stops the download for \(item.displayName).",
                isEnabled: true
            )
        }

        let blockReason: String?
        if let displayedIssue {
            blockReason = displayedIssue
        } else if operation != .idle {
            blockReason = "Another model action is in progress"
        } else if !canDownload {
            blockReason = unavailableReason ?? "Reload model controls before downloading"
        } else {
            blockReason = nil
        }
        return ModelActionPresentation(
            accessibilityLabel: "Download \(item.displayName)",
            accessibilityHint: blockReason
                ?? "Downloads \(item.displayName) to this Mac.",
            isEnabled: blockReason == nil
        )
    }

    fileprivate static func contains(
        _ item: ModelInventoryItem,
        in selectors: [String],
        selector: String?
    ) -> Bool {
        selectors.contains(item.catalogID)
            || selector.map(selectors.contains) == true
    }

    func requestDeletion(
        of item: ModelInventoryItem,
        using request: (ModelInventoryItem) -> Void
    ) {
        guard deleteAction?.isEnabled == true else { return }
        request(item)
    }
}

@MainActor
struct ModelManagerView: View {
    @ObservedObject var store: ProviderControlStore
    var networkContext: (String, Date) -> [String] = { _, _ in [] }
    var telemetry = ModelManagerTelemetry()
    @State private var deletion: ModelDeletionConfirmation?
    @State private var section = 0
    @State private var search = ""
    @State private var inspectedModel: ModelInventoryItem?
    @State private var runPercentByModel: [String: Int] = [:]
    @AppStorage("models.daily-serving-schedule-v1") private var savedRunSchedule = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                modelList(currentTime: context.date)
                Divider()
                ModelManagerFooter(store: store)
            }
        }
        .alert(item: $deletion) { confirmation in
            Alert(
                title: Text("Delete \(confirmation.displayName)?"),
                message: Text(
                    "This removes approximately \(confirmation.formattedSize) of downloaded model data."
                ),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await store.delete(confirmation.localID) }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $inspectedModel) { item in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Model settings & forecast").font(.title2.bold())
                    Spacer()
                    Button("Done") { inspectedModel = nil }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    let current = store.snapshot?.inventory.myCatalog.first { $0.catalogID == item.catalogID }
                        ?? store.snapshot?.inventory.available.first { $0.catalogID == item.catalogID } ?? item
                    modelCard(current, at: Date(), expanded: true)
                }
            }.padding(24).frame(width: 620, height: 740)
        }
        .onAppear(perform: restoreRunSchedule)
        .onChange(of: runPercentByModel) { _, schedule in
            guard let data = try? JSONEncoder().encode(schedule) else { return }
            savedRunSchedule = String(decoding: data, as: UTF8.self)
        }
    }

    private func contextBadges(for modelID: String, at date: Date) -> some View {
        ForEach(networkContext(modelID, date), id: \.self) { label in
            Text(label).font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelList(currentTime: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("View", selection: $section) {
                    Text("On this Mac").tag(0)
                    Text("Available").tag(1)
                    Text("Capacity").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
                Spacer(minLength: 4)
                if section != 2 {
                    TextField("Find models", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 220)
                        .accessibilityLabel("Find a model")
                }
            }
            if section == 0 {
                Text("Enabled models can receive work; startup loading is subject to memory.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Scheduled serving: \(ModelManagerPresentation.runHoursPerDay(percent: ModelManagerPresentation.totalRunPercent(enabledSchedule)).formatted(.number.precision(.fractionLength(0...1)))) h/day · active work estimate, not memory use")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if section == 2 {
                            capacityControls
                        } else {
                            let items = visibleModels
                            if store.snapshot == nil && store.operation == .refreshing {
                                HStack { ProgressView().controlSize(.small); Text("Reading your model catalog…") }
                                    .foregroundStyle(.secondary).padding(.vertical, 20)
                            } else if items.isEmpty {
                                ContentUnavailableView(search.isEmpty ? "No models here" : "No matching models",
                                    systemImage: "cpu", description: Text(store.snapshot == nil
                                        ? "Refresh to load the model catalog." : "Try another view or search."))
                            }
                            LazyVGrid(columns: ModelCardLayout.columns(for: geometry.size.width),
                                      alignment: .leading, spacing: ModelCardLayout.rowSpacing) {
                                ForEach(items) { item in
                                    modelCard(item, at: currentTime)
                                }
                            }
                        }
                        if let issues = store.snapshot?.inventory.issues, !issues.isEmpty {
                            DisclosureGroup("Catalog notices (\(issues.count))") {
                                ForEach(issues, id: \.self) { issue in
                                    Text(store.sanitizedDiagnostic(issue)).font(.callout).foregroundStyle(.orange)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(geometry.size.height, ModelCardLayout.maximumVisibleHeight))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var visibleModels: [ModelInventoryItem] {
        let items = section == 0 ? store.snapshot?.inventory.myCatalog : store.snapshot?.inventory.available
        let filtered = ModelManagerPresentation.filtered(items ?? [], search: search)
        return ModelManagerPresentation.enabledFirst(filtered, isEnabled: isEffectivelyEnabled)
    }

    private var enabledSchedule: [String: Int] {
        let enabled = (store.snapshot?.inventory.myCatalog ?? []).filter(isEffectivelyEnabled)
            .sorted { $0.catalogID < $1.catalogID }
        var result: [String: Int] = [:]
        for item in enabled {
            let remaining = ModelManagerPresentation.maximumRunPercent(modelID: item.catalogID, selected: result)
            result[item.catalogID] = min(remaining, max(0, runPercentByModel[item.catalogID] ?? 0))
        }
        return result
    }

    private func isEffectivelyEnabled(_ item: ModelInventoryItem) -> Bool {
        guard let draft = store.draft else { return item.isEnabled }
        return ModelRowPresentation.contains(item, in: draft.selection.enabled, selector: item.enabledSelector)
    }

    private func restoreRunSchedule() {
        guard !savedRunSchedule.isEmpty,
              let decoded = try? JSONDecoder().decode([String: Int].self, from: Data(savedRunSchedule.utf8))
        else { return }
        var sanitized: [String: Int] = [:]
        for (id, value) in decoded.sorted(by: { $0.key < $1.key }).prefix(128) {
            guard !id.isEmpty, id.utf8.count <= 512, (0...100).contains(value) else { continue }
            sanitized[id] = value
        }
        runPercentByModel = sanitized
    }

    private func setRunPercent(_ value: Int, for item: ModelInventoryItem) {
        var selected = enabledSchedule
        let limit = ModelManagerPresentation.maximumRunPercent(modelID: item.catalogID, selected: selected)
        selected[item.catalogID] = min(limit, max(0, value))
        runPercentByModel[item.catalogID] = selected[item.catalogID]
    }

    private func tokenRate(for item: ModelInventoryItem) -> ModelTokenRateAverage? {
        telemetry.tokenRates.first { $0.model == item.catalogID || $0.model == item.localID }
    }

    private func servingAverage(for item: ModelInventoryItem) -> ModelServingProfitAverage? {
        telemetry.servingAverages.first { $0.model == item.catalogID || $0.model == item.localID }
    }

    private func demand(for item: ModelInventoryItem, at date: Date) -> NetworkModelCapacity? {
        guard let capacity = telemetry.networkCapacity, capacity.isFresh(at: date) else { return nil }
        return capacity.models.first { $0.id == item.catalogID }
    }

    private func opportunitySignals(at date: Date) -> [ModelOpportunitySignal] {
        (store.snapshot?.inventory.myCatalog ?? []).filter(isEffectivelyEnabled).compactMap { item in
            let rate = tokenRate(for: item)
            let serving = servingAverage(for: item)
            return ModelOpportunitySignal(
                modelID: item.catalogID,
                tokensPerSecond: rate?.tokensPerSecond,
                activeHours: serving?.activeHours ?? 0,
                demand: demand(for: item, at: date)?.demandBand,
                netProfitUSDPerActiveHour: serving?.profitUSDPerActiveHour
            )
        }
    }

    @ViewBuilder
    private func modelCard(_ item: ModelInventoryItem, at date: Date, expanded: Bool = false) -> some View {
        let rate = tokenRate(for: item)
        let serving = servingAverage(for: item)
        let calibratedServing = serving.flatMap { $0.activeHours >= 2 ? $0 : nil }
        let capacity = demand(for: item, at: date)
        let runPercent = enabledSchedule[item.catalogID] ?? 0
        let forecast = ModelRunForecast.calculate(runPercent: runPercent, serving: calibratedServing, tokenRate: rate)
        let peers = opportunitySignals(at: date)
        let grade = ModelManagerPresentation.opportunityGrade(modelID: item.catalogID, peers: peers)
        VStack(alignment: .leading, spacing: 14) {
            ModelCardSummary(
                item: item,
                installedMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                rate: rate,
                capacity: capacity,
                serving: serving,
                grade: grade,
                forecast: forecast,
                runPercent: runPercent,
                isScheduleEnabled: item.isDownloaded && isEffectivelyEnabled(item),
                maximumRunPercent: ModelManagerPresentation.maximumRunPercent(
                    modelID: item.catalogID, selected: enabledSchedule
                ),
                setRunPercent: { setRunPercent($0, for: item) },
                showsDetails: expanded
            )
            if expanded {
            if item.isDownloaded, let snapshot = store.snapshot {
                DownloadedModelRow(item: item, draft: store.draft,
                    operation: store.operation, sources: snapshot.sources,
                    currentTime: date, sanitize: store.sanitizedDiagnostic,
                    setEnabled: { store.setEnabled($0, modelID: $1) },
                    setPreloaded: { store.setPreloaded($0, modelID: $1) },
                    requestDelete: { item in
                        guard let localID = item.localID else { return }
                        inspectedModel = nil
                        deletion = ModelDeletionConfirmation(localID: localID,
                            displayName: item.displayName, sizeGB: item.sizeGB)
                    }).disabled(store.queuedStopState != nil)
            } else {
                AvailableModelRow(item: item, store: store).disabled(store.queuedStopState != nil)
            }
            modelDetails(item, at: date)
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if item.isDownloaded, let snapshot = store.snapshot {
                        DownloadedModelRow(item: item, draft: store.draft,
                            operation: store.operation, sources: snapshot.sources,
                            currentTime: date, sanitize: store.sanitizedDiagnostic,
                            setEnabled: { store.setEnabled($0, modelID: $1) },
                            setPreloaded: { store.setPreloaded($0, modelID: $1) },
                            requestDelete: { _ in }, compact: true)
                            .disabled(store.queuedStopState != nil)
                    } else {
                        Label("Not downloaded", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                }.frame(height: 66, alignment: .topLeading)
                Button("Manage & forecast") { inspectedModel = item }
                    .help("Open daily serving estimates, model details, and additional controls. Serving allocation estimates compute time, not memory residency.")
                    .buttonStyle(.bordered).controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).fill(ModelCardSummary.companyColor(for: item.catalogID))
                .frame(width: 40, height: 4).padding(.leading, 16)
        }
        .accessibilityIdentifier("model.\(item.catalogID).card")
    }

    @ViewBuilder
    private var capacityControls: some View {
        if let draft = store.draft {
            VStack(alignment: .leading, spacing: 20) {
                capacityCard("Simultaneous requests", icon: "arrow.triangle.branch",
                    value: draft.engineV2MaxConcurrent, defaultValue: 4, selectableMaximum: 24,
                    explanation: "Maximum concurrent requests per model engine. Choose 1–24. Higher limits use more memory; CLI 0.9.7 caps actual per-model concurrency at 8. Model-specific overrides may also reduce it.",
                    set: store.setEngineV2MaxConcurrent)
                capacityCard("Models kept in memory", icon: "memorychip",
                    value: draft.maxModelSlots, defaultValue: 3,
                    explanation: "The provider can keep this many models loaded, when memory allows. This is separate from simultaneous requests.",
                    set: store.setMaxModelSlots)
                Label("Save, then restart the provider to apply these limits.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }.disabled(store.operation != .idle || store.queuedStopState != nil)
        } else {
            ContentUnavailableView("Capacity settings unavailable", systemImage: "slider.horizontal.3",
                description: Text("Refresh to read the provider configuration."))
        }
    }

    private func capacityCard(_ title: String, icon: String, value: Int?, defaultValue: Int, effectiveMaximum: Int? = nil, selectableMaximum: Int = 8,
                              explanation: String, set: @escaping @MainActor @Sendable (Int) -> Void) -> some View {
        let effective = ModelManagerPresentation.effectiveLimit(value ?? defaultValue, maximum: effectiveMaximum)
        return VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            HStack {
                Text(String(effective)).font(.largeTitle.bold().monospacedDigit())
                Text(value == nil ? "CLI default" : "Selected limit")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker(title, selection: Binding(get: { value ?? defaultValue }, set: set)) {
                    ForEach(Array(1...selectableMaximum), id: \.self) { Text(String($0)).tag($0) }
                    if let value, !(1...selectableMaximum).contains(value) {
                        Text("\(value) · existing setting").tag(value)
                    }
                }
                .labelsHidden().frame(width: 110).accessibilityLabel(title)
            }
            if let value, value != effective {
                Text("Saved value \(value); the CLI applies a limit of \(effective). Choose a value to replace it.")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private func modelDetails(_ item: ModelInventoryItem, at date: Date) -> some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 4) {
                ModelIdentityDetails(item: item)
                Text("\(ModelFormatting.size(item.sizeGB)) catalog estimate")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(item.minimumRAMGB) GB minimum RAM (catalog requirement)")
                    .font(.caption).foregroundStyle(.secondary)
                if let bytes = item.downloadedSizeBytes {
                    Text("Downloaded · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) reported locally")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let quantization = ModelFormatting.quantization(item) {
                    Text("Quantization: \(quantization) · catalog metadata")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let limits = ModelFormatting.catalogLimits(item) {
                    Text(limits)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let requirements = ModelFormatting.providerRequirements(item) {
                    Label(requirements, systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("model.\(item.catalogID).provider-requirements")
                }
                ForEach(ModelFormatting.capabilityAdvisories(item), id: \.self) { advisory in
                    Label(advisory, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                contextBadges(for: item.catalogID, at: date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .disclosureGroupStyle(ModelDetailsDisclosureStyle())
        .accessibilityIdentifier("model.\(item.catalogID).details")
    }


}

enum ModelCardLayout {
    static let maximumColumns = 3
    static let maximumVisibleRows = 2
    static let rowSpacing: CGFloat = 20
    static let estimatedCardHeight: CGFloat = 530
    static let maximumVisibleHeight = CGFloat(maximumVisibleRows) * estimatedCardHeight + rowSpacing

    static func columnCount(for width: CGFloat) -> Int {
        min(maximumColumns, max(1, Int((width + rowSpacing) / 370)))
    }

    static func columns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: rowSpacing, alignment: .top),
              count: columnCount(for: width))
    }
}

struct ModelCardSummary: View {
    let item: ModelInventoryItem
    let installedMemoryGB: Double
    let rate: ModelTokenRateAverage?
    let capacity: NetworkModelCapacity?
    let serving: ModelServingProfitAverage?
    let grade: String?
    let forecast: ModelRunForecast
    let runPercent: Int
    let isScheduleEnabled: Bool
    let maximumRunPercent: Int
    let setRunPercent: (Int) -> Void
    var showsDetails = false

    private var company: ModelCompany { ModelManagerPresentation.vendor(for: item.catalogID) }
    private var accent: Color { Self.companyColor(for: item.catalogID) }
    private var ramFit: String { ModelManagerPresentation.hardwareFit(item, installedMemoryGB: installedMemoryGB) }

    var body: some View {
        if showsDetails { detailedBody } else { cardFace }
    }

    private var cardFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let image = DarkbloomLogoAsset.modelImage(family: ModelFamilyIcon.select(status: .online, activeModel: item.catalogID)) {
                    Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
                        .foregroundStyle(accent).frame(width: 32, height: 32)
                        .frame(width: 48, height: 48)
                        .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                }
                Text(companyName).font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
                Spacer()
                if item.isDownloaded {
                    LiveStatePill(state: item.liveState)
                        .help("Current provider residency or activity. Loaded means in memory; it does not necessarily mean serving a request. This can differ from your saved enable and startup settings.")
                }
                else { Text("Available").font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            Text(item.displayName)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(3).help(item.displayName)
                .frame(height: 76, alignment: .topLeading)
                .padding(.top, 14)
            Text("\(item.modelType.uppercased())  ·  \(ModelFormatting.size(item.sizeGB)) weights")
                .help("Model type and catalog weight-size estimate. This is not the model’s total memory use while running.")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .padding(.bottom, 20)
            HStack(alignment: .top, spacing: 20) {
                headlineMetric("Measured speed", icon: "speedometer", value: speedValue, unit: "tok/s", explanation: "Average measured token generation speed on this Mac. Based on recent samples, not advertised performance. A dash means no usable samples yet.")
                Spacer(minLength: 0)
                headlineMetric("Average profit", icon: "dollarsign.arrow.circlepath", value: profitValue, unit: profitUnit, explanation: "Recorded earnings per active serving hour, less estimated electricity when available. Power is estimated from whole-Mac adapter draw above idle, not measured separately for this model. Gross excludes electricity. Learning requires at least two active hours; this is not a guaranteed payout.")
            }
            .frame(height: 116, alignment: .top)
            Divider()
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: "shield.fill")
                        .foregroundStyle(
                            LinearGradient(colors: [demandColor.opacity(0.55), demandColor, demandColor.opacity(0.65)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: demandColor.opacity(0.25), radius: 3, x: 0, y: 2)
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(.white.opacity(0.23))
                    Image(systemName: "shield")
                        .foregroundStyle(
                            LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08)],
                                           startPoint: .top, endPoint: .bottom))
                }
                .font(.system(size: 27, weight: .regular))
                .help(demandHelp)
                .accessibilityHidden(true)
                Text(capacity.map { demandTitle($0.demandBand).replacingOccurrences(of: " demand", with: "") } ?? "—")
                    .help(demandHelp)
                Spacer(minLength: 4)
                if let capacity {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(capacity.activeRequests.formatted()) active")
                            .help("Requests currently running across the network for this model—not just on your Mac.")
                        Text("\(capacity.queuedRequests.formatted()) waiting")
                            .foregroundStyle(.secondary)
                            .help("Requests queued across the network for this model, waiting to be served.")
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .help("Network-wide requests for this model, not just this Mac.")
                }
                HStack(spacing: 5) {
                    Image(systemName: "seal")
                        .foregroundStyle(accent).accessibilityHidden(true)
                    Text(grade ?? "—").font(.system(size: 17, weight: .semibold, design: .rounded))
                }.help(gradeHelp)
            }
            .font(.system(size: 13, weight: .medium)).padding(.vertical, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Network demand: " + (capacity.map { demandTitle($0.demandBand) } ?? "unavailable")
                                + demandRequestDescription + ". Opportunity grade: " + (grade ?? "not yet rated"))
        }
        .frame(height: 336, alignment: .top)
    }

    private var demandHelp: String {
        "Network demand for this model. Red: urgent. Yellow: high or moderate. Green: low. Gray: no fresh reading. This describes network traffic, not your Mac’s health or a guarantee of work."
    }

    private var gradeHelp: String {
        "Opportunity grade: " + (grade ?? "not yet rated") + ". Speed contributes 40%, demand 30%, and estimated net profit 30%. Speed and profit are compared with your enabled models. Requires at least two active hours and usable speed, demand and net-profit data. A is highest; F includes nonpositive profit. A dash means insufficient data."
    }

    private var demandRequestDescription: String {
        guard let capacity else { return ". Request counts unavailable" }
        return ". Network-wide: \(capacity.activeRequests) active requests, \(capacity.queuedRequests) waiting"
    }

    private var demandColor: Color {
        guard let capacity else { return .gray }
        switch capacity.demandBand {
        case .low: return .green
        case .moderate, .high: return .yellow
        case .urgent: return .red
        }
    }

    private var speedValue: String {
        guard let rate, rate.tokensPerSecond.isFinite, rate.tokensPerSecond > 0, rate.sampleCount > 0 else { return "—" }
        return rate.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))
    }

    private var profitValue: String {
        guard let serving, serving.activeHours >= 2 else { return "Learning" }
        return serving.profitUSDPerActiveHour.map(money) ?? serving.grossUSDPerActiveHour.formatted(.currency(code: "USD"))
    }

    private var profitUnit: String {
        guard let serving, serving.activeHours >= 2 else { return "needs 2 active hours" }
        return serving.profitUSDPerActiveHour == nil ? "gross / active hour" : "net / active hour"
    }

    private func headlineMetric(_ title: String, icon: String, value: String, unit: String, explanation: String) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                Image(systemName: icon)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(accent.opacity(0.45))
                    .frame(height: 78, alignment: .top)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.system(size: value == "Learning" ? 23 : 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            }
            Text(unit).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(title + ": " + value + " " + unit + "\n\n" + explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ": " + value + " " + unit)
        .accessibilityHint(explanation)
    }

    private var detailedBody: some View {

        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: modelSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(item.displayName)
                    HStack(spacing: 6) {
                        Text(companyName).font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text("·").foregroundStyle(.tertiary)
                        Text(item.modelType.uppercased()).font(.caption).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(ModelFormatting.size(item.sizeGB)).font(.caption).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if item.isDownloaded {
                    LiveStatePill(state: item.liveState)
                } else {
                    Text("Available")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }

            Label(ramFit, systemImage: ramFit.hasPrefix("Below") ? "exclamationmark.circle" : (ramFit.contains("unverified") ? "questionmark.circle" : "checkmark.circle"))
                .font(.caption.weight(.medium))
                .foregroundStyle(ramFit.hasPrefix("Below") ? .orange : (ramFit.contains("unverified") ? .orange : .secondary))
                .fixedSize(horizontal: false, vertical: true)
                .help("RAM is compared with the catalog minimum. Provider requirements are not verified by this machine fit check.")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ModelMetricTile(icon: "speedometer", title: "Measured speed", accent: accent) {
                    if let rate, rate.tokensPerSecond.isFinite, rate.tokensPerSecond > 0, rate.sampleCount > 0 {
                        ModelMetricCopy(
                            value: "\(rate.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s",
                            detail: "\(rate.sampleCount) recent samples"
                        )
                    } else {
                        ModelMetricCopy(value: "Collecting speed samples", detail: "Run this model to measure it")
                    }
                }
                ModelMetricTile(icon: "chart.line.uptrend.xyaxis", title: "Live demand", accent: accent) {
                    if let capacity {
                        ModelMetricCopy(
                            value: demandTitle(capacity.demandBand),
                            detail: "\(capacity.activeRequests) active · \(capacity.queuedRequests) queued · \(capacity.warmProviders) warm"
                        )
                    } else {
                        ModelMetricCopy(value: "Demand unavailable", detail: "Waiting for a fresh network reading")
                    }
                }
                ModelMetricTile(icon: "dollarsign.circle", title: "Average profit", accent: accent) {
                    if let serving, serving.activeHours < 2 {
                        ModelMetricCopy(
                            value: "Calibrating",
                            detail: "\(serving.activeHours.formatted(.number.precision(.fractionLength(1)))) / 2 active hours · provisional gross \(money(serving.grossUSDPerActiveHour))/hr"
                        )
                    } else if let net = serving?.profitUSDPerActiveHour {
                        ModelMetricCopy(
                            value: "\(money(net)) net / active hour",
                            detail: "\(serving?.activeHours.formatted(.number.precision(.fractionLength(1))) ?? "0") measured active hours"
                        )
                    } else if let gross = serving?.grossUSDPerActiveHour {
                        ModelMetricCopy(value: "\(money(gross)) gross / active hour", detail: "Net estimate needs an idle-power baseline")
                    } else {
                        ModelMetricCopy(value: "Calibrating payout and power", detail: "Needs complete earnings and activity data")
                    }
                }
                ModelMetricTile(icon: "seal", title: "Opportunity grade", accent: accent) {
                    if let grade {
                        ModelMetricCopy(value: grade, detail: "Local score · speed 40% · demand 30% · profit 30%", emphasis: true)
                    } else if let serving, serving.activeHours < 2 {
                        ModelMetricCopy(value: "Calibrating", detail: "Needs 2 hours of measured serving")
                    } else {
                        ModelMetricCopy(value: "Not rated yet", detail: "Waiting for speed, demand, and net profit")
                    }
                }
            }

            if isScheduleEnabled {
                Divider()
                scheduleControl
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var scheduleControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label("Daily serving allocation", systemImage: "clock")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 5)
                Text("\(runPercent)% · \(hours(runPercent)) h/day")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(accent)
            }
            Slider(value: Binding(
                get: { Double(runPercent) },
                set: { setRunPercent(Int($0.rounded())) }
            ), in: 0...Double(maximumRunPercent), step: 5)
                .tint(accent)
                .accessibilityLabel("Daily serving allocation for \(item.displayName)")
                .accessibilityValue("\(runPercent) percent, \(hours(runPercent)) hours per day")
                .accessibilityHint("Shares one 24-hour daily serving budget across enabled models. This does not control memory residency.")

            if runPercent > 0, let profit = forecast.profitUSDPerDay {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkline")
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Estimated net \(money(profit))/day · \(money(forecast.profitUSDPerClockHour ?? 0))/clock hour")
                            .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if let gross = forecast.grossUSDPerDay,
                           let electricity = forecast.incrementalElectricityUSDPerDay {
                            Text("Gross \(money(gross)) · incremental adapter power estimate \(money(electricity)) per day")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let tokens = forecast.tokensPerDay {
                            Text("About \(tokens.formatted(.number.notation(.compactName).precision(.fractionLength(1)))) tokens/day at recent measured speed")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("model.\(item.catalogID).forecast")
            } else if runPercent > 0, let serving, serving.activeHours < 2 {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Calibrating payout and power · \(serving.activeHours.formatted(.number.precision(.fractionLength(1)))) of 2 active hours measured", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let tokens = forecast.tokensPerDay {
                        Text("Speed-only projection: about \(tokens.formatted(.number.notation(.compactName).precision(.fractionLength(1)))) tokens/day.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if runPercent > 0, let gross = forecast.grossUSDPerDay {
                Label("Estimated gross \(money(gross))/day; net awaits a measured idle-power baseline and electricity price.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if runPercent > 0 {
                Label("Projection appears after this model has measured earning, serving-time, and power data.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No serving time scheduled. At 50%, this model would be estimated at 12 hours/day.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Estimate from recent model activity, local token speed, and whole-Mac adapter draw above idle. Serving allocation is separate from loaded-model slots.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func companyColor(for modelID: String) -> Color {
        switch ModelManagerPresentation.vendor(for: modelID) {
        case .google: Color(red: 0.36, green: 0.55, blue: 0.72)
        case .qwen: Color(red: 0.32, green: 0.60, blue: 0.56)
        case .openai, .xai: Color(red: 0.38, green: 0.59, blue: 0.47)
        case .nvidia: Color(red: 0.53, green: 0.62, blue: 0.36)
        case .meta, .deepseek: Color(red: 0.38, green: 0.53, blue: 0.65)
        case .mistral: Color(red: 0.70, green: 0.47, blue: 0.30)
        case .microsoft: Color(red: 0.34, green: 0.57, blue: 0.68)
        case .ibm, .cohere: Color(red: 0.47, green: 0.50, blue: 0.65)
        case .prismml: Color(red: 0.57, green: 0.48, blue: 0.68)
        case .other: Color(red: 0.48, green: 0.52, blue: 0.56)
        }
    }

    private var companyName: String {
        switch company {
        case .google: "Google"
        case .qwen: "Qwen"
        case .openai: "OpenAI"
        case .nvidia: "NVIDIA"
        case .meta: "Meta"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .microsoft: "Microsoft"
        case .ibm: "IBM"
        case .cohere: "Cohere"
        case .xai: "xAI"
        case .prismml: "PrismML"
        case .other: "Other"
        }
    }

    private var modelSymbol: String {
        let capabilities = Set(item.capabilities.map { $0.lowercased() })
        if capabilities.contains("vision") || capabilities.contains("image") { return "eye" }
        if capabilities.contains("video") { return "video" }
        if capabilities.contains("tools") || capabilities.contains("tool_calling") { return "wrench.and.screwdriver" }
        if capabilities.contains("code") { return "chevron.left.forwardslash.chevron.right" }
        return "cpu"
    }

    private func demandTitle(_ band: NetworkDemandBand) -> String {
        switch band {
        case .low: "Low demand"
        case .moderate: "Moderate demand"
        case .high: "High demand"
        case .urgent: "Urgent demand"
        }
    }

    private func hours(_ percent: Int) -> String {
        ModelManagerPresentation.runHoursPerDay(percent: percent)
            .formatted(.number.precision(.fractionLength(0...1)))
    }

    private func money(_ value: Double) -> String {
        let cleaned = value.isFinite ? value : 0
        return (cleaned < 0 ? "−$" : "$") + abs(cleaned).formatted(.number.precision(.fractionLength(2)))
    }
}

private struct ModelMetricTile<Content: View>: View {
    let icon: String
    let title: String
    let accent: Color
    let content: Content

    init(icon: String, title: String, accent: Color, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold)).foregroundStyle(accent)
            content
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .padding(10)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ModelMetricCopy: View {
    let value: String
    let detail: String
    var emphasis = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(emphasis ? .title2.weight(.bold) : .callout.weight(.medium)).foregroundStyle(.primary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ModelDetailsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 14)
            }
        }
    }
}

struct DownloadedModelRow: View {
    let item: ModelInventoryItem
    let draft: ProviderConfigDraft?
    let operation: ProviderOperation
    let sources: ProviderControlSourceStates
    let currentTime: Date
    let sanitize: (String) -> String
    let setEnabled: (Bool, String) -> Void
    let setPreloaded: (Bool, String) -> Void
    let requestDelete: (ModelInventoryItem) -> Void
    var compact = false

    private var presentation: ModelRowPresentation {
        .make(
            item: item,
            draft: draft,
            operation: operation,
            sources: sources,
            currentTime: currentTime,
            canDownload: false,
            downloadUnavailableReason: nil,
            sanitize: sanitize
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !compact {
                Text(ModelFormatting.size(item.sizeGB))
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: compact ? 10 : 1) {
                if presentation.showsEnableToggle {
                    ModelOptionToggle(title: "Enabled", isOn: enabledBinding)
                        .disabled(presentation.enableAction?.isEnabled != true)
                        .accessibilityLabel(
                            presentation.enableAction?.accessibilityLabel ?? "Enable \(item.displayName)"
                        )
                        .accessibilityHint(
                            presentation.enableAction?.accessibilityHint ?? ""
                        )
                        .help(presentation.enableAction?.isEnabled == false
                              ? (presentation.enableAction?.accessibilityHint ?? "Unavailable")
                              : "Allow this model to receive work. This stages a setting change; use Save Changes to save it. Enabling does not guarantee it stays loaded in memory.")
                        .accessibilityIdentifier("model.\(item.catalogID).enable")
                }
                if presentation.showsPreloadToggle {
                    ModelOptionToggle(title: "Load at startup", isOn: preloadedBinding)
                        .disabled(presentation.preloadAction?.isEnabled != true)
                        .accessibilityLabel(
                            presentation.preloadAction?.accessibilityLabel ?? "Preload \(item.displayName)"
                        )
                        .accessibilityHint(
                            presentation.preloadAction?.accessibilityHint ?? ""
                        )
                        .help(presentation.preloadAction?.isEnabled == false
                              ? (presentation.preloadAction?.accessibilityHint ?? "Unavailable")
                              : "Request that the provider load this model into memory at startup. Save changes, then restart the provider to apply. Loading remains subject to available memory.")
                        .accessibilityIdentifier("model.\(item.catalogID).preload")
                }
                if !compact && presentation.showsDelete {
                    Button(role: .destructive) {
                        presentation.requestDeletion(of: item, using: requestDelete)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(presentation.deleteAction?.isEnabled != true)
                    .help(presentation.deleteAction?.accessibilityHint ?? "Delete \(item.displayName)")
                    .accessibilityLabel(
                        presentation.deleteAction?.accessibilityLabel ?? "Delete \(item.displayName)"
                    )
                    .accessibilityHint(
                        presentation.deleteAction?.accessibilityHint ?? ""
                    )
                    .accessibilityIdentifier("model.\(item.catalogID).delete")
                }
            }


            if !compact, let reason = presentation.deleteBlockReason {
                Label(reason, systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var enabledBinding: Binding<Bool> {
        selectionBinding(
            \.enabled,
            selector: item.enabledSelector,
            setter: setEnabled
        )
    }

    private var preloadedBinding: Binding<Bool> {
        selectionBinding(
            \.preloaded,
            selector: item.preloadSelector,
            setter: setPreloaded
        )
    }

    private func selectionBinding(
        _ keyPath: KeyPath<ProviderModelSelection, [String]>,
        selector: String?,
        setter: @escaping (Bool, String) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard let selectors = draft?.selection[keyPath: keyPath] else { return false }
                return ModelRowPresentation.contains(
                    item,
                    in: selectors,
                    selector: selector
                )
            },
            set: { enabled in
                let selectors = draft?.selection[keyPath: keyPath] ?? []
                setter(enabled, selectionID(
                    in: selectors,
                    selector: selector
                ))
            }
        )
    }

    private func selectionID(
        in selectors: [String],
        selector: String?
    ) -> String {
        if selectors.contains(item.catalogID) { return item.catalogID }
        if let selector,
           selectors.contains(selector) {
            return selector
        }
        return selector ?? item.catalogID
    }
}

enum ModelOptionToggleOrder: Equatable {
    case labelThenSwitch
    case switchThenLabel
}

struct ModelOptionToggle: View {
    static let order = ModelOptionToggleOrder.switchThenLabel
    static let labelSpacing: CGFloat = 6
    static let groupSpacing: CGFloat = 20

    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Self.labelSpacing) {
            switch Self.order {
            case .labelThenSwitch:
                Text(title)
                switchControl
            case .switchThenLabel:
                switchControl
                Text(title)
            }
        }
        .fixedSize()
    }

    private var switchControl: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
    }
}

@MainActor
private struct AvailableModelRow: View {
    let item: ModelInventoryItem
    @ObservedObject var store: ProviderControlStore

    private var isDownloading: Bool {
        store.operation == .downloading(item.catalogID)
    }

    private var presentation: ModelRowPresentation {
        ModelManagerPresentation.availableRow(item: item, store: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(presentation.availableMetadataText ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(presentation.availableMetadataText ?? "")
                .accessibilityIdentifier("model.\(item.catalogID).metadata")
            HStack {
                Spacer(minLength: 0)
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Downloading \(item.displayName)")
                    if let action = presentation.downloadAction,
                       store.canCancelCurrentOperation {
                        Button("Cancel") {
                            store.cancelCurrentOperation()
                        }
                        .accessibilityLabel(action.accessibilityLabel)
                        .accessibilityHint(action.accessibilityHint)
                        .accessibilityIdentifier("model.\(item.catalogID).download")
                    }
                } else {
                    Button {
                        Task { await store.download(item.catalogID) }
                    } label: {
                        Label("Download", systemImage: "square.and.arrow.down")
                    }
                    .disabled(presentation.downloadAction?.isEnabled != true)
                    .help(presentation.downloadAction?.accessibilityHint ?? "")
                    .accessibilityLabel(
                        presentation.downloadAction?.accessibilityLabel
                            ?? "Download \(item.displayName)"
                    )
                    .accessibilityHint(
                        presentation.downloadAction?.accessibilityHint ?? ""
                    )
                    .accessibilityIdentifier("model.\(item.catalogID).download")
                }
            }

            if isDownloading {
                Text(
                    store.operationPhase == .reconciling
                        ? "Refreshing model catalog…"
                        : store.latestDownloadProgressLine ?? "Downloading…"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let issue = presentation.displayedIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct ModelManagerFooter: View {
    @ObservedObject var store: ProviderControlStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    Task { await store.refreshPreservingDraft() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.operation != .idle)

                if store.operation == .refreshing || store.operation == .saving {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if store.draft?.hasChanges == true {
                    Button("Discard edits") { Task { await store.refresh() } }
                        .disabled(store.operation != .idle)
                    Text("Unsaved changes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button("Save Changes") {
                    Task { await store.save() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!store.canSave)
                .accessibilityIdentifier("models.save")
            }

            if let validation = store.draftValidationMessage, store.operation != .refreshing {
                Label(
                    ModelManagerPresentation.diagnostic(
                        validation,
                        sanitize: store.sanitizedDiagnostic
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Text("Save changes first, then restart the provider to apply them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = store.errorMessage {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(12)
    }
}

private struct LiveStatePill: View {
    let state: InventoryLiveState

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var label: String {
        switch state {
        case .active: "Active"
        case .loadedIdle: "Loaded"
        case .unloaded: "Unloaded"
        }
    }

    private var color: Color {
        switch state {
        case .active: .green
        case .loadedIdle: .blue
        case .unloaded: .secondary
        }
    }
}

private struct ModelDeletionConfirmation: Identifiable {
    let localID: String
    let displayName: String
    let sizeGB: Double

    var id: String { localID }
    var formattedSize: String { ModelFormatting.size(sizeGB) }
}

enum ModelFormatting {
    static func size(_ sizeGB: Double) -> String {
        sizeGB.formatted(.number.precision(.fractionLength(0...1))) + " GB"
    }

    static func availableDetails(_ item: ModelInventoryItem) -> String {
        let capabilities = item.capabilities.isEmpty
            ? "Capabilities unavailable"
            : item.capabilities.map { $0.capitalized }.joined(separator: ", ")
        return "\(item.modelType.uppercased()) · \(capabilities) · \(size(item.sizeGB)) · \(item.minimumRAMGB) GB minimum RAM"
    }

    static func quantization(_ item: ModelInventoryItem) -> String? {
        guard let value = item.quantization?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.count <= 64 else { return nil }
        switch value.lowercased() {
        case "2bit", "2-bit": return "2-bit"
        case "3bit", "3-bit": return "3-bit"
        case "4bit", "4-bit": return "4-bit"
        case "8bit", "8-bit": return "8-bit"
        default: return value.uppercased()
        }
    }

    static func catalogLimits(_ item: ModelInventoryItem) -> String? {
        let limits = [
            item.maxContextLength.flatMap { validTokenLimit($0).map { "up to \($0.formatted(.number)) context tokens" } },
            item.maxOutputLength.flatMap { validTokenLimit($0).map { "up to \($0.formatted(.number)) output tokens" } },
        ].compactMap { $0 }
        guard !limits.isEmpty else { return nil }
        return "Catalog limits (not a per-machine guarantee): " + limits.joined(separator: " · ")
    }

    static func providerRequirements(_ item: ModelInventoryItem) -> String? {
        guard let values = item.requiredProviderCapabilities else { return nil }
        let requirements = values.prefix(32).compactMap { providerRequirementName($0) }
        guard !requirements.isEmpty else { return nil }
        return "Provider requirements: \(requirements.joined(separator: " · ")) · unverified (runtime evidence unavailable)"
    }

    static func capabilityAdvisories(_ item: ModelInventoryItem) -> [String] {
        item.capabilities.compactMap { capability in
            switch capability.lowercased() {
            case "chat": return "Chat"
            case "tools", "tool_calling", "function_calling": return "Tool calling"
            case "vision", "image": return "Vision input"
            case "video": return "Video input"
            case "reasoning": return "Reasoning"
            case "json_mode": return "Structured JSON output"
            case "code": return "Code"
            case "text": return "Text"
            default: return capability.capitalized
            }
        }
    }

    private static func providerRequirementName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return nil }
        switch trimmed.lowercased() {
        case "apple_m5": return "Apple M5"
        case "mlx_nax": return "MLX NAX"
        default:
            return trimmed
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private static func validTokenLimit(_ value: Int) -> Int? {
        (1...10_000_000).contains(value) ? value : nil
    }
}

private struct ModelIdentityDetails: View {
    let item: ModelInventoryItem

    var body: some View {
        Text(item.catalogID)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
            .help(item.catalogID)
            .accessibilityLabel("Canonical model ID: \(item.catalogID)")
    }
}
