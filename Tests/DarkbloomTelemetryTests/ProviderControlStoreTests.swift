import AppKit
import DarkbloomTelemetry
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomMonitor

@Suite("Provider control store")
@MainActor
struct ProviderControlStoreTests {
    @Test("draft toggles are independent stable and valid only when saved")
    func stagesIndependentSelections() async throws {
        let controller = FakeProviderController.fixture()
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        store.setEnabled(true, modelID: "second-model")
        store.setEnabled(true, modelID: "second-model")
        #expect(store.draft?.selection.enabled == ["saved-model", "second-model"])
        #expect(store.draft?.selection.preloaded == [])
        #expect(store.canSave)

        store.setPreloaded(true, modelID: "second-model")
        store.setEnabled(false, modelID: "second-model")
        #expect(store.draft?.selection.enabled == ["saved-model"])
        #expect(store.draft?.selection.preloaded == ["second-model"])
        #expect(!store.canSave)
        #expect(store.draftValidationMessage == "Enable 'second-model' or remove it from preload")

        store.setEnabled(true, modelID: "second-model")
        store.setPreloaded(false, modelID: "second-model")
        #expect(store.draft?.selection.enabled == ["saved-model", "second-model"])
        #expect(store.draft?.selection.preloaded == [])
        #expect(store.canSave)
    }

    @Test("save promotes staged selectors and retains restart required state")
    func savesDraft() async throws {
        let controller = FakeProviderController.fixture()
        let store = ProviderControlStore(controller: controller)
        await store.refresh()
        store.setEnabled(true, modelID: "second-model")

        await store.save()

        #expect(store.draft?.original.enabled == ["saved-model", "second-model"])
        #expect(store.draft?.selection.enabled == ["saved-model", "second-model"])
        #expect(store.restartRequired)
        #expect(!store.canSave)
        #expect(await controller.saveCount == 1)
    }

    @Test("download and delete never stage enable or preload")
    func keepsModelMutationsSeparate() async throws {
        let controller = FakeProviderController.fixture()
        let store = ProviderControlStore(controller: controller)
        await store.refresh()
        store.setEnabled(true, modelID: "second-model")
        let before = store.draft?.selection

        await store.download("available-model")
        #expect(store.draft?.selection == before)

        await store.delete("second-model")
        #expect(store.draft?.selection == before)
        #expect(await controller.downloadedModels == ["available-model"])
        #expect(await controller.deletedModels == ["second-model"])
    }

    @Test("download failures use action-specific text without controller details")
    func mapsDownloadError() async throws {
        let controller = FakeProviderController.fixture(
            downloadFailure: .secret("auth_token=do-not-display /Users/alice/private")
        )
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        await store.download("available-model")

        #expect(store.errorMessage == "Could not download 'available-model'.")
        #expect(!store.errorMessage.orEmpty.contains("do-not-display"))
        #expect(store.snapshot != nil)
    }

    @Test("a running download rejects overlap and cancellation reaches the controller")
    func serializesAndCancelsOperations() async throws {
        let controller = FakeProviderController.fixture(blockDownload: true)
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        let download = Task { await store.download("available-model") }
        await controller.waitUntilDownloadStarts()
        #expect(store.operation == .downloading("available-model"))

        await store.delete("second-model")
        #expect(await controller.deletedModels.isEmpty)
        #expect(store.operation == .downloading("available-model"))

        store.cancelCurrentOperation()
        await download.value
        #expect(store.operation == .idle)
        #expect(await controller.downloadCancellationCount == 1)
        #expect(store.errorMessage == nil)
    }

    @Test("caller cancellation is propagated to the controller")
    func propagatesCallerCancellation() async throws {
        let controller = FakeProviderController.fixture(blockDownload: true)
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        let download = Task { await store.download("available-model") }
        await controller.waitUntilDownloadStarts()
        download.cancel()
        await download.value

        #expect(await controller.downloadCancellationCount == 1)
        #expect(store.operation == .idle)
    }

