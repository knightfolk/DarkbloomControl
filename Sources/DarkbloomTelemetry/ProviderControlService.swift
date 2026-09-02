import Foundation

private final class MutationDispatchEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomeMayBeAmbiguous = false

    var indicatesPossibleLaunch: Bool { lock.withLock { outcomeMayBeAmbiguous } }

    func recordPossibleLaunch() {
        lock.withLock { outcomeMayBeAmbiguous = true }
    }
}

public enum ProviderLifecycleAction: String, Equatable, Sendable {
    case start
    case stop
    case restart
}

public enum ProviderActivityRisk: Equatable, Sendable {
    case idle
    case active
    case unknown(String)
}

public enum ProviderControlSourceState: Equatable, Sendable {
    /// The source was fresh when evaluated. `evidenceAt` is the source's
    /// embedded timestamp when one exists, otherwise the successful acquisition time.
    case fresh(evidenceAt: Date)
    case stale(String)
    case unavailable(String)

    public static let maximumEvidenceAge: TimeInterval = 10

    public var isMarkedFresh: Bool {
        if case .fresh = self { return true }
        return false
    }

    public func evaluated(
        at currentTime: Date,
        invalidReason: String,
        staleReason: String,
        futureReason: String
    ) -> Self {
        guard case .fresh(let evidenceAt) = self else { return self }
        guard evidenceAt.timeIntervalSince1970.isFinite,
              currentTime.timeIntervalSince1970.isFinite
        else { return .unavailable(invalidReason) }
        let age = currentTime.timeIntervalSince(evidenceAt)
        guard age.isFinite else { return .unavailable(invalidReason) }
        if age < 0 { return .stale(futureReason) }
        if age > Self.maximumEvidenceAge { return .stale(staleReason) }
        return self
    }
}

public struct ProviderControlSourceStates: Equatable, Sendable {
    public let catalog: ProviderControlSourceState
    public let localModels: ProviderControlSourceState
    public let daemon: ProviderControlSourceState
    public let loadedModels: ProviderControlSourceState

    public init(
        catalog: ProviderControlSourceState,
        localModels: ProviderControlSourceState,
        daemon: ProviderControlSourceState,
        loadedModels: ProviderControlSourceState
    ) {
        self.catalog = catalog
        self.localModels = localModels
        self.daemon = daemon
        self.loadedModels = loadedModels
    }

    public static let unknown = ProviderControlSourceStates(
        catalog: .unavailable("Model catalog source state was not provided"),
        localModels: .unavailable("Local model source state was not provided"),
        daemon: .unavailable("Provider activity source state was not provided"),
        loadedModels: .unavailable("Loaded model source state was not provided")
    )
}

public struct ProviderControlSnapshot: Equatable, Sendable {
    public let inventory: ModelInventory
    public let draft: ProviderConfigDraft
    public let capturedAt: Date
    public let sources: ProviderControlSourceStates

    public init(
        inventory: ModelInventory,
        draft: ProviderConfigDraft,
        capturedAt: Date,
        sources: ProviderControlSourceStates = .unknown
    ) {
        self.inventory = inventory
        self.draft = draft
        self.capturedAt = capturedAt
        self.sources = sources
    }
}

public enum ProviderMutationPhase: Equatable, Sendable {
    /// Preconditions and the external command/publication remain cancellable.
    case mutating
    /// The external mutation completed; only authoritative reconciliation remains.
    case reconciling
}

public enum ProviderMutationCompletion: Equatable, Sendable {
    case refreshed(ProviderControlSnapshot)
    case refreshUncertain
    case outcomeUncertain

    public var snapshot: ProviderControlSnapshot? {
        guard case .refreshed(let snapshot) = self else { return nil }
        return snapshot
    }

    public var isOutcomeUncertain: Bool {
        self == .outcomeUncertain
    }
}

public struct ProviderSaveMutationCompletion: Equatable, Sendable {
    public let result: ProviderConfigSaveResult
    public let controls: ProviderMutationCompletion

    public init(result: ProviderConfigSaveResult, controls: ProviderMutationCompletion) {
        self.result = result
        self.controls = controls
    }
}

public typealias ProviderMutationPhaseObserver =
    @Sendable (ProviderMutationPhase) async -> Void

