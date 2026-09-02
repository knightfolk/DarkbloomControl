import DarkbloomTelemetry
import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Provider lifecycle presentation")
struct ProviderLifecyclePresentationTests {
    @Test("running provider offers stop and restart")
    func runningActions() {
        let value = ProviderLifecyclePresentation.make(
            providerKnownRunning: true,
            operation: .idle,
            enabledModels: ["gemma-4-26b-qat-4bit"]
        )

        #expect(!value.canStart)
        #expect(value.canStop)
        #expect(value.canRestart)
        #expect(value.unavailableReason == nil)
    }

    @Test("stopped provider needs a saved enabled model")
    func startRequirements() {
        let missingModel = ProviderLifecyclePresentation.make(
            providerKnownRunning: false,
            operation: .idle,
            enabledModels: []
        )
        let enabledModel = ProviderLifecyclePresentation.make(
            providerKnownRunning: false,
            operation: .idle,
            enabledModels: ["gpt-oss"]
        )

        #expect(!missingModel.canStart)
        #expect(!missingModel.canStop)
        #expect(!missingModel.canRestart)
        #expect(missingModel.unavailableReason == "Start requires at least one saved enabled model")
        #expect(enabledModel.canStart)
        #expect(!enabledModel.canStop)
        #expect(!enabledModel.canRestart)
        #expect(enabledModel.unavailableReason == nil)
    }

    @Test("unknown provider state disables every action with an explanation")
    func unknownState() {
        let value = ProviderLifecyclePresentation.make(
            providerKnownRunning: nil,
            operation: .idle,
            enabledModels: ["gpt-oss"]
        )

        #expect(!value.canStart)
        #expect(!value.canStop)
        #expect(!value.canRestart)
        #expect(value.unavailableReason == "Provider state is unavailable")
    }

    @Test("fresh stopped status overrides stale last-good daemon state")
    func freshStoppedStatusWins() {
        let daemonCases: [(
            SourceAvailability<DaemonState>,
            ProviderControlSourceState
        )] = [
            (
                .stale(
                    value: daemonState(),
                    capturedAt: now,
                    reason: "Provider activity is stale"
                ),
                .stale("Provider activity is stale")
            ),
            (
                .unavailable(reason: "Provider activity is unavailable"),
                .unavailable("Provider activity is unavailable")
            ),
        ]

        for (daemon, controlDaemon) in daemonCases {
            let input = lifecycleInput(
                daemon: daemon,
                daemonStatus: .available(value: status(daemon: "not running"), capturedAt: now),
                controlDaemon: controlDaemon
            )

            #expect(input.providerKnownRunning == false)
            let value = ProviderLifecyclePresentation.make(
                sourceInput: input,
                operation: .idle,
                enabledModels: ["gpt-oss"]
            )
            #expect(value.canStart)
            #expect(!value.canStop)
            #expect(!value.canRestart)
        }
    }

    @Test("fresh daemon evidence wins over stale stopped status")
    func freshDaemonWinsOverStaleStatus() {
        let input = lifecycleInput(
            daemon: .available(value: daemonState(), capturedAt: now),
            daemonStatus: .stale(
                value: status(daemon: "not running"),
                capturedAt: now,
                reason: "Darkbloom status is stale"
            ),
            controlDaemon: .fresh
        )

        #expect(input.providerKnownRunning == true)
    }

    @Test("future and unavailable observations remain unverifiable")
    func futureAndUnknownDisableLifecycle() {
        let input = lifecycleInput(
            daemon: .stale(
                value: daemonState(),
                capturedAt: now,
                reason: "Provider activity timestamp is in the future"
            ),
            daemonStatus: .unavailable(reason: "Darkbloom status is unavailable"),
            controlDaemon: .stale("Provider activity timestamp is in the future")
        )

        #expect(input.providerKnownRunning == nil)
        let value = ProviderLifecyclePresentation.make(
            sourceInput: input,
            operation: .idle,
            enabledModels: ["gpt-oss"]
        )
        #expect(!value.canStart)
        #expect(!value.canStop)
        #expect(!value.canRestart)
        #expect(value.unavailableReason == "Provider state is unavailable")
    }