    @Test("download progress publishes only a sanitized bounded latest line")
    func sanitizesProgress() async throws {
        let chunks = [
            ProcessOutputChunk(
                destination: .standardOutput,
                data: Data("\u{001B}[31mDownloading 42%\u{001B}[0m\r".utf8)
            ),
            ProcessOutputChunk(
                destination: .standardError,
                data: Data("auth_token=super-secret /Users/alice/private.bin\n".utf8)
            ),
        ]
        let controller = FakeProviderController.fixture(downloadChunks: chunks)
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        await store.download("available-model")

        let progress = try #require(store.latestDownloadProgressLine)
        #expect(progress == "auth_token=<redacted> ~/private.bin")
        #expect(!progress.contains("super-secret"))
        #expect(!progress.contains("\u{001B}"))
        #expect(progress.count <= 200)
    }

    @Test("a failed refresh retains the last good snapshot and maps a secret error")
    func retainsLastGoodSnapshot() async throws {
        let controller = FakeProviderController.fixture()
        let store = ProviderControlStore(controller: controller)
        await store.refresh()
        let lastGood = try #require(store.snapshot)
        await controller.failRefresh(with: .secret("auth_token=do-not-display"))

        await store.refresh()

        #expect(store.snapshot == lastGood)
        #expect(store.draft == lastGood.draft)
        #expect(store.errorMessage == "Could not refresh model controls.")
        #expect(!store.errorMessage.orEmpty.contains("do-not-display"))
    }

    @Test("active restart requires confirmation but remains executable")
    func confirmsActiveRestart() async throws {
        let controller = FakeProviderController.fixture(activityRisks: [.active, .active])
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        await store.request(.restart)
        #expect(store.pendingConfirmation == .restart(.active))
        #expect(await controller.executedActions.isEmpty)

        await store.confirmPendingLifecycle()
        #expect(await controller.executedActions.map(\.action) == [.restart])
        #expect(await controller.activityReadCount == 2)
        #expect(store.pendingConfirmation == nil)
    }

    @Test("unknown stop requires confirmation and the override executes after a final read")
    func confirmsUnknownStop() async throws {
        let controller = FakeProviderController.fixture(activityRisks: [
            .unknown("secret state detail"),
            .unknown("different secret detail"),
        ])
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        await store.request(.stop)
        #expect(store.pendingConfirmation == .stop(.unknown("secret state detail")))

        await store.confirmPendingLifecycle()
        #expect(await controller.executedActions.map(\.action) == [.stop])
        #expect(await controller.activityReadCount == 2)
    }

    @Test("idle lifecycle runs only after an immediate second idle read")
    func doubleChecksIdle() async throws {
        let controller = FakeProviderController.fixture(activityRisks: [.idle, .idle])
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        await store.request(.stop)

        #expect(await controller.executedActions.map(\.action) == [.stop])
        #expect(await controller.activityReadCount == 2)
        #expect(store.pendingConfirmation == nil)
    }

    @Test("activity changing after idle warns then the override performs a final read")
    func warnsOnActivityRace() async throws {
        let controller = FakeProviderController.fixture(activityRisks: [
            .idle,
            .active,
            .unknown("Provider activity is unavailable"),
        ])
        let store = ProviderControlStore(controller: controller)
        await store.refresh()

        await store.request(.restart)
        #expect(store.pendingConfirmation == .restart(.active))
        #expect(await controller.executedActions.isEmpty)

        await store.confirmPendingLifecycle()
        #expect(await controller.executedActions.map(\.action) == [.restart])
        #expect(await controller.activityReadCount == 3)
    }

    @Test("cancelling a lifecycle warning performs no command")
    func cancelsConfirmation() async throws {
        let controller = FakeProviderController.fixture(activityRisks: [.active])
        let store = ProviderControlStore(controller: controller)
        await store.refresh()
        await store.request(.stop)

        store.cancelPendingLifecycle()

        #expect(store.pendingConfirmation == nil)
        #expect(await controller.executedActions.isEmpty)
    }

