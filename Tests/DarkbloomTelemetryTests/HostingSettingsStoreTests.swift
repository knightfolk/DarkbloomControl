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
        endpointAvailability: LocalEndpointAvailability = .none("fixture"),
        tokenFile: any LocalEndpointTokenManaging = HostingTokenFileFake()
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
            tokenFile: tokenFile,
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
        #expect(store.pendingExposureConfirmation == nil)
    }

    @Test("preferences persist and reload with safe fallbacks")
    func persistenceRoundTrip() throws {
        let defaults = makeDefaults()
        let (store, _) = try makeStore(defaults: defaults)
        store.setMode(.unified)
        #expect(store.setPortText("8123"))
        store.setBindAddress("192.168.1.20")
        store.setRequiresAuthentication(false)

        let reloaded = HostingSettingsStore.loadOptions(from: defaults)
        #expect(reloaded == HostingOptions(
            mode: .unified,
            port: 8123,
            bindAddress: "192.168.1.20",
            requiresAuthentication: false
        ))

        defaults.removeObject(forKey: HostingSettingsStore.requiresAuthenticationKey)
        #expect(HostingSettingsStore.loadOptions(from: defaults).requiresAuthentication)

        defaults.set("banana", forKey: HostingSettingsStore.bindAddressKey)
        defaults.set(70_000, forKey: HostingSettingsStore.portKey)
        defaults.set("sideways", forKey: HostingSettingsStore.modeKey)
        let recovered = HostingSettingsStore.loadOptions(from: defaults)
        #expect(recovered == .default)
    }

    @Test("a custom bearer token is saved for the CLI and never enters app preferences")
    func savesCustomBearerToken() throws {
        let defaults = makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostingSettingsToken-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenFile = LocalEndpointTokenFile(fileURL: directory.appendingPathComponent("local_token"))
        let (store, _) = try makeStore(defaults: defaults, tokenFile: tokenFile)
        store.setMode(.unified)

        let token = "custom-openai-client-key-12345"
        #expect(store.saveBearerToken(token))
        #expect(store.localTokenNeedsRestart)
        #expect(store.localTokenStatusMessage?.contains("Apply changes") == true)
        #expect(store.localTokenStatusMessage?.contains(token) == false)
        #expect(store.canCopyBearerToken)

        var savedToken: String?
        #expect(tokenFile.withBearerToken { savedToken = $0 })
        #expect(savedToken == token)
        #expect(defaults.dictionaryRepresentation().values.allSatisfy { ($0 as? String) != token })
    }

    @Test("a custom token is reported for Terminal restart in unmanaged local-only mode")
    func standaloneTokenRequiresTerminalRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostingStandaloneToken-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenFile = LocalEndpointTokenFile(fileURL: directory.appendingPathComponent("local_token"))
        let (store, _) = try makeStore(defaults: makeDefaults(), tokenFile: tokenFile)
        store.setMode(.standalone)

        #expect(store.saveBearerToken("custom-openai-client-key-12345"))
        #expect(!store.localTokenNeedsRestart)
        #expect(store.localTokenStatusMessage?.contains("darkbloom start --local") == true)
        #expect(store.localTokenStatusMessage?.contains("Terminal") == true)
    }

    @Test("saving a custom token while auth is disabled retains it for a later authenticated start")
    func savesTokenForLaterAuthenticatedStart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostingNoAuthToken-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenFile = LocalEndpointTokenFile(fileURL: directory.appendingPathComponent("local_token"))
        let (store, _) = try makeStore(defaults: makeDefaults(), tokenFile: tokenFile)
        store.setRequiresAuthentication(false)

        #expect(store.saveBearerToken("custom-openai-client-key-12345"))
        #expect(store.localTokenStatusMessage?.contains("Darkbloom's protected token file") == true)
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
        #expect(store.pendingExposureConfirmation == nil)
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
        #expect(store.pendingExposureConfirmation == HostingOptions(mode: .unified, port: 8123, bindAddress: "192.168.1.20"))

        store.cancelPendingExposureConfirmation()
        #expect(store.pendingExposureConfirmation == nil)
        #expect(await controller.hostingExecutions.isEmpty)

        await store.requestApply()
        await store.confirmPendingExposureConfirmation()
        let executions = await controller.hostingExecutions
        #expect(executions.count == 1)
        #expect(executions.first?.hosting.bindAddress == "192.168.1.20")
        #expect(store.pendingExposureConfirmation == nil)
    }

    @Test("an all-interfaces bind also requires confirmation")
    func allInterfacesRequiresConfirmation() async throws {
        let (store, controller) = try makeStore(defaults: makeDefaults())
        store.setMode(.unified)
        store.setBindAddress("0.0.0.0")
        await store.requestApply()
        #expect(await controller.hostingExecutions.isEmpty)
        #expect(store.pendingExposureConfirmation != nil)
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
        #expect(store.pendingExposureConfirmation == nil)
        #expect(store.errorMessage == "That address is not active on this Mac. Choose a current LAN or tailnet address, or use loopback.")
    }

    @Test("disabling authentication requires confirmation even on loopback")
    func unauthenticatedApplyRequiresConfirmation() async throws {
        let (store, controller) = try makeStore(defaults: makeDefaults())
        store.setMode(.unified)
        store.setRequiresAuthentication(false)

        await store.requestApply()

        #expect(await controller.hostingExecutions.isEmpty)
        #expect(store.pendingExposureConfirmation?.bindAddress == HostingOptions.loopbackBindAddress)
        #expect(store.exposureConfirmationTitle == "Disable API-key authentication?")
        #expect(store.exposureConfirmationMessage.contains("anyone who can reach this endpoint"))

        await store.confirmPendingExposureConfirmation()
        let executions = await controller.hostingExecutions
        #expect(executions.count == 1)
        #expect(executions.first?.hosting.requiresAuthentication == false)
        #expect(store.pendingExposureConfirmation == nil)
    }

    @Test("standalone preview reflects the selected local CLI options")
    func standaloneCommandPreview() throws {
        let (store, _) = try makeStore(
            defaults: makeDefaults(),
            lanAddresses: ["192.168.1.20", "100.101.22.3"]
        )
        store.setMode(.standalone)
        store.setPortText("8123")
        store.setBindAddress("100.101.22.3")
        store.setRequiresAuthentication(false)

        #expect(store.standaloneStartCommand == "darkbloom start --local --port 8123 --bind 100.101.22.3 --no-auth")
    }

    @Test("standalone command preview requires the selected interface to be active")
    func standaloneCommandRejectsInactiveAddress() throws {
        let (store, _) = try makeStore(defaults: makeDefaults(), lanAddresses: ["192.168.1.20"])
        store.setMode(.standalone)
        store.setBindAddress("192.168.1.99")

        #expect(store.standaloneStartCommand == nil)
    }

    @Test("authentication warning explains the selected mode without promising a nonexistent gate")
    func unauthenticatedWarningMatchesMode() throws {
        let (store, _) = try makeStore(defaults: makeDefaults())
        store.setRequiresAuthentication(false)
        #expect(store.unauthenticatedAccessWarning.contains("No local endpoint is active"))

        store.setMode(.unified)
        #expect(store.unauthenticatedAccessWarning.contains("second confirmation before the provider is restarted"))

        store.setMode(.standalone)
        #expect(store.unauthenticatedAccessWarning.contains("app will not run or supervise this command"))
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

private struct HostingTokenFileFake: LocalEndpointTokenManaging {
    func withBearerToken(_ action: (String) -> Void) -> Bool { false }
    func saveBearerToken(_ token: String) throws {}
}
