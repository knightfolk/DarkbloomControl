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

    @Test("running provider disables restart when no saved enabled model exists")
    func runningActionsRequireSavedModelForRestart() {
        let value = ProviderLifecyclePresentation.make(
            providerKnownRunning: true,
            operation: .idle,
            enabledModels: []
        )

        #expect(!value.canStart)
        #expect(value.canStop)
        #expect(!value.canRestart)
        #expect(value.unavailableReason == "Start requires at least one saved enabled model")
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

    @Test("disabled lifecycle controls expose compact inline reason copy")
    func disabledControlsExposeInlineReason() {
        let unavailable = ProviderLifecyclePresentation.make(
            providerKnownRunning: nil,
            operation: .idle,
            enabledModels: ["gpt-oss"]
        )
        let available = ProviderLifecyclePresentation.make(
            providerKnownRunning: false,
            operation: .idle,
            enabledModels: ["gpt-oss"]
        )

        #expect(
            ProviderLifecycleUnavailableReasonPresentation.make(from: unavailable)
                == .init(message: "Provider state is unavailable")
        )
        #expect(
            ProviderLifecycleUnavailableReasonPresentation.make(from: unavailable)?.systemImage
                == "exclamationmark.triangle"
        )
        #expect(
            ProviderLifecycleUnavailableReasonPresentation.make(from: unavailable)?.accessibilityIdentifier
                == "provider.lifecycle.unavailable-reason"
        )
        #expect(ProviderLifecycleUnavailableReasonPresentation.make(from: available) == nil)
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
            controlDaemon: .fresh(evidenceAt: now)
        )

        #expect(input.providerKnownRunning == true)
    }

    @Test("fresh daemon evidence wins while the slower status command still says stopped")
    func freshDaemonWinsOverFreshStoppedStatus() {
        let input = lifecycleInput(
            daemon: .available(value: daemonState(), capturedAt: now),
            daemonStatus: .available(
                value: status(daemon: "not running"),
                capturedAt: now.addingTimeInterval(-1)
            ),
            controlDaemon: .fresh(evidenceAt: now)
        )

        #expect(input.providerKnownRunning == true)
        let value = ProviderLifecyclePresentation.make(
            sourceInput: input,
            operation: .idle,
            enabledModels: ["gpt-oss"]
        )
        #expect(!value.canStart)
        #expect(value.canStop)
        #expect(value.canRestart)
    }

    @Test("a newer stopped status wins over prior running evidence after shutdown")
    func newerStoppedStatusWinsAfterShutdown() {
        let input = lifecycleInput(
            daemon: .available(
                value: daemonState(),
                capturedAt: now.addingTimeInterval(-1)
            ),
            daemonStatus: .available(
                value: status(daemon: "not running"),
                capturedAt: now
            ),
            controlDaemon: .fresh(evidenceAt: now.addingTimeInterval(-1))
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

    @Test("lifecycle feedback explains work and failures in the popup")
    func lifecycleFeedback() {
        #expect(
            ProviderLifecycleFeedbackPresentation.make(
                operation: .lifecycle(.start),
                errorMessage: nil
            ) == .init(message: "Starting provider…", isError: false)
        )
        #expect(
            ProviderLifecycleFeedbackPresentation.make(
                operation: .idle,
                errorMessage: "Could not stop the provider."
            ) == .init(message: "Could not stop the provider.", isError: true)
        )
        #expect(
            ProviderLifecycleFeedbackPresentation.make(
                operation: .idle,
                errorMessage: nil
            ) == nil
        )
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
            controlDaemon: .fresh(evidenceAt: now),
            currentTime: now
        )

        #expect(input.providerKnownRunning == true)
    }

    @Test("nine-second-old control evidence expires from its source time")
    func controlEvidenceAgesFromSourceTime() {
        let evidenceAt = now.addingTimeInterval(-9)
        let initiallyFresh = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh(evidenceAt: evidenceAt),
            currentTime: now
        )
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh(evidenceAt: evidenceAt),
            currentTime: now.addingTimeInterval(1)
        )
        let expired = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh(evidenceAt: evidenceAt),
            currentTime: now.addingTimeInterval(1.001)
        )

        #expect(initiallyFresh.providerKnownRunning == true)
        #expect(input.providerKnownRunning == true)
        expectUnknownLifecycle(expired)
    }

    @Test("control evidence remains valid at exactly ten seconds")
    func controlFreshnessBoundaryIsInclusive() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh(evidenceAt: now.addingTimeInterval(-10)),
            currentTime: now
        )

        #expect(input.providerKnownRunning == true)
    }

    @Test("control evidence expires just beyond ten seconds")
    func controlFreshnessExpires() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh(evidenceAt: now.addingTimeInterval(-10.001)),
            currentTime: now
        )

        expectUnknownLifecycle(input)
    }

    @Test("future control evidence cannot establish running")
    func futureControlEvidenceIsUnknown() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh(evidenceAt: now.addingTimeInterval(0.001)),
            currentTime: now
        )

        expectUnknownLifecycle(input)
    }

    @Test("non-finite control evidence cannot establish running")
    func nonFiniteControlEvidenceIsUnknown() {
        let input = lifecycleInput(
            daemon: .unavailable(reason: "Waiting for daemon state"),
            daemonStatus: .unavailable(reason: "Waiting for Darkbloom status"),
            controlDaemon: .fresh(evidenceAt: Date(timeIntervalSince1970: .infinity)),
            currentTime: now
        )

        expectUnknownLifecycle(input)
    }

    @Test("popup model pills require fresh residency evidence")
    func modelPillsRequireFreshResidencyEvidence() {
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

        #expect(PopupModelPresentation.make(input: fresh, currentTime: now) == .models([
            DashboardModel(name: "gpt-oss", state: .availableUnloaded),
        ]))
        #expect(PopupModelPresentation.make(input: staleDaemon, currentTime: now) == .unavailable)
        #expect(PopupModelPresentation.make(input: futureLoaded, currentTime: now) == .unavailable)
    }

    @Test("fresh daemon model state is withheld when the loaded-model file is stale")
    func freshDaemonModelsAreWithheldWhenLoadedModelsAreStale() {
        let daemon = DaemonState(
            schema: 1,
            version: "test",
            currentModel: "gemma-4-26b-qat-4bit",
            warmModels: ["gemma-4-26b-qat-4bit"],
            stats: ProviderStats(tokensGenerated: 10, requestsServed: 1, usageGaps: 0),
            trust: TrustState(level: "local", status: "online", reason: "test", receivedAt: 0),
            capacity: MemoryCapacity(totalMemoryGB: 64, gpuMemoryActiveGB: 24, gpuMemoryCacheGB: 0),
            slots: [ModelSlot(
                model: "gemma-4-26b-qat-4bit",
                mtpEnabled: true,
                mtpActive: true,
                mtpReason: nil,
                kvBackend: "contiguous",
                requestedKVBackend: "auto"
            )],
            inferenceActive: true,
            startedAt: now.timeIntervalSince1970 - 60,
            writtenAt: now.timeIntervalSince1970,
            pid: 123,
            processIdentity: ProcessIdentity(pid: 123, startTimeMicros: 1)
        )
        let input = PopupModelSourceInput(
            daemonState: .available(value: daemon, capturedAt: now),
            loadedModels: .stale(
                value: LoadedModelsState(
                    schema: 1,
                    models: ["old-loaded-model"],
                    updatedAt: now.addingTimeInterval(-86_400).timeIntervalSince1970
                ),
                capturedAt: now,
                reason: "Loaded models are older than 10 seconds"
            ),
            status: .available(
                value: status(daemon: "running", enabled: "gemma-4-26b-qat-4bit,gpt-oss"),
                capturedAt: now
            )
        )
        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .unavailable)
    }

    @Test("popup keeps unchanged current-run loaded models visible")
    func unchangedCurrentRunLoadedModelsRemainVisible() {
        let daemon = DaemonState(
            schema: 1,
            version: "test",
            currentModel: "gemma",
            warmModels: ["gemma"],
            stats: ProviderStats(tokensGenerated: 10, requestsServed: 1, usageGaps: 0),
            trust: TrustState(level: "local", status: "online", reason: "test", receivedAt: 0),
            capacity: MemoryCapacity(totalMemoryGB: 64, gpuMemoryActiveGB: 24, gpuMemoryCacheGB: 0),
            slots: [],
            inferenceActive: false,
            startedAt: now.addingTimeInterval(-86_500).timeIntervalSince1970,
            writtenAt: now.timeIntervalSince1970,
            pid: 123,
            processIdentity: ProcessIdentity(pid: 123, startTimeMicros: 1)
        )
        let input = PopupModelSourceInput(
            daemonState: .available(value: daemon, capturedAt: now),
            loadedModels: .available(
                value: LoadedModelsState(
                    schema: 1,
                    models: ["gemma"],
                    updatedAt: now.addingTimeInterval(-86_400).timeIntervalSince1970
                ),
                capturedAt: now
            ),
            status: .available(
                value: status(daemon: "running", enabled: "gemma"),
                capturedAt: now
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .models([
            DashboardModel(name: "gemma", state: .loadedIdle),
        ]))
    }

    @Test("popup model pills derive from the continuously refreshed telemetry snapshot")
    func modelPillsUseTelemetrySnapshot() {
        let input = PopupModelSourceInput(
            daemonState: .available(value: daemonState(), capturedAt: now),
            loadedModels: .available(
                value: LoadedModelsState(
                    schema: 1,
                    models: ["gemma"],
                    updatedAt: now.timeIntervalSince1970
                ),
                capturedAt: now
            ),
            status: .available(value: status(daemon: "running", enabled: "gpt-oss"), capturedAt: now),
            controlSnapshot: popupControlSnapshot(
                daemonState: daemonState(),
                residentModelIDs: ["gpt-oss"],
                sources: popupControlSources(
                    daemon: .stale("Provider activity is stale"),
                    loadedModels: .stale("Loaded model state is stale")
                )
            )
        )
        let expected = PopupModelPresentation.models([
            DashboardModel(name: "gemma", state: .loadedIdle),
            DashboardModel(name: "gpt-oss", state: .availableUnloaded),
        ])
        #expect(PopupModelPresentation.make(input: input, currentTime: now) == expected)
    }

    @Test("stale active daemon state is not rendered as authoritative")
    func staleDaemonStateNeverShowsActive() {
        let input = PopupModelSourceInput(
            daemonState: .stale(
                value: activeDaemonState(),
                capturedAt: now,
                reason: "Provider activity is stale"
            ),
            loadedModels: .stale(
                value: LoadedModelsState(
                    schema: 1,
                    models: ["gemma"],
                    updatedAt: now.addingTimeInterval(-60).timeIntervalSince1970
                ),
                capturedAt: now,
                reason: "Loaded models are stale"
            ),
            status: .available(
                value: status(daemon: "running", enabled: "gemma,gpt-oss"),
                capturedAt: now
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .unavailable)
    }

    @Test("stopped provider shows configured models as available instead of stale residency")
    func stoppedProviderShowsConfiguredModelsAvailable() {
        let input = PopupModelSourceInput(
            daemonState: .available(value: activeDaemonState(), capturedAt: now),
            loadedModels: .available(
                value: LoadedModelsState(
                    schema: 1,
                    models: ["gemma"],
                    updatedAt: now.timeIntervalSince1970
                ),
                capturedAt: now
            ),
            status: .available(
                value: status(daemon: "not running", enabled: "gemma,gpt-oss"),
                capturedAt: now
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .models([
            DashboardModel(name: "gemma", state: .availableUnloaded),
            DashboardModel(name: "gpt-oss", state: .availableUnloaded),
        ]))
    }

    @Test("popup ignores a slower stopped status when fresh residency says provider is running")
    func popupFreshResidencyWinsOverSlowerStoppedStatus() {
        let input = PopupModelSourceInput(
            daemonState: .available(value: daemonState(), capturedAt: now),
            loadedModels: .available(
                value: LoadedModelsState(
                    schema: 1,
                    models: ["gpt-oss"],
                    updatedAt: now.timeIntervalSince1970
                ),
                capturedAt: now
            ),
            status: .available(
                value: status(daemon: "not running", enabled: "gemma,gpt-oss"),
                capturedAt: now.addingTimeInterval(-1)
            ),
            controlSnapshot: popupControlSnapshot(
                daemonState: daemonState(),
                residentModelIDs: ["gpt-oss"],
                sources: popupControlSources(
                    daemon: .fresh(evidenceAt: now),
                    loadedModels: .fresh(evidenceAt: now)
                )
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .models([
            DashboardModel(name: "gpt-oss", state: .loadedIdle),
            DashboardModel(name: "gemma", state: .availableUnloaded),
        ]))
    }

    @Test("popup respects a newer stopped status over older resident evidence")
    func popupNewerStoppedStatusWinsOverOlderResidency() {
        let input = PopupModelSourceInput(
            daemonState: .available(
                value: activeDaemonState(),
                capturedAt: now.addingTimeInterval(-1)
            ),
            loadedModels: .available(
                value: LoadedModelsState(
                    schema: 1,
                    models: ["gemma"],
                    updatedAt: now.addingTimeInterval(-1).timeIntervalSince1970
                ),
                capturedAt: now.addingTimeInterval(-1)
            ),
            status: .available(
                value: status(daemon: "not running", enabled: "gemma,gpt-oss"),
                capturedAt: now
            ),
            controlSnapshot: popupControlSnapshot(
                daemonState: activeDaemonState(),
                residentModelIDs: ["gemma"],
                sources: popupControlSources(
                    daemon: .fresh(evidenceAt: now.addingTimeInterval(-1)),
                    loadedModels: .fresh(evidenceAt: now.addingTimeInterval(-1))
                )
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .models([
            DashboardModel(name: "gemma", state: .availableUnloaded),
            DashboardModel(name: "gpt-oss", state: .availableUnloaded),
        ]))
    }

    @Test("stopped provider falls back to saved enabled models when status omits its filter")
    func stoppedProviderUsesSavedConfigurationWhenStatusOmitsFilter() {
        let input = PopupModelSourceInput(
            daemonState: .unavailable(reason: "Provider activity unavailable"),
            loadedModels: .unavailable(reason: "Loaded model state unavailable"),
            status: .available(
                value: status(daemon: "not running"),
                capturedAt: now
            ),
            controlSnapshot: popupControlSnapshot(
                daemonState: nil,
                residentModelIDs: [],
                sources: popupControlSources(
                    daemon: .unavailable("Provider activity unavailable"),
                    loadedModels: .unavailable("Loaded model state unavailable")
                )
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .models([
            DashboardModel(name: "gemma", state: .availableUnloaded),
            DashboardModel(name: "gpt-oss", state: .availableUnloaded),
        ]))
    }

    @Test("stopped provider resolves a saved enabled alias to its catalog model")
    func stoppedProviderResolvesSavedEnabledAlias() {
        let selection = ProviderModelSelection(enabled: ["gpt-oss"], preloaded: [])
        let catalogModel = CatalogModel(
            id: "gpt-oss-20b",
            displayName: "GPT OSS 20B",
            family: "gpt-oss",
            modelType: "llm",
            capabilities: ["text"],
            sizeGB: 12.1,
            minimumRAMGB: 24,
            active: true
        )
        let input = PopupModelSourceInput(
            daemonState: .unavailable(reason: "Provider activity unavailable"),
            loadedModels: .unavailable(reason: "Loaded model state unavailable"),
            status: .available(
                value: status(daemon: "not running"),
                capturedAt: now
            ),
            controlSnapshot: popupControlSnapshot(
                daemonState: nil,
                residentModelIDs: [],
                sources: popupControlSources(
                    daemon: .unavailable("Provider activity unavailable"),
                    loadedModels: .unavailable("Loaded model state unavailable")
                ),
                selection: selection,
                catalog: [catalogModel],
                local: [LocalModel(
                    id: catalogModel.id,
                    modelType: catalogModel.modelType,
                    sizeBytes: 12_100_000_000,
                    estimatedMemoryGB: 16
                )]
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .models([
            DashboardModel(name: "gpt-oss-20b", state: .availableUnloaded),
        ]))
    }

    @Test("running provider with unavailable residency does not show configured models as loaded")
    func unavailableDaemonDoesNotShowConfiguredModels() {
        let input = PopupModelSourceInput(
            daemonState: .unavailable(reason: "Waiting for daemon state"),
            loadedModels: .unavailable(reason: "Waiting for loaded models"),
            status: .available(
                value: status(daemon: "running", enabled: "gemma,gpt-oss"),
                capturedAt: now
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .unavailable)
    }

    @Test("fresh control residency replaces stale telemetry residency")
    func freshControlResidencyIsAuthoritativeWhenTelemetryIsStale() {
        let input = PopupModelSourceInput(
            daemonState: .stale(
                value: activeDaemonState(),
                capturedAt: now,
                reason: "Provider activity is stale"
            ),
            loadedModels: .stale(
                value: LoadedModelsState(
                    schema: 1,
                    models: ["gemma"],
                    updatedAt: now.addingTimeInterval(-60).timeIntervalSince1970
                ),
                capturedAt: now,
                reason: "Loaded models are stale"
            ),
            status: .available(
                value: status(daemon: "running", enabled: "gemma,gpt-oss"),
                capturedAt: now
            ),
            controlSnapshot: popupControlSnapshot(
                daemonState: daemonState(),
                residentModelIDs: ["gpt-oss"],
                sources: popupControlSources(
                    daemon: .fresh(evidenceAt: now),
                    loadedModels: .fresh(evidenceAt: now)
                )
            )
        )

        #expect(PopupModelPresentation.make(input: input, currentTime: now) == .models([
            DashboardModel(name: "gpt-oss", state: .loadedIdle),
            DashboardModel(name: "gemma", state: .availableUnloaded),
        ]))
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
        #expect(value.body == "Darkbloom Control cannot confirm whether a customer job is running. Continuing may interrupt customer work.")
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
    currentTime: Date = now
) -> ProviderLifecycleSourceInput {
    ProviderLifecycleSourceInput(
        daemonState: daemon,
        status: daemonStatus,
        controlDaemonState: controlDaemon,
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

private func activeDaemonState() -> DaemonState {
    DaemonState(
        schema: 1,
        version: "test",
        currentModel: "gemma",
        warmModels: ["gemma"],
        stats: ProviderStats(tokensGenerated: 10, requestsServed: 1, usageGaps: 0),
        trust: TrustState(level: "local", status: "online", reason: "test", receivedAt: 0),
        capacity: MemoryCapacity(totalMemoryGB: 64, gpuMemoryActiveGB: 24, gpuMemoryCacheGB: 0),
        slots: [],
        inferenceActive: true,
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
                    catalog: .fresh(evidenceAt: now),
                    localModels: .fresh(evidenceAt: now),
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
        catalog: .fresh(evidenceAt: now),
        localModels: .fresh(evidenceAt: now),
        daemon: .fresh(evidenceAt: now),
        loadedModels: .fresh(evidenceAt: now)
    )
}

private func popupControlSources(
    daemon: ProviderControlSourceState,
    loadedModels: ProviderControlSourceState
) -> ProviderControlSourceStates {
    ProviderControlSourceStates(
        catalog: .fresh(evidenceAt: now),
        localModels: .fresh(evidenceAt: now),
        daemon: daemon,
        loadedModels: loadedModels
    )
}

private func popupControlSnapshot(
    daemonState: DaemonState?,
    residentModelIDs: Set<String>,
    sources: ProviderControlSourceStates,
    selection: ProviderModelSelection = ProviderModelSelection(
        enabled: ["gemma", "gpt-oss"],
        preloaded: []
    ),
    catalog: [CatalogModel] = [],
    local: [LocalModel] = []
) -> ProviderControlSnapshot {
    let draft = ProviderConfigDraft(
        sourceRevision: "popup-control",
        original: selection,
        selection: selection
    )
    let inventory = ModelInventoryBuilder.build(
        catalog: catalog,
        local: local,
        selection: selection,
        daemon: daemonState,
        loadedModels: Array(residentModelIDs)
    )
    return ProviderControlSnapshot(
        inventory: inventory,
        draft: draft,
        daemonState: daemonState,
        residentModelIDs: residentModelIDs,
        capturedAt: now,
        sources: sources
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
