import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Provider control service")
struct ProviderControlServiceTests {
    @Test("refresh combines catalog local config and live telemetry")
    func refreshesInventory() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }

        let snapshot = try await harness.service.refresh()

        #expect(snapshot.inventory.myCatalog.count == 2)
        #expect(snapshot.inventory.available.count == 1)
        #expect(snapshot.draft.selection.enabled == ["gemma-4-26b-qat-4bit"])
        #expect(snapshot.capturedAt == harness.now)
        #expect(snapshot.inventory.myCatalog.first { $0.catalogID == "gemma-4-26b-qat-4bit" }?.liveState == .loadedIdle)
    }

    @Test("download and delete never change configuration")
    func mutationsStaySeparate() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }

        try await harness.service.download("gpt-oss-20b", onOutput: nil)
        try await harness.service.delete("gpt-oss-20b")

        #expect(await harness.configStore.saveCount == 0)
        #expect(await harness.runner.mutationArguments == [
            ["models", "download", "--config", harness.configURL.path, "gpt-oss-20b"],
            ["models", "remove", "gpt-oss-20b", "--force"],
        ])
    }

    @Test("catalog and local caches become stale independently")
    func cachesSourcesIndependently() async throws {
        let catalogHarness = try ServiceHarness.make()
        defer { catalogHarness.cleanup() }
        _ = try await catalogHarness.service.refresh()
        await catalogHarness.runner.failNextCatalog()
        await catalogHarness.runner.useNextLocal(localGemmaOnlyJSON)

        let staleCatalog = try await catalogHarness.service.refresh()

        #expect(staleCatalog.inventory.issues.contains("Model catalog is stale; showing the last successful result"))
        #expect(!staleCatalog.inventory.issues.contains("Local model list is stale; download state may be outdated"))
        #expect(staleCatalog.inventory.myCatalog.map(\.catalogID) == ["gemma-4-26b-qat-4bit"])

        let localHarness = try ServiceHarness.make()
        defer { localHarness.cleanup() }
        _ = try await localHarness.service.refresh()
        await localHarness.runner.useNextCatalog(catalogWithExtraModelJSON)
        await localHarness.runner.failNextLocal()

        let staleLocal = try await localHarness.service.refresh()

        #expect(staleLocal.inventory.issues.contains("Local model list is stale; download state may be outdated"))
        #expect(!staleLocal.inventory.issues.contains("Model catalog is stale; showing the last successful result"))
        #expect(staleLocal.inventory.available.map(\.catalogID).contains("llama-3-8b"))
        #expect(staleLocal.inventory.myCatalog.count == 2)
    }

    @Test("a required source that has never decoded throws a bounded unavailable error")
    func rejectsUnavailableFirstRefresh() async throws {
        let catalogHarness = try ServiceHarness.make()
        defer { catalogHarness.cleanup() }
        await catalogHarness.runner.failNextCatalog()

        await #expect(throws: ProviderControlError.inventoryUnavailable("Model catalog is unavailable")) {
            try await catalogHarness.service.refresh()
        }
        #expect(await catalogHarness.runner.sourceArguments.count == 2)

        let localHarness = try ServiceHarness.make()
        defer { localHarness.cleanup() }
        await localHarness.runner.failNextLocal()

        await #expect(throws: ProviderControlError.inventoryUnavailable("Local model list is unavailable")) {
            try await localHarness.service.refresh()
        }
        #expect(await localHarness.runner.sourceArguments.count == 2)
    }

    @Test("delete requires a fresh inventory")
    func deleteRequiresFreshInventory() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        _ = try await harness.service.refresh()
        await harness.runner.failNextCatalog()

        await #expect(throws: ProviderControlError.inventoryUnavailable("Model catalog is unavailable")) {
            try await harness.service.delete("gpt-oss-20b")
        }

        #expect(await harness.runner.mutationArguments.isEmpty)
    }

    @Test("delete rejects active loaded enabled and preloaded models in the service")
    func deleteRejectsUnsafeStates() async throws {
        let active = try ServiceHarness.make(
            daemonState: daemon(currentModel: "gpt-oss-20b", inferenceActive: true),
            loadedModels: []
        )
        defer { active.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("The active model cannot be deleted")) {
            try await active.service.delete("gpt-oss-20b")
        }

        let loaded = try ServiceHarness.make(loadedModels: ["gpt-oss-20b"])
        defer { loaded.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("A loaded model cannot be deleted")) {
            try await loaded.service.delete("gpt-oss-20b")
        }

        let enabled = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: ["gpt-oss-20b"],
            preloaded: []
        ))
        defer { enabled.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("Disable the model and save before deleting it")) {
            try await enabled.service.delete("gpt-oss-20b")
        }

        let preloaded = try ServiceHarness.make(selection: ProviderModelSelection(
            enabled: [],
            preloaded: ["gpt-oss-20b"]
        ))
        defer { preloaded.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("Remove the model from preload and save before deleting it")) {
            try await preloaded.service.delete("gpt-oss-20b")
        }

        #expect(await active.runner.mutationArguments.isEmpty)
        #expect(await loaded.runner.mutationArguments.isEmpty)
        #expect(await enabled.runner.mutationArguments.isEmpty)
        #expect(await preloaded.runner.mutationArguments.isEmpty)
    }

    @Test("delete rejects unmatched and ambiguous local identities")
    func deleteRejectsUnsafeIdentity() async throws {
        let unmatched = try ServiceHarness.make()
        defer { unmatched.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("The local model could not be matched safely")) {
            try await unmatched.service.delete("orphan-local-model")
        }

        let ambiguous = try ServiceHarness.make(catalog: duplicateCatalogIDJSON)
        defer { ambiguous.cleanup() }
        await #expect(throws: ProviderControlError.deleteBlocked("The local model identity is ambiguous")) {
            try await ambiguous.service.delete("gpt-oss-20b")
        }

        #expect(await unmatched.runner.mutationArguments.isEmpty)
        #expect(await ambiguous.runner.mutationArguments.isEmpty)
    }

    @Test("lifecycle commands use exact arguments and policy bounds")
    func lifecycleCommandsAreExact() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }

        try await harness.service.execute(.start, enabledModels: ["gemma-4-26b-qat-4bit", "gpt-oss"])
        try await harness.service.execute(.stop, enabledModels: [])
        try await harness.service.execute(.restart, enabledModels: [])

        let invocations = await harness.runner.lifecycleInvocations
        #expect(invocations.map(\.command.arguments) == [
            ["start", "--config", harness.configURL.path, "--model", "gemma-4-26b-qat-4bit", "--model", "gpt-oss"],
            ["stop"],
            ["restart", "--config", harness.configURL.path],
        ])
        #expect(invocations.allSatisfy { $0.timeout == DarkbloomSourcePolicy.lifecycleTimeout })
        #expect(invocations.allSatisfy { $0.outputLimit == DarkbloomSourcePolicy.mutationOutputByteLimit })
        #expect(invocations.allSatisfy { !$0.command.arguments.contains("--uninstall") })
    }

    @Test("start rejects an empty saved enabled selection")
    func startRequiresEnabledModels() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }

        await #expect(throws: ProviderControlError.noEnabledModels) {
            try await harness.service.execute(.start, enabledModels: [])
        }

        #expect(await harness.runner.lifecycleInvocations.isEmpty)
    }

    @Test("activity maps fresh daemon telemetry directly")
    func mapsActivityRisk() async throws {
        let active = try ServiceHarness.make(
            daemonState: daemon(currentModel: "gpt-oss-20b", inferenceActive: true)
        )
        defer { active.cleanup() }
        #expect(await active.service.activityRisk() == .active)

        let idle = try ServiceHarness.make()
        defer { idle.cleanup() }
        #expect(await idle.service.activityRisk() == .idle)

        await idle.telemetry.failNextDaemonRead()
        #expect(await idle.service.activityRisk() == .unknown("Provider activity is unavailable"))
    }

    @Test("an absent approved executable is a bounded service error")
    func rejectsMissingExecutable() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        try FileManager.default.removeItem(at: harness.executableURL)

        await #expect(throws: ProviderControlError.executableUnavailable) {
            try await harness.service.refresh()
        }

        #expect(await harness.runner.invocations.isEmpty)
    }

    @Test("model and lifecycle commands reject overlap while the actor is suspended")
    func rejectsOverlappingCommands() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        await harness.runner.blockNextMutation()
        let download = Task {
            try await harness.service.download("gpt-oss-20b", onOutput: nil)
        }
        await harness.runner.waitUntilBlocked()

        await #expect(throws: ProviderControlError.commandAlreadyRunning) {
            try await harness.service.delete("gpt-oss-20b")
        }
        await #expect(throws: ProviderControlError.commandAlreadyRunning) {
            try await harness.service.execute(.stop, enabledModels: [])
        }

        await harness.runner.releaseBlockedCommand()
        try await download.value
    }

    @Test("save participates in command serialization")
    func serializesSave() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let draft = try await harness.configStore.load()
        await harness.configStore.blockNextSave()
        let save = Task {
            try await harness.service.save(draft.withSelection(ProviderModelSelection(
                enabled: ["gpt-oss-20b"],
                preloaded: []
            )))
        }
        await harness.configStore.waitUntilSaveBlocked()

        await #expect(throws: ProviderControlError.commandAlreadyRunning) {
            try await harness.service.download("gpt-oss-20b", onOutput: nil)
        }

        await harness.configStore.releaseBlockedSave()
        let result = try await save.value
        #expect(result.restartRequired)
        #expect(result.draft.selection.enabled == ["gpt-oss-20b"])
    }

    @Test("download forwards bounded output chunks")
    func forwardsDownloadOutput() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        let recorder = ServiceOutputRecorder()

        try await harness.service.download("gpt-oss-20b", onOutput: recorder.record)

        #expect(recorder.data == Data("download 25%".utf8))
        let invocation = try #require(await harness.runner.mutationInvocations.first)
        #expect(invocation.timeout == DarkbloomSourcePolicy.downloadTimeout)
        #expect(invocation.outputLimit == DarkbloomSourcePolicy.mutationOutputByteLimit)
    }

    @Test("download cancellation reaches the executor skips refresh and releases serialization")
    func propagatesCancellation() async throws {
        let harness = try ServiceHarness.make()
        defer { harness.cleanup() }
        await harness.runner.blockNextMutation()
        let download = Task {
            try await harness.service.download("gpt-oss-20b", onOutput: nil)
        }
        await harness.runner.waitUntilBlocked()

        download.cancel()
        do {
            try await download.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected: the service does not translate executor cancellation.
        }

        #expect(await harness.runner.sourceArguments.isEmpty)
        try await harness.service.execute(.stop, enabledModels: [])
    }
}

