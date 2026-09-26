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

    static func runHoursPerDay(percent: Int) -> Double {
        24 * Double(min(100, max(0, percent))) / 100
    }

    /// The one clear entry action every compact card offers to its shared
    /// details/forecast sheet, alongside its real hosting controls.
    static func compactEntryActionLabel(for item: ModelInventoryItem) -> String {
        item.isDownloaded ? "Manage" : "Details"
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

/// The two collapsible model groups shown in the model manager. `capacity`
/// covers the provider limits disclosure, which is settings rather than a
/// model group, so only `enabled` and `available` partition the catalog.
enum ModelGroupScope: String, CaseIterable {
    case enabled
    case available
    case capacity

    var defaultsKey: String { "models.group-collapse.v2.\(rawValue)" }
}

/// Partitions the whole catalog into exactly two groups: models enabled in
/// the staged draft, and everything else — downloaded-but-disabled models
/// together with models that have not been downloaded.
struct ModelGrouping: Equatable {
    let enabled: [ModelInventoryItem]
    let available: [ModelInventoryItem]

    var isEmpty: Bool { enabled.isEmpty && available.isEmpty }

    /// `isEnabled` must reflect the staged draft (the caller's
    /// `isEffectivelyEnabled`) so unsaved enable/disable changes move cards
    /// between groups immediately. MainActor because it reuses the
    /// MainActor-isolated `ModelManagerPresentation.filtered` ordering.
    @MainActor
    static func partition(
        myCatalog: [ModelInventoryItem],
        available: [ModelInventoryItem],
        search: String,
        isEnabled: (ModelInventoryItem) -> Bool
    ) -> ModelGrouping {
        var seenCatalogIDs = Set<String>()
        var catalog: [ModelInventoryItem] = []
        for item in myCatalog + available where seenCatalogIDs.insert(item.catalogID).inserted {
            catalog.append(item)
        }
        let filtered = ModelManagerPresentation.filtered(catalog, search: search)
        var enabledItems: [ModelInventoryItem] = []
        var availableItems: [ModelInventoryItem] = []
        for item in filtered {
            if isEnabled(item) {
                enabledItems.append(item)
            } else {
                availableItems.append(item)
            }
        }
        // Within Available, downloaded models read first: they are closest to
        // being usable, while undownloaded cards stay muted further down.
        let sortedAvailable = availableItems.enumerated().sorted { lhs, rhs in
            if lhs.element.isDownloaded != rhs.element.isDownloaded {
                return lhs.element.isDownloaded
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return Self(enabled: enabledItems, available: sortedAvailable)
    }
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
    @State private var search = ""
    @State private var inspectedModel: ModelInventoryItem?
    @State private var whatIfRunPercent: [String: Int] = [:]
    @AppStorage("models.what-if-runtime-v1") private var savedWhatIfRuntime = ""
    @AppStorage(ModelGroupScope.enabled.defaultsKey) private var enabledGroupCollapsed = false
    @AppStorage(ModelGroupScope.available.defaultsKey) private var availableGroupCollapsed = false
    @AppStorage(ModelGroupScope.capacity.defaultsKey) private var capacityGroupCollapsed = true

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
        .onAppear(perform: restoreWhatIfRuntime)
        .onChange(of: whatIfRunPercent) { _, runtime in
            guard let data = try? JSONEncoder().encode(runtime) else { return }
            savedWhatIfRuntime = String(decoding: data, as: UTF8.self)
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

    private var currentGrouping: ModelGrouping {
        ModelGrouping.partition(
            myCatalog: store.snapshot?.inventory.myCatalog ?? [],
            available: store.snapshot?.inventory.available ?? [],
            search: search,
            isEnabled: isEffectivelyEnabled
        )
    }

    private func modelList(currentTime: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                modelSearchField
                Spacer(minLength: 4)
            }
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        let grouping = currentGrouping
                        if store.snapshot == nil && store.operation == .refreshing {
                            HStack { ProgressView().controlSize(.small); Text("Reading your model catalog…") }
                                .foregroundStyle(.secondary).padding(.vertical, 20)
                        } else if grouping.isEmpty {
                            ContentUnavailableView(search.isEmpty ? "No models here" : "No matching models",
                                systemImage: "cpu", description: Text(store.snapshot == nil
                                    ? "Refresh to load the model catalog." : "Try another search."))
                        } else {
                            modelGroup(.enabled, items: grouping.enabled,
                                collapsed: $enabledGroupCollapsed, gridWidth: geometry.size.width,
                                currentTime: currentTime)
                            modelGroup(.available, items: grouping.available,
                                collapsed: $availableGroupCollapsed, gridWidth: geometry.size.width,
                                currentTime: currentTime)
                        }
                        capacityGroup
                        if let issues = store.snapshot?.inventory.issues, !issues.isEmpty {
                            DisclosureGroup("Catalog notices (\(issues.count))") {
                                ForEach(issues, id: \.self) { issue in
                                    Text(store.sanitizedDiagnostic(issue)).font(.callout).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// While searching, groups with matches stay expanded so results are
    /// visible; the persisted collapsed state still applies otherwise.
    private func groupExpansion(_ collapsed: Binding<Bool>, matches: Int) -> Binding<Bool> {
        Binding(
            get: { search.isEmpty ? !collapsed.wrappedValue : matches > 0 },
            set: { collapsed.wrappedValue = !$0 }
        )
    }

    private func modelGroup(
        _ scope: ModelGroupScope,
        items: [ModelInventoryItem],
        collapsed: Binding<Bool>,
        gridWidth: CGFloat,
        currentTime: Date
    ) -> some View {
        DisclosureGroup(isExpanded: groupExpansion(collapsed, matches: items.count)) {
            if items.isEmpty {
                Text(scope == .enabled ? "No enabled models here." : "No available models here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: ModelCardLayout.columns(for: gridWidth),
                          alignment: .leading, spacing: ModelCardLayout.rowSpacing) {
                    ForEach(items) { item in
                        modelCard(item, at: currentTime)
                    }
                }
            }
        } label: {
            groupHeader(scope, items: items)
        }
        .disclosureGroupStyle(ModelGroupDisclosureStyle())
        .accessibilityIdentifier("models.group.\(scope.rawValue)")
    }

    private func groupHeader(_ scope: ModelGroupScope, items: [ModelInventoryItem]) -> some View {
        HStack(spacing: 8) {
            Text(scope == .enabled ? "Enabled" : "Available")
                .font(.headline)
            Text("\(items.count)")
                .font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .fixedSize()
            Spacer(minLength: 8)
            Text(subtitle(for: scope, items: items))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .help(headerHelp(for: scope))
    }

    private func subtitle(for scope: ModelGroupScope, items: [ModelInventoryItem]) -> String {
        if scope == .enabled {
            return "Runtime earnings on cards are what-if estimates, not a schedule"
        }
        let downloaded = items.filter(\.isDownloaded).count
        let notDownloaded = items.count - downloaded
        switch (downloaded, notDownloaded) {
        case (0, 0): return "No models"
        case (0, _): return "\(notDownloaded) to download"
        case (_, 0): return "\(downloaded) downloaded, disabled"
        default: return "\(downloaded) downloaded · \(notDownloaded) to download"
        }
    }

    private func headerHelp(for scope: ModelGroupScope) -> String {
        switch scope {
        case .enabled:
            return "Enabled models can receive work; startup loading is subject to memory. Serving allocation describes active work time, not memory use. Counts reflect the current search."
        case .available:
            return "Downloaded models that are currently disabled, plus catalog models not yet downloaded. Not-downloaded cards stay muted until you download them. Counts reflect the current search."
        case .capacity:
            return "Provider-wide concurrency and memory-slot limits."
        }
    }

    private var capacityGroup: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { search.isEmpty ? !capacityGroupCollapsed : !capacityGroupCollapsed },
            set: { capacityGroupCollapsed = !$0 }
        )) {
            capacityControls.padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text("Provider capacity").font(.headline)
                Spacer(minLength: 8)
                Text("Concurrency & memory slots")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disclosureGroupStyle(ModelGroupDisclosureStyle())
        .accessibilityIdentifier("models.group.capacity")
    }

    private var modelSearchField: some View {
        TextField("Find models", text: $search)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 220)
            .accessibilityLabel("Find a model")
    }

    private func isEffectivelyEnabled(_ item: ModelInventoryItem) -> Bool {
        guard let draft = store.draft else { return item.isEnabled }
        return ModelRowPresentation.contains(item, in: draft.selection.enabled, selector: item.enabledSelector)
    }

    /// Restores the per-model what-if runtime selection. Each value is an
    /// independent 0–100% share of a 24-hour day; models do not share a
    /// single allocation budget.
    private func restoreWhatIfRuntime() {
        whatIfRunPercent = Self.decodeRuntime(savedWhatIfRuntime)
    }

    static func decodeRuntime(_ stored: String) -> [String: Int] {
        guard !stored.isEmpty,
              let decoded = try? JSONDecoder().decode([String: Int].self, from: Data(stored.utf8))
        else { return [:] }
        var sanitized: [String: Int] = [:]
        for (id, value) in decoded.sorted(by: { $0.key < $1.key }).prefix(128) {
            guard !id.isEmpty, id.utf8.count <= 512, (0...100).contains(value) else { continue }
            sanitized[id] = value
        }
        return sanitized
    }

    private func setWhatIfRunPercent(_ value: Int, for item: ModelInventoryItem) {
        whatIfRunPercent[item.catalogID] = min(100, max(0, value))
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
        let runPercent = whatIfRunPercent[item.catalogID] ?? 0
        let forecast = ModelRunForecast.calculate(runPercent: runPercent, serving: calibratedServing, tokenRate: rate)
        let peers = opportunitySignals(at: date)
        let grade = ModelManagerPresentation.opportunityGrade(modelID: item.catalogID, peers: peers)
        VStack(alignment: .leading, spacing: 12) {
            ModelCardSummary(
                item: item,
                installedMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                rate: rate,
                capacity: capacity,
                serving: serving,
                grade: grade,
                forecast: forecast,
                runPercent: runPercent,
                setRunPercent: { setWhatIfRunPercent($0, for: item) },
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
                        })
                } else {
                    AvailableModelRow(item: item, store: store)
                }
                modelDetails(item, at: date)
            } else {
                Divider()
                cardControls(item: item, at: date)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(item.isDownloaded ? 0.4 : 0.22),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ModelCardSummary.companyColor(for: item.catalogID)
                    .opacity(item.isDownloaded ? 1 : 0.55))
                .frame(width: 28, height: 3)
                .padding(.leading, 14)
        }
        .accessibilityIdentifier("model.\(item.catalogID).card")
    }

    /// The single controls row of a compact card: real hosting controls plus
    /// one clear action. Undownloaded cards keep their Download action fully
    /// interactive even though the informational content above is muted, and
    /// every card can still reach its details/forecast sheet.
    @ViewBuilder
    func cardControls(item: ModelInventoryItem, at date: Date) -> some View {
        if item.isDownloaded, let snapshot = store.snapshot {
            HStack(alignment: .center, spacing: 12) {
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
                    }, compact: true)
                Spacer(minLength: 8)
                Button(ModelManagerPresentation.compactEntryActionLabel(for: item)) { inspectedModel = item }
                    .help("Open the what-if forecast, model details, and additional controls for \(item.displayName).")
                    .buttonStyle(.bordered).controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("model.\(item.catalogID).manage")
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                AvailableModelRow(item: item, store: store, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(ModelManagerPresentation.compactEntryActionLabel(for: item)) { inspectedModel = item }
                    .help("Open model details, assumptions, and the what-if forecast for \(item.displayName).")
                    .buttonStyle(.bordered).controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("model.\(item.catalogID).manage")
            }
        }
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
            }.disabled(store.operation != .idle)
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
    static let maximumColumns = 2
    /// Bounded card width keeps text readable and controls intact: cards sit
    /// between a ~300pt floor and a 400pt ceiling so wide windows show a
    /// left-aligned 2×2-style grid instead of stretched cards.
    static let minimumCardWidth: CGFloat = 300
    static let maximumCardWidth: CGFloat = 400
    static let rowSpacing: CGFloat = 14
    /// Expected compact-card height; the previous card measured ~530pt.
    static let estimatedCardHeight: CGFloat = 268

    static func columnCount(for width: CGFloat) -> Int {
        width >= CGFloat(maximumColumns) * minimumCardWidth + rowSpacing ? maximumColumns : 1
    }

    /// Card width for the given container width: two even bounded columns,
    /// or one bounded column on genuinely narrow containers.
    static func cardWidth(for width: CGFloat) -> CGFloat {
        let columns = CGFloat(columnCount(for: width))
        let available = max(0, width - (columns - 1) * rowSpacing)
        return min(maximumCardWidth, available / columns)
    }

    static func columns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth(for: width)), spacing: rowSpacing, alignment: .top),
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
    let setRunPercent: (Int) -> Void
    var showsDetails = false

    /// Informational content of not-yet-downloaded cards is muted, while the
    /// Download action stays fully opaque and enabled whenever it is allowed.
    static let mutedOpacity: Double = 0.62

    private var company: ModelCompany { ModelManagerPresentation.vendor(for: item.catalogID) }
    private var accent: Color { Self.companyColor(for: item.catalogID) }
    private var ramFit: String { ModelManagerPresentation.hardwareFit(item, installedMemoryGB: installedMemoryGB) }

    var body: some View {
        if showsDetails { detailedBody } else { cardFace }
    }

    // MARK: - Compact card face

    private var cardFace: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                identityRow
                if item.isDownloaded {
                    historyStrip
                } else {
                    catalogStrip
                }
            }
            .opacity(item.isDownloaded ? 1 : Self.mutedOpacity)
            whatIfControl
        }
    }

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 10) {
            familyMark
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.displayName)
                Text("\(companyName) · \(item.modelType.uppercased()) · \(ModelFormatting.size(item.sizeGB))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help("Model type and catalog weight-size estimate (\(ModelFormatting.size(item.sizeGB)) weights). This is not the model’s total memory use while running.")
            }
            Spacer(minLength: 6)
            residencyBadge
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.displayName), \(companyName), \(item.modelType.uppercased())")
        .accessibilityValue(residencyDescription)
    }

    private var residencyDescription: String {
        guard item.isDownloaded else { return "Not downloaded" }
        switch item.liveState {
        case .active: return "Active"
        case .loadedIdle: return "Loaded"
        case .unloaded: return "Unloaded"
        }
    }

    private var residencyBadge: some View {
        Group {
            if item.isDownloaded {
                LiveStatePill(state: item.liveState)
            } else {
                Text("Not downloaded")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .help(item.isDownloaded
            ? "Current provider residency or activity. Loaded means in memory; it does not necessarily mean serving a request. This can differ from your saved enable and startup settings."
            : "Not downloaded to this Mac. The Download action remains available.")
    }

    private var familyMark: some View {
        familyImage
            .frame(width: 34, height: 34)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var familyImage: some View {
        let family = ModelFamilyIcon.select(status: .online, activeModel: item.catalogID)
        // `.darkbloom` is the app mark, not a vendor logo; models without a
        // bundled family logo fall back to a capability symbol.
        if family != .darkbloom, let image = DarkbloomLogoAsset.modelImage(family: family) {
            Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(accent)
        } else {
            Image(systemName: modelSymbol)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
        }
    }

    private struct CompactStat: Identifiable {
        let id: String
        let icon: String
        let iconTint: Color?
        let value: String
        let unit: String?
        let label: String
        let help: String
    }

    /// Stats for a downloaded model. Locally measured facts come first; any
    /// slot not backed by history is filled with a catalog fact rather than a
    /// dash, and one caption explains what is still learning.
    private var historyStats: [CompactStat] {
        var stats: [CompactStat] = []
        if hasMeasuredSpeed {
            stats.append(CompactStat(
                id: "Measured speed", icon: "speedometer", iconTint: nil,
                value: speedValue, unit: "tok/s", label: "Measured speed", help: speedHelp))
        }
        if let demand = demandStatSpec {
            stats.append(demand)
        }
        if hasAccountEarnings {
            stats.append(CompactStat(
                id: "Derived account earnings", icon: "dollarsign.circle", iconTint: nil,
                value: Self.money(serving?.grossUSDPerActiveHour ?? 0), unit: "gross/hr",
                label: "Derived rate", help: accountEarningsHelp))
        }
        for filler in catalogFillers where stats.count < 3 && !stats.contains(where: { $0.id == filler.id }) {
            stats.append(filler)
        }
        return Array(stats.prefix(3))
    }

    /// Catalog facts used to complete the stat row when history is partial.
    private var catalogFillers: [CompactStat] {
        var fillers: [CompactStat] = [
            CompactStat(
                id: "Minimum RAM", icon: "memorychip", iconTint: nil,
                value: "\(item.minimumRAMGB) GB", unit: nil,
                label: "Minimum RAM",
                help: "Catalog minimum RAM requirement. On this Mac: \(ramFit).")
        ]
        let capabilities = ModelFormatting.capabilityAdvisories(item)
        if !capabilities.isEmpty {
            fillers.append(CompactStat(
                id: "Capabilities", icon: "square.grid.2x2", iconTint: nil,
                value: capabilities.first ?? "", unit: nil,
                label: capabilities.count > 1 ? "Capabilities +\(capabilities.count - 1)" : "Capabilities",
                help: "Catalog capabilities: " + capabilities.joined(separator: " · ") + "."))
        }
        return fillers
    }

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            statsRow(historyStats)
            if let status = learningStatus {
                Text(status)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Catalog facts for an undownloaded model. A demand tile without a
    /// fresh reading is omitted rather than shown empty.
    private var catalogStats: [CompactStat] {
        var stats: [CompactStat] = [
            CompactStat(
                id: "Download size", icon: "internaldrive", iconTint: nil,
                value: ModelFormatting.size(item.sizeGB), unit: nil,
                label: "Download size",
                help: "Catalog estimate of the weights download size. Actual disk use can differ.")
        ]
        if let demand = demandStatSpec {
            stats.append(demand)
        }
        stats.append(CompactStat(
            id: "Minimum RAM", icon: "memorychip", iconTint: nil,
            value: "\(item.minimumRAMGB) GB", unit: nil,
            label: "Minimum RAM",
            help: "Catalog minimum RAM requirement. On this Mac: \(ramFit)."))
        return stats
    }

    private var catalogStrip: some View {
        statsRow(catalogStats)
            .accessibilityIdentifier("model.\(item.catalogID).metadata")
    }

    private func statsRow(_ stats: [CompactStat]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 { statDivider }
                statView(stat)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The unit sits under the value so full money amounts never truncate at
    /// the narrowest column width.
    private func statView(_ stat: CompactStat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: stat.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((stat.iconTint ?? accent).opacity(0.9))
                    .accessibilityHidden(true)
                Text(stat.value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).truncationMode(.tail)
            }
            if let unit = stat.unit {
                Text(unit)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Text(stat.label)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .help(stat.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stat.label + ": " + stat.value + (stat.unit.map { " " + $0 } ?? ""))
    }

    private var statDivider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 42)
    }

    /// Demand keeps its text next to the tinted shield so color is never the
    /// only carrier of meaning. The caption carries the live network count,
    /// and the tile is omitted entirely without a fresh reading.
    private var demandStatSpec: CompactStat? {
        guard let capacity else { return nil }
        return CompactStat(
            id: "Network demand", icon: "shield.fill", iconTint: demandColor,
            value: demandValue, unit: nil,
            label: "\(capacity.activeRequests.formatted()) network active",
            help: demandHelp + demandRequestDescription)
    }

    /// Independent 0–100% runtime what-if with an estimate that is clearly
    /// labeled as estimated and visually separate from measured facts.
    private var whatIfControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Runtime")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(runPercent) },
                    set: { setRunPercent(Int($0.rounded())) }
                ), in: 0...100, step: 5)
                    .tint(accent)
                    .controlSize(.small)
                    .accessibilityLabel("What-if daily runtime for \(item.displayName)")
                    .accessibilityValue("\(runPercent) percent, \(hours(runPercent)) hours per day")
                    .accessibilityHint(Self.whatIfEstimateHint)
                Text("\(runPercent)% · \(hours(runPercent)) h")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 74, alignment: .trailing)
            }
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(Self.whatIfEstimateText(forecast))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(Self.whatIfEstimateHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Estimated scenario: " + Self.whatIfEstimateText(forecast))
        }
    }

    private var learningStatus: String? {
        switch (hasMeasuredSpeed, hasAccountEarnings) {
        case (true, true): return nil
        case (false, true): return "Measured speed appears after this model serves on this Mac"
        case (true, false): return "Derived earnings rate appears after two active serving hours"
        case (false, false): return "Learning · measured speed and account earnings appear after this model serves"
        }
    }

    private var demandHelp: String {
        "Network demand for this model. Red: urgent. Yellow: high or moderate. Green: low. Gray: no fresh reading. This describes network traffic, not your Mac’s health or a guarantee of work."
    }

    private var demandRequestDescription: String {
        guard let capacity else { return " Request counts unavailable." }
        return " Network-wide: \(capacity.activeRequests) active requests, \(capacity.queuedRequests) waiting."
    }

    private var demandColor: Color {
        guard let capacity else { return .gray }
        switch capacity.demandBand {
        case .low: return .green
        case .moderate, .high: return .yellow
        case .urgent: return .red
        }
    }

    private var demandValue: String {
        capacity.map { demandTitle($0.demandBand).replacingOccurrences(of: " demand", with: "") } ?? "No reading"
    }

    private var demandLabel: String {
        guard let capacity else { return "Network demand" }
        return "\(capacity.activeRequests.formatted()) active · \(capacity.queuedRequests.formatted()) queued"
    }

    private var hasMeasuredSpeed: Bool {
        guard let rate else { return false }
        return rate.tokensPerSecond.isFinite && rate.tokensPerSecond > 0 && rate.sampleCount > 0
    }

    private var speedValue: String {
        hasMeasuredSpeed
            ? rate?.tokensPerSecond.formatted(.number.precision(.fractionLength(1))) ?? "—"
            : "—"
    }

    private var speedHelp: String {
        "Average measured token generation speed on this Mac. Based on recent samples, not advertised performance."
    }

    /// Earnings history is account-level (it may include other machines) and
    /// only becomes a rate once the model has served here for two active
    /// hours; before that there is nothing honest to show.
    private var hasAccountEarnings: Bool {
        guard let serving else { return false }
        return serving.activeHours >= 2
    }

    private var accountEarningsHelp: String {
        "History-based and account-derived: earnings recorded for this model on the account, divided by this Mac’s observed active serving hours. The account may include other machines, so this is not measured income on this Mac. Gross excludes electricity; a derived net only feeds the labeled what-if estimate below. Not a guaranteed payout."
    }

    /// Compact-card estimate line. Only real inputs are used: no measured
    /// speed or earnings history means the absence is stated, never filled in.
    @MainActor
    static func whatIfEstimateText(_ forecast: ModelRunForecast) -> String {
        guard forecast.runPercent > 0 else {
            return "0% runtime · estimated $0/day"
        }
        let hours = ModelManagerPresentation.runHoursPerDay(percent: forecast.runPercent)
            .formatted(.number.precision(.fractionLength(0...1)))
        if let net = forecast.profitUSDPerDay {
            return "Est. net \(Self.money(net))/day if it served \(hours) h/day · what-if, not actual"
        }
        if let gross = forecast.grossUSDPerDay {
            return "Est. gross \(Self.money(gross))/day · net needs a power baseline · what-if"
        }
        if let tokens = forecast.tokensPerDay, tokens > 0 {
            return "Est. ≈\(tokens.formatted(.number.notation(.compactName).precision(.fractionLength(1)))) tokens/day at measured speed · earnings unmeasured"
        }
        return "No estimate yet · needs measured speed or earnings history"
    }

    static var whatIfEstimateHelp: String {
        "Independent what-if: assumes this model served requests for the selected share of a 24-hour day at its recent measured speed on this Mac and its account-derived per-active-hour earnings, including estimated incremental electricity where a baseline exists. It assumes this Mac produced the account earnings recorded for this model; until provider-aware tracking ships, the account may include other machines. Estimated only — never actual earnings or a guarantee, and not a schedule."
    }

    static var whatIfEstimateHint: String {
        "Independent what-if: assumes this model served requests for the selected share of a 24-hour day. Estimated, not actual earnings, and not a schedule."
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
                ModelMetricTile(icon: "dollarsign.circle", title: "Earnings per active hour", accent: accent) {
                    if let serving, serving.activeHours < 2 {
                        ModelMetricCopy(
                            value: "Calibrating",
                            detail: "\(serving.activeHours.formatted(.number.precision(.fractionLength(1)))) / 2 active hours · provisional gross \(Self.money(serving.grossUSDPerActiveHour))/hr"
                        )
                    } else if let net = serving?.profitUSDPerActiveHour {
                        ModelMetricCopy(
                            value: "\(Self.money(net)) net / active hour",
                            detail: "\(serving?.activeHours.formatted(.number.precision(.fractionLength(1))) ?? "0") local active hours · net derived from account earnings minus estimated power"
                        )
                    } else if let gross = serving?.grossUSDPerActiveHour {
                        ModelMetricCopy(value: "\(Self.money(gross)) gross / active hour", detail: "Account-derived · net needs an idle-power baseline")
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

            Divider()
            scheduleControl
        }
        .accessibilityElement(children: .contain)
    }

    private var scheduleControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label("What-if daily runtime", systemImage: "clock")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 5)
                Text("\(runPercent)% · \(hours(runPercent)) h/day")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(accent)
            }
            Slider(value: Binding(
                get: { Double(runPercent) },
                set: { setRunPercent(Int($0.rounded())) }
            ), in: 0...100, step: 5)
                .tint(accent)
                .accessibilityLabel("What-if daily runtime for \(item.displayName)")
                .accessibilityValue("\(runPercent) percent, \(hours(runPercent)) hours per day")
                .accessibilityHint(Self.whatIfEstimateHint)

            if runPercent > 0, let profit = forecast.profitUSDPerDay {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Estimated net \(Self.money(profit))/day · \(Self.money(forecast.profitUSDPerClockHour ?? 0))/clock hour")
                            .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if let gross = forecast.grossUSDPerDay,
                           let electricity = forecast.incrementalElectricityUSDPerDay {
                            Text("Gross \(Self.money(gross)) · incremental adapter power estimate \(Self.money(electricity)) per day")
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
                Label("Estimated gross \(Self.money(gross))/day; net awaits a measured idle-power baseline and electricity price.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if runPercent > 0 {
                Label("No dollar estimate yet: this model needs measured earning, serving-time, and power data first.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("0% runtime selected · the what-if estimate is $0/day. Drag to explore a scenario.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Estimate from recent local model activity, local token speed, and whole-Mac adapter draw above idle. Earnings history is account-level: until provider-aware tracking ships, this what-if assumes this Mac produced the account earnings recorded for this model. Each model’s runtime is an independent what-if, not a schedule or a shared allocation.")
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

    static func money(_ value: Double) -> String {
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

private struct ModelGroupDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
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
        VStack(alignment: .leading, spacing: compact ? 0 : 5) {
            if !compact {
                Text(ModelFormatting.size(item.sizeGB))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if compact {
                // One horizontal row of real hosting controls keeps the
                // compact card short; Delete stays in the Manage sheet.
                HStack(spacing: 14) {
                    enableToggle(checkbox: true)
                    preloadToggle(checkbox: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    enableToggle(checkbox: false)
                    preloadToggle(checkbox: false)
                    deleteButton
                }
                if let reason = presentation.deleteBlockReason {
                    Label(reason, systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, compact ? 0 : 4)
    }

    @ViewBuilder
    private func enableToggle(checkbox: Bool) -> some View {
        if presentation.showsEnableToggle {
            ModelOptionToggle(title: "Enabled", isOn: enabledBinding, checkbox: checkbox)
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
    }

    @ViewBuilder
    private func preloadToggle(checkbox: Bool) -> some View {
        if presentation.showsPreloadToggle {
            ModelOptionToggle(title: "Load at startup", isOn: preloadedBinding, checkbox: checkbox)
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
    }

    @ViewBuilder
    private var deleteButton: some View {
        if presentation.showsDelete {
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
    /// Compact cards use checkboxes: fixed-size switches crowd out the card's
    /// single action button in narrow columns. The Manage sheet keeps switches.
    var checkbox = false

    var body: some View {
        if checkbox {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .font(.caption.weight(.medium))
                .fixedSize()
        } else {
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
    /// Compact cards surface catalog facts in their stat strip; the row then
    /// shows only the Download action (kept fully opaque on muted cards),
    /// progress, and issues.
    var compact = false

    private var isDownloading: Bool {
        store.operation == .downloading(item.catalogID)
    }

    private var presentation: ModelRowPresentation {
        ModelManagerPresentation.availableRow(item: item, store: store)
    }

    private var progressLine: String {
        store.operationPhase == .reconciling
            ? "Refreshing model catalog…"
            : store.latestDownloadProgressLine ?? "Downloading…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            if !compact {
                Text(presentation.availableMetadataText ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(presentation.availableMetadataText ?? "")
                    .accessibilityIdentifier("model.\(item.catalogID).metadata")
            }
            HStack(alignment: .center) {
                if compact, !isDownloading, let issue = presentation.displayedIssue {
                    Text(issue)
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                        .help(issue)
                }
                Spacer(minLength: 0)
                if isDownloading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Downloading \(item.displayName)")
                        if compact {
                            Text(progressLine)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        if let action = presentation.downloadAction,
                           store.canCancelCurrentOperation {
                            Button("Cancel") {
                                store.cancelCurrentOperation()
                            }
                            .controlSize(.small)
                            .accessibilityLabel(action.accessibilityLabel)
                            .accessibilityHint(action.accessibilityHint)
                            .accessibilityIdentifier("model.\(item.catalogID).download")
                        }
                    }
                } else {
                    Button {
                        Task { await store.download(item.catalogID) }
                    } label: {
                        Label("Download", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(ModelCardSummary.companyColor(for: item.catalogID))
                    .disabled(presentation.downloadAction?.isEnabled != true)
                    .help(presentation.downloadAction?.accessibilityHint
                        ?? "Downloads \(item.displayName) to this Mac.")
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

            if !compact {
                if isDownloading {
                    Text(progressLine)
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
        }
        .padding(.vertical, compact ? 0 : 4)
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
