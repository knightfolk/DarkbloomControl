import AppKit
import DarkbloomTelemetry
import Foundation

/// Owns the monitor's hosting start-flag preferences, the explicit network and
/// authentication confirmation gate, and mode-appropriate endpoint details.
///
/// The options are application preferences, never provider configuration:
/// they are applied only through the official `darkbloom start` path and
/// persisted in user defaults without any secret material. The provider-owned
/// token file is read or updated only after an explicit user action; standalone
/// discovery uses `darkbloom local --json`.
@MainActor
final class HostingSettingsStore: ObservableObject {
    static let modeKey = "hosting.endpointMode"
    static let portKey = "hosting.port"
    static let bindAddressKey = "hosting.bindAddress"
    static let requiresAuthenticationKey = "hosting.requiresAuthentication"

    @Published private(set) var options: HostingOptions
    @Published private(set) var lanAddresses: [String] = []
    @Published private(set) var cliVersion: String?
    @Published private(set) var cliSupportsHosting = false
    @Published private(set) var pendingExposureConfirmation: HostingOptions?
    @Published private(set) var errorMessage: String?
    @Published private(set) var endpointDetails: LocalEndpointAvailability?
    @Published private(set) var isFetchingEndpointDetails = false
    @Published private(set) var localTokenStatusMessage: String?
    @Published private(set) var localTokenNeedsRestart = false

    private let defaults: UserDefaults
    private var controlStore: ProviderControlStore?
    private let endpointClient: any LocalEndpointFetching
    private let tokenFile: any LocalEndpointTokenManaging
    private let cliVersionProvider: () -> String?
    private let lanScanner: @Sendable () -> [String]

    init(
        controlStore: ProviderControlStore?,
        endpointClient: any LocalEndpointFetching,
        tokenFile: any LocalEndpointTokenManaging,
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
    /// endpoint, loopback bind, and authentication enabled. A persisted
    /// LAN/tailnet bind is retained but still requires a fresh confirmation
    /// before apply. A public or malformed address falls back to loopback.
    static func loadOptions(from defaults: UserDefaults) -> HostingOptions {
        let mode = defaults.string(forKey: modeKey)
            .flatMap(HostingEndpointMode.init(rawValue:)) ?? .off
        let portValue = defaults.integer(forKey: portKey)
        let port = (1...65_535).contains(portValue) ? UInt16(portValue) : HostingOptions.defaultPort
        var bindAddress = defaults.string(forKey: bindAddressKey) ?? HostingOptions.loopbackBindAddress
        if !HostingAddressPolicy.isSupportedBindAddress(bindAddress) {
            bindAddress = HostingOptions.loopbackBindAddress
        }
        let requiresAuthentication = defaults.object(forKey: requiresAuthenticationKey) as? Bool ?? true
        return HostingOptions(
            mode: mode,
            port: port,
            bindAddress: bindAddress,
            requiresAuthentication: requiresAuthentication
        )
    }

    /// Re-reads the runtime environment: the CLI version that authoritative
    /// status observed, and the currently active LAN/tailnet addresses.
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
        if localTokenNeedsRestart {
            localTokenStatusMessage = tokenStatusMessage(for: mode)
        }
    }

    /// Returns false when the text is not a usable port; the caller keeps the
    /// field editable instead of persisting a half-entered value.
    @discardableResult
    func setPortText(_ text: String) -> Bool {
        guard let value = UInt16(text), (1...65_535).contains(Int(value)) else { return false }
        update(\.port, to: value)
        return true
    }

    @discardableResult
    func setBindAddress(_ address: String) -> Bool {
        guard HostingAddressPolicy.isSupportedBindAddress(address) else { return false }
        update(\.bindAddress, to: address)
        return true
    }

    func setRequiresAuthentication(_ required: Bool) {
        update(\.requiresAuthentication, to: required)
    }