private final class ServiceHarness: @unchecked Sendable {
    let directory: URL
    let configURL: URL
    let executableURL: URL
    let runner: ServiceRunnerFake
    let telemetry: ServiceTelemetryFake
    let configStore: ServiceConfigStoreFake
    let service: ProviderControlService
    let now = Date(timeIntervalSince1970: 1_788_282_000)

    static func make(
        catalog: Data = catalogJSON,
        local: Data = localJSON,
        selection: ProviderModelSelection = ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit"],
            preloaded: []
        ),
        daemonState: DaemonState = daemon(currentModel: "", inferenceActive: false),
        loadedModels: [String] = ["gemma-4-26b-qat-4bit"]
    ) throws -> ServiceHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-provider-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableURL = directory.appendingPathComponent("darkbloom")
        #expect(FileManager.default.createFile(atPath: executableURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        let configURL = directory.appendingPathComponent(".config/darkbloom/provider.toml")
        let runner = ServiceRunnerFake(catalog: catalog, local: local)
        let telemetry = ServiceTelemetryFake(
            daemon: daemonState,
            loadedModels: LoadedModelsState(schema: 1, models: loadedModels, updatedAt: 1)
        )
        let configStore = ServiceConfigStoreFake(selection: selection)
        let policy = DarkbloomSourcePolicy(homeDirectory: directory, environmentPath: directory.path)
        return ServiceHarness(
            directory: directory,
            configURL: configURL,
            executableURL: executableURL,
            runner: runner,
            telemetry: telemetry,
            configStore: configStore,
            policy: policy
        )
    }

    private init(
        directory: URL,
        configURL: URL,
        executableURL: URL,
        runner: ServiceRunnerFake,
        telemetry: ServiceTelemetryFake,
        configStore: ServiceConfigStoreFake,
        policy: DarkbloomSourcePolicy
    ) {
        self.directory = directory
        self.configURL = configURL
        self.executableURL = executableURL
        self.runner = runner
        self.telemetry = telemetry
        self.configStore = configStore
        service = ProviderControlService(
            policy: policy,
            telemetrySource: telemetry,
            configStore: configStore,
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_788_282_000) }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ServiceRunnerFake: ProcessExecuting {
    private enum Response: Sendable {
        case data(Data)
        case failure
    }

    struct Invocation: Sendable {
        let command: ProcessCommand
        let timeout: Duration
        let outputLimit: Int
    }

    private let catalog: Data
    private let local: Data
    private var nextCatalog: Response?
    private var nextLocal: Response?
    private(set) var invocations: [Invocation] = []
    private var blockedGate: ServiceAsyncGate?
    private var shouldBlockNextMutation = false

    init(catalog: Data, local: Data) {
        self.catalog = catalog
        self.local = local
    }

    var mutationArguments: [[String]] {
        invocations.compactMap { invocation in
            let arguments = invocation.command.arguments
            guard arguments.count > 1, arguments[0] == "models",
                  arguments[1] == "download" || arguments[1] == "remove" else { return nil }
            return arguments
        }
    }

    var sourceArguments: [[String]] {
        invocations.compactMap { invocation in
            let arguments = invocation.command.arguments
            guard Array(arguments.prefix(2)) == ["models", "catalog"]
                    || Array(arguments.prefix(2)) == ["models", "list"] else { return nil }
            return arguments
        }
    }

    var lifecycleInvocations: [Invocation] {
        invocations.filter { ["start", "stop", "restart"].contains($0.command.arguments.first ?? "") }
    }

    var mutationInvocations: [Invocation] {
        invocations.filter {
            let arguments = $0.command.arguments
            return arguments.count > 1 && arguments[0] == "models"
                && (arguments[1] == "download" || arguments[1] == "remove")
        }
    }

    func blockNextMutation() {
        blockedGate = ServiceAsyncGate()
        shouldBlockNextMutation = true
    }

    func waitUntilBlocked() async {
        await blockedGate?.waitUntilStarted()
    }

    func releaseBlockedCommand() async {
        await blockedGate?.release()
    }

    func failNextCatalog() { nextCatalog = .failure }
    func failNextLocal() { nextLocal = .failure }
    func useNextCatalog(_ data: Data) { nextCatalog = .data(data) }
    func useNextLocal(_ data: Data) { nextLocal = .data(data) }

    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult {
        invocations.append(Invocation(command: command, timeout: timeout, outputLimit: outputLimit))
        if command.arguments.count > 1,
           command.arguments[0] == "models",
           command.arguments[1] == "download" || command.arguments[1] == "remove",
           shouldBlockNextMutation {
            shouldBlockNextMutation = false
            if let blockedGate {
                try await blockedGate.wait()
            }
        }
        if Array(command.arguments.prefix(2)) == ["models", "download"] {
            onOutput?(ProcessOutputChunk(
                destination: .standardOutput,
                data: Data("download 25%".utf8)
            ))
        }
        let output: Data
        switch Array(command.arguments.prefix(2)) {
        case ["models", "catalog"]:
            output = try consume(&nextCatalog, fallback: catalog)
        case ["models", "list"]:
            output = try consume(&nextLocal, fallback: local)
        default: output = Data()
        }
        return CommandResult(exitCode: 0, standardOutput: output, standardError: Data())
    }

    private func consume(_ response: inout Response?, fallback: Data) throws -> Data {
        let selected = response ?? .data(fallback)
        response = nil
        switch selected {
        case .data(let data): return data
        case .failure: throw ServiceFakeError.sourceFailed
        }
    }
}

