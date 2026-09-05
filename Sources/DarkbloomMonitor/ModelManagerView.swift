import DarkbloomTelemetry
import Foundation
import SwiftUI

enum ModelWarmupPreferences {
    static let headroomKey = "modelWarmupHeadroomGB"
    static let automaticSwitchingKey = "automaticDemandSwitching"
    static let automaticSwitchLastAttemptKey = "automaticDemandSwitchLastAttemptAt"
    static let defaultHeadroomGB = 16.0
    static let headroomChoices = [8.0, 12.0, 16.0, 20.0, 24.0]

    static var selectedHeadroomGB: Double {
        let value = UserDefaults.standard.double(forKey: headroomKey)
        return headroomChoices.contains(value) ? value : defaultHeadroomGB
    }

    static var automaticSwitchingEnabled: Bool {
        UserDefaults.standard.bool(forKey: automaticSwitchingKey)
    }

    static func automaticSwitchLastAttemptAt(
        in defaults: UserDefaults = .standard
    ) -> Date? {
        guard defaults.object(forKey: automaticSwitchLastAttemptKey) != nil else {
            return nil
        }
        let seconds = defaults.double(forKey: automaticSwitchLastAttemptKey)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func recordAutomaticSwitchAttempt(
        at date: Date,
        in defaults: UserDefaults = .standard
    ) {
        guard date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 > 0
        else { return }
        defaults.set(
            date.timeIntervalSince1970,
            forKey: automaticSwitchLastAttemptKey
        )
    }
}

@MainActor
enum ModelWarmupPresentation {
    static func blockReason(
        operation: ProviderOperation,
        draftHasChanges: Bool,
        restartRequired: Bool,
        pendingConfirmation: LifecycleConfirmation?,
        item: ModelInventoryItem,
        snapshot: ProviderControlSnapshot,
        currentTime: Date,
        minimumHeadroomGB: Double,
        availableSystemMemoryGB: Double?
    ) -> String? {
        guard operation == .idle else {
            return "Another provider action is in progress"
        }
        guard pendingConfirmation == nil else {
            return "Another provider action is awaiting confirmation"
        }
        guard !draftHasChanges else {
            return "Save or reload model settings before warming a model"
        }
        guard !restartRequired else {
            return "Restart the provider to apply saved model settings"
        }
        return ProviderWarmupPolicy.blockReason(
            for: item,
            in: snapshot,
            currentTime: currentTime,
            minimumHeadroomGB: minimumHeadroomGB,
            availableSystemMemoryGB: availableSystemMemoryGB
        )
    }
}

enum ProviderCapacityMode: Int, CaseIterable, Identifiable {
    case memorySaver = 1
    case twoModelCapacity = 2

    var id: Int { rawValue }
    var maxModelSlots: Int { rawValue }

    init?(maxModelSlots: Int) {
        self.init(rawValue: maxModelSlots)
    }

    var title: String {
        switch self {
        case .memorySaver: "1 · Memory Saver"
        case .twoModelCapacity: "2 · Two Models"
        }
    }

    var detail: String {
        switch self {
        case .memorySaver:
            "Uses the least memory. An idle model unloads before another model can load. Customer jobs are allowed to finish first."
        case .twoModelCapacity:
            "Allows the coordinator to load and serve as many as two models. A free second slot can also make a manual switch faster."
        }
    }
}

struct ModelWarmupFeaturePresentation: Equatable {
    let isAvailable: Bool
    let badgeText: String?
    let accessibilityHint: String?

