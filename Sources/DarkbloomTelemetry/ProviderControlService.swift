import Foundation

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

public struct ProviderControlSnapshot: Equatable, Sendable {
    public let inventory: ModelInventory
    public let draft: ProviderConfigDraft
    public let capturedAt: Date

    public init(inventory: ModelInventory, draft: ProviderConfigDraft, capturedAt: Date) {
        self.inventory = inventory
        self.draft = draft
        self.capturedAt = capturedAt
    }
}

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
        return try await refresh(using: executable, allowStaleSources: true)
    }

    public func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {
        try beginCommand()
        defer { endCommand() }
        let executable = try resolveExecutable()
        _ = try await runner.run(
            DarkbloomCommand.download(
                executable: executable,
                config: policy.providerConfig,
                modelID: modelID
            ),
            timeout: DarkbloomSourcePolicy.downloadTimeout,
            outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
            onOutput: onOutput
        )
        _ = try await refresh(using: executable, allowStaleSources: true)
    }

    public func delete(_ localModelID: String) async throws {
        try beginCommand()
        defer { endCommand() }
        let executable = try resolveExecutable()
        let snapshot = try await refresh(using: executable, allowStaleSources: false)
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
        _ = try await runner.run(
            DarkbloomCommand.remove(executable: executable, modelID: localModelID),
            timeout: DarkbloomSourcePolicy.lifecycleTimeout,
            outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
            onOutput: nil
        )
        _ = try await refresh(using: executable, allowStaleSources: true)
    }

    public func activityRisk() async -> ProviderActivityRisk {
        do {
            return try await telemetrySource.readDaemonState().inferenceActive ? .active : .idle
        } catch {
            return .unknown("Provider activity is unavailable")
        }
    }

    public func execute(
        _ action: ProviderLifecycleAction,
        enabledModels _: [String]
    ) async throws {
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
        _ = try await runner.run(
            command,
            timeout: DarkbloomSourcePolicy.lifecycleTimeout,
            outputLimit: DarkbloomSourcePolicy.mutationOutputByteLimit,
            onOutput: nil
        )
        _ = try await refresh(using: executable, allowStaleSources: true)
    }

    public func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        try beginCommand()
        defer { endCommand() }
        return try await configStore.save(draft)
    }

    private func refresh(
        using executable: URL,
        allowStaleSources: Bool
    ) async throws -> ProviderControlSnapshot {
        nextRefreshGeneration &+= 1
        let generation = nextRefreshGeneration
        var catalog: [CatalogModel]?
        var local: [LocalModel]?
        var sourceIssues: [String] = []

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
        } catch let error as CancellationError {
            throw error
        } catch {
            if allowStaleSources, let lastCatalog {
                catalog = lastCatalog
                sourceIssues.append("Model catalog is stale; showing the last successful result")
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
        } catch let error as CancellationError {
            throw error
        } catch {
            if allowStaleSources, let lastLocalModels {
                local = lastLocalModels
                sourceIssues.append("Local model list is stale; download state may be outdated")
            }
        }

        guard let catalog else {
            throw ProviderControlError.inventoryUnavailable("Model catalog is unavailable")
        }
        guard let local else {
            throw ProviderControlError.inventoryUnavailable("Local model list is unavailable")
        }
        let draft = try await configStore.load()
        let daemon: DaemonState?
        do {
            daemon = try await telemetrySource.readDaemonState()
        } catch let error as CancellationError {
            throw error
        } catch {
            guard allowStaleSources else {
                throw ProviderControlError.deleteBlocked(
                    "Provider activity is unavailable; deletion was not attempted"
                )
            }
            daemon = nil
        }
        let loadedModels: [String]
        do {
            loadedModels = try await telemetrySource.readLoadedModels().models
        } catch let error as CancellationError {
            throw error
        } catch {
            guard allowStaleSources else {
                throw ProviderControlError.deleteBlocked(
                    "Loaded model state is unavailable; deletion was not attempted"
                )
            }
            loadedModels = []
        }
        let builtInventory = ModelInventoryBuilder.build(
            catalog: catalog,
            local: local,
            selection: draft.selection,
            daemon: daemon,
            loadedModels: loadedModels
        )
        let inventory = ModelInventory(
            myCatalog: builtInventory.myCatalog,
            available: builtInventory.available,
            issues: builtInventory.issues + sourceIssues
        )
        return ProviderControlSnapshot(inventory: inventory, draft: draft, capturedAt: now())
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
