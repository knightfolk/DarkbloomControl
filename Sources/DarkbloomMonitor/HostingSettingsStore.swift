import AppKit
import DarkbloomTelemetry
import Foundation

/// Owns the monitor's hosting start-flag preferences, the explicit LAN
/// confirmation gate, and mode-appropriate local-endpoint details.
///
/// The options are application preferences, never provider configuration:
/// they are applied only through the official `darkbloom start` path and
/// persisted in user defaults without any secret material. Unified mode reads
/// the provider-owned token file only for the explicit copy action; standalone
/// discovery uses `darkbloom local --json`.
@MainActor
final class HostingSettingsStore: ObservableObject {
    static let modeKey = "hosting.endpointMode"
    static let portKey = "hosting.port"
    static let bindAddressKey = "hosting.bindAddress"

    @Published private(set) var options: HostingOptions
    @Published private(set) var lanAddresses: [String] = []
    @Published private(set) var cliVersion: String?
    @Published private(set) var cliSupportsHosting = false
    @Published private(set) var pendingLANConfirmation: HostingOptions?
    @Published private(set) var errorMessage: String?
    @Published private(set) var endpointDetails: LocalEndpointAvailability?
    @Published private(set) var isFetchingEndpointDetails = false

    private let defaults: UserDefaults
    private var controlStore: ProviderControlStore?
    private let endpointClient: any LocalEndpointFetching
    private let tokenFile: any LocalEndpointTokenProviding
    private let cliVersionProvider: () -> String?
    private let lanScanner: @Sendable () -> [String]

    init(
        controlStore: ProviderControlStore?,
        endpointClient: any LocalEndpointFetching,
        tokenFile: any LocalEndpointTokenProviding,
        cliVersionProvider: @escaping () -> String?,
        defaults: UserDefaults = .standard,
        lanScanner: @escaping @Sendable () -> [String] = LANAddressScanner.activePrivateIPv4Addresses
    ) {
        self.controlStore = controlStore
        self.endpointClient = endpointClient
        self.tokenFile = tokenFile
        self.cliVersionProvider = cliVersionProvider
        self.defaults = defaults
        self.lanScanner = lanScanner
        options = Self.loadOptions(from: defaults)
    }

    /// Completes two-phase wiring: the control store's hosting-option source
    /// is this store, so it is constructed afterwards.
    func attachControlStore(_ controlStore: ProviderControlStore) {
        self.controlStore = controlStore
    }

    /// Loads persisted preferences, falling back to the safe default: no
    /// endpoint, loopback bind. A persisted private-LAN bind is retained but
    /// still requires a fresh explicit confirmation before any apply. A public
    /// or malformed address falls back to loopback.
    static func loadOptions(from defaults: UserDefaults) -> HostingOptions {
        let mode = defaults.string(forKey: modeKey)
            .flatMap(HostingEndpointMode.init(rawValue:)) ?? .off
        let portValue = defaults.integer(forKey: portKey)
        let port = (1...65_535).contains(portValue) ? UInt16(portValue) : HostingOptions.defaultPort
        var bindAddress = defaults.string(forKey: bindAddressKey) ?? HostingOptions.loopbackBindAddress
        if !HostingAddressPolicy.isSupportedBindAddress(bindAddress) {
            bindAddress = HostingOptions.loopbackBindAddress
        }
        return HostingOptions(mode: mode, port: port, bindAddress: bindAddress)
    }

    /// Re-reads the runtime environment: the CLI version that authoritative
    /// status observed, and the currently active private LAN addresses.
    func refreshEnvironment() {
        let version = cliVersionProvider()
        cliVersion = version
        cliSupportsHosting = HostingCapability.supportsHostServing(cliVersion: version)
        lanAddresses = lanScanner()
    }

    func setMode(_ mode: HostingEndpointMode) {
        if options.mode != mode {
            endpointDetails = nil
        }
        update(\.mode, to: mode)
    }

    /// Returns false when the text is not a usable port; the caller keeps the
    /// field editable instead of persisting a half-entered value.
    @discardableResult
    func setPortText(_ text: String) -> Bool {
        guard let value = UInt16(text), (1...65_535).contains(Int(value)) else { return false }
        update(\.port, to: value)
        return true
    }

