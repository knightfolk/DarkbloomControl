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
            contains(item, in: $0.selection.enabled)
        } ?? item.isEnabled
        let isPreloaded = draft.map {
            contains(item, in: $0.selection.preloaded)
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
        if contains(item, in: draft.original.preloaded) {
            return "Remove preload and save before deleting this model"
        }
        if contains(item, in: draft.original.enabled) {
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
        for (state, invalid, stale, future, recovery) in checks {
            switch state.evaluated(
                at: currentTime,
                invalidReason: invalid,
                staleReason: stale,
                futureReason: future
            ) {
            case .fresh:
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

    fileprivate static func contains(_ item: ModelInventoryItem, in selectors: [String]) -> Bool {
        selectors.contains(item.catalogID)
            || item.configuredSelector.map(selectors.contains) == true
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
    @State private var deletion: ModelDeletionConfirmation?

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

    private func modelList(currentTime: Date) -> some View {
        List {
            Section {
                if let snapshot = store.snapshot, !snapshot.inventory.myCatalog.isEmpty {
                    ForEach(snapshot.inventory.myCatalog) { item in
                        DownloadedModelRow(
                            item: item,
                            draft: store.draft,
                            operation: store.operation,
                            sources: snapshot.sources,
                            currentTime: currentTime,
                            sanitize: store.sanitizedDiagnostic,
                            setEnabled: { enabled, modelID in
                                store.setEnabled(enabled, modelID: modelID)
                            },
                            setPreloaded: { preloaded, modelID in
                                store.setPreloaded(preloaded, modelID: modelID)
                            },
                            requestDelete: { item in
                                guard let localID = item.localID else { return }
                                deletion = ModelDeletionConfirmation(
                                    localID: localID,
                                    displayName: item.displayName,
                                    sizeGB: item.sizeGB
                                )
                            }
                        )
                    }
                } else {
                    Text(store.snapshot == nil ? "Model catalog is unavailable." : "No downloaded models.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("My Catalog")
                    .accessibilityIdentifier("models.my-catalog")
            }

            Section {
                if let items = store.snapshot?.inventory.available, !items.isEmpty {
                    ForEach(items) { item in
                        AvailableModelRow(item: item, store: store)
                    }
                } else {
                    Text(store.snapshot == nil ? "Reload to discover available models." : "No additional models available.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Available")
                    .accessibilityIdentifier("models.available")
            }

            if let issues = store.snapshot?.inventory.issues, !issues.isEmpty {
                Section("Inventory status") {
                    ForEach(issues, id: \.self) { issue in
                        Label(
                            ModelManagerPresentation.diagnostic(
                                issue,
                                sanitize: store.sanitizedDiagnostic
                            ),
                            systemImage: "exclamationmark.triangle"
                        )
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .listStyle(.inset)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.displayName)
                    .font(.headline)
                Spacer(minLength: 8)
                LiveStatePill(state: item.liveState)
            }

            HStack(spacing: ModelOptionToggle.groupSpacing) {
                Text(ModelFormatting.size(item.sizeGB))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)

                if presentation.showsEnableToggle {
                    ModelOptionToggle(title: "Enable", isOn: enabledBinding)
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
                    ModelOptionToggle(title: "Preload", isOn: preloadedBinding)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var enabledBinding: Binding<Bool> {
        selectionBinding(\.enabled, setter: setEnabled)
    }

    private var preloadedBinding: Binding<Bool> {
        selectionBinding(\.preloaded, setter: setPreloaded)
    }

    private func selectionBinding(
        _ keyPath: KeyPath<ProviderModelSelection, [String]>,
        setter: @escaping (Bool, String) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard let selectors = draft?.selection[keyPath: keyPath] else { return false }
                return ModelRowPresentation.contains(item, in: selectors)
            },
            set: { enabled in
                let selectors = draft?.selection[keyPath: keyPath] ?? []
                setter(enabled, selectionID(in: selectors))
            }
        )
    }

    private func selectionID(in selectors: [String]) -> String {
        if selectors.contains(item.catalogID) { return item.catalogID }
        if let configuredSelector = item.configuredSelector,
           selectors.contains(configuredSelector) {
            return configuredSelector
        }
        return item.configuredSelector ?? item.catalogID
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
                        Label("Add", systemImage: "square.and.arrow.down")
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
                    Task { await store.refresh() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(store.operation != .idle)

                if store.operation == .refreshing || store.operation == .saving {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if store.draft?.hasChanges == true {
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

            if let validation = store.draftValidationMessage {
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
            if store.restartRequired {
                Label("Restart required", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
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

private enum ModelFormatting {
    static func size(_ sizeGB: Double) -> String {
        sizeGB.formatted(.number.precision(.fractionLength(0...1))) + " GB"
    }

    static func availableDetails(_ item: ModelInventoryItem) -> String {
        let capabilities = item.capabilities.isEmpty
            ? "Capabilities unavailable"
            : item.capabilities.map { $0.capitalized }.joined(separator: ", ")
        return "\(item.modelType.uppercased()) · \(capabilities) · \(size(item.sizeGB)) · \(item.minimumRAMGB) GB minimum RAM"
    }
}
