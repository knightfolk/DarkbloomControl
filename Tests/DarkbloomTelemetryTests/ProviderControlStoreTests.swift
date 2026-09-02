import AppKit
import DarkbloomTelemetry
import Foundation
import SwiftUI
import Testing
@testable import DarkbloomMonitor

private let providerControlTestNow = Date(timeIntervalSince1970: 1_750_000_000)

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

    @Test("save preserves typed source freshness before its follow-up refresh")
    func savePreservesSourceFreshness() async throws {
        let expectedSources = freshProviderSources()
        let controller = FakeProviderController.fixture(failRefreshAfterSave: true)
        let store = ProviderControlStore(controller: controller)
        await store.refresh()
        store.setEnabled(true, modelID: "second-model")

        await store.save()

        #expect(store.snapshot?.sources == expectedSources)
        #expect(store.errorMessage == "Settings were saved, but model controls could not refresh.")
    }

    @Test("save and download gates require typed fresh catalog and local state")
    func gatesMutationsOnTypedFreshSources() async throws {
        let freshController = FakeProviderController.fixture()
        let freshStore = ProviderControlStore(controller: freshController)
        await freshStore.refresh()
        freshStore.setEnabled(true, modelID: "second-model")
        #expect(freshStore.canSave)
        #expect(freshStore.canDownload("available-model"))

        let staleStates: [ProviderControlSourceStates] = [
            ProviderControlSourceStates(
                catalog: .stale("otherwise harmless diagnostic"),
                localModels: .fresh(evidenceAt: providerControlTestNow),
                daemon: .fresh(evidenceAt: providerControlTestNow),
                loadedModels: .fresh(evidenceAt: providerControlTestNow)
            ),
            ProviderControlSourceStates(
                catalog: .unavailable("otherwise harmless diagnostic"),
                localModels: .fresh(evidenceAt: providerControlTestNow),
                daemon: .fresh(evidenceAt: providerControlTestNow),
                loadedModels: .fresh(evidenceAt: providerControlTestNow)
            ),
            ProviderControlSourceStates(
                catalog: .fresh(evidenceAt: providerControlTestNow),
                localModels: .stale("otherwise harmless diagnostic"),
                daemon: .fresh(evidenceAt: providerControlTestNow),
                loadedModels: .fresh(evidenceAt: providerControlTestNow)
            ),
            ProviderControlSourceStates(
                catalog: .fresh(evidenceAt: providerControlTestNow),
                localModels: .unavailable("otherwise harmless diagnostic"),
                daemon: .fresh(evidenceAt: providerControlTestNow),
                loadedModels: .fresh(evidenceAt: providerControlTestNow)
            ),
        ]
        for sources in staleStates {
            let controller = FakeProviderController.fixture(
                snapshot: fixtureSnapshot(sources: sources)
            )
            let store = ProviderControlStore(controller: controller)
            await store.refresh()
            store.setEnabled(true, modelID: "second-model")

            #expect(!store.canSave)
            #expect(!store.canDownload("available-model"))
        }
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
        let store = ProviderControlStore(
            controller: controller,
            homeDirectory: URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        )
        await store.refresh()

        await store.download("available-model")

        let progress = try #require(store.latestDownloadProgressLine)
        #expect(progress == "auth_token=<redacted> ~/private.bin")
        #expect(!progress.contains("super-secret"))
        #expect(!progress.contains("\u{001B}"))
        #expect(progress.count <= 200)
    }

    @Test("user diagnostics redact credentials and the injected home path")
    func sanitizesUserDiagnostics() async throws {
        let home = URL(fileURLWithPath: "/Volumes/Network Homes/kevin", isDirectory: true)
        let store = ProviderControlStore(
            controller: FakeProviderController.fixture(),
            homeDirectory: home
        )
        let secrets = [
            "Authorization: Bearer bearer-secret",
            "access_token=access-secret",
            "refresh_token: refresh-secret",
            "token=token-secret",
            "api_key=underscore-secret",
            "api-key: hyphen-secret",
            "api key = spaced-secret",
            "password=password-secret",
            "secret: plain-secret",
        ]

        for value in secrets {
            let sanitized = store.sanitizedDiagnostic(
                "\(value) /Volumes/Network Homes/kevin/private/config " + String(repeating: "x", count: 300)
            )
            #expect(sanitized.contains("<redacted>"))
            #expect(sanitized.contains("~/private/config"))
            #expect(!sanitized.contains("-secret"))
            #expect(!sanitized.contains("/Volumes/Network Homes/kevin"))
            #expect(sanitized.count <= 200)
        }
    }

    @Test("diagnostics normalize control and ANSI obfuscation before matching")
    func sanitizesObfuscatedDiagnostics() async throws {
        let store = ProviderControlStore(
            controller: FakeProviderController.fixture(),
            homeDirectory: URL(
                fileURLWithPath: "/Volumes/Network Homes/kevin",
                isDirectory: true
            )
        )
        let diagnostic = """
        to\u{0000}ken=control-secret \
        Authori\u{0007}zation: Bearer bearer-secret \
        api_\u{001B}[\u{0000}31mkey=ansi-secret \
        /Volumes/Net\u{001B}[34mwork\u{0000} Homes/kevin/private
        """

        let sanitized = store.sanitizedDiagnostic(diagnostic)

        #expect(!sanitized.contains("control-secret"))
        #expect(!sanitized.contains("bearer-secret"))
        #expect(!sanitized.contains("ansi-secret"))
        #expect(!sanitized.contains("/Volumes/Network Homes/kevin"))
        #expect(sanitized.contains("<redacted>"))
        #expect(sanitized.contains("~/private"))
    }

    @Test("progress normalizes split control-obfuscated keys values and home paths")
    func sanitizesAdversarialSplitProgress() async throws {
        let chunks = [
            ProcessOutputChunk(destination: .standardError, data: Data("acc".utf8)),
            ProcessOutputChunk(
                destination: .standardError,
                data: Data("ess_to\u{0000}".utf8)
            ),
            ProcessOutputChunk(
                destination: .standardError,
                data: Data("ken=".utf8)
            ),
            ProcessOutputChunk(
                destination: .standardError,
                data: Data("split-\u{0000}secret /Volumes/Net".utf8)
            ),
            ProcessOutputChunk(
                destination: .standardError,
                data: Data("work\u{0000} Homes/kevin/private\n".utf8)
            ),
        ]
        let controller = FakeProviderController.fixture(downloadChunks: chunks)
        let store = ProviderControlStore(
            controller: controller,
            homeDirectory: URL(
                fileURLWithPath: "/Volumes/Network Homes/kevin",
                isDirectory: true
            )
        )
        await store.refresh()

        await store.download("available-model")

        let progress = try #require(store.latestDownloadProgressLine)
        #expect(!progress.contains("split-secret"))
        #expect(!progress.contains("/Volumes/Network Homes/kevin"))
        #expect(progress.contains("access_token=<redacted>"))
        #expect(progress.contains("~/private"))
    }

    @Test("truncated progress never publishes a credential value tail")
    func rejectsTruncatedCredentialLines() async throws {
        let secret = String(repeating: "long-secret-", count: 500)
        for terminator in ["", "\n"] {
            let chunks = [
                ProcessOutputChunk(
                    destination: .standardError,
                    data: Data("token=".utf8)
                ),
                ProcessOutputChunk(
                    destination: .standardError,
                    data: Data("\(secret)\(terminator)".utf8)
                ),
            ]
            let controller = FakeProviderController.fixture(downloadChunks: chunks)
            let store = ProviderControlStore(controller: controller)
            await store.refresh()

            await store.download("available-model")

            #expect(!store.latestDownloadProgressLine.orEmpty.contains("long-secret"))
        }
    }

    @Test("download sanitization joins split credential and home-path chunks")
    func sanitizesSplitProgressChunks() async throws {
        let chunks = [
            ProcessOutputChunk(
                destination: .standardError,
                data: Data("Authorization: Bea".utf8)
            ),
            ProcessOutputChunk(
                destination: .standardError,
                data: Data("rer split-secret /Volumes/Network Homes/kevin/private.bin\n".utf8)
            ),
        ]
        let controller = FakeProviderController.fixture(downloadChunks: chunks)
        let store = ProviderControlStore(
            controller: controller,
            homeDirectory: URL(fileURLWithPath: "/Volumes/Network Homes/kevin", isDirectory: true)
        )
        await store.refresh()

        await store.download("available-model")

        let progress = try #require(store.latestDownloadProgressLine)
        #expect(progress.contains("Authorization: <redacted>"))
        #expect(progress.contains("~/private.bin"))
        #expect(!progress.contains("split-secret"))
        #expect(!progress.contains("/Volumes/Network Homes/kevin"))
    }

    @Test("configuration failures map only fixed safe diagnostics")
    func mapsConfigurationFailures() async throws {
        let cases: [(ProviderConfigError, String)] = [
            (.changedExternally, "Provider settings changed outside the app. Reload and try again."),
            (.validationFailed("Darkbloom rejected the candidate configuration"), "Darkbloom rejected the provider settings."),
            (.validationFailed("Could not read the provider configuration"), "Could not read the provider configuration."),
            (.validationFailed("Could not save the provider configuration"), "Could not save the provider configuration."),
            (.validationFailed("Provider configuration changed during recovery; recovery data was preserved beside it"), "Provider configuration changed during recovery; recovery data was preserved beside it."),
            (.validationFailed("Could not preserve provider configuration security metadata"), "Could not preserve provider configuration security metadata."),
            (.validationFailed("Provider configuration is busy; try again"), "Provider configuration is busy; try again."),
            (.validationFailed("Could not remove the candidate configuration; recovery data was preserved beside the provider configuration"), "Could not remove the candidate configuration; recovery data was preserved beside the provider configuration."),
            (.validationFailed("Authorization: Bearer arbitrary-secret"), "Could not save provider settings."),
        ]

        for (failure, expected) in cases {
            let controller = FakeProviderController.fixture(saveFailure: failure)
            let store = ProviderControlStore(controller: controller)
            await store.refresh()
            store.setEnabled(true, modelID: "second-model")

            await store.save()

            #expect(store.errorMessage == expected)
            #expect(!store.errorMessage.orEmpty.contains("arbitrary-secret"))
        }
    }

    @Test("save inventory preflight failures preserve only production safe diagnostics")
    func mapsSaveInventoryFailures() async throws {
        let safeCases: [(ProviderControlError, String)] = [
            (.inventoryUnavailable("Model catalog is unavailable"), "Model catalog is unavailable"),
            (.inventoryUnavailable("Local model list is unavailable"), "Local model list is unavailable"),
            (
                .inventoryUnavailable(
                    "Saved model selection is not an unambiguous downloaded catalog model"
                ),
                "Saved model selection is not an unambiguous downloaded catalog model"
            ),
        ]

        for (failure, expected) in safeCases {
            let controller = FakeProviderController.fixture(saveControlFailure: failure)
            let store = ProviderControlStore(controller: controller)
            await store.refresh()
            store.setEnabled(true, modelID: "second-model")

            await store.save()

            #expect(store.errorMessage == expected)
        }

        let unsafeController = FakeProviderController.fixture(
            saveControlFailure: .inventoryUnavailable(
                "Authorization: Bearer arbitrary-secret"
            )
        )
        let unsafeStore = ProviderControlStore(controller: unsafeController)
        await unsafeStore.refresh()
        unsafeStore.setEnabled(true, modelID: "second-model")
        await unsafeStore.save()
        #expect(unsafeStore.errorMessage == "Model inventory is unavailable.")
        #expect(!unsafeStore.errorMessage.orEmpty.contains("arbitrary-secret"))
    }

    @Test("delete blockers preserve every production safe diagnostic")
    func mapsControlBlockers() async throws {
        let safeMessages = [
            "The local model identity is ambiguous",
            "Disable the model and save before deleting it",
            "Remove the model from preload and save before deleting it",
            "The local model could not be matched safely",
            "The active model cannot be deleted",
            "A loaded model cannot be deleted",
            "Provider activity is unavailable; deletion was not attempted",
            "Provider activity timestamp is invalid; deletion was not attempted",
            "Provider activity is stale; deletion was not attempted",
            "Provider activity timestamp is in the future; deletion was not attempted",
            "Loaded model state is unavailable; deletion was not attempted",
            "Loaded model state timestamp is invalid; deletion was not attempted",
            "Loaded model state is stale; deletion was not attempted",
            "Loaded model state timestamp is in the future; deletion was not attempted",
        ]
        for message in safeMessages {
            let controller = FakeProviderController.fixture(
                deleteFailure: .deleteBlocked(message)
            )
            let store = ProviderControlStore(controller: controller)
            await store.refresh()

            await store.delete("second-model")

            #expect(store.errorMessage == message)
        }

        let unsafeController = FakeProviderController.fixture(
            deleteFailure: .deleteBlocked("Authorization: Bearer arbitrary-secret")
        )
        let unsafeStore = ProviderControlStore(controller: unsafeController)
        await unsafeStore.refresh()
        await unsafeStore.delete("second-model")
        #expect(unsafeStore.errorMessage == "The model cannot be deleted safely.")
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

    @Test("lifecycle remains active until the awaited telemetry refresh completes")
    func awaitsTelemetryRefreshBeforeBecomingIdle() async throws {
        let gate = TelemetryRefreshGate()
        let controller = FakeProviderController.fixture()
        let store = ProviderControlStore(
            controller: controller,
            refreshTelemetry: { await gate.refresh() }
        )
        await store.refresh()

        let start = Task { await store.request(.start) }
        let telemetryStarted = await gate.waitUntilStarted()
        #expect(telemetryStarted)

        #expect(store.operation == .lifecycle(.start))
        #expect(await controller.executedActions.map(\.action) == [.start])
        await gate.release()
        await start.value

        #expect(store.operation == .idle)
        #expect(await gate.callCount == 1)
    }

    @Test("failed and timed out lifecycle attempts reconcile changed control state")
    func reconcilesFailedLifecycleAttempts() async throws {
        let changedSources = ProviderControlSourceStates(
            catalog: .fresh(evidenceAt: providerControlTestNow),
            localModels: .fresh(evidenceAt: providerControlTestNow),
            daemon: .unavailable("Provider activity is unavailable"),
            loadedModels: .unavailable("Loaded model state is unavailable")
        )

        for failure in [
            FakeProviderController.Failure.nonzero,
            FakeProviderController.Failure.timedOut,
        ] {
            let gate = TelemetryRefreshGate()
            await gate.release()
            let controller = FakeProviderController.fixture(
                executeFailure: failure,
                lifecycleSnapshotAfterExecute: fixtureSnapshot(sources: changedSources)
            )
            let store = ProviderControlStore(
                controller: controller,
                refreshTelemetry: { await gate.refresh() }
            )
            await store.refresh()

            await store.request(.start)

            #expect(store.snapshot?.sources == changedSources)
            #expect(store.errorMessage == "Could not start the provider.")
            #expect(await gate.callCount == 1)
            #expect(await controller.refreshCount == 2)
        }
    }

    @Test("failed lifecycle preserves its error and stays active through failed reconciliation")
    func preservesLifecycleErrorThroughFailedReconciliation() async throws {
        let gate = TelemetryRefreshGate()
        let controller = FakeProviderController.fixture(
            executeControlFailure: .invalidOutput("original command detail"),
            failRefreshAfterExecute: true
        )
        let store = ProviderControlStore(
            controller: controller,
            refreshTelemetry: { await gate.refresh() }
        )
        await store.refresh()

        let start = Task { await store.request(.start) }
        let telemetryStarted = await gate.waitUntilStarted()
        #expect(telemetryStarted)

        #expect(store.operation == .lifecycle(.start))
        #expect(store.errorMessage == nil)
        await gate.release()
        await start.value

        #expect(store.operation == .idle)
        #expect(
            store.errorMessage
                == "Darkbloom returned an invalid response while trying to start."
        )
        #expect(await controller.refreshCount == 2)
    }

    @Test("controller lifecycle cancellation skips reconciliation and publication")
    func skipsReconciliationAfterControllerCancellation() async throws {
        let telemetry = TelemetryRefreshGate()
        await telemetry.release()
        let changedSources = unavailableLifecycleSources()
        let controller = FakeProviderController.fixture(
            executeCancellation: true,
            lifecycleSnapshotAfterExecute: fixtureSnapshot(sources: changedSources)
        )
        let store = ProviderControlStore(
            controller: controller,
            refreshTelemetry: { await telemetry.refresh() }
        )
        await store.refresh()
        let initialSnapshot = try #require(store.snapshot)

        await store.request(.start)

        #expect(store.operation == .idle)
        #expect(store.errorMessage == nil)
        #expect(store.snapshot == initialSnapshot)
        #expect(store.snapshot?.sources != changedSources)
        #expect(await telemetry.callCount == 0)
        #expect(await controller.refreshCount == 1)
    }

    @Test("cancellation during telemetry reconciliation prevents control refresh and publication")
    func cancelsDuringTelemetryReconciliation() async throws {
        let telemetry = TelemetryRefreshGate()
        let changedSources = unavailableLifecycleSources()
        let controller = FakeProviderController.fixture(
            lifecycleSnapshotAfterExecute: fixtureSnapshot(sources: changedSources)
        )
        let store = ProviderControlStore(
            controller: controller,
            refreshTelemetry: { await telemetry.refresh() }
        )
        await store.refresh()
        let initialSnapshot = try #require(store.snapshot)

        let start = Task { await store.request(.start) }
        let telemetryStarted = await telemetry.waitUntilStarted()
        #expect(telemetryStarted)
        #expect(store.operation == .lifecycle(.start))

        start.cancel()
        await telemetry.release()
        await start.value

        #expect(store.operation == .idle)
        #expect(store.errorMessage == nil)
        #expect(store.snapshot == initialSnapshot)
        #expect(store.snapshot?.sources != changedSources)
        #expect(await controller.refreshCount == 1)
    }

    @Test("cancellation during controller reconciliation prevents snapshot publication")
    func cancelsDuringControllerReconciliation() async throws {
        let telemetry = TelemetryRefreshGate()
        await telemetry.release()
        let controllerRefresh = TelemetryRefreshGate()
        let changedSources = unavailableLifecycleSources()
        let controller = FakeProviderController.fixture(
            lifecycleSnapshotAfterExecute: fixtureSnapshot(sources: changedSources),
            reconciliationRefreshGate: controllerRefresh
        )
        let store = ProviderControlStore(
            controller: controller,
            refreshTelemetry: { await telemetry.refresh() }
        )
        await store.refresh()
        let initialSnapshot = try #require(store.snapshot)

        let start = Task { await store.request(.start) }
        let refreshStarted = await controllerRefresh.waitUntilStarted()
        #expect(refreshStarted)
        #expect(store.operation == .lifecycle(.start))

        start.cancel()
        await controllerRefresh.release()
        await start.value

        #expect(store.operation == .idle)
        #expect(store.errorMessage == nil)
        #expect(store.snapshot == initialSnapshot)
        #expect(store.snapshot?.sources != changedSources)
        #expect(await telemetry.callCount == 1)
        #expect(await controller.refreshCount == 2)
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
        case nonzero
        case timedOut
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
    private let saveFailure: ProviderConfigError?
    private let saveControlFailure: ProviderControlError?
    private let failRefreshAfterSave: Bool
    private let deleteFailure: ProviderControlError?
    private let executeFailure: Failure?
    private let executeControlFailure: ProviderControlError?
    private let executeCancellation: Bool
    private let lifecycleSnapshotAfterExecute: ProviderControlSnapshot?
    private let failRefreshAfterExecute: Bool
    private let reconciliationRefreshGate: TelemetryRefreshGate?
    private var shouldGateRefresh = false
    private var downloadStarted = false
    private(set) var downloadedModels: [String] = []
    private(set) var deletedModels: [String] = []
    private(set) var executedActions: [Execution] = []
    private(set) var saveCount = 0
    private(set) var activityReadCount = 0
    private(set) var downloadCancellationCount = 0
    private(set) var refreshCount = 0

    static func fixture(
        snapshot: ProviderControlSnapshot = fixtureSnapshot(),
        activityRisks: [ProviderActivityRisk] = [],
        blockDownload: Bool = false,
        downloadChunks: [ProcessOutputChunk] = [],
        downloadFailure: Failure? = nil,
        saveFailure: ProviderConfigError? = nil,
        saveControlFailure: ProviderControlError? = nil,
        failRefreshAfterSave: Bool = false,
        deleteFailure: ProviderControlError? = nil,
        executeFailure: Failure? = nil,
        executeControlFailure: ProviderControlError? = nil,
        executeCancellation: Bool = false,
        lifecycleSnapshotAfterExecute: ProviderControlSnapshot? = nil,
        failRefreshAfterExecute: Bool = false,
        reconciliationRefreshGate: TelemetryRefreshGate? = nil
    ) -> FakeProviderController {
        FakeProviderController(
            snapshot: snapshot,
            activityRisks: activityRisks,
            blockDownload: blockDownload,
            downloadChunks: downloadChunks,
            downloadFailure: downloadFailure,
            saveFailure: saveFailure,
            saveControlFailure: saveControlFailure,
            failRefreshAfterSave: failRefreshAfterSave,
            deleteFailure: deleteFailure,
            executeFailure: executeFailure,
            executeControlFailure: executeControlFailure,
            executeCancellation: executeCancellation,
            lifecycleSnapshotAfterExecute: lifecycleSnapshotAfterExecute,
            failRefreshAfterExecute: failRefreshAfterExecute,
            reconciliationRefreshGate: reconciliationRefreshGate
        )
    }

    init(
        snapshot: ProviderControlSnapshot,
        activityRisks: [ProviderActivityRisk],
        blockDownload: Bool,
        downloadChunks: [ProcessOutputChunk],
        downloadFailure: Failure?,
        saveFailure: ProviderConfigError?,
        saveControlFailure: ProviderControlError?,
        failRefreshAfterSave: Bool,
        deleteFailure: ProviderControlError?,
        executeFailure: Failure?,
        executeControlFailure: ProviderControlError?,
        executeCancellation: Bool,
        lifecycleSnapshotAfterExecute: ProviderControlSnapshot?,
        failRefreshAfterExecute: Bool,
        reconciliationRefreshGate: TelemetryRefreshGate?
    ) {
        currentSnapshot = snapshot
        self.activityRisks = activityRisks
        self.blockDownload = blockDownload
        self.downloadChunks = downloadChunks
        self.downloadFailure = downloadFailure
        self.saveFailure = saveFailure
        self.saveControlFailure = saveControlFailure
        self.failRefreshAfterSave = failRefreshAfterSave
        self.deleteFailure = deleteFailure
        self.executeFailure = executeFailure
        self.executeControlFailure = executeControlFailure
        self.executeCancellation = executeCancellation
        self.lifecycleSnapshotAfterExecute = lifecycleSnapshotAfterExecute
        self.failRefreshAfterExecute = failRefreshAfterExecute
        self.reconciliationRefreshGate = reconciliationRefreshGate
    }

    func refresh() async throws -> ProviderControlSnapshot {
        refreshCount += 1
        if shouldGateRefresh, let reconciliationRefreshGate {
            await reconciliationRefreshGate.refresh()
        }
        if let refreshFailure { throw refreshFailure }
        return currentSnapshot
    }

    func failRefresh(with failure: Failure) {
        refreshFailure = failure
    }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        saveCount += 1
        if let saveControlFailure { throw saveControlFailure }
        if let saveFailure { throw saveFailure }
        let savedDraft = ProviderConfigDraft(
            sourceRevision: "saved-revision-\(saveCount)",
            original: draft.selection,
            selection: draft.selection
        )
        currentSnapshot = ProviderControlSnapshot(
            inventory: currentSnapshot.inventory,
            draft: savedDraft,
            capturedAt: currentSnapshot.capturedAt.addingTimeInterval(1),
            sources: currentSnapshot.sources
        )
        if failRefreshAfterSave {
            refreshFailure = .secret("post-save refresh failed")
        }
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
        if let deleteFailure { throw deleteFailure }
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
        if let lifecycleSnapshotAfterExecute {
            currentSnapshot = lifecycleSnapshotAfterExecute
        }
        if failRefreshAfterExecute {
            refreshFailure = .secret("post-execution refresh failed")
        }
        shouldGateRefresh = reconciliationRefreshGate != nil
        if executeCancellation { throw CancellationError() }
        if let executeControlFailure { throw executeControlFailure }
        if let executeFailure { throw executeFailure }
    }
}

private func fixtureSnapshot(
    sources: ProviderControlSourceStates = freshProviderSources()
) -> ProviderControlSnapshot {
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
        capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
        sources: sources
    )
}

private func freshProviderSources() -> ProviderControlSourceStates {
    ProviderControlSourceStates(
        catalog: .fresh(evidenceAt: providerControlTestNow),
        localModels: .fresh(evidenceAt: providerControlTestNow),
        daemon: .fresh(evidenceAt: providerControlTestNow),
        loadedModels: .fresh(evidenceAt: providerControlTestNow)
    )
}

private func unavailableLifecycleSources() -> ProviderControlSourceStates {
    ProviderControlSourceStates(
        catalog: .fresh(evidenceAt: providerControlTestNow),
        localModels: .fresh(evidenceAt: providerControlTestNow),
        daemon: .unavailable("Provider activity is unavailable"),
        loadedModels: .unavailable("Loaded model state is unavailable")
    )
}

private actor TelemetryRefreshGate {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func refresh() async {
        callCount += 1
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted(timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !started {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
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
