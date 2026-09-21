import DarkbloomTelemetry
import Foundation
import SwiftUI

struct ModelActionPresentation: Equatable {
    let accessibilityLabel: String
    let accessibilityHint: String
    let isEnabled: Bool
}

@MainActor
enum ModelManagerPresentation {
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
    @State private var deletion: ModelDeletionConfirmation?
    @State private var section = 0
    @State private var search = ""

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
        VStack(alignment: .leading, spacing: 14) {
            Picker("View", selection: $section) {
                Text("On this Mac").tag(0)
                Text("Available").tag(1)
                Text("Capacity").tag(2)
            }.pickerStyle(.segmented)
            if section == 0 {
                Text("Enable models to receive work. Load at startup requests them after a restart, subject to memory.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if section != 2 {
                TextField("Find a model", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Find a model")
            }
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
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 12) {
                                if item.isDownloaded, let snapshot = store.snapshot {
                                    DownloadedModelRow(item: item, draft: store.draft,
                                        operation: store.operation, sources: snapshot.sources,
                                        currentTime: currentTime, sanitize: store.sanitizedDiagnostic,
                                        setEnabled: { store.setEnabled($0, modelID: $1) },
                                        setPreloaded: { store.setPreloaded($0, modelID: $1) },
                                        requestDelete: { item in
                                            guard let localID = item.localID else { return }
                                            deletion = ModelDeletionConfirmation(localID: localID,
                                                displayName: item.displayName, sizeGB: item.sizeGB)
                                        }).disabled(store.queuedStopState != nil)
                                } else {
                                    AvailableModelRow(item: item, store: store).disabled(store.queuedStopState != nil)
                                }
                                modelDetails(item, at: currentTime)
                            }
                            .padding(16)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
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
        }.padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var visibleModels: [ModelInventoryItem] {
        let items = section == 0 ? store.snapshot?.inventory.myCatalog : store.snapshot?.inventory.available
        return ModelManagerPresentation.filtered(items ?? [], search: search)
    }

    @ViewBuilder
    private var capacityControls: some View {
        if let draft = store.draft {
            VStack(alignment: .leading, spacing: 20) {
                capacityCard("Simultaneous requests", icon: "arrow.triangle.branch",
                    value: draft.engineV2MaxConcurrent, defaultValue: 4, effectiveMaximum: 8,
                    explanation: "Maximum concurrent requests per model engine. Higher limits use more memory; model-specific overrides can differ.",
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

    private func capacityCard(_ title: String, icon: String, value: Int?, defaultValue: Int, effectiveMaximum: Int? = nil,
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
                    ForEach(Array(1...8), id: \.self) { Text(String($0)).tag($0) }
                    if let value, !(1...8).contains(value) {
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

private struct DownloadedModelRow: View {
    let item: ModelInventoryItem
    let draft: ProviderConfigDraft?
    let operation: ProviderOperation
    let sources: ProviderControlSourceStates
    let currentTime: Date
    let sanitize: (String) -> String
    let setEnabled: (Bool, String) -> Void
    let setPreloaded: (Bool, String) -> Void
    let requestDelete: (ModelInventoryItem) -> Void

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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.displayName)
                    .font(.headline)
                Spacer(minLength: 8)
                LiveStatePill(state: item.liveState)
            }

            HStack(spacing: ModelOptionToggle.groupSpacing) {
                Text(ModelFormatting.size(item.sizeGB))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)

                if presentation.showsEnableToggle {
                    ModelOptionToggle(title: "Enabled", isOn: enabledBinding)
                        .disabled(presentation.enableAction?.isEnabled != true)
                        .accessibilityLabel(
                            presentation.enableAction?.accessibilityLabel ?? "Enable \(item.displayName)"
                        )
                        .accessibilityHint(
                            presentation.enableAction?.accessibilityHint ?? ""
                        )
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
                        .accessibilityIdentifier("model.\(item.catalogID).preload")
                }
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


            if let reason = presentation.deleteBlockReason {
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
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.headline)
                    Text(presentation.availableMetadataText ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(presentation.availableMetadataText ?? "")
                        .accessibilityIdentifier("model.\(item.catalogID).metadata")
                }
                Spacer(minLength: 8)

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
