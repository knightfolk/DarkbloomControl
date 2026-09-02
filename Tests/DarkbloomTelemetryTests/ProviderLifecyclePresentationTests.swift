import DarkbloomTelemetry
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

    @Test("daemon telemetry takes precedence while status distinguishes a stopped provider")
    func derivesKnownRunningState() {
        #expect(ProviderLifecyclePresentation.providerKnownRunning(
            hasDaemonState: true,
            daemonStatus: "not running"
        ) == true)
        #expect(ProviderLifecyclePresentation.providerKnownRunning(
            hasDaemonState: false,
            daemonStatus: "running (pid 123, up 3m)"
        ) == true)
        #expect(ProviderLifecyclePresentation.providerKnownRunning(
            hasDaemonState: false,
            daemonStatus: "not running"
        ) == false)
        #expect(ProviderLifecyclePresentation.providerKnownRunning(
            hasDaemonState: false,
            daemonStatus: nil
        ) == nil)
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
