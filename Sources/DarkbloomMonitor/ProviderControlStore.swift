import DarkbloomTelemetry
import Foundation
import SwiftUI

@MainActor
protocol ProviderRestartRequirementPersisting: AnyObject {
    func loadRequired() -> Bool
    func saveRequired(_ required: Bool)
}

@MainActor
final class UserDefaultsProviderRestartRequirementPersistence:
    ProviderRestartRequirementPersisting
{
    static let key = "providerRestartRequired"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRequired() -> Bool {
        defaults.bool(forKey: Self.key)
    }

    func saveRequired(_ required: Bool) {
        defaults.set(required, forKey: Self.key)
    }
}

@MainActor
private final class TransientProviderRestartRequirementPersistence:
    ProviderRestartRequirementPersisting
{
    private var required = false

    func loadRequired() -> Bool { required }
    func saveRequired(_ required: Bool) { self.required = required }
}

private final class WarmupMutationLaunchEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var launched = false

    func markLaunched() {
        lock.lock()
        launched = true
        lock.unlock()
    }

    var didLaunch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return launched
    }
}

enum ProviderOperation: Equatable {
    case idle
    case refreshing
    case saving
    case downloading(String)
    case deleting(String)
    case warming(String)
    case lifecycle(ProviderLifecycleAction)
}

enum LifecycleConfirmation: Equatable {
    case stop(ProviderActivityRisk)
    case restart(ProviderActivityRisk)

    var action: ProviderLifecycleAction {
        switch self {
        case .stop: .stop
        case .restart: .restart
        }
    }

    var risk: ProviderActivityRisk {
        switch self {
        case .stop(let risk), .restart(let risk): risk
        }
    }
}

@MainActor
final class ProviderControlStore: ObservableObject {
    private enum RuntimeConfigurationProof {
        case matches
        case mismatches
        case unavailable
    }

    @Published private(set) var snapshot: ProviderControlSnapshot?
    @Published private(set) var draft: ProviderConfigDraft?
    @Published private(set) var operation: ProviderOperation = .idle
    @Published private(set) var operationPhase: ProviderMutationPhase?
    @Published private(set) var pendingConfirmation: LifecycleConfirmation?
    @Published private(set) var restartRequired = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestDownloadProgressLine: String?

    private let controller: any ProviderControlling
    private let diagnosticSanitizer: UserDiagnosticSanitizer
    private let refreshTelemetry: @MainActor @Sendable () async -> Void
    private let restartRequirementPersistence: any ProviderRestartRequirementPersisting
    private let now: @MainActor () -> Date
    private var currentTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0

