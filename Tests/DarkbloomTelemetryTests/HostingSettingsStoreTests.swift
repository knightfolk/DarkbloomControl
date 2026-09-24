import AppKit
import Foundation
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

@Suite("Hosting settings store")
@MainActor
struct HostingSettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "HostingSettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(
        defaults: UserDefaults,
        cliVersion: String? = "0.9.7",
        lanAddresses: [String] = ["192.168.1.20"],
        endpointAvailability: LocalEndpointAvailability = .none("fixture")
    ) throws -> (HostingSettingsStore, HostingSpyController) {
        let controller = HostingSpyController()
        let controlStore = ProviderControlStore(
            controller: controller,
            hostingOptions: { .default }
        )
        let endpointClient = EndpointFetchFake(availability: endpointAvailability)
        let store = HostingSettingsStore(
            controlStore: controlStore,
            endpointClient: endpointClient,
            tokenFile: HostingTokenFileFake(),
            cliVersionProvider: { cliVersion },
            defaults: defaults,
            lanScanner: { lanAddresses }
        )
        store.attachControlStore(controlStore)
        store.refreshEnvironment()
        return (store, controller)
    }

    @Test("fresh defaults are off, loopback, and unconfirmed")
    func freshDefaults() throws {
        let (store, _) = try makeStore(defaults: makeDefaults())
        #expect(store.options == .default)
        #expect(store.cliSupportsHosting)
        #expect(store.pendingLANConfirmation == nil)
    }

    @Test("preferences persist and reload with safe fallbacks")
    func persistenceRoundTrip() throws {
        let defaults = makeDefaults()
        let (store, _) = try makeStore(defaults: defaults)
        store.setMode(.unified)
        #expect(store.setPortText("8123"))
        store.setBindAddress("192.168.1.20")

        let reloaded = HostingSettingsStore.loadOptions(from: defaults)
        #expect(reloaded == HostingOptions(mode: .unified, port: 8123, bindAddress: "192.168.1.20"))

        defaults.set("banana", forKey: HostingSettingsStore.bindAddressKey)
        defaults.set(70_000, forKey: HostingSettingsStore.portKey)
        defaults.set("sideways", forKey: HostingSettingsStore.modeKey)
        let recovered = HostingSettingsStore.loadOptions(from: defaults)
        #expect(recovered == .default)
    }

    @Test("an invalid port text is rejected without changing the saved value")
    func invalidPortText() throws {
        let defaults = makeDefaults()
        let (store, _) = try makeStore(defaults: defaults)
        #expect(store.setPortText("8123"))
        #expect(!store.setPortText("0"))
        #expect(!store.setPortText("99999"))
        #expect(!store.setPortText("abc"))
        #expect(store.options.port == 8123)
    }

    @Test("the unified URL follows the configured local or LAN bind")
    func configuredEndpointURL() throws {
        let (store, _) = try makeStore(defaults: makeDefaults())
        #expect(store.configuredEndpointURL == nil)

        store.setMode(.unified)
        #expect(store.configuredEndpointURL == "http://127.0.0.1:8000/v1")
        store.setPortText("8123")
        store.setBindAddress("192.168.1.20")
        #expect(store.configuredEndpointURL == "http://192.168.1.20:8123/v1")
        store.setBindAddress(HostingOptions.allInterfacesBindAddress)
        #expect(store.configuredEndpointURL == "http://127.0.0.1:8123/v1")
    }

    @Test("a loopback unified apply dispatches immediately through the control gate")
    func loopbackApplyDispatches() async throws {
        let (store, controller) = try makeStore(defaults: makeDefaults())
        store.setMode(.unified)
        store.setPortText("8123")
        await store.requestApply()
        let executions = await controller.hostingExecutions
        #expect(executions.count == 1)
        #expect(executions.first?.action == .start)
        #expect(executions.first?.hosting == HostingOptions(mode: .unified, port: 8123, bindAddress: "127.0.0.1"))
        #expect(store.pendingLANConfirmation == nil)
        #expect(store.errorMessage == nil)
    }

    @Test("a LAN bind never dispatches without explicit confirmation")
    func lanApplyRequiresConfirmation() async throws {
        let (store, controller) = try makeStore(defaults: makeDefaults())
        store.setMode(.unified)
        store.setPortText("8123")
        store.setBindAddress("192.168.1.20")
        #expect(store.lanAddresses == ["192.168.1.20"])

        await store.requestApply()
        #expect(await controller.hostingExecutions.isEmpty)
        #expect(store.pendingLANConfirmation == HostingOptions(mode: .unified, port: 8123, bindAddress: "192.168.1.20"))

        store.cancelPendingLANConfirmation()
        #expect(store.pendingLANConfirmation == nil)
        #expect(await controller.hostingExecutions.isEmpty)

        await store.requestApply()
        await store.confirmPendingLANConfirmation()
        let executions = await controller.hostingExecutions
        #expect(executions.count == 1)
        #expect(executions.first?.hosting.bindAddress == "192.168.1.20")
        #expect(store.pendingLANConfirmation == nil)
    }

    @Test("an all-interfaces bind also requires confirmation")
    func allInterfacesRequiresConfirmation() async throws {
        let (store, controller) = try makeStore(defaults: makeDefaults())
        store.setMode(.unified)
        store.setBindAddress("0.0.0.0")
        await store.requestApply()
        #expect(await controller.hostingExecutions.isEmpty)
        #expect(store.pendingLANConfirmation != nil)
    }

    @Test("a saved private address must still belong to an active LAN interface")
    func staleLANAddressIsRejected() async throws {
        let (store, controller) = try makeStore(
            defaults: makeDefaults(),
            lanAddresses: []
        )
        store.setMode(.unified)
        store.setBindAddress("192.168.1.20")
        await store.requestApply()

        #expect(await controller.hostingExecutions.isEmpty)
        #expect(store.pendingLANConfirmation == nil)
        #expect(store.errorMessage == "That LAN address is no longer active. Choose a current LAN address or use loopback.")
    }

    @Test("an unverified CLI blocks every apply")
    func unsupportedCLIBlocksApply() async throws {
        let (store, controller) = try makeStore(
            defaults: makeDefaults(),
            cliVersion: "0.8.15"
        )
        #expect(!store.cliSupportsHosting)
        store.setMode(.unified)
        await store.requestApply()
        #expect(await controller.hostingExecutions.isEmpty)
        #expect(store.errorMessage == HostingSettingsStore.unsupportedMessage(cliVersion: "0.8.15"))
    }

    @Test("standalone mode is represented as unavailable and never dispatched")
    func standaloneIsNeverDispatched() async throws {
        let (store, controller) = try makeStore(defaults: makeDefaults())
        store.setMode(.standalone)
        await store.requestApply()
        #expect(await controller.hostingExecutions.isEmpty)
        #expect(store.errorMessage == HostingEndpointMode.standaloneUnavailableReason)
    }

    @Test("endpoint details stay in memory and the token stays hidden")
    func endpointDetailsHandling() async throws {
        let record = LocalEndpointRecord(
            baseURL: "http://127.0.0.1:8000/v1",
            apiKey: "synthetic-token-value",
            host: "127.0.0.1",
            port: 8000,
            processID: 4242
        )
        let (store, _) = try makeStore(
            defaults: makeDefaults(),
            endpointAvailability: .live(record)
        )
        await store.fetchEndpointDetails()
        guard case .live(let observed) = store.endpointDetails else {
            Issue.record("expected a live endpoint")
            return
        }
        #expect(observed.processID == 4242)
        #expect(store.canCopyBearerToken)
        #expect(String(describing: observed).contains("bearerToken"))
        #expect(!String(describing: observed).contains("synthetic-token-value"))
    }
}