    @Test("fresh control daemon state can establish running when monitor reads are unavailable")
    func freshControlStateEstablishesRunning() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh,
            controlCapturedAt: now,
            currentTime: now
        )

        #expect(input.providerKnownRunning == true)
    }

    @Test("fresh control fallback remains valid at exactly ten seconds")
    func controlFreshnessBoundaryIsInclusive() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh,
            controlCapturedAt: now.addingTimeInterval(-10),
            currentTime: now
        )

        #expect(input.providerKnownRunning == true)
    }

    @Test("fresh control fallback expires just beyond ten seconds")
    func controlFreshnessExpires() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh,
            controlCapturedAt: now.addingTimeInterval(-10.001),
            currentTime: now
        )

        expectUnknownLifecycle(input)
    }

    @Test("future control capture cannot establish running")
    func futureControlCaptureIsUnknown() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh,
            controlCapturedAt: now.addingTimeInterval(0.001),
            currentTime: now
        )

        expectUnknownLifecycle(input)
    }

    @Test("non-finite control capture cannot establish running")
    func nonFiniteControlCaptureIsUnknown() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh,
            controlCapturedAt: Date(timeIntervalSince1970: .infinity),
            currentTime: now
        )

        expectUnknownLifecycle(input)
    }

    @Test("popup model pills require fresh daemon and loaded-model evidence")
    func modelPillsFailClosedOnResidencyFreshness() {
        let fresh = PopupModelSourceInput(
            daemonState: .available(value: daemonState(), capturedAt: now),
            loadedModels: .available(
                value: LoadedModelsState(schema: 1, models: [], updatedAt: now.timeIntervalSince1970),
                capturedAt: now
            ),
            status: .available(value: status(daemon: "running", enabled: "gpt-oss"), capturedAt: now)
        )
        let staleDaemon = PopupModelSourceInput(
            daemonState: .stale(value: daemonState(), capturedAt: now, reason: "stale"),
            loadedModels: fresh.loadedModels,
            status: fresh.status
        )
        let futureLoaded = PopupModelSourceInput(
            daemonState: fresh.daemonState,
            loadedModels: .stale(
                value: LoadedModelsState(schema: 1, models: [], updatedAt: now.timeIntervalSince1970 + 30),
                capturedAt: now,
                reason: "Loaded model state timestamp is in the future"
            ),
            status: fresh.status
        )

        #expect(PopupModelPresentation.make(input: fresh, controlSources: .allFresh) == .models([
            DashboardModel(name: "gpt-oss", state: .availableUnloaded),
        ]))
        #expect(PopupModelPresentation.make(input: staleDaemon, controlSources: .allFresh) == .unavailable)
        #expect(PopupModelPresentation.make(input: futureLoaded, controlSources: .allFresh) == .unavailable)
        #expect(PopupModelPresentation.make(
            input: fresh,
            controlSources: ProviderControlSourceStates(
                catalog: .fresh,
                localModels: .fresh,
                daemon: .fresh,
                loadedModels: .stale("Loaded model state is stale")
            )
        ) == .unavailable)
    }

    @Test("awaited Stop telemetry refresh makes Start available without relaunch")
    @MainActor
    func stopTransitionUsesRefreshedPresentation() async {
        let controller = InertStopTransitionController()
        var daemonAvailability: SourceAvailability<DaemonState> =
            .available(value: daemonState(), capturedAt: now)
        var statusAvailability: SourceAvailability<StatusSnapshot> =
            .available(value: status(daemon: "running"), capturedAt: now)
        let store = ProviderControlStore(
            controller: controller,
            refreshTelemetry: {
                daemonAvailability = .stale(
                    value: daemonState(),
                    capturedAt: now,
                    reason: "Provider activity is stale"
                )
                statusAvailability = .available(
                    value: status(daemon: "not running"),
                    capturedAt: now
                )
            }
        )
        await store.refresh()

        await store.request(.stop)

        #expect(await controller.executedActions == [.stop])
        #expect(store.snapshot?.sources.daemon == .stale("Provider activity is stale"))
        let value = ProviderLifecyclePresentation.make(
            sourceInput: lifecycleInput(
                daemon: daemonAvailability,
                daemonStatus: statusAvailability,
                controlDaemon: store.snapshot?.sources.daemon
            ),
            operation: store.operation,
            enabledModels: store.draft?.original.enabled ?? []
        )
        #expect(value.canStart)
        #expect(!value.canStop)
        #expect(!value.canRestart)
    }

    @Test("any in-flight provider operation disables every action")
    func disablesDuringOperations() {
        let operations: [ProviderOperation] = [
            .refreshing,
            .saving,
            .downloading("gpt-oss"),
            .deleting("gpt-oss"),
            .lifecycle(.start),
            .lifecycle(.stop),
            .lifecycle(.restart),
        ]

        for operation in operations {
            let value = ProviderLifecyclePresentation.make(
                providerKnownRunning: true,
                operation: operation,
                enabledModels: ["gpt-oss"]
            )
            #expect(!value.canStart)
            #expect(!value.canStop)
            #expect(!value.canRestart)
            #expect(value.unavailableReason == "Another provider action is in progress")
        }
    }

    @Test("controls expose exact symbols labels and identifiers")
    func exactControlMetadata() {
        #expect(ProviderLifecycleControl.start.systemImage == "play.fill")
        #expect(ProviderLifecycleControl.start.accessibilityLabel == "Start Darkbloom provider")
        #expect(ProviderLifecycleControl.start.accessibilityIdentifier == "provider.start")

        #expect(ProviderLifecycleControl.stop.systemImage == "stop.fill")
        #expect(ProviderLifecycleControl.stop.accessibilityLabel == "Stop Darkbloom provider")
        #expect(ProviderLifecycleControl.stop.accessibilityIdentifier == "provider.stop")

        #expect(ProviderLifecycleControl.restart.systemImage == "arrow.clockwise")
        #expect(ProviderLifecycleControl.restart.accessibilityLabel == "Restart Darkbloom provider")
        #expect(ProviderLifecycleControl.restart.accessibilityIdentifier == "provider.restart")

        #expect(ProviderLifecycleControl.start.isActive(in: .lifecycle(.start)))
        #expect(ProviderLifecycleControl.stop.isActive(in: .lifecycle(.stop)))
        #expect(ProviderLifecycleControl.restart.isActive(in: .lifecycle(.restart)))
        #expect(!ProviderLifecycleControl.restart.isActive(in: .downloading("gpt-oss")))
    }

    @Test("active warning names the interrupting action")
    func activeWarningCopy() {
        let stop = LifecycleConfirmationPresentation.make(.stop(.active))
        let restart = LifecycleConfirmationPresentation.make(.restart(.active))

        #expect(stop.title == "Customer work may be interrupted")
        #expect(stop.body == "A customer job is currently running. Continuing will interrupt it.")
        #expect(stop.confirmLabel == "Stop Anyway")
        #expect(restart.title == "Customer work may be interrupted")
        #expect(restart.body == "A customer job is currently running. Continuing will interrupt it.")
        #expect(restart.confirmLabel == "Restart Anyway")
    }

    @Test("unknown warning uses bounded generic copy")
    func unknownWarningCopy() {
        let value = LifecycleConfirmationPresentation.make(
            .restart(.unknown("private provider detail"))
        )

        #expect(value.title == "Customer work may be interrupted")
        #expect(value.body == "Darkbloom Monitor cannot confirm whether a customer job is running. Continuing may interrupt customer work.")
        #expect(value.confirmLabel == "Continue Anyway")
        #expect(!value.body.contains("private provider detail"))
    }

    @Test("system dismissal cancels pending confirmation exactly once")
    @MainActor
    func systemDismissalCancelsOnce() async {
        let coordinator = LifecycleConfirmationDismissalCoordinator()
        let state = ConfirmationDismissalState()

        state.scheduleCancellation(on: coordinator)
        state.scheduleCancellation(on: coordinator)
        await drainScheduledCancellation()

        #expect(state.cancellationCount == 1)
        #expect(!state.pending)

        state.scheduleCancellation(on: coordinator)
        await drainScheduledCancellation()
        #expect(state.cancellationCount == 1)
    }

    @Test("explicit cancel is not duplicated by binding teardown")
    @MainActor
    func explicitCancelRunsOnce() async {
        let coordinator = LifecycleConfirmationDismissalCoordinator()
        let state = ConfirmationDismissalState()

        state.scheduleCancellation(on: coordinator)
        state.cancel()
        await drainScheduledCancellation()

        #expect(state.cancellationCount == 1)
    }

    @Test("scheduled system dismissal survives coordinator release")
    @MainActor
    func systemDismissalSurvivesRelease() async {
        var coordinator: LifecycleConfirmationDismissalCoordinator? =
            LifecycleConfirmationDismissalCoordinator()
        let state = ConfirmationDismissalState()

        state.scheduleCancellation(on: coordinator!)
        coordinator = nil
        await drainScheduledCancellation()

        #expect(state.cancellationCount == 1)
        #expect(!state.pending)
    }

    @Test("destructive action suppresses an earlier binding teardown")
    @MainActor
    func destructiveActionWinsAfterDismissal() async {
        let coordinator = LifecycleConfirmationDismissalCoordinator()
        let state = ConfirmationDismissalState()

        state.scheduleCancellation(on: coordinator)
        coordinator.beginConfirmation()
        await drainScheduledCancellation()

        #expect(state.cancellationCount == 0)
        #expect(state.pending)

        state.completeConfirmation()
        coordinator.endConfirmation()
    }

    @Test("destructive action suppresses a later binding teardown")
    @MainActor
    func destructiveActionWinsBeforeDismissal() async {
        let coordinator = LifecycleConfirmationDismissalCoordinator()
        let state = ConfirmationDismissalState()

        coordinator.beginConfirmation()
        state.scheduleCancellation(on: coordinator)
        await drainScheduledCancellation()

        #expect(state.cancellationCount == 0)
        #expect(state.pending)

        state.completeConfirmation()
        coordinator.endConfirmation()
    }

    @MainActor
    private func drainScheduledCancellation() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