    init(
        controller: any ProviderControlling,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        refreshTelemetry: @escaping @MainActor @Sendable () async -> Void = {},
        restartRequirementPersistence: any ProviderRestartRequirementPersisting =
            TransientProviderRestartRequirementPersistence(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.controller = controller
        diagnosticSanitizer = UserDiagnosticSanitizer(homeDirectory: homeDirectory)
        self.refreshTelemetry = refreshTelemetry
        self.restartRequirementPersistence = restartRequirementPersistence
        self.now = now
        restartRequired = restartRequirementPersistence.loadRequired()
    }

    var canSave: Bool {
        guard operation == .idle, let draft, draft.hasChanges else { return false }
        return draftValidationMessage == nil
    }

    func canDownload(_ modelID: String) -> Bool {
        guard operation == .idle, hasFreshModelSources, let snapshot else { return false }
        return snapshot.inventory.available.contains {
            $0.catalogID == modelID && $0.issue == nil
        }
    }

    func sanitizedDiagnostic(_ value: String) -> String {
        diagnosticSanitizer.sanitize(value)
    }

    var canCancelCurrentOperation: Bool {
        guard case .downloading = operation else { return false }
        return operationPhase == .mutating
    }

    var draftValidationMessage: String? {
        guard let draft else { return "Provider configuration is unavailable" }
        guard let snapshot else { return "Model inventory is unavailable" }
        guard snapshot.sources.catalog.isMarkedFresh else {
            return "Refresh the model catalog before changing provider settings"
        }
        guard snapshot.sources.localModels.isMarkedFresh else {
            return "Refresh local models before changing provider settings"
        }

        let enabledIDs = Set(draft.selection.enabled.compactMap {
            Self.resolvedCatalogID(for: $0, in: snapshot.inventory)
        })
        if let selector = draft.selection.preloaded.first(where: {
            guard let modelID = Self.resolvedCatalogID(
                for: $0,
                in: snapshot.inventory
            ) else { return false }
            return !enabledIDs.contains(modelID)
        }) {
            return "Enable '\(Self.safeIdentifier(selector))' or remove it from preload"
        }

        let validSelectors = Set(snapshot.inventory.myCatalog.flatMap { item in
            [item.catalogID, item.enabledSelector, item.preloadSelector]
                .compactMap { $0 }
        })
        if let modelID = (draft.selection.enabled + draft.selection.preloaded).first(where: {
            !validSelectors.contains($0)
        }) {
            return "Downloaded model '\(Self.safeIdentifier(modelID))' is unavailable"
        }
        return nil
    }

    private var hasFreshModelSources: Bool {
        guard let sources = snapshot?.sources else { return false }
        return sources.catalog.isMarkedFresh && sources.localModels.isMarkedFresh
    }

    func refresh() async {
        await refresh(preserving: nil)
    }

    /// Refresh authoritative controls without discarding a staged draft. This
    /// is used by read-only surfaces that need fresh safety evidence while a
    /// user may still be editing settings.
    func refreshPreservingDraft() async {
        await refresh(preserving: draft)
    }

    private func refresh(preserving stagedDraft: ProviderConfigDraft?) async {
        guard let generation = begin(.refreshing) else { return }
        let controller = self.controller
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await controller.refresh()
                try Task.checkCancellation()
                accept(refreshed, preserving: stagedDraft)
            } catch is CancellationError {
                // Cancellation is an intentional state transition, not a user-facing failure.
            } catch {
                errorMessage = "Could not refresh model controls."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func setEnabled(_ enabled: Bool, modelID: String) {
        guard var draft else { return }
        Self.setMembership(enabled, modelID: modelID, in: &draft.selection.enabled)
        self.draft = draft
    }

    func setPreloaded(_ preloaded: Bool, modelID: String) {
        guard var draft else { return }
        Self.setMembership(preloaded, modelID: modelID, in: &draft.selection.preloaded)
        self.draft = draft
    }

    func setMaxModelSlots(_ maxModelSlots: Int) {
        guard var draft, (1...2).contains(maxModelSlots) else { return }
        draft.maxModelSlots = maxModelSlots
        self.draft = draft
    }

    func save() async {
        guard canSave, let draftToSave = draft,
              let generation = begin(.saving)
        else { return }
        let controller = self.controller
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let completion = try await controller.performSave(
                    draftToSave,
                    onPhase: { [weak self] phase in
                        await self?.advanceMutationPhase(phase, generation: generation)
                    }
                )
                let result = completion.result
                draft = result.draft
                if result.restartRequired {
                    setRestartRequired(true)
                }
                if let snapshot {
                    self.snapshot = ProviderControlSnapshot(
                        inventory: snapshot.inventory,
                        draft: result.draft,
                        daemonState: snapshot.daemonState,
                        supportsProtectedWarmup: snapshot.supportsProtectedWarmup,
                        protectedWarmupMaxModelSlots: snapshot.protectedWarmupMaxModelSlots,
                        protectedWarmupAdvertisedModelIDs:
                            snapshot.protectedWarmupAdvertisedModelIDs,
                        protectedWarmupLaunchModelIDs:
                            snapshot.protectedWarmupLaunchModelIDs,
                        protectedWarmupConfiguredMaxModelSlots:
                            snapshot.protectedWarmupConfiguredMaxModelSlots,
                        protectedWarmupConfiguredEnabledModels:
                            snapshot.protectedWarmupConfiguredEnabledModels,
                        protectedWarmupConfiguredPreloadModels:
                            snapshot.protectedWarmupConfiguredPreloadModels,
                        residentModelIDs: snapshot.residentModelIDs,
                        capturedAt: snapshot.capturedAt,
                        sources: snapshot.sources
                    )
                }
                await reconcileCompletedMutation(
                    completion.controls,
                    preserving: nil,
                    failureMessage: "Settings were saved, but model controls could not refresh.",
                    uncertainFailureMessage: "Settings were saved, but model controls could not refresh."
                )
            } catch is CancellationError {
                // The service owns rollback and publication boundaries.
            } catch let error as ProviderControlError {
                errorMessage = controlErrorMessage(error, action: "save")
            } catch let error as ProviderConfigError {
                errorMessage = configErrorMessage(error)
            } catch {
                errorMessage = "Could not save provider settings."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func download(_ modelID: String) async {
        guard let generation = begin(.downloading(modelID)) else { return }
        latestDownloadProgressLine = nil
        let controller = self.controller
        let progress = DownloadProgressAccumulator(sanitizer: diagnosticSanitizer)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let completion = try await controller.performDownload(
                    modelID,
                    onOutput: { [weak self] chunk in
                        guard let line = progress.accept(chunk) else { return }
                        Task { @MainActor [weak self] in
                            guard self?.operation == .downloading(modelID) else { return }
                            self?.latestDownloadProgressLine = line
                        }
                    },
                    onPhase: { [weak self] phase in
                        await self?.advanceMutationPhase(phase, generation: generation)
                    }
                )
                latestDownloadProgressLine = progress.latestLine
                await reconcileCompletedMutation(
                    completion,
                    preserving: draft,
                    failureMessage: "Download completed, but model controls could not refresh.",
                    uncertainFailureMessage:
                        "Download outcome could not be confirmed; model controls could not refresh."
                )
            } catch is CancellationError {
                // Cancellation is surfaced by returning to idle.
            } catch let error as ProviderControlError {
                errorMessage = controlErrorMessage(error, action: "download")
            } catch {
                errorMessage = "Could not download '\(Self.safeIdentifier(modelID))'."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func delete(_ modelID: String) async {
        guard let generation = begin(.deleting(modelID)) else { return }
        let controller = self.controller
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let completion = try await controller.performDelete(
                    modelID,
                    onPhase: { [weak self] phase in
                        await self?.advanceMutationPhase(phase, generation: generation)
                    }
                )
                await reconcileCompletedMutation(
                    completion,
                    preserving: draft,
                    failureMessage: "Delete completed, but model controls could not refresh.",
                    uncertainFailureMessage:
                        "Delete outcome could not be confirmed; model controls could not refresh."
                )
            } catch is CancellationError {
                // Cancellation is surfaced by returning to idle.
            } catch let error as ProviderControlError {
                errorMessage = controlErrorMessage(error, action: "delete")
            } catch {
                errorMessage = "Could not delete '\(Self.safeIdentifier(modelID))'."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    @discardableResult
    func warm(_ modelID: String) async -> Bool {
        guard pendingConfirmation == nil,
              let generation = begin(.warming(modelID))
        else { return false }
        let controller = self.controller
        let launchEvidence = WarmupMutationLaunchEvidence()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let completion = try await controller.performWarmup(
                    modelID,
                    onPhase: { [weak self] phase in
                        await self?.advanceMutationPhase(phase, generation: generation)
                    },
                    onMutationLaunch: {
                        launchEvidence.markLaunched()
                    }
                )
                await reconcileCompletedMutation(
                    completion,
                    preserving: draft,
                    failureMessage: "Warmup completed, but model state could not refresh.",
                    uncertainFailureMessage: "Warmup outcome could not be confirmed."
                )
            } catch is CancellationError {
                await reconcileFailedWarmupState(
                    mayHaveMutated: launchEvidence.didLaunch
                )
            } catch let error as ProviderControlError {
                await reconcileFailedWarmupState(
                    mayHaveMutated: launchEvidence.didLaunch
                )
                errorMessage = controlErrorMessage(error, action: "warm")
            } catch {
                await reconcileFailedWarmupState(
                    mayHaveMutated: launchEvidence.didLaunch
                )
                errorMessage = "Could not warm '\(Self.safeIdentifier(modelID))'."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
        return launchEvidence.didLaunch
    }

    func request(_ action: ProviderLifecycleAction) async {
        pendingConfirmation = nil
        guard let generation = begin(.lifecycle(action)) else { return }
        let controller = self.controller
        let savedEnabledModels = draft?.original.enabled ?? snapshot?.draft.original.enabled ?? []
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if action == .start {
                    try await executeLifecycle(
                        action,
                        enabledModels: savedEnabledModels,
                        generation: generation
                    )
                } else {
                    let firstRisk = await controller.activityRisk()
                    try Task.checkCancellation()
                    if firstRisk == .idle {
                        let finalRisk = await controller.activityRisk()
                        try Task.checkCancellation()
                        if finalRisk == .idle {
                            try await executeLifecycle(
                                action,
                                enabledModels: savedEnabledModels,
                                generation: generation
                            )
                        } else {
                            pendingConfirmation = Self.confirmation(action: action, risk: finalRisk)
                        }
                    } else {
                        pendingConfirmation = Self.confirmation(action: action, risk: firstRisk)
                    }
                }
            } catch is CancellationError {
                // Cancellation leaves authoritative state unchanged.
            } catch let error as ProviderControlError {
                errorMessage = controlErrorMessage(error, action: action.rawValue)
            } catch {
                errorMessage = "Could not \(action.rawValue) the provider."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func confirmPendingLifecycle() async {
        guard let confirmation = pendingConfirmation,
              let generation = begin(.lifecycle(confirmation.action))
        else { return }
        let action = confirmation.action
        let controller = self.controller
        let savedEnabledModels = draft?.original.enabled ?? snapshot?.draft.original.enabled ?? []
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let finalRisk = await controller.activityRisk()
                try Task.checkCancellation()
                pendingConfirmation = Self.confirmation(action: action, risk: finalRisk)
                pendingConfirmation = nil
                try await executeLifecycle(
                    action,
                    enabledModels: savedEnabledModels,
                    generation: generation
                )
            } catch is CancellationError {
                // Cancellation leaves authoritative state unchanged.
            } catch let error as ProviderControlError {
                pendingConfirmation = nil
                errorMessage = controlErrorMessage(error, action: action.rawValue)
            } catch {
                pendingConfirmation = nil
                errorMessage = "Could not \(action.rawValue) the provider."
            }
            finish(generation)
        }
        currentTask = task
        await awaitTask(task)
    }

    func cancelPendingLifecycle() {
        pendingConfirmation = nil
    }

    func cancelCurrentOperation() {
        currentTask?.cancel()
    }

    private func executeLifecycle(
        _ action: ProviderLifecycleAction,
        enabledModels: [String],
        generation: UInt64
    ) async throws {
        let completion: ProviderMutationCompletion
        do {
            completion = try await controller.performLifecycle(
                action,
                enabledModels: enabledModels,
                onPhase: { [weak self] phase in
                    await self?.advanceMutationPhase(phase, generation: generation)
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let commandError = error
            advanceMutationPhase(.reconciling, generation: generation)
            do {
                try await reconcileFailedLifecycleState()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Preserve the command failure when its best-effort
                // reconciliation also fails.
            }
            throw commandError
        }
        guard await reconcileLifecycleState(after: completion) else {
            errorMessage = completion.isOutcomeUncertain
                ? "Provider \(action.rawValue) outcome could not be confirmed; current state could not refresh."
                : "Provider \(action.rawValue) completed, but current state could not be confirmed."
            return
        }
    }

    private func reconcileLifecycleState(
        after completion: ProviderMutationCompletion
    ) async -> Bool {
        await refreshTelemetryAfterCompletedMutation()
        do {
            let refreshed = try await refreshControlsAfterCompletedMutation()
            accept(refreshed, preserving: draft)
            return true
        } catch {
            guard let refreshed = completion.snapshot else {
                invalidateActionableSnapshot()
                return false
            }
            accept(refreshed, preserving: draft)
            return true
        }
    }

    private func reconcileFailedLifecycleState() async throws {
        await refreshTelemetry()
        try Task.checkCancellation()
        let refreshed = try await controller.refresh()
        try Task.checkCancellation()
        accept(refreshed, preserving: draft)
    }

    private func reconcileFailedWarmupState(mayHaveMutated: Bool) async {
        await refreshTelemetryAfterCompletedMutation()
        do {
            let refreshed = try await refreshControlsAfterCompletedMutation()
            accept(refreshed, preserving: draft)
        } catch {
            if mayHaveMutated {
                invalidateActionableSnapshot()
            }
        }
    }

    private func begin(_ newOperation: ProviderOperation) -> UInt64? {
        guard operation == .idle else { return nil }
        operationGeneration &+= 1
        operation = newOperation
        switch newOperation {
        case .saving, .downloading, .deleting, .warming, .lifecycle:
            operationPhase = .mutating
        case .idle, .refreshing:
            operationPhase = nil
        }
        errorMessage = nil
        return operationGeneration
    }

    private func advanceMutationPhase(
        _ phase: ProviderMutationPhase,
        generation: UInt64
    ) {
        guard operationGeneration == generation, operation != .idle else { return }
        operationPhase = phase
    }

    private func finish(_ generation: UInt64) {
        guard operationGeneration == generation else { return }
        currentTask = nil
        operation = .idle
        operationPhase = nil
    }

    private func awaitTask(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func accept(
        _ refreshed: ProviderControlSnapshot,
        preserving stagedDraft: ProviderConfigDraft? = nil
    ) {
        snapshot = refreshed
        draft = stagedDraft ?? refreshed.draft
        switch runtimeConfigurationProof(in: refreshed) {
        case .matches where restartRequired:
            setRestartRequired(false)
        case .mismatches:
            setRestartRequired(true)
        case .matches, .unavailable:
            break
        }
    }

    private func setRestartRequired(_ required: Bool) {
        guard restartRequired != required else { return }
        restartRequired = required
        restartRequirementPersistence.saveRequired(required)
    }

    private func runtimeConfigurationProof(
        in snapshot: ProviderControlSnapshot
    ) -> RuntimeConfigurationProof {
        let currentTime = now()
        let catalogState = snapshot.sources.catalog.evaluated(
            at: currentTime,
            invalidReason: "Model catalog timestamp is invalid",
            staleReason: "Model catalog is stale",
            futureReason: "Model catalog timestamp is in the future"
        )
        let localState = snapshot.sources.localModels.evaluated(
            at: currentTime,
            invalidReason: "Local model timestamp is invalid",
            staleReason: "Local model list is stale",
            futureReason: "Local model timestamp is in the future"
        )
        let daemonState = snapshot.sources.daemon.evaluated(
            at: currentTime,
            invalidReason: "Provider activity timestamp is invalid",
            staleReason: "Provider activity is stale",
            futureReason: "Provider activity timestamp is in the future"
        )
        guard catalogState.isMarkedFresh,
              localState.isMarkedFresh,
              daemonState.isMarkedFresh,
              snapshot.supportsProtectedWarmup,
              let savedMaxModelSlots = snapshot.draft.originalMaxModelSlots,
              let configuredMaxModelSlots =
                  snapshot.protectedWarmupConfiguredMaxModelSlots,
              let configuredEnabled = snapshot.protectedWarmupConfiguredEnabledModels,
              let configuredPreloaded = snapshot.protectedWarmupConfiguredPreloadModels,
              let effectiveMaxModelSlots = snapshot.protectedWarmupMaxModelSlots,
              let advertisedModels = snapshot.protectedWarmupAdvertisedModelIDs,
              let launchModels = snapshot.protectedWarmupLaunchModelIDs,
              let expectedAdvertised = Self.resolveSavedEnabledModelIDs(
                  snapshot.draft.original.enabled,
                  in: snapshot.inventory
              )
        else { return .unavailable }
        let expectedEffectiveMaxModelSlots = max(
            1,
            min(
                configuredMaxModelSlots,
                max(launchModels.count, advertisedModels.count)
            )
        )
        let matches = configuredMaxModelSlots == savedMaxModelSlots
            && effectiveMaxModelSlots == expectedEffectiveMaxModelSlots
            && Self.sameUniqueIdentifiers(
                configuredEnabled,
                snapshot.draft.original.enabled
            )
            && Self.sameUniqueIdentifiers(
                configuredPreloaded,
                snapshot.draft.original.preloaded
            )
            && launchModels == expectedAdvertised
        return matches ? .matches : .mismatches
    }

    private static func sameUniqueIdentifiers(
        _ lhs: [String],
        _ rhs: [String]
    ) -> Bool {
        let left = Set(lhs)
        let right = Set(rhs)
        return left.count == lhs.count
            && right.count == rhs.count
            && left == right
    }

    private static func resolveSavedEnabledModelIDs(
        _ selectors: [String],
        in inventory: ModelInventory
    ) -> Set<String>? {
        var result: Set<String> = []
        for selector in selectors {
            let exact = inventory.myCatalog.filter { $0.catalogID == selector }
            let matches = exact.isEmpty
                ? inventory.myCatalog.filter { $0.enabledSelector == selector }
                : exact
            guard matches.count == 1,
                  matches[0].isDownloaded,
                  result.insert(matches[0].catalogID).inserted
            else { return nil }
        }
        return result.count == selectors.count ? result : nil
    }

    private static func resolvedCatalogID(
        for selector: String,
        in inventory: ModelInventory
    ) -> String? {
        let exact = inventory.myCatalog.filter { $0.catalogID == selector }
        if exact.count == 1 {
            return exact[0].catalogID
        }
        guard exact.isEmpty else { return nil }
        let aliases = inventory.myCatalog.filter {
            $0.enabledSelector == selector || $0.preloadSelector == selector
        }
        guard aliases.count == 1 else { return nil }
        return aliases[0].catalogID
    }

    private func reconcileCompletedMutation(
        _ completion: ProviderMutationCompletion,
        preserving stagedDraft: ProviderConfigDraft?,
        failureMessage: String,
        uncertainFailureMessage: String
    ) async {
        do {
            let refreshed = try await refreshControlsAfterCompletedMutation()
            accept(refreshed, preserving: stagedDraft)
        } catch {
            if let refreshed = completion.snapshot {
                accept(refreshed, preserving: stagedDraft)
            } else {
                invalidateActionableSnapshot()
                errorMessage = completion.isOutcomeUncertain
                    ? uncertainFailureMessage
                    : failureMessage
            }
        }
    }

    private func refreshControlsAfterCompletedMutation() async throws -> ProviderControlSnapshot {
        let controller = self.controller
        let refresh = Task.detached(priority: Task.currentPriority) {
            try await controller.refresh()
        }
        return try await refresh.value
    }

    private func refreshTelemetryAfterCompletedMutation() async {
        let refreshTelemetry = self.refreshTelemetry
        let refresh = Task.detached(priority: Task.currentPriority) {
            await refreshTelemetry()
        }
        await refresh.value
    }

    private func invalidateActionableSnapshot() {
        guard let snapshot else { return }
        self.snapshot = ProviderControlSnapshot(
            inventory: snapshot.inventory,
            draft: snapshot.draft,
            daemonState: snapshot.daemonState,
            supportsProtectedWarmup: snapshot.supportsProtectedWarmup,
            protectedWarmupMaxModelSlots: snapshot.protectedWarmupMaxModelSlots,
            protectedWarmupAdvertisedModelIDs:
                snapshot.protectedWarmupAdvertisedModelIDs,
            protectedWarmupLaunchModelIDs:
                snapshot.protectedWarmupLaunchModelIDs,
            protectedWarmupConfiguredMaxModelSlots:
                snapshot.protectedWarmupConfiguredMaxModelSlots,
            protectedWarmupConfiguredEnabledModels:
                snapshot.protectedWarmupConfiguredEnabledModels,
            protectedWarmupConfiguredPreloadModels:
                snapshot.protectedWarmupConfiguredPreloadModels,
            residentModelIDs: snapshot.residentModelIDs,
            capturedAt: snapshot.capturedAt,
            sources: .unknown
        )
    }

    private static func setMembership(
        _ included: Bool,
        modelID: String,
        in values: inout [String]
    ) {
        if included {
            if !values.contains(modelID) {
                values.append(modelID)
            }
        } else {
            values.removeAll { $0 == modelID }
        }
    }

    private static func confirmation(
        action: ProviderLifecycleAction,
        risk: ProviderActivityRisk
    ) -> LifecycleConfirmation? {
        switch (action, risk) {
        case (.stop, .active), (.stop, .unknown): .stop(risk)
        case (.restart, .active), (.restart, .unknown): .restart(risk)
        case (_, .idle), (.start, _): nil
        }
    }

    private func controlErrorMessage(
        _ error: ProviderControlError,
        action: String
    ) -> String {
        switch error {
        case .commandAlreadyRunning:
            "Another provider action is already running."
        case .executableUnavailable:
            "The Darkbloom command is unavailable."
        case .noEnabledModels:
            "Start requires at least one saved enabled model."
        case .inventoryUnavailable(let reason):
            Self.safeInventoryDiagnostics.contains(reason)
                ? diagnosticSanitizer.sanitize(reason)
                : "Model inventory is unavailable."
        case .deleteBlocked(let reason):
            Self.safeDeleteDiagnostics.contains(reason)
                ? diagnosticSanitizer.sanitize(reason)
                : "The model cannot be deleted safely."
        case .warmupBlocked(let reason):
            Self.safeWarmupDiagnostics.contains(reason)
                ? diagnosticSanitizer.sanitize(reason)
                : "The model cannot be warmed safely."
        case .invalidOutput:
            "Darkbloom returned an invalid response while trying to \(action)."
        }
    }

    private func configErrorMessage(_ error: ProviderConfigError) -> String {
        switch error {
        case .changedExternally:
            "Provider settings changed outside the app. Reload and try again."
        case .preloadRequiresEnabled(let modelID):
            "Enable '\(Self.safeIdentifier(modelID))' or remove it from preload."
        case .validationFailed(let reason):
            configValidationMessage(reason)
        case .invalidUTF8, .missingArray, .missingInteger, .duplicateArray,
             .duplicateInteger, .malformedArray, .malformedInteger,
             .nonStringValue, .unsupportedInteger, .duplicateModel:
            "Provider settings could not be read safely."
        }
    }

    private func configValidationMessage(_ reason: String) -> String {
        let message: String
        switch reason {
        case "Darkbloom rejected the candidate configuration":
            message = "Darkbloom rejected the provider settings."
        case "Could not read the provider configuration":
            message = "Could not read the provider configuration."
        case "Could not save the provider configuration":
            message = "Could not save the provider configuration."
        case "Provider configuration changed during recovery; recovery data was preserved beside it":
            message = "Provider configuration changed during recovery; recovery data was preserved beside it."
        case "Could not preserve provider configuration security metadata":
            message = "Could not preserve provider configuration security metadata."
        case "Provider configuration is busy; try again":
            message = "Provider configuration is busy; try again."
        case "Could not remove the candidate configuration; recovery data was preserved beside the provider configuration":
            message = "Could not remove the candidate configuration; recovery data was preserved beside the provider configuration."
        default:
            message = "Could not save provider settings."
        }
        return diagnosticSanitizer.sanitize(message)
    }

    private static let safeInventoryDiagnostics: Set<String> = [
        "The requested model is not a fresh available catalog entry",
        "Saved model selection is not an unambiguous downloaded catalog model",
        "Model catalog is unavailable",
        "Local model list is unavailable",
    ]

    private static let safeDeleteDiagnostics: Set<String> = {
        let fixed = [
            "The local model identity is ambiguous",
            "Disable the model and save before deleting it",
            "Remove the model from preload and save before deleting it",
            "The local model could not be matched safely",
            "The active model cannot be deleted",
            "A loaded model cannot be deleted",
        ]
        let residency = [
            "Provider activity is unavailable",
            "Provider activity timestamp is invalid",
            "Provider activity is stale",
            "Provider activity timestamp is in the future",
            "Loaded model state is unavailable",
            "Loaded model state timestamp is invalid",
            "Loaded model state is stale",
            "Loaded model state timestamp is in the future",
        ].map { "\($0); deletion was not attempted" }
        return Set(fixed + residency)
    }()

    private static let safeWarmupDiagnostics: Set<String> = {
        let fixed = [
            "The selected model could not be matched safely",
            "Download this model first",
            "Enable and save this model first",
            "Waiting for fresh provider activity",
            "Waiting for the current customer job to finish",
            "Both model slots are occupied; waiting avoids evicting another model",
            "Protected model switching requires a provider update",
            "Protected two-model staging requires a provider update",
            "Waiting for enough memory to stage this model without eviction",
            "Choose one- or two-model serving capacity in Settings first",
            "Loaded model state conflicts with one-model capacity; waiting for a clean refresh",
            "Restart the provider to apply the saved model capacity",
            "Protected warmup requires complete applied provider runtime proof",
            "The provider did not preserve the previously loaded model",
            "The selected model was not confirmed warm",
            "Target warmed, but the previous model could not be retired safely",
        ]
        let residency = [
            "Provider activity is unavailable",
            "Provider activity timestamp is invalid",
            "Provider activity is stale",
            "Provider activity timestamp is in the future",
            "Loaded model state is unavailable",
            "Loaded model state timestamp is invalid",
            "Loaded model state is stale",
            "Loaded model state timestamp is in the future",
        ].map { "\($0); warmup was not attempted" }
        return Set(fixed + residency)
    }()

    private static func safeIdentifier(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
        let sanitized = String(String.UnicodeScalarView(allowed))
        return String(sanitized.prefix(80))
    }
}

private final class UserDiagnosticSanitizer: @unchecked Sendable {
    private static let maximumLength = 200
    private let homePath: String

    init(homeDirectory: URL) {
        homePath = Self.normalizedForMatching(homeDirectory.standardizedFileURL.path)
    }

    func sanitize(_ value: String) -> String {
        var result = Self.normalizedForMatching(value)
        if homePath != "/" && !homePath.isEmpty {
            result = result.replacingOccurrences(of: homePath, with: "~")
        }
        result = Self.replacing(
            pattern: #"(?i)Authorization\s*:\s*Bearer\s+[^\s,;]+"#,
            in: result,
            with: "Authorization: <redacted>"
        )
        result = Self.replacing(
            pattern: #"(?i)\b(access[_ -]?token|refresh[_ -]?token|auth(?:orization)?[_ -]?token|token|api[_ -]?key|password|secret)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            in: result,
            with: "$1=<redacted>"
        )
        result = Self.normalizedForMatching(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(result.prefix(Self.maximumLength))
    }

    private static func normalizedForMatching(_ value: String) -> String {
        var normalized = value.precomposedStringWithCanonicalMapping
        // Collapse obfuscating controls while retaining ANSI delimiters long
        // enough to remove the entire sequence, including its visible payload.
        normalized = String(normalized.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                || $0.value == 0x07
                || $0.value == 0x1B
        })
        let ansiPatterns = [
            #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#,
            #"\x1B\[[0-?]*[ -/]*[@-~]"#,
            #"\x1B[@-_]"#,
        ]
        for pattern in ansiPatterns {
            normalized = replacing(
                pattern: pattern,
                in: normalized,
                with: ""
            )
        }
        return String(normalized.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
    }

    private static func replacing(
        pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }
}

private final class DownloadProgressAccumulator: @unchecked Sendable {
    private struct StreamState {
        var line = Data()
        var isTruncated = false
        var lastUpdate: UInt64 = 0

        mutating func accept(
            _ data: Data,
            maximumLineBytes: Int,
            sanitizer: UserDiagnosticSanitizer
        ) -> String? {
            var latestCompletedLine: String?
            for byte in data {
                if byte == 0x0A || byte == 0x0D {
                    if !isTruncated,
                       let candidate = Self.sanitized(line, using: sanitizer) {
                        latestCompletedLine = candidate
                    }
                    line.removeAll(keepingCapacity: true)
                    isTruncated = false
                } else if !isTruncated {
                    if line.count < maximumLineBytes {
                        line.append(byte)
                    } else {
                        // Never retain a suffix after losing its identifying
                        // prefix: the entire logical line becomes unrenderable.
                        line.removeAll(keepingCapacity: false)
                        isTruncated = true
                    }
                }
            }
            return latestCompletedLine
        }

        func sanitizedIncompleteLine(
            using sanitizer: UserDiagnosticSanitizer
        ) -> String? {
            guard !isTruncated else { return nil }
            return Self.sanitized(line, using: sanitizer)
        }

        private static func sanitized(
            _ data: Data,
            using sanitizer: UserDiagnosticSanitizer
        ) -> String? {
            guard !data.isEmpty else { return nil }
            let value = sanitizer.sanitize(String(decoding: data, as: UTF8.self))
            return value.isEmpty ? nil : value
        }
    }

    private struct StoredLine {
        let sequence: UInt64
        let value: String
    }

    private static let maximumLineBytes = 4_096
    private let lock = NSLock()
    private let sanitizer: UserDiagnosticSanitizer
    private var standardOutput = StreamState()
    private var standardError = StreamState()
    private var storedLatestLine: StoredLine?
    private var sequence: UInt64 = 0

    init(sanitizer: UserDiagnosticSanitizer) {
        self.sanitizer = sanitizer
    }

    var latestLine: String? {
        lock.withLock {
            var candidates = [StoredLine]()
            if let storedLatestLine {
                candidates.append(storedLatestLine)
            }
            if let value = standardOutput.sanitizedIncompleteLine(using: sanitizer) {
                candidates.append(StoredLine(
                    sequence: standardOutput.lastUpdate,
                    value: value
                ))
            }
            if let value = standardError.sanitizedIncompleteLine(using: sanitizer) {
                candidates.append(StoredLine(
                    sequence: standardError.lastUpdate,
                    value: value
                ))
            }
            return candidates.max { $0.sequence < $1.sequence }?.value
        }
    }

    func accept(_ chunk: ProcessOutputChunk) -> String? {
        lock.withLock {
            sequence &+= 1
            let completed: String?
            switch chunk.destination {
            case .standardOutput:
                standardOutput.lastUpdate = sequence
                completed = standardOutput.accept(
                    chunk.data,
                    maximumLineBytes: Self.maximumLineBytes,
                    sanitizer: sanitizer
                )
            case .standardError:
                standardError.lastUpdate = sequence
                completed = standardError.accept(
                    chunk.data,
                    maximumLineBytes: Self.maximumLineBytes,
                    sanitizer: sanitizer
                )
            }
            if let completed {
                storedLatestLine = StoredLine(sequence: sequence, value: completed)
            }
            return completed
        }
    }
}