    @Test("start skips impact reads and passes saved selectors not staged selectors")
    func startsWithSavedSelection() async throws {
        let controller = FakeProviderController.fixture(activityRisks: [.active])
        let store = ProviderControlStore(controller: controller)
        await store.refresh()
        store.setEnabled(true, modelID: "second-model")
        #expect(store.draft?.selection.enabled == ["saved-model", "second-model"])

        await store.request(.start)

        let execution = try #require(await controller.executedActions.first)
        #expect(execution.action == .start)
        #expect(execution.enabledModels == ["saved-model"])
        #expect(await controller.activityReadCount == 0)
    }

    @Test("status controller retains the one store injected into both surfaces")
    func sharesOneInjectedStore() async throws {
        let telemetryService = TelemetryService(source: InertStoreTelemetrySource())
        let monitorStore = MonitorStore(
            service: telemetryService,
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000))
        )
        let controlStore = ProviderControlStore(controller: FakeProviderController.fixture())
        let statusController = StatusItemController(
            store: monitorStore,
            controlStore: controlStore
        )

        #expect(statusController.controlStore === controlStore)
    }

    @Test("app Settings waits for and then retains the exact shared store")
    func appSettingsUsesSharedStore() async throws {
        let controlStore = ProviderControlStore(controller: FakeProviderController.fixture())
        let waitingRoot = AppSettingsSceneRoot(controlStore: nil)
        let readyRoot = AppSettingsSceneRoot(controlStore: controlStore)
        let settingsRoot = ProviderSettingsRoot(controlStore: controlStore)
        let waitingHost = NSHostingController(rootView: waitingRoot)
        let waitingSize = waitingHost.sizeThatFits(in: NSSize(width: 800, height: 800))

        #expect(waitingRoot.controlStore == nil)
        #expect(waitingSize == NSSize(width: 420, height: 180))
        #expect(readyRoot.controlStore === controlStore)
        #expect(settingsRoot.controlStore === controlStore)
    }

    @Test("app and status-item Settings roots share one store identity")
    func allSettingsRootsShareIdentity() async throws {
        let telemetryService = TelemetryService(source: InertStoreTelemetrySource())
        let monitorStore = MonitorStore(
            service: telemetryService,
            initial: .unavailable(now: Date(timeIntervalSince1970: 1_750_000_000))
        )
        let controlStore = ProviderControlStore(controller: FakeProviderController.fixture())
        let appRoot = AppSettingsSceneRoot(controlStore: controlStore)
        let statusController = StatusItemController(
            store: monitorStore,
            controlStore: controlStore
        )

        let appIdentity = try #require(appRoot.controlStore.map(ObjectIdentifier.init))
        let statusIdentity = try #require(
            statusController.controlStore.map(ObjectIdentifier.init)
        )
        #expect(appIdentity == ObjectIdentifier(controlStore))
        #expect(statusIdentity == appIdentity)
    }
}