private let now = Date(timeIntervalSince1970: 1_788_282_000)

private func lifecycleInput(
    daemon: SourceAvailability<DaemonState>,
    daemonStatus: SourceAvailability<StatusSnapshot>,
    controlDaemon: ProviderControlSourceState?,
    controlCapturedAt: Date? = now,
    currentTime: Date = now
) -> ProviderLifecycleSourceInput {
    ProviderLifecycleSourceInput(
        daemonState: daemon,
        status: daemonStatus,
        controlDaemonState: controlDaemon,
        controlCapturedAt: controlCapturedAt,
        currentTime: currentTime
    )
}

private func expectUnknownLifecycle(_ input: ProviderLifecycleSourceInput) {
    #expect(input.providerKnownRunning == nil)
    let value = ProviderLifecyclePresentation.make(
        sourceInput: input,
        operation: .idle,
        enabledModels: ["gpt-oss"]
    )
    #expect(!value.canStart)
    #expect(!value.canStop)
    #expect(!value.canRestart)
    #expect(value.unavailableReason == "Provider state is unavailable")
}

private func status(daemon: String?, enabled: String? = nil) -> StatusSnapshot {
    var value = StatusSnapshot()
    value.daemon = daemon
    value.enabledModelFilter = enabled
    return value
}

private func daemonState() -> DaemonState {
    DaemonState(
        schema: 1,
        version: "test",
        currentModel: "",
        warmModels: [],
        stats: ProviderStats(tokensGenerated: 0, requestsServed: 0, usageGaps: 0),
        trust: TrustState(level: "local", status: "online", reason: "test", receivedAt: 0),
        capacity: MemoryCapacity(totalMemoryGB: 64, gpuMemoryActiveGB: 0, gpuMemoryCacheGB: 0),
        slots: [],
        inferenceActive: false,
        startedAt: now.timeIntervalSince1970 - 60,
        writtenAt: now.timeIntervalSince1970,
        pid: 123,
        processIdentity: ProcessIdentity(pid: 123, startTimeMicros: 1)
    )
}