    static func make(supportsProtectedWarmup: Bool) -> Self {
        guard supportsProtectedWarmup else {
            return Self(
                isAvailable: false,
                badgeText: "Coming Soon",
                accessibilityHint: "Live model switching requires a future signed Darkbloom update."
            )
        }
        return Self(
            isAvailable: true,
            badgeText: nil,
            accessibilityHint: nil
        )
    }
}

struct ComingSoonBadge: View {
    var body: some View {
        Text("Coming Soon")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.14))
            )
            .accessibilityLabel("Coming Soon")
    }
}

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
    @AppStorage(ModelWarmupPreferences.headroomKey) private var warmupHeadroomGB =
        ModelWarmupPreferences.defaultHeadroomGB
    @AppStorage(ModelWarmupPreferences.automaticSwitchingKey) private var automaticSwitching = false

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
        List {
            Section {
                capacityControls
            } header: {
                Text("Serving Capacity")
                    .accessibilityIdentifier("models.capacity")
            }

            Section {
                if let snapshot = store.snapshot, !snapshot.inventory.myCatalog.isEmpty {
                    ForEach(snapshot.inventory.myCatalog) { item in
                        VStack(alignment: .leading, spacing: 4) {
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
                        modelDetails(item, at: currentTime)
                        }
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
                        VStack(alignment: .leading, spacing: 4) {
                        AvailableModelRow(item: item, store: store)
                        modelDetails(item, at: currentTime)
                        }
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

    @ViewBuilder
    private var capacityControls: some View {
        if store.draft != nil {
            let liveSwitching = ModelWarmupFeaturePresentation.make(
                supportsProtectedWarmup: store.snapshot?.supportsProtectedWarmup == true
            )
            VStack(alignment: .leading, spacing: 8) {
                Picker("Maximum resident models", selection: capacityBinding) {
                    ForEach(ProviderCapacityMode.allCases) { option in
                        Text(option.title).tag(Optional(option))
                    }
                }
                .pickerStyle(.segmented)
                .disabled(store.operation != .idle)
                .accessibilityIdentifier("models.capacity.mode")

                if let mode = selectedCapacityMode {
                    Text(mode.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(
                        "Choose one or two resident models to add the missing provider setting, then save and restart.",
                        systemImage: "wrench.and.screwdriver"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if selectedCapacityMode == .twoModelCapacity {
                    Label(
                        "The second slot is shared with network work; it is not reserved for manual staging.",
                        systemImage: "network"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Picker("Staging memory reserve", selection: $warmupHeadroomGB) {
                            ForEach(ModelWarmupPreferences.headroomChoices, id: \.self) { value in
                                Text("\(Int(value)) GB").tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(
                            store.operation != .idle || !liveSwitching.isAvailable
                        )
                        .help(
                            liveSwitching.accessibilityHint
                                ?? "A manual warmup waits unless this much memory should remain after loading the requested model."
                        )
                        .accessibilityIdentifier("models.capacity.headroom")

                        if liveSwitching.badgeText != nil {
                            ComingSoonBadge()
                                .help(liveSwitching.accessibilityHint ?? "")
                                .accessibilityIdentifier(
                                    "models.capacity.headroom.coming-soon"
                                )
                        }
                    }
                }

                if selectedCapacityMode != nil {
                    HStack(spacing: 8) {
                        Toggle(
                            "Automatic demand switching",
                            isOn: $automaticSwitching
                        )
                        .disabled(!liveSwitching.isAvailable)
                        .accessibilityIdentifier(
                            "models.capacity.automatic-switching"
                        )

                        if liveSwitching.badgeText != nil {
                            ComingSoonBadge()
                                .help(liveSwitching.accessibilityHint ?? "")
                                .accessibilityIdentifier(
                                    "models.capacity.automatic-switching.coming-soon"
                                )
                        }
                    }
                    Text(
                        liveSwitching.accessibilityHint
                            ?? "After three high-demand samples, warm the recommended enabled model. Attempts are limited to once every 30 minutes and use the same no-interruption safety checks."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 3)
        } else {
            Label(
                "Provider configuration is unavailable.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        }
    }

    private func modelDetails(_ item: ModelInventoryItem, at date: Date) -> some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 4) {
                ModelIdentityDetails(item: item)
                Text("\(ModelFormatting.size(item.sizeGB)) catalog estimate · \(item.minimumRAMGB) GB minimum RAM")
                    .font(.caption).foregroundStyle(.secondary)
                if let bytes = item.downloadedSizeBytes {
                    Text("Downloaded · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) reported locally")
                        .font(.caption).foregroundStyle(.secondary)
                }
                contextBadges(for: item.catalogID, at: date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .disclosureGroupStyle(ModelDetailsDisclosureStyle())
        .accessibilityIdentifier("model.\(item.catalogID).details")
    }

    private var selectedCapacityMode: ProviderCapacityMode? {
        guard let slots = store.draft?.maxModelSlots else { return nil }
        return ProviderCapacityMode(maxModelSlots: slots)
    }

    private var capacityBinding: Binding<ProviderCapacityMode?> {
        Binding(
            get: { selectedCapacityMode },
            set: { mode in
                guard let mode else { return }
                store.setMaxModelSlots(mode.maxModelSlots)
            }
        )
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
