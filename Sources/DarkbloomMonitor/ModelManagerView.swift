import DarkbloomTelemetry
import SwiftUI

struct ModelRowPresentation: Equatable {
    let showsDownload: Bool
    let showsEnableToggle: Bool
    let showsPreloadToggle: Bool
    let showsDelete: Bool
    let deleteBlockReason: String?
    let availableMetadataText: String?

    static func make(
        item: ModelInventoryItem,
        draft: ProviderConfigDraft?,
        operation: ProviderOperation
    ) -> Self {
        let isDownloaded = item.isDownloaded
        return Self(
            showsDownload: !isDownloaded,
            showsEnableToggle: isDownloaded,
            showsPreloadToggle: isDownloaded,
            showsDelete: isDownloaded,
            deleteBlockReason: isDownloaded
                ? deleteBlockReason(item: item, draft: draft, operation: operation)
                : nil,
            availableMetadataText: isDownloaded
                ? nil
                : ModelFormatting.availableDetails(item)
        )
    }

    private static func deleteBlockReason(
        item: ModelInventoryItem,
        draft: ProviderConfigDraft?,
        operation: ProviderOperation
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
        if let issue = item.issue { return issue }
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

    fileprivate static func contains(_ item: ModelInventoryItem, in selectors: [String]) -> Bool {
        selectors.contains(item.catalogID)
            || item.configuredSelector.map(selectors.contains) == true
    }
}

@MainActor
struct ModelManagerView: View {
    @ObservedObject var store: ProviderControlStore
    @State private var deletion: ModelDeletionConfirmation?

    var body: some View {
        VStack(spacing: 0) {
            modelList
            Divider()
            ModelManagerFooter(store: store)
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

    private var modelList: some View {
        List {
            Section {
                if let items = store.snapshot?.inventory.myCatalog, !items.isEmpty {
                    ForEach(items) { item in
                        DownloadedModelRow(
                            item: item,
                            draft: store.draft,
                            operation: store.operation,
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
                        Label(issue, systemImage: "exclamationmark.triangle")
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
    let setEnabled: (Bool, String) -> Void
    let setPreloaded: (Bool, String) -> Void
    let requestDelete: (ModelInventoryItem) -> Void

    private var presentation: ModelRowPresentation {
        .make(item: item, draft: draft, operation: operation)
    }

    private var controlsDisabled: Bool {
        operation != .idle || item.issue != nil || draft == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.displayName)
                    .font(.headline)
                Spacer(minLength: 8)
                LiveStatePill(state: item.liveState)
            }

            HStack(spacing: 14) {
                Text(ModelFormatting.size(item.sizeGB))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)

                if presentation.showsEnableToggle {
                    Toggle("Enable", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .disabled(controlsDisabled)
                        .accessibilityIdentifier("model.\(item.catalogID).enable")
                }
                if presentation.showsPreloadToggle {
                    Toggle("Preload", isOn: preloadedBinding)
                        .toggleStyle(.switch)
                        .disabled(controlsDisabled)
                        .accessibilityIdentifier("model.\(item.catalogID).preload")
                }
                if presentation.showsDelete {
                    Button(role: .destructive) {
                        requestDelete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(presentation.deleteBlockReason != nil)
                    .help(presentation.deleteBlockReason ?? "Delete \(item.displayName)")
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

@MainActor
private struct AvailableModelRow: View {
    let item: ModelInventoryItem
    @ObservedObject var store: ProviderControlStore

    private var isDownloading: Bool {
        store.operation == .downloading(item.catalogID)
    }

    private var presentation: ModelRowPresentation {
        .make(item: item, draft: store.draft, operation: store.operation)
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
                    Button("Cancel") {
                        store.cancelCurrentOperation()
                    }
                } else {
                    Button {
                        Task { await store.download(item.catalogID) }
                    } label: {
                        Label("Add", systemImage: "square.and.arrow.down")
                    }
                    .disabled(store.operation != .idle || item.issue != nil)
                    .accessibilityIdentifier("model.\(item.catalogID).download")
                }
            }

            if isDownloading {
                Text(store.latestDownloadProgressLine ?? "Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let issue = item.issue {
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
                Label(validation, systemImage: "exclamationmark.triangle")
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