    func setBindAddress(_ address: String) {
        guard HostingAddressPolicy.isSupportedBindAddress(address) else { return }
        update(\.bindAddress, to: address)
    }

    /// Requests application of the current options. A non-loopback bind never
    /// dispatches from here: it first requires the explicit LAN confirmation.
    func requestApply() async {
        errorMessage = nil
        pendingLANConfirmation = nil
        guard cliSupportsHosting else {
            errorMessage = Self.unsupportedMessage(cliVersion: cliVersion)
            return
        }
        guard options.mode.isDispatchable else {
            errorMessage = HostingEndpointMode.standaloneUnavailableReason
            return
        }
        guard options.isValid else {
            errorMessage = "Enter a valid port and bind address before applying hosting settings."
            return
        }
        if options.mode != .off,
           options.bindScope == .specificInterface,
           !lanAddresses.contains(options.bindAddress) {
            errorMessage = "That LAN address is no longer active. Choose a current LAN address or use loopback."
            return
        }
        if options.requiresLANConfirmation {
            pendingLANConfirmation = options
            return
        }
        await apply(options)
    }

    func confirmPendingLANConfirmation() async {
        guard let pending = pendingLANConfirmation else { return }
        pendingLANConfirmation = nil
        await apply(pending)
    }

    func cancelPendingLANConfirmation() {
        pendingLANConfirmation = nil
    }

    func clearErrorMessage() {
        errorMessage = nil
    }

    /// On-demand standalone-mode `darkbloom local --json` read. Unified mode
    /// has no discovery record; its address comes from these settings.
    func fetchEndpointDetails() async {
        isFetchingEndpointDetails = true
        defer { isFetchingEndpointDetails = false }
        endpointDetails = await endpointClient.fetch()
    }

    var canCopyBearerToken: Bool {
        if options.mode == .unified { return true }
        if case .live(let record) = endpointDetails, record.hasBearerToken { return true }
        return false
    }

    var configuredEndpointURL: String? {
        guard options.mode == .unified else { return nil }
        let host = options.bindAddress == HostingOptions.allInterfacesBindAddress
            ? HostingOptions.loopbackBindAddress
            : options.bindAddress
        return "http://\(host):\(options.port)/v1"
    }

    /// Copies the bearer token through the explicit user action only. The
    /// token is never displayed, logged, or persisted.
    func copyBearerTokenToPasteboard() -> Bool {
        var copied = false
        if options.mode == .unified {
            let found = tokenFile.withBearerToken { token in
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(token, forType: .string)
            }
            if !found {
                errorMessage = "The endpoint token is not available yet. Apply the hosting settings and start the endpoint first."
            }
            return found && copied
        }
        guard case .live(let record) = endpointDetails, record.hasBearerToken else { return false }
        record.withBearerToken { token in
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(token, forType: .string)
        }
        return copied
    }

    static func unsupportedMessage(cliVersion: String?) -> String {
        let observed = cliVersion.map { " (observed CLI \($0))" } ?? ""
        return "Hosting requires Darkbloom CLI \(HostingCapability.minimumCLIVersion) or newer\(observed). Update the CLI, then refresh."
    }

    private func apply(_ options: HostingOptions) async {
        guard let controlStore else {
            errorMessage = "Hosting controls are unavailable."
            return
        }
        let succeeded = await controlStore.applyHosting(options)
        if !succeeded {
            errorMessage = "Hosting settings could not be applied. Refresh before trying again."
        }
    }

    private func update<Value: Equatable>(
        _ keyPath: WritableKeyPath<HostingOptions, Value>,
        to value: Value
    ) {
        guard options[keyPath: keyPath] != value else { return }
        options[keyPath: keyPath] = value
        persist(options)
    }

    private func persist(_ options: HostingOptions) {
        defaults.set(options.mode.rawValue, forKey: Self.modeKey)
        defaults.set(Int(options.port), forKey: Self.portKey)
        defaults.set(options.bindAddress, forKey: Self.bindAddressKey)
    }
}
