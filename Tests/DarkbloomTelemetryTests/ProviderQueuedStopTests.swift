import Foundation
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Provider queued stop")
@MainActor
struct ProviderQueuedStopTests {
    @Test("active work stays queued and dispatches only after two idle reads")
    func waitsForFreshIdleAndStops() async {
        let controller = QueuedStopController(risks: [.active, .idle, .idle])
        let store = ProviderControlStore(
            controller: controller,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            queuedStopWait: { try await Task.sleep(for: .milliseconds(1)) }
        )

        store.queueStopWhenIdle()
        #expect(await waitUntil { store.queuedStopState != nil })
        #expect(await waitUntil { store.queuedStopState == nil && store.operation == .idle })
        #expect(await controller.executedActions == [.stop])
        #expect(await controller.activityReadCount == 3)
    }

    @Test("unknown and stale activity never authorizes a stop")
    func unknownDoesNotCountAsIdle() async {
        let controller = QueuedStopController(risks: [.unknown("private detail")])
        let store = ProviderControlStore(
            controller: controller,
            queuedStopWait: { try await Task.sleep(for: .milliseconds(1)) }
        )

        store.queueStopWhenIdle()
        #expect(await waitUntil {
            store.queuedStopState?.lastObservation == .unknown
        })
        #expect(await controller.executedActions.isEmpty)
        store.cancelQueuedStop()
        #expect(store.queuedStopState == nil)
    }

    @Test("a final activity race keeps the queue pending")
    func finalIdleRecheckRacesWithNewWork() async {
        let controller = QueuedStopController(risks: [.idle, .active])
        let store = ProviderControlStore(
            controller: controller,
            queuedStopWait: { try await Task.sleep(for: .milliseconds(1)) }
        )

        store.queueStopWhenIdle()
        #expect(await waitUntil {
            store.queuedStopState?.lastObservation == .active
        })
        #expect(await controller.executedActions.isEmpty)
        store.cancelQueuedStop()
    }

    @Test("queued stop is visible and cancellable without leaving a stop command")
    func pendingCanBeCancelled() async throws {
        let controller = QueuedStopController(risks: [.active])
        let gate = AsyncStopGate()
        let store = ProviderControlStore(
            controller: controller,
            queuedStopWait: { try await gate.wait() }
        )

        store.queueStopWhenIdle()
        #expect(await waitUntil {
            store.queuedStopState?.lastObservation == .active
        })
        let pending = try #require(store.queuedStopState)
        #expect(pending.phase == .waiting)
        #expect(ProviderQueuedStopPresentation.make(state: pending).canCancel)

        store.cancelQueuedStop()
        await gate.release()
        #expect(await waitUntil { store.queuedStopState == nil })
        #expect(await controller.executedActions.isEmpty)
    }

    @Test("queued stop reserves lifecycle mutation and blocks a conflicting start")
    func blocksConflictingLifecycleAction() async {
        let controller = QueuedStopController(risks: [.active])
        let gate = AsyncStopGate()
        let store = ProviderControlStore(
            controller: controller,
            queuedStopWait: { try await gate.wait() }
        )

        store.queueStopWhenIdle()
        #expect(await waitUntil { store.queuedStopState != nil })
        await store.request(.start)
        #expect(await controller.executedActions.isEmpty)
        #expect(store.queuedStopState != nil)
        store.cancelQueuedStop()
        await gate.release()
    }

    @Test("a read-only refresh does not cancel the queued stop")
    func refreshOverlapPreservesQueue() async {
        let refreshGate = AsyncStopGate()
        let queueGate = AsyncStopGate()
        let controller = QueuedStopController(
            risks: [.active],
            refreshGate: refreshGate
        )
        let store = ProviderControlStore(
            controller: controller,
            queuedStopWait: { try await queueGate.wait() }
        )

        store.queueStopWhenIdle()
        #expect(await waitUntil {
            store.queuedStopState?.lastObservation == .active
        })

        let refresh = Task { @MainActor in await store.refresh() }
        #expect(await waitUntil { store.operation == .refreshing })
        #expect(store.queuedStopState != nil)

        await refreshGate.release()
        await refresh.value
        #expect(store.queuedStopState != nil)
        store.cancelQueuedStop()
        await queueGate.release()
        #expect(await waitUntil { store.queuedStopState == nil })
        #expect(await controller.executedActions.isEmpty)
    }

    @Test("queued stop copy is generic and explains in-memory lifetime")
    func pendingCopy() {
        let state = ProviderQueuedStopState(
            requestedAt: Date(timeIntervalSince1970: 1_750_000_000),
            lastCheckedAt: Date(timeIntervalSince1970: 1_750_000_000),
            lastObservation: .active
        )
        let presentation = ProviderQueuedStopPresentation.make(
            state: state,
            now: Date(timeIntervalSince1970: 1_750_000_001)
        )
        #expect(presentation.title == "Waiting for current work to finish")
        #expect(presentation.detail.contains("Keep Darkbloom Control open"))
        #expect(!presentation.detail.contains("private"))
        #expect(presentation.canCancel)
    }
}

@MainActor
private func waitUntil(
    // Native rendering tests share the main actor and may hold it for several seconds.
    timeout: Duration = .seconds(10),
    _ predicate: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !predicate() {
        guard clock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

private actor AsyncStopGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor QueuedStopController: ProviderControlling {
    private var risks: [ProviderActivityRisk]
    private let refreshGate: AsyncStopGate?
    private(set) var executedActions: [ProviderLifecycleAction] = []
    private(set) var activityReadCount = 0

    init(
        risks: [ProviderActivityRisk],
        refreshGate: AsyncStopGate? = nil
    ) {
        self.risks = risks
        self.refreshGate = refreshGate
    }

    func refresh() async throws -> ProviderControlSnapshot {
        try await refreshGate?.wait()
        return queuedStopSnapshot()
    }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        throw TestError.unexpectedMutation
    }

    func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {
        throw TestError.unexpectedMutation
    }

    func delete(_ localModelID: String) async throws {
        throw TestError.unexpectedMutation
    }

    func activityRisk() async -> ProviderActivityRisk {
        activityReadCount += 1
        return risks.isEmpty ? .unknown("no more activity samples") : risks.removeFirst()
    }

    func execute(
        _ action: ProviderLifecycleAction,
        enabledModels: [String]
    ) async throws {
        guard action == .stop else { throw TestError.unexpectedMutation }
        executedActions.append(action)
    }

    private func queuedStopSnapshot() -> ProviderControlSnapshot {
        let selection = ProviderModelSelection(enabled: ["saved-model"], preloaded: [])
        let draft = ProviderConfigDraft(
            sourceRevision: "queued-stop-test",
            original: selection,
            selection: selection
        )
        return ProviderControlSnapshot(
            inventory: ModelInventory(myCatalog: [], available: [], issues: []),
            draft: draft,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }
}

private enum TestError: Error {
    case unexpectedMutation
}