private actor HostingSpyController: ProviderControlling {
    struct HostingExecution: Equatable, Sendable {
        let action: ProviderLifecycleAction
        let hosting: HostingOptions
    }

    private let snapshot: ProviderControlSnapshot
    private(set) var hostingExecutions: [HostingExecution] = []

    init() {
        let draft = ProviderConfigDraft(
            sourceRevision: "fixture",
            original: ProviderModelSelection(enabled: ["model-a"], preloaded: []),
            selection: ProviderModelSelection(enabled: ["model-a"], preloaded: []),
            originalMaxModelSlots: 1,
            maxModelSlots: 1
        )
        snapshot = ProviderControlSnapshot(
            inventory: ModelInventoryBuilder.build(
                catalog: [],
                local: [],
                selection: ProviderModelSelection(enabled: [], preloaded: []),
                daemon: nil,
                loadedModels: []
            ),
            draft: draft,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    func refresh() async throws -> ProviderControlSnapshot { snapshot }

    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult {
        throw ProviderControlError.invalidOutput("unused")
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
    ) async throws {}

    func performLifecycle(
        _ action: ProviderLifecycleAction,
        enabledModels: [String],
        hosting: HostingOptions,
        onPhase: ProviderMutationPhaseObserver?
    ) async throws -> ProviderMutationCompletion {
        hostingExecutions.append(HostingExecution(action: action, hosting: hosting))
        return .refreshUncertain
    }
}

private struct EndpointFetchFake: LocalEndpointFetching {
    let availability: LocalEndpointAvailability
    func fetch() async -> LocalEndpointAvailability { availability }
}

private struct HostingTokenFileFake: LocalEndpointTokenProviding {
    func withBearerToken(_ action: (String) -> Void) -> Bool { false }
}