    /// Requests application of the current options. Network exposure and
    /// disabling API-key authentication both require fresh confirmation.
    func requestApply() async {
        errorMessage = nil
        pendingExposureConfirmation = nil
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
            errorMessage = "That address is not active on this Mac. Choose a current LAN or tailnet address, or use loopback."
            return
        }
        if options.requiresExposureConfirmation {
            pendingExposureConfirmation = options
            return
        }
        await apply(options)
    }

    func confirmPendingExposureConfirmation() async {
        guard let pending = pendingExposureConfirmation else { return }
        pendingExposureConfirmation = nil
        await apply(pending)
    }

    func cancelPendingExposureConfirmation() {
        pendingExposureConfirmation = nil
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

    /// Writes the custom key to the exact protected file read by `darkbloom
    /// start`. Secrets never enter user defaults. Existing servers keep the key
    /// they loaded at startup until their normal apply/restart path is used.
    @discardableResult
    func saveBearerToken(_ token: String) -> Bool {
        errorMessage = nil
        do {
            try tokenFile.saveBearerToken(token)
        } catch LocalEndpointTokenFileError.invalidToken {
            errorMessage = "Use 16–256 letters, numbers, or - . _ ~ + / = characters for the bearer token."
            return false
        } catch {
            errorMessage = "Could not save the token to Darkbloom's protected local storage."
            return false
        }

        localTokenNeedsRestart = options.mode == .unified
        localTokenStatusMessage = tokenStatusMessage(for: options.mode)
        return true
    }

    var canCopyBearerToken: Bool {
        if case .live(let record) = endpointDetails { return record.hasBearerToken }
        var available = false
        _ = tokenFile.withBearerToken { _ in available = true }
        return available
    }

    var configuredEndpointURL: String? {
        Self.endpointURL(from: options)
    }

    /// The unified-mode endpoint URL implied by persisted preferences. An
    /// all-interfaces bind is addressed through loopback on this Mac. This is
    /// the chat route's local base URL source; unified mode has no discovery
    /// record.
    static func endpointURL(from options: HostingOptions) -> String? {
        guard options.mode == .unified else { return nil }
        let host = options.bindAddress == HostingOptions.allInterfacesBindAddress
            ? HostingOptions.loopbackBindAddress
            : options.bindAddress
        return "http://\(host):\(options.port)/v1"
    }

    /// The app cannot supervise direct mode because `darkbloom start --local`
    /// remains in the foreground. This safe, argument-only command is offered
    /// for an explicit user-initiated copy to Terminal.
    var standaloneStartCommand: String? {
        guard options.mode == .standalone, options.isValid else { return nil }
        if options.bindScope == .specificInterface,
           !lanAddresses.contains(options.bindAddress) {
            return nil
        }
        var parts = [
            "darkbloom", "start", "--local",
            "--port", String(options.port),
            "--bind", options.bindAddress,
        ]
        if !options.requiresAuthentication { parts.append("--no-auth") }
        return parts.joined(separator: " ")
    }

    var exposureConfirmationTitle: String {
        guard let pendingExposureConfirmation else { return "Confirm local endpoint access" }
        if !pendingExposureConfirmation.requiresAuthentication {
            return pendingExposureConfirmation.bindScope == .loopback
                ? "Disable API-key authentication?"
                : "Expose an unauthenticated endpoint?"
        }
        return "Allow access from the network?"
    }

    var exposureConfirmationMessage: String {
        guard let pendingExposureConfirmation else { return "Review the endpoint settings before applying." }
        var details: [String] = []
        if pendingExposureConfirmation.bindScope == .allInterfaces {
            details.append("0.0.0.0 listens on every network interface, not only your LAN.")
        } else if pendingExposureConfirmation.bindScope == .specificInterface {
            details.append("The endpoint will listen on \(pendingExposureConfirmation.bindAddress), which other devices able to reach that address can access.")
        }
        if !pendingExposureConfirmation.requiresAuthentication {
            details.append("API-key authentication will be disabled; anyone who can reach this endpoint can send requests to this Mac.")
        } else {
            details.append("API-key authentication stays on. The token remains in Darkbloom's protected local storage.")
        }
        details.append("The endpoint uses HTTP without TLS or rate limiting.")
        return details.joined(separator: " ")
    }

    var unauthenticatedAccessWarning: String {
        switch options.mode {
        case .off:
            return "No local endpoint is active. If you enable local hosting later, the app will ask for confirmation before applying this setting."
        case .unified:
            return "No API key will be required. This is unsafe on shared, public, or untrusted networks. Applying requires a second confirmation before the provider is restarted."
        case .standalone:
            return "No API key will be required. The copied command includes --no-auth; the app will not run or supervise this command, so review it before executing in Terminal."
        }
    }

    /// Refreshes the live CLI record only after an explicit copy action, so a
    /// custom token staged on disk cannot be confused with a running server's
    /// still-active key. The secret is never displayed, logged, or persisted.
    func copyBearerTokenToPasteboard() async -> Bool {
        var copied = false
        await fetchEndpointDetails()
        if case .live(let record) = endpointDetails, record.hasBearerToken {
            record.withBearerToken { token in
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(token, forType: .string)
            }
            return copied
        }
        if case .live = endpointDetails {
            errorMessage = "The running local endpoint has bearer-token authentication disabled."
            return false
        }

        let found = tokenFile.withBearerToken { token in
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(token, forType: .string)
        }
        if !found {
            errorMessage = "The bearer token is not available yet. Start local hosting first, or save a custom token."
        }
        return found && copied
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
            return
        }
        if localTokenNeedsRestart {
            localTokenNeedsRestart = false
            localTokenStatusMessage = options.mode == .off
                ? "Hosting changes applied. The saved token will be used next time you enable a local endpoint."
                : "Hosting changes applied. The running endpoint has restarted with the saved token."
        }
    }

    private func tokenStatusMessage(for mode: HostingEndpointMode) -> String {
        if localTokenNeedsRestart {
            switch mode {
            case .off:
                return "Saved in Darkbloom's protected token file. Choose Apply changes to return to Fleet only; this key stays saved for future local hosting."
            case .unified:
                return "Saved in Darkbloom's protected token file. Choose Apply changes to restart the provider with it."
            case .standalone:
                return "Token saved. Stop the current provider from the CLI before starting the Terminal-managed local mode."
            }
        }
        switch mode {
        case .off:
            return "Saved in Darkbloom's protected token file. A running endpoint keeps its current key until restarted; future local starts use this one."
        case .unified:
            return "Saved in Darkbloom's protected token file for the next local endpoint start."
        case .standalone:
            return "Saved for the next `darkbloom start --local`. Stop and restart any running local-only server in Terminal to activate it."
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
        defaults.set(options.requiresAuthentication, forKey: Self.requiresAuthenticationKey)
    }
}