public protocol ProviderControlling: Sendable {
    func refresh() async throws -> ProviderControlSnapshot
    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult
    func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws
    func delete(_ localModelID: String) async throws
    func activityRisk() async -> ProviderActivityRisk
    func execute(_ action: ProviderLifecycleAction, enabledModels: [String]) async throws
    func performSave(
        _ draft: ProviderConfigDraft,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderSaveMutationCompletion
    func performDownload(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion
    func performDelete(
        _ localModelID: String,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion
    func performLifecycle(
        _ action: ProviderLifecycleAction,
        enabledModels: [String],
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion
}

public extension ProviderControlling {
    func performSave(
        _ draft: ProviderConfigDraft,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderSaveMutationCompletion {
        let result = try await save(draft)
        await onPhase?(.reconciling)
        return ProviderSaveMutationCompletion(result: result, controls: .refreshUncertain)
    }

    func performDownload(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion {
        try await download(modelID, onOutput: onOutput)
        await onPhase?(.reconciling)
        return .refreshUncertain
    }

    func performDelete(
        _ localModelID: String,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion {
        try await delete(localModelID)
        await onPhase?(.reconciling)
        return .refreshUncertain
    }

    func performLifecycle(
        _ action: ProviderLifecycleAction,
        enabledModels: [String],
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion {
        try await execute(action, enabledModels: enabledModels)
        await onPhase?(.reconciling)
        return .refreshUncertain
    }
}

public enum ProviderControlError: Error, Equatable, Sendable {
    case commandAlreadyRunning
    case executableUnavailable
    case noEnabledModels
    case inventoryUnavailable(String)
    case deleteBlocked(String)
    case invalidOutput(String)
}

public actor ProviderControlService: ProviderControlling {
    private struct ModelSources: Sendable {
        let catalog: [CatalogModel]
        let local: [LocalModel]
        let catalogState: ProviderControlSourceState
        let localState: ProviderControlSourceState
    }

    private static let invalidSelectionMessage =
        "Saved model selection is not an unambiguous downloaded catalog model"
    private static let invalidDownloadMessage =
        "The requested model is not a fresh available catalog entry"

    private let policy: DarkbloomSourcePolicy
    private let telemetrySource: any TelemetrySource
    private let configStore: any ProviderConfigManaging
    private let runner: any ProcessExecuting
    private let now: @Sendable () -> Date
    private var lastCatalog: [CatalogModel]?
    private var lastLocalModels: [LocalModel]?
    private var nextRefreshGeneration: UInt64 = 0
    private var lastCatalogGeneration: UInt64 = 0
    private var lastLocalModelsGeneration: UInt64 = 0
    private var commandRunning = false

    public init(
        policy: DarkbloomSourcePolicy,
        telemetrySource: any TelemetrySource,
        configStore: any ProviderConfigManaging,
        runner: any ProcessExecuting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.policy = policy
        self.telemetrySource = telemetrySource
        self.configStore = configStore
        self.runner = runner
        self.now = now
    }

    public func refresh() async throws -> ProviderControlSnapshot {
        let executable = try resolveExecutable()
        return try await refresh(
            using: executable,
            allowStaleModelSources: true,
            requireFreshResidency: false
        )
    }

    public func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {
        _ = try await performDownload(modelID, onOutput: onOutput, onPhase: nil)
    }

    public func performDownload(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion {
        try beginCommand()
        defer { endCommand() }
        let executable = try resolveExecutable()
        let sources = try await readModelSources(
            using: executable,
            allowStaleSources: false
        )
        guard isFreshAvailableDownload(modelID, in: sources) else {
            throw ProviderControlError.inventoryUnavailable(Self.invalidDownloadMessage)
        }
        return try await runDispatchedMutation(
            DarkbloomCommand.download(
                executable: executable,
                config: policy.providerConfig,
                modelID: modelID
            ),
            timeout: DarkbloomSourcePolicy.downloadTimeout,
            outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
            onOutput: onOutput,
            onPhase: onPhase,
            executable: executable
        )
    }

    public func delete(_ localModelID: String) async throws {
        _ = try await performDelete(localModelID, onPhase: nil)
    }

    public func performDelete(
        _ localModelID: String,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion {
        try beginCommand()
        defer { endCommand() }
        let executable = try resolveExecutable()
        let snapshot = try await refresh(
            using: executable,
            allowStaleModelSources: false,
            requireFreshResidency: true
        )
        let matches = snapshot.inventory.myCatalog.filter { $0.localID == localModelID }
        guard matches.count <= 1 else {
            throw ProviderControlError.deleteBlocked("The local model identity is ambiguous")
        }
        guard let item = matches.first else {
            if snapshot.draft.selection.enabled.contains(localModelID) {
                throw ProviderControlError.deleteBlocked("Disable the model and save before deleting it")
            }
            if snapshot.draft.selection.preloaded.contains(localModelID) {
                throw ProviderControlError.deleteBlocked("Remove the model from preload and save before deleting it")
            }
            throw ProviderControlError.deleteBlocked("The local model could not be matched safely")
        }
        if item.issue != nil {
            throw ProviderControlError.deleteBlocked("The local model identity is ambiguous")
        }
        switch item.liveState {
        case .active:
            throw ProviderControlError.deleteBlocked("The active model cannot be deleted")
        case .loadedIdle:
            throw ProviderControlError.deleteBlocked("A loaded model cannot be deleted")
        case .unloaded:
            break
        }
        if item.isEnabled {
            throw ProviderControlError.deleteBlocked("Disable the model and save before deleting it")
        }
        if item.isPreloaded {
            throw ProviderControlError.deleteBlocked("Remove the model from preload and save before deleting it")
        }
        return try await runDispatchedMutation(
            DarkbloomCommand.remove(executable: executable, modelID: localModelID),
            timeout: DarkbloomSourcePolicy.lifecycleTimeout,
            outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
            onOutput: nil,
            onPhase: onPhase,
            executable: executable
        )
    }

    public func activityRisk() async -> ProviderActivityRisk {
        do {
            let daemon = try await telemetrySource.readDaemonState()
            switch liveStateFreshness(
                timestamp: daemon.writtenAt,
                at: now(),
                unavailable: "Provider activity timestamp is invalid",
                stale: "Provider activity is stale",
                future: "Provider activity timestamp is in the future"
            ) {
            case .fresh:
                return daemon.inferenceActive ? .active : .idle
            case .stale(let reason), .unavailable(let reason):
                return .unknown(reason)
            }
        } catch {
            return .unknown("Provider activity is unavailable")
        }
    }

    public func execute(
        _ action: ProviderLifecycleAction,
        enabledModels _: [String]
    ) async throws {
        _ = try await performLifecycle(action, enabledModels: [], onPhase: nil)
    }

    public func performLifecycle(
        _ action: ProviderLifecycleAction,
        enabledModels _: [String],
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion {
        try beginCommand()
        defer { endCommand() }
        let savedEnabledModels: [String]
        if action == .start {
            savedEnabledModels = try await configStore.load().original.enabled
            guard !savedEnabledModels.isEmpty else {
                throw ProviderControlError.noEnabledModels
            }
        } else {
            savedEnabledModels = []
        }
        let executable = try resolveExecutable()
        let command: ProcessCommand
        switch action {
        case .start:
            command = DarkbloomCommand.start(
                executable: executable,
                config: policy.providerConfig,
                models: savedEnabledModels
            )
        case .stop:
            command = DarkbloomCommand.stop(executable: executable)
        case .restart:
            command = DarkbloomCommand.restart(
                executable: executable,
                config: policy.providerConfig
            )
        }
        return try await runDispatchedMutation(
            command,
            timeout: DarkbloomSourcePolicy.lifecycleTimeout,
            outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
            onOutput: nil,
            onPhase: onPhase,
            executable: executable
        )
    }

    public func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        try await performSave(draft, onPhase: nil).result
    }

    public func performSave(
        _ draft: ProviderConfigDraft,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderSaveMutationCompletion {
        try beginCommand()
        defer { endCommand() }
        let executable = try resolveExecutable()
        let sources = try await readModelSources(
            using: executable,
            allowStaleSources: false
        )
        guard selectionIsValid(draft.selection, in: sources) else {
            throw ProviderControlError.inventoryUnavailable(Self.invalidSelectionMessage)
        }
        let result = try await configStore.save(draft)
        await onPhase?(.reconciling)
        return ProviderSaveMutationCompletion(
            result: result,
            controls: await refreshAfterCompletedMutation(using: executable)
        )
    }

    /// The external mutation has already completed when this begins. Run its
    /// mandatory refresh in an independent task so cancellation of the caller
    /// cannot turn a completed mutation into a pre-mutation `CancellationError`.
    private func refreshAfterCompletedMutation(
        using executable: URL
    ) async -> ProviderMutationCompletion {
        let service = self
        let refresh = Task.detached(priority: Task.currentPriority) {
            try await service.refresh(
                using: executable,
                allowStaleModelSources: true,
                requireFreshResidency: false
            )
        }
        do {
            return .refreshed(try await refresh.value)
        } catch {
            return .refreshUncertain
        }
    }

    /// Cancellation is authoritative until the runner positively acknowledges
    /// a successful child launch. Once launched, the child may have changed
    /// external state even when the runner reports `CancellationError`
    /// (including an exit/handler bookkeeping race), so reconcile before
    /// releasing command serialization.
    private func runDispatchedMutation(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?,
        onPhase: ProviderMutationPhaseObserver?,
        executable: URL
    ) async throws -> ProviderMutationCompletion {
        try Task.checkCancellation()
        let dispatchEvidence = MutationDispatchEvidence()
        do {
            if let reportingRunner = runner as? any LaunchReportingProcessExecuting {
                _ = try await reportingRunner.run(
                    command,
                    timeout: timeout,
                    outputLimit: outputLimit,
                    onOutput: onOutput,
                    onLaunch: dispatchEvidence.recordPossibleLaunch
                )
            } else {
                // A legacy executor cannot prove that cancellation preceded its
                // external side effect, so invocation is the conservative boundary.
                dispatchEvidence.recordPossibleLaunch()
                _ = try await runner.run(
                    command,
                    timeout: timeout,
                    outputLimit: outputLimit,
                    onOutput: onOutput
                )
            }
        } catch let error as CancellationError {
            guard dispatchEvidence.indicatesPossibleLaunch else { throw error }
            await onPhase?(.reconciling)
            let completion = await refreshAfterCompletedMutation(using: executable)
            return completion == .refreshUncertain ? .outcomeUncertain : completion
        }
        await onPhase?(.reconciling)
        return await refreshAfterCompletedMutation(using: executable)
    }

    private func refresh(
        using executable: URL,
        allowStaleModelSources: Bool,
        requireFreshResidency: Bool
    ) async throws -> ProviderControlSnapshot {
        let modelSources = try await readModelSources(
            using: executable,
            allowStaleSources: allowStaleModelSources
        )
        let draft = try await configStore.load()
        var sourceIssues: [String] = []
        if case .stale(let issue) = modelSources.catalogState { sourceIssues.append(issue) }
        if case .stale(let issue) = modelSources.localState { sourceIssues.append(issue) }

        let daemonRead: DaemonState?
        let daemonFailure: ProviderControlSourceState?
        do {
            daemonRead = try await telemetrySource.readDaemonState()
            daemonFailure = nil
        } catch let error as CancellationError {
            throw error
        } catch {
            daemonRead = nil
            daemonFailure = .unavailable("Provider activity is unavailable")
        }

        let loadedModelsRead: LoadedModelsState?
        let loadedModelsFailure: ProviderControlSourceState?
        do {
            loadedModelsRead = try await telemetrySource.readLoadedModels()
            loadedModelsFailure = nil
        } catch let error as CancellationError {
            throw error
        } catch {
            loadedModelsRead = nil
            loadedModelsFailure = .unavailable("Loaded model state is unavailable")
        }

        let capturedAt = now()
        let daemonState = daemonFailure ?? liveStateFreshness(
            timestamp: daemonRead?.writtenAt ?? .nan,
            at: capturedAt,
            unavailable: "Provider activity timestamp is invalid",
            stale: "Provider activity is stale",
            future: "Provider activity timestamp is in the future"
        )
        let daemon = daemonState.isMarkedFresh ? daemonRead : nil
        try requireFreshResidencyIfNeeded(daemonState, required: requireFreshResidency)
        appendIssue(from: daemonState, to: &sourceIssues)

        let loadedModelsState = loadedModelsFailure ?? liveStateFreshness(
            timestamp: loadedModelsRead?.updatedAt ?? .nan,
            at: capturedAt,
            unavailable: "Loaded model state timestamp is invalid",
            stale: "Loaded model state is stale",
            future: "Loaded model state timestamp is in the future"
        )
        let loadedModels = loadedModelsState.isMarkedFresh ? loadedModelsRead?.models ?? [] : []
        try requireFreshResidencyIfNeeded(loadedModelsState, required: requireFreshResidency)
        appendIssue(from: loadedModelsState, to: &sourceIssues)

        let builtInventory = ModelInventoryBuilder.build(
            catalog: modelSources.catalog,
            local: modelSources.local,
            selection: draft.selection,
            daemon: daemon,
            loadedModels: loadedModels
        )
        let inventory = ModelInventory(
            myCatalog: builtInventory.myCatalog,
            available: builtInventory.available,
            issues: builtInventory.issues + sourceIssues
        )
        return ProviderControlSnapshot(
            inventory: inventory,
            draft: draft,
            capturedAt: capturedAt,
            sources: ProviderControlSourceStates(
                catalog: modelSources.catalogState,
                localModels: modelSources.localState,
                daemon: daemonState,
                loadedModels: loadedModelsState
            )
        )
    }

    private func readModelSources(
        using executable: URL,
        allowStaleSources: Bool
    ) async throws -> ModelSources {
        nextRefreshGeneration &+= 1
        let generation = nextRefreshGeneration
        var catalog: [CatalogModel]?
        var local: [LocalModel]?
        var catalogState: ProviderControlSourceState = .unavailable("Model catalog is unavailable")
        var localState: ProviderControlSourceState = .unavailable("Local model list is unavailable")

        do {
            let result = try await runner.run(
                DarkbloomCommand.catalog(executable: executable, config: policy.providerConfig),
                timeout: DarkbloomSourcePolicy.catalogTimeout,
                outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
                onOutput: nil
            )
            let decoded = try ModelCatalogDecoder.decode(result.standardOutput)
            if generation > lastCatalogGeneration {
                lastCatalog = decoded
                lastCatalogGeneration = generation
            }
            catalog = decoded
            catalogState = .fresh(evidenceAt: now())
        } catch let error as CancellationError {
            throw error
        } catch {
            if allowStaleSources, let lastCatalog {
                catalog = lastCatalog
                catalogState = .stale("Model catalog is stale; showing the last successful result")
            }
        }

        do {
            let result = try await runner.run(
                DarkbloomCommand.localModels(executable: executable, config: policy.providerConfig),
                timeout: DarkbloomSourcePolicy.catalogTimeout,
                outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
                onOutput: nil
            )
            let decoded = try LocalModelListDecoder.decode(result.standardOutput).models
            if generation > lastLocalModelsGeneration {
                lastLocalModels = decoded
                lastLocalModelsGeneration = generation
            }
            local = decoded
            localState = .fresh(evidenceAt: now())
        } catch let error as CancellationError {
            throw error
        } catch {
            if allowStaleSources, let lastLocalModels {
                local = lastLocalModels
                localState = .stale("Local model list is stale; download state may be outdated")
            }
        }

        guard let catalog else {
            throw ProviderControlError.inventoryUnavailable("Model catalog is unavailable")
        }
        guard let local else {
            throw ProviderControlError.inventoryUnavailable("Local model list is unavailable")
        }
        return ModelSources(
            catalog: catalog,
            local: local,
            catalogState: catalogState,
            localState: localState
        )
    }

    private func liveStateFreshness(
        timestamp: TimeInterval,
        at capturedAt: Date,
        unavailable: String,
        stale: String,
        future: String
    ) -> ProviderControlSourceState {
        guard timestamp.isFinite else { return .unavailable(unavailable) }
        return ProviderControlSourceState
            .fresh(evidenceAt: Date(timeIntervalSince1970: timestamp))
            .evaluated(
                at: capturedAt,
                invalidReason: unavailable,
                staleReason: stale,
                futureReason: future
            )
    }

    private func requireFreshResidencyIfNeeded(
        _ state: ProviderControlSourceState,
        required: Bool
    ) throws {
        guard required, !state.isMarkedFresh else { return }
        let reason: String
        switch state {
        case .fresh:
            return
        case .stale(let value), .unavailable(let value):
            reason = value
        }
        throw ProviderControlError.deleteBlocked("\(reason); deletion was not attempted")
    }

    private func appendIssue(
        from state: ProviderControlSourceState,
        to issues: inout [String]
    ) {
        switch state {
        case .fresh:
            break
        case .stale(let reason), .unavailable(let reason):
            issues.append(reason)
        }
    }

    private func selectionIsValid(
        _ selection: ProviderModelSelection,
        in sources: ModelSources
    ) -> Bool {
        let localIDs = Set(sources.local.map(\.id))
        return (selection.enabled + selection.preloaded).allSatisfy { selector in
            let exactMatches = sources.catalog.filter { $0.id == selector }
            let matches = exactMatches.isEmpty
                ? sources.catalog.filter { $0.family == selector }
                : exactMatches
            return matches.count == 1 && localIDs.contains(matches[0].id)
        }
    }

    private func isFreshAvailableDownload(
        _ modelID: String,
        in sources: ModelSources
    ) -> Bool {
        let exactMatches = sources.catalog.filter { $0.id == modelID }
        guard exactMatches.count == 1 else { return false }
        return sources.local.allSatisfy { $0.id != modelID }
    }

    private func resolveExecutable() throws -> URL {
        guard let executable = policy.cliCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw ProviderControlError.executableUnavailable
        }
        return executable
    }

    private func beginCommand() throws {
        guard !commandRunning else {
            throw ProviderControlError.commandAlreadyRunning
        }
        commandRunning = true
    }

    private func endCommand() {
        commandRunning = false
    }
}