private actor FakeProviderController: ProviderControlling {
    enum Failure: Error, Sendable {
        case secret(String)
    }

    struct Execution: Equatable, Sendable {
        let action: ProviderLifecycleAction
        let enabledModels: [String]
    }

    private var currentSnapshot: ProviderControlSnapshot
    private var refreshFailure: Failure?
    private var activityRisks: [ProviderActivityRisk]
    private let blockDownload: Bool
    private let downloadChunks: [ProcessOutputChunk]
    private let downloadFailure: Failure?
    private var downloadStarted = false
    private(set) var downloadedModels: [String] = []
    private(set) var deletedModels: [String] = []
    private(set) var executedActions: [Execution] = []
    private(set) var saveCount = 0
    private(set) var activityReadCount = 0
    private(set) var downloadCancellationCount = 0

    static func fixture(
        activityRisks: [ProviderActivityRisk] = [],
        blockDownload: Bool = false,
        downloadChunks: [ProcessOutputChunk] = [],
        downloadFailure: Failure? = nil
    ) -> FakeProviderController {
        FakeProviderController(
            snapshot: fixtureSnapshot(),
            activityRisks: activityRisks,
            blockDownload: blockDownload,
            downloadChunks: downloadChunks,
            downloadFailure: downloadFailure
        )
    }

    init(
        snapshot: ProviderControlSnapshot,
        activityRisks: [ProviderActivityRisk],
        blockDownload: Bool,
        downloadChunks: [ProcessOutputChunk],
        downloadFailure: Failure?
    ) {
        currentSnapshot = snapshot
        self.activityRisks = activityRisks
        self.blockDownload = blockDownload
        self.downloadChunks = downloadChunks
        self.downloadFailure = downloadFailure
    }

    func refresh() async throws -> ProviderControlSnapshot {
        if let refreshFailure { throw refreshFailure }
        return currentSnapshot
    }

    func failRefresh(with failure: Failure) {
        refreshFailure = failure
    }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        saveCount += 1
        let savedDraft = ProviderConfigDraft(
            sourceRevision: "saved-revision-\(saveCount)",
            original: draft.selection,
            selection: draft.selection
        )
        currentSnapshot = ProviderControlSnapshot(
            inventory: currentSnapshot.inventory,
            draft: savedDraft,
            capturedAt: currentSnapshot.capturedAt.addingTimeInterval(1)
        )
        return ProviderConfigSaveResult(draft: savedDraft, restartRequired: true)
    }

    func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {
        downloadedModels.append(modelID)
        downloadChunks.forEach { onOutput?($0) }
        downloadStarted = true
        if let downloadFailure { throw downloadFailure }
        guard blockDownload else { return }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            downloadCancellationCount += 1
            throw CancellationError()
        }
    }

    func waitUntilDownloadStarts() async {
        while !downloadStarted {
            await Task.yield()
        }
    }

    func delete(_ localModelID: String) async throws {
        deletedModels.append(localModelID)
    }

    func activityRisk() async -> ProviderActivityRisk {
        activityReadCount += 1
        guard !activityRisks.isEmpty else { return .unknown("Provider activity is unavailable") }
        return activityRisks.removeFirst()
    }

    func execute(
        _ action: ProviderLifecycleAction,
        enabledModels: [String]
    ) async throws {
        executedActions.append(Execution(action: action, enabledModels: enabledModels))
    }
}

private func fixtureSnapshot() -> ProviderControlSnapshot {
    let draft = ProviderConfigDraft(
        sourceRevision: "fixture-revision",
        original: ProviderModelSelection(enabled: ["saved-model"], preloaded: []),
        selection: ProviderModelSelection(enabled: ["saved-model"], preloaded: [])
    )
    let catalog = [
        CatalogModel(
            id: "saved-model",
            displayName: "Saved Model",
            family: "saved",
            modelType: "text",
            capabilities: ["text"],
            sizeGB: 1,
            minimumRAMGB: 4,
            active: true
        ),
        CatalogModel(
            id: "second-model",
            displayName: "Second Model",
            family: "second",
            modelType: "text",
            capabilities: ["text"],
            sizeGB: 2,
            minimumRAMGB: 8,
            active: true
        ),
        CatalogModel(
            id: "available-model",
            displayName: "Available Model",
            family: "available",
            modelType: "text",
            capabilities: ["text"],
            sizeGB: 3,
            minimumRAMGB: 12,
            active: true
        ),
    ]
    let local = [
        LocalModel(id: "saved-model", modelType: "text", sizeBytes: 1, estimatedMemoryGB: nil),
        LocalModel(id: "second-model", modelType: "text", sizeBytes: 2, estimatedMemoryGB: nil),
    ]
    return ProviderControlSnapshot(
        inventory: ModelInventoryBuilder.build(
            catalog: catalog,
            local: local,
            selection: draft.selection,
            daemon: nil,
            loadedModels: []
        ),
        draft: draft,
        capturedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
}

private struct InertStoreTelemetrySource: TelemetrySource {
    func readDaemonState() async throws -> DaemonState { throw CancellationError() }
    func readLoadedModels() async throws -> LoadedModelsState { throw CancellationError() }
    func readStatus() async throws -> StatusSnapshot { throw CancellationError() }
    func readLegacyEvents(limit: Int) async throws -> [LogEvent] { throw CancellationError() }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