private actor InertStopTransitionController: ProviderControlling {
    private(set) var executedActions: [ProviderLifecycleAction] = []
    private var didExecute = false

    func refresh() async throws -> ProviderControlSnapshot {
        let selection = ProviderModelSelection(enabled: ["gpt-oss"], preloaded: [])
        let draft = ProviderConfigDraft(
            sourceRevision: "stop-transition",
            original: selection,
            selection: selection
        )
        return ProviderControlSnapshot(
            inventory: ModelInventoryBuilder.build(
                catalog: [],
                local: [],
                selection: selection,
                daemon: nil,
                loadedModels: []
            ),
            draft: draft,
            capturedAt: now,
            sources: didExecute
                ? ProviderControlSourceStates(
                    catalog: .fresh,
                    localModels: .fresh,
                    daemon: .stale("Provider activity is stale"),
                    loadedModels: .stale("Loaded model state is stale")
                )
                : .allFresh
        )
    }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        ProviderConfigSaveResult(draft: draft, restartRequired: false)
    }

    func download(
        _ modelID: String,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws {}

    func delete(_ localModelID: String) async throws {}
    func activityRisk() async -> ProviderActivityRisk { .idle }

    func execute(
        _ action: ProviderLifecycleAction,
        enabledModels: [String]
    ) async throws {
        executedActions.append(action)
        didExecute = true
    }
}

private extension ProviderControlSourceStates {
    static let allFresh = ProviderControlSourceStates(
        catalog: .fresh,
        localModels: .fresh,
        daemon: .fresh,
        loadedModels: .fresh
    )
}

@MainActor
private final class ConfirmationDismissalState {
    private(set) var pending = true
    private(set) var cancellationCount = 0

    func scheduleCancellation(on coordinator: LifecycleConfirmationDismissalCoordinator) {
        coordinator.scheduleCancellation(
            isPending: { self.pending },
            cancel: { self.cancel() }
        )
    }

    func cancel() {
        cancellationCount += 1
        pending = false
    }

    func completeConfirmation() {
        pending = false
    }
}