private enum ServiceFakeError: Error { case sourceFailed }

private actor ServiceAsyncGate {
    private var started = false
    private var released = false
    private var cancelled = false
    private var waitContinuation: CheckedContinuation<Void, any Error>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        started = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if released {
                    continuation.resume()
                } else {
                    waitContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        waitContinuation?.resume()
        waitContinuation = nil
    }

    private func cancel() {
        cancelled = true
        waitContinuation?.resume(throwing: CancellationError())
        waitContinuation = nil
    }
}

private final class ServiceOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = Data()

    var data: Data { lock.withLock { recorded } }

    func record(_ chunk: ProcessOutputChunk) {
        lock.withLock { recorded.append(chunk.data) }
    }
}

private actor ServiceConfigStoreFake: ProviderConfigManaging {
    private var draft: ProviderConfigDraft
    private(set) var saveCount = 0
    private var blockedSaveGate: ServiceAsyncGate?

    init(selection: ProviderModelSelection) {
        draft = ProviderConfigDraft(sourceRevision: "fixture", original: selection, selection: selection)
    }

    func load() async throws -> ProviderConfigDraft { draft }

    func blockNextSave() { blockedSaveGate = ServiceAsyncGate() }
    func waitUntilSaveBlocked() async { await blockedSaveGate?.waitUntilStarted() }
    func releaseBlockedSave() async { await blockedSaveGate?.release() }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        saveCount += 1
        if let blockedSaveGate {
            try await blockedSaveGate.wait()
        }
        self.draft = ProviderConfigDraft(
            sourceRevision: "saved",
            original: draft.selection,
            selection: draft.selection
        )
        return ProviderConfigSaveResult(draft: self.draft, restartRequired: true)
    }
}

