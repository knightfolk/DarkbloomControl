import AppKit
import DarkbloomTelemetry
import SwiftUI

/// A dedicated dashboard destination for the official provider's local
/// OpenAI-compatible endpoints. It configures CLI flags only; it never starts
/// an app-owned inference server or writes hosting values into provider.toml.
struct HostingSettingsView: View {
    @ObservedObject var store: HostingSettingsStore
    @State private var portText = ""
    @State private var customAddressText = ""
    @State private var customAddressError: String?
    @State private var copiedCommand = false
    @State private var bearerTokenText = ""

    private var isPortValid: Bool {
        guard let port = UInt16(portText) else { return false }
        return port > 0
    }

    private var canUseSelectedAddress: Bool {
        store.lanAddresses.contains(store.options.bindAddress)
    }

    private var standaloneCommandMatchesDraft: Bool {
        store.cliSupportsHosting && isPortValid && UInt16(portText) == store.options.port
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let error = store.errorMessage {
                    HostingNotice(
                        title: "Could not update hosting",
                        message: error,
                        style: .danger,
                        symbol: "exclamationmark.triangle.fill"
                    )
                    .accessibilityIdentifier("hosting.error")
                }

                if !store.cliSupportsHosting {
                    HostingNotice(
                        title: "Update Darkbloom CLI",
                        message: HostingSettingsStore.unsupportedMessage(cliVersion: store.cliVersion),
                        style: .warning,
                        symbol: "arrow.down.circle"
                    )
                    .accessibilityIdentifier("hosting.cliUnavailable")
                }

                servingModeCard
                endpointCard
                securityCard
                connectionDetailsCard
                applyCard
            }
            .padding(24)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("hosting.page")
        .onAppear {
            portText = String(store.options.port)
            if store.options.bindScope == .specificInterface {
                customAddressText = store.options.bindAddress
            }
            store.refreshEnvironment()
        }
        .confirmationDialog(
            store.exposureConfirmationTitle,
            isPresented: exposureConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(confirmationActionTitle) {
                Task { await store.confirmPendingExposureConfirmation() }
            }
            Button("Cancel", role: .cancel) {
                store.cancelPendingExposureConfirmation()
            }
        } message: {
            Text(store.exposureConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, height: 54)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))

            VStack(alignment: .leading, spacing: 4) {
                Text("Hosting")
                    .font(.largeTitle.bold())
                Text("Choose how this Mac shares its local inference endpoint.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            statusBadge
            Button {
                store.refreshEnvironment()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh the CLI version and detected LAN addresses")
            .accessibilityLabel("Refresh hosting environment")
            .accessibilityIdentifier("hosting.refresh")
        }
        .padding(.bottom, 2)
    }

    private var statusBadge: some View {
        let title: String
        let symbol: String
        let tint: Color
        switch store.options.mode {
        case .off:
            title = "Fleet only"
            symbol = "network"
            tint = .secondary
        case .unified:
            title = "Fleet + local"
            symbol = "checkmark.circle.fill"
            tint = .green
        case .standalone:
            title = "Local only"
            symbol = "desktopcomputer"
            tint = .orange
        }
        return Label(title, systemImage: symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("hosting.currentMode")
    }

    private var servingModeCard: some View {
        HostingCard(
            title: "How this Mac serves",
            subtitle: "Choose a mode; Apply uses the installed Darkbloom CLI with the matching start options."
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                modeCard(
                    .off,
                    title: "Fleet only",
                    detail: "Keep serving the Darkbloom network. No local API endpoint is started.",
                    symbol: "network"
                )
                modeCard(
                    .unified,
                    title: "Fleet + local API",
                    detail: "Accept local API requests while remaining available to the fleet. Both share model slots.",
                    symbol: "arrow.triangle.branch"
                )
                modeCard(
                    .standalone,
                    title: "Local only",
                    detail: "Uses `--local`. Runs in Terminal; this app cannot start or stop it.",
                    symbol: "desktopcomputer"
                )
            }
        }
    }

    private func modeCard(
        _ mode: HostingEndpointMode,
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        let selected = store.options.mode == mode
        return Button {
            store.setMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Text(cliModeSummary(for: mode))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if mode == .standalone {
                    Text("TERMINAL MANAGED")
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(.orange)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.18),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!store.cliSupportsHosting)
        .accessibilityIdentifier("hosting.mode.\(mode.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cliModeSummary(for mode: HostingEndpointMode) -> String {
        switch mode {
        case .off: "darkbloom start"
        case .unified: "darkbloom start --local-endpoint"
        case .standalone: "darkbloom start --local"
        }
    }

    private var endpointCard: some View {
        HostingCard(
            title: "Local endpoint",
            subtitle: "Port and network reach map to the CLI's `--port` and `--bind` options. Apply sends them to Darkbloom."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    Label("Port", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.headline)
                    TextField(String(HostingOptions.defaultPort), text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .monospacedDigit()
                        .accessibilityLabel("Local endpoint port")
                        .accessibilityIdentifier("hosting.port")
                        .onChange(of: portText) { _, value in
                            _ = store.setPortText(value)
                            store.clearErrorMessage()
                        }
                    Text("Default \(String(HostingOptions.defaultPort))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !portText.isEmpty && !isPortValid {
                        Label("Enter 1–65,535", systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("hosting.portError")
                    }
                    Spacer(minLength: 0)
                }

                Divider()

                VStack(alignment: .leading, spacing: 11) {
                    Label("Reachable from", systemImage: "wifi")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                        bindCard(
                            preset: .loopback,
                            title: "This Mac only",
                            detail: "127.0.0.1 · private to this Mac",
                            symbol: "laptopcomputer"
                        )
                        bindCard(
                            preset: .specificInterface,
                            title: "One LAN / tailnet address",
                            detail: specificBindDescription,
                            symbol: "wifi"
                        )
                        bindCard(
                            preset: .allInterfaces,
                            title: "All interfaces",
                            detail: "0.0.0.0 · widest exposure",
                            symbol: "dot.radiowaves.left.and.right"
                        )
                    }

                    if store.options.bindScope == .specificInterface {
                        VStack(alignment: .leading, spacing: 10) {
                            if store.lanAddresses.isEmpty {
                                Text("No active private LAN or tailnet IPv4 address was detected.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Active addresses on this Mac")
                                    .font(.subheadline.weight(.medium))
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 8)], spacing: 8) {
                                    ForEach(store.lanAddresses, id: \.self) { address in
                                        Button {
                                            selectAddress(address)
                                        } label: {
                                            Label(address, systemImage: address == store.options.bindAddress ? "checkmark.circle.fill" : "network")
                                                .font(.callout.monospacedDigit())
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(address == store.options.bindAddress ? .accentColor : .secondary)
                                        .accessibilityIdentifier("hosting.bind.address.\(address)")
                                    }
                                }
                            }

                            HStack(spacing: 10) {
                                TextField("Enter an active IPv4 address", text: $customAddressText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout.monospacedDigit())
                                    .accessibilityLabel("Custom local interface address")
                                    .accessibilityIdentifier("hosting.bind.customAddress")
                                Button("Use address") { useCustomAddress() }
                                    .disabled(customAddressText == store.options.bindAddress)
                                    .accessibilityIdentifier("hosting.bind.useCustomAddress")
                            }
                            if let customAddressError {
                                Text(customAddressError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if !canUseSelectedAddress {
                                Label(
                                    "This saved address is no longer active. Select a current address before applying.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                        .padding(.top, 2)
                    }

                    if store.options.bindScope == .allInterfaces {
                        HostingNotice(
                            title: "Listens on every interface",
                            message: "0.0.0.0 can include Wi-Fi, Ethernet, and other reachable networks. Keep API-key authentication on unless you have a specific trusted, isolated setup.",
                            style: .warning,
                            symbol: "exclamationmark.shield.fill"
                        )
                        .accessibilityIdentifier("hosting.bind.wildcardWarning")
                    } else if store.options.bindScope == .specificInterface {
                        HostingNotice(
                            title: "Network access requires confirmation",
                            message: "Only devices that can route to this Mac and port can connect. The app will ask before applying this bind.",
                            style: .warning,
                            symbol: "exclamationmark.triangle.fill"
                        )
                    } else {
                        Label("Loopback keeps the endpoint private to this Mac.", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var securityCard: some View {
        HostingCard(
            title: "Local API access",
            subtitle: "These controls map to the CLI's local API-key behavior. They do not change your Darkbloom fleet account."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: authenticationBinding) {
                    Label("Require a bearer token", systemImage: "key.fill")
                        .font(.headline)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("hosting.auth.required")

                if store.options.requiresAuthentication {
                    Text("On is the CLI default. Turning it off adds `--no-auth` and needs confirmation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HostingNotice(
                        title: "Anyone who can reach this endpoint can use it",
                        message: store.unauthenticatedAccessWarning,
                        style: .danger,
                        symbol: "lock.slash"
                    )
                    .accessibilityIdentifier("hosting.auth.warning")
                    Text("The saved bearer token stays available for a future authenticated start, but `--no-auth` ignores it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    SecureField("Set a custom bearer token", text: $bearerTokenText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("hosting.auth.bearerToken")
                        .onChange(of: bearerTokenText) { _, _ in
                            store.clearErrorMessage()
                        }
                    Button("Save token") {
                        if store.saveBearerToken(bearerTokenText) {
                            bearerTokenText = ""
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!LocalEndpointTokenFile.isValidBearerToken(bearerTokenText))
                    .accessibilityIdentifier("hosting.auth.saveToken")
                }
                Text("16–256 letters, numbers, or - . _ ~ + / =. Saved as `~/.darkbloom/local_token` with private file permissions—not in app preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Darkbloom creates a token automatically. Enter a custom value only if your client needs a fixed key; saving replaces it for future starts. A running endpoint keeps its current key until restarted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let status = store.localTokenStatusMessage {
                    Label(status, systemImage: store.localTokenNeedsRestart ? "arrow.clockwise" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(store.localTokenNeedsRestart ? .orange : .secondary)
                        .accessibilityIdentifier("hosting.auth.tokenStatus")
                }

                HStack(spacing: 10) {
                    Button("Copy bearer token") {
                        Task { _ = await store.copyBearerTokenToPasteboard() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!store.canCopyBearerToken)
                    .accessibilityIdentifier("hosting.auth.copyToken")
                    Text("Copies the active endpoint key, or the saved CLI key when no endpoint is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var connectionDetailsCard: some View {
        HostingCard(
            title: "Connection details",
            subtitle: "The URL reflects your selected settings, not a reachability check. Apply changes to start or restart it; manage its key under Local API access."
        ) {
            switch store.options.mode {
            case .off:
                Label("The local endpoint is off in Fleet only mode.", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .unified:
                configuredConnectionDetails
            case .standalone:
                standaloneConnectionDetails
            }
        }
    }

    @ViewBuilder
    private var configuredConnectionDetails: some View {
        if let url = store.configuredEndpointURL {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(url)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("hosting.details.configuredURL")
                }
                Spacer(minLength: 0)
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    _ = NSPasteboard.general.setString(url, forType: .string)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("hosting.details.copyURL")
            }

            if store.options.bindScope == .allInterfaces {
                if store.lanAddresses.isEmpty {
                    Text("No active private LAN or tailnet address was found. Other devices cannot use the loopback URL above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect from another device")
                            .font(.subheadline.weight(.medium))
                        ForEach(store.lanAddresses, id: \.self) { address in
                            Text("http://\(address):\(store.options.port)/v1")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("hosting.details.lanURLs")
                }
            }

            if !store.options.requiresAuthentication {
                Label("API-key authentication is disabled for this endpoint.", systemImage: "lock.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var standaloneConnectionDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Direct mode is read from the live CLI discovery record.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(store.isFetchingEndpointDetails ? "Checking…" : "Check for a running local-only endpoint") {
                Task { await store.fetchEndpointDetails() }
            }
            .disabled(store.isFetchingEndpointDetails)
            .accessibilityIdentifier("hosting.details.refresh")

            switch store.endpointDetails {
            case .some(.none):
                Text("No running local-only endpoint is advertised right now.")
                    .foregroundStyle(.secondary)
            case .some(.live(let record)):
                VStack(alignment: .leading, spacing: 5) {
                    Text("Base URL · \(record.baseURL)")
                    Text("Listening at \(record.host):\(record.port)")
                        .foregroundStyle(.secondary)
                    if !record.hasBearerToken {
                        Text("API-key authentication is disabled on this endpoint.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
            case nil:
                Text("Choose Local only to view and copy its Terminal command.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var applyCard: some View {
        HostingCard(
            title: store.options.mode == .standalone ? "Run in Terminal" : "Apply changes",
            subtitle: applyDescription
        ) {
            if store.options.mode == .standalone {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The official CLI keeps direct mode running in the foreground, so this app will not launch or stop it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if standaloneCommandMatchesDraft, let command = store.standaloneStartCommand {
                        HStack(spacing: 10) {
                            Text(command)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(copiedCommand ? "Copied" : "Copy Terminal command") {
                                NSPasteboard.general.clearContents()
                                _ = NSPasteboard.general.setString(command, forType: .string)
                                copiedCommand = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!standaloneCommandMatchesDraft)
                            .accessibilityIdentifier("hosting.copyStandaloneCommand")
                        }
                        Text("The CLI will ask you to choose local models when you run the command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(standaloneCommandIssue, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("hosting.standalone.invalidPort")
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    Button(applyTitle) {
                        Task { await store.requestApply() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!store.cliSupportsHosting || !isPortValid)
                    .accessibilityIdentifier("hosting.apply")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Uses the official darkbloom start command.")
                            .font(.callout.weight(.medium))
                        Text("Accepted requests drain before the provider restarts. Local and fleet requests share model slots.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }

        }
    }

    private var applyTitle: String {
        store.options.mode == .unified ? "Apply & restart provider" : "Apply fleet-only mode"
    }

    private var standaloneCommandIssue: String {
        if !store.cliSupportsHosting {
            return "Update Darkbloom CLI to use local-only serving."
        }
        if !isPortValid {
            return "Enter a valid port to preview the updated command."
        }
        if store.options.bindScope == .specificInterface && !canUseSelectedAddress {
            return "Choose an active LAN or tailnet address, then refresh if needed."
        }
        return "Choose a valid bind address to preview the command."
    }

    private var applyDescription: String {
        switch store.options.mode {
        case .off:
            return "Use the official `darkbloom start` command without a local API. Your saved port, network, and token settings stay available for later."
        case .unified:
            let access = store.options.requiresAuthentication ? "authenticated" : "unauthenticated"
            return "Start the \(access) local API alongside fleet serving. Network access or disabled authentication always requires a fresh confirmation."
        case .standalone:
            return "Direct mode is available through the CLI, but remains a foreground process outside this app's lifecycle controls."
        }
    }

    private var specificBindDescription: String {
        if store.options.bindScope == .specificInterface {
            return "\(store.options.bindAddress) · selected interface"
        }
        if let first = store.lanAddresses.first {
            return "\(first) · this Mac only on that network"
        }
        return "Choose one active LAN or tailnet interface"
    }

    private var confirmationActionTitle: String {
        guard let pending = store.pendingExposureConfirmation else { return "Continue" }
        if !pending.requiresAuthentication {
            return pending.bindScope == .loopback ? "Disable API-key authentication" : "Expose without API-key authentication"
        }
        return pending.bindScope == .allInterfaces ? "Expose on all interfaces" : "Allow LAN access"
    }

    private var authenticationBinding: Binding<Bool> {
        Binding(
            get: { store.options.requiresAuthentication },
            set: { store.setRequiresAuthentication($0) }
        )
    }

    private var exposureConfirmationBinding: Binding<Bool> {
        Binding(
            get: { store.pendingExposureConfirmation != nil },
            set: { if !$0 { store.cancelPendingExposureConfirmation() } }
        )
    }

    @ViewBuilder
    private func bindCard(preset: HostingBindPreset, title: String, detail: String, symbol: String) -> some View {
        let selected = preset.isSelected(for: store.options)
        Button {
            customAddressError = nil
            guard let address = preset.address(for: store.options, activeAddresses: store.lanAddresses) else {
                customAddressError = "Enter an active LAN or tailnet IPv4 address below."
                return
            }
            _ = store.setBindAddress(address)
            if preset == .specificInterface {
                customAddressText = address
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 27)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.16), lineWidth: selected ? 1.25 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hosting.bind.choice.\(preset.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectAddress(_ address: String) {
        customAddressText = address
        customAddressError = nil
        _ = store.setBindAddress(address)
    }

    private func useCustomAddress() {
        guard HostingAddressPolicy.isSupportedBindAddress(customAddressText),
              HostingAddressPolicy.bindScope(for: customAddressText) == .specificInterface
        else {
            customAddressError = "Enter a valid RFC 1918 LAN or Tailscale IPv4 address."
            return
        }
        _ = store.setBindAddress(customAddressText)
        customAddressError = nil
    }
}

enum HostingBindPreset: String, CaseIterable, Sendable {
    case loopback
    case specificInterface
    case allInterfaces

    var scope: HostingBindScope {
        switch self {
        case .loopback: .loopback
        case .specificInterface: .specificInterface
        case .allInterfaces: .allInterfaces
        }
    }

    func isSelected(for options: HostingOptions) -> Bool {
        options.bindScope == scope
    }

    func address(for options: HostingOptions, activeAddresses: [String]) -> String? {
        switch self {
        case .loopback:
            return HostingOptions.loopbackBindAddress
        case .specificInterface:
            if options.bindScope == .specificInterface { return options.bindAddress }
            return activeAddresses.first(where: HostingAddressPolicy.isSupportedBindAddress)
        case .allInterfaces:
            return HostingOptions.allInterfacesBindAddress
        }
    }
}

private struct HostingCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct HostingNotice: View {
    enum Style { case information, warning, danger }
    let title: String
    let message: String
    let style: Style
    let symbol: String

    private var tint: Color {
        switch style {
        case .information: .accentColor
        case .warning: .orange
        case .danger: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(style == .danger ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 11))
    }
}