private actor ServiceTelemetryFake: TelemetrySource {
    private let daemon: DaemonState
    private let loadedModels: LoadedModelsState
    private var daemonReadShouldFail = false

    init(daemon: DaemonState, loadedModels: LoadedModelsState) {
        self.daemon = daemon
        self.loadedModels = loadedModels
    }

    func failNextDaemonRead() { daemonReadShouldFail = true }

    func readDaemonState() async throws -> DaemonState {
        if daemonReadShouldFail {
            daemonReadShouldFail = false
            throw ServiceFakeError.sourceFailed
        }
        return daemon
    }
    func readLoadedModels() async throws -> LoadedModelsState { loadedModels }
    func readStatus() async throws -> StatusSnapshot { StatusSnapshot() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { [] }
}

private func daemon(currentModel: String, inferenceActive: Bool) -> DaemonState {
    DaemonState(
        schema: 1,
        version: "0.8.15",
        currentModel: currentModel,
        warmModels: [],
        stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
        trust: TrustState(level: "local", status: "online", reason: "", receivedAt: 0),
        capacity: MemoryCapacity(totalMemoryGB: 32, gpuMemoryActiveGB: 0, gpuMemoryCacheGB: 0),
        slots: [],
        inferenceActive: inferenceActive,
        startedAt: 0,
        writtenAt: 0,
        pid: 1,
        processIdentity: ProcessIdentity(pid: 1, startTimeMicros: 1)
    )
}

private let catalogJSON = Data(#"""
[
  {"id":"gpt-oss-20b","display_name":"GPT OSS 20B","family":"gpt-oss","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true},
  {"id":"gemma-4-26b-qat-4bit","display_name":"Gemma 4 26B","family":"gemma-4","model_type":"llm","capabilities":["text"],"size_gb":15.2,"min_ram_gb":24,"active":true},
  {"id":"qwen3-8b","display_name":"Qwen3 8B","family":"qwen3","model_type":"llm","capabilities":["text"],"size_gb":5.0,"min_ram_gb":8,"active":true}
]
"""#.utf8)

private let localJSON = Data(#"""
{
  "cache_directory":"/inert/cache",
  "filtered_by_config":false,
  "models":[
    {"id":"gpt-oss-20b","model_type":"llm","size_bytes":13421772800,"estimated_memory_gb":15.0},
    {"id":"gemma-4-26b-qat-4bit","model_type":"llm","size_bytes":16320875724,"estimated_memory_gb":18.5}
  ]
}
"""#.utf8)

private let localGemmaOnlyJSON = Data(#"""
{
  "cache_directory":"/inert/cache",
  "filtered_by_config":false,
  "models":[
    {"id":"gemma-4-26b-qat-4bit","model_type":"llm","size_bytes":16320875724,"estimated_memory_gb":18.5}
  ]
}
"""#.utf8)

private let catalogWithExtraModelJSON = Data(#"""
[
  {"id":"gpt-oss-20b","display_name":"GPT OSS 20B","family":"gpt-oss","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true},
  {"id":"gemma-4-26b-qat-4bit","display_name":"Gemma 4 26B","family":"gemma-4","model_type":"llm","capabilities":["text"],"size_gb":15.2,"min_ram_gb":24,"active":true},
  {"id":"qwen3-8b","display_name":"Qwen3 8B","family":"qwen3","model_type":"llm","capabilities":["text"],"size_gb":5.0,"min_ram_gb":8,"active":true},
  {"id":"llama-3-8b","display_name":"Llama 3 8B","family":"llama-3","model_type":"llm","capabilities":["text"],"size_gb":5.0,"min_ram_gb":8,"active":true}
]
"""#.utf8)

private let duplicateCatalogIDJSON = Data(#"""
[
  {"id":"gpt-oss-20b","display_name":"GPT OSS Primary","family":"gpt-oss","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true},
  {"id":"gpt-oss-20b","display_name":"GPT OSS Duplicate","family":"gpt-oss-duplicate","model_type":"llm","capabilities":["text"],"size_gb":12.5,"min_ram_gb":16,"active":true}
]
"""#.utf8)
