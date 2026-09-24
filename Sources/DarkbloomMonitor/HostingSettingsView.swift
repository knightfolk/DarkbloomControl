import DarkbloomTelemetry
import SwiftUI

/// The Hosting surface inside Settings. It configures the official local
/// OpenAI-compatible inference endpoint through documented `darkbloom start`
/// flags only; this app never starts its own server and never disables
/// bearer-token authentication.
struct HostingSettingsView: View {
    @ObservedObject var store: HostingSettingsStore
    @State private var portText: String = ""

    var body: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hosting").font(.title2.bold())
                    Text("Serve an official local OpenAI-compatible endpoint from this Mac's provider. Applied through the provider's own start command with bearer-token authentication always on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            endpointModeSection
            if !store.cliSupportsHosting {
                Section {
                    Text(HostingSettingsStore.unsupportedMessage(cliVersion: store.cliVersion))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            connectionDetailsSection
        }
        .onAppear {
            portText = String(store.options.port)
            store.refreshEnvironment()
        }
    }

    private var endpointModeSection: some View {
        Section("Local inference endpoint") {
            Picker("Endpoint", selection: modeBinding) {
                Text("Off · Fleet serving only").tag(HostingEndpointMode.off)
                Text("Alongside fleet · Local + coordinator").tag(HostingEndpointMode.unified)
                Text("Standalone · Not available").tag(HostingEndpointMode.standalone)
            }
            .pickerStyle(.menu)
            .disabled(!store.cliSupportsHosting)
            .accessibilityIdentifier("hosting.mode")

            modeExplanation
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.options.mode != .off {
                endpointNetworkRows
            }

            if store.options.mode == .standalone {
                Text(HostingEndpointMode.standaloneUnavailableReason)
                    .font(calloutWeighted)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.cliSupportsHosting {
                applyRow
            }

            if let message = store.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            "Allow LAN access to the local endpoint?",
            isPresented: lanConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Expose to LAN") {
                Task { await store.confirmPendingLANConfirmation() }
            }
            Button("Keep loopback only", role: .cancel) {
                store.cancelPendingLANConfirmation()
            }
        } message: {
            Text("The endpoint has no TLS and no rate limiting. Bearer-token authentication stays on, but anyone on the network who obtains the token can send inference requests on this Mac. Keep loopback unless you specifically need other devices to connect.")
        }
    }

    @ViewBuilder
    private var endpointNetworkRows: some View {
        TextField("Port (default \(HostingOptions.defaultPort))", text: $portText)
            .accessibilityIdentifier("hosting.port")
            .onChange(of: portText) { _, newValue in
                if !store.setPortText(newValue) {
                    // Keep the field editable; apply validates the final value.
                    store.clearErrorMessage()
                }
            }
        Picker("Reachable from", selection: bindBinding) {
            Text("This Mac only (loopback) · Recommended").tag(HostingOptions.loopbackBindAddress)
            ForEach(store.lanAddresses, id: \.self) { address in
                Text("LAN address \(address)").tag(address)
            }
            Text("All interfaces · Not recommended").tag(HostingOptions.allInterfacesBindAddress)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("hosting.bind")

        if store.options.bindScope == .specificInterface,
           !store.lanAddresses.contains(store.options.bindAddress) {
            Text("Saved LAN address \(store.options.bindAddress) is no longer active. Choose a current address or use loopback.")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if store.options.requiresLANConfirmation {
            Text("LAN exposure: the endpoint serves your network with no TLS and no rate limiting. Bearer-token authentication stays enabled, and applying asks again before anything changes.")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Loopback keeps the endpoint private to this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var applyRow: some View {
        Button(applyTitle) {
            Task { await store.requestApply() }
        }
        .accessibilityIdentifier("hosting.apply")
        Text(applyExplanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var applyTitle: String {
        store.options.mode == .unified ? "Apply · Restart provider" : "Apply · Remove endpoint"
    }

    private var applyExplanation: String {
        switch store.options.mode {
        case .off:
            "Applies through the provider's start command and removes the local endpoint. Accepted requests drain before the provider restarts; coordinator serving continues."
        case .unified:
            "Applies through the provider's start command. Fleet traffic and earnings continue; local and coordinator requests share model slots. Accepted requests drain before the provider restarts."
        case .standalone:
            HostingEndpointMode.standaloneUnavailableReason
        }
    }

    @ViewBuilder
    private var modeExplanation: some View {
        switch store.options.mode {
        case .off:
            Text("No local endpoint. The provider serves the Darkbloom network exactly as before.")
        case .unified:
            Text("The local endpoint runs alongside coordinator serving: fleet traffic keeps earning, and local plus fleet requests share one engine and the same model slots.")
        case .standalone:
            Text("Coordinator-less serving with no fleet traffic and no earnings, run as a plain foreground process.")
        }
    }

    private var connectionDetailsSection: some View {
        Section("Connection details") {
            if store.options.mode == .unified {
                unifiedEndpointDetails
            } else if store.options.mode == .off {
                standaloneEndpointDetails
            } else {
                Text("Standalone hosting is not managed by this app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var unifiedEndpointDetails: some View {
        Text("Configured address · available after Apply")
            .font(.callout.weight(.medium))
        if let url = store.configuredEndpointURL {
            Text(url)
                .textSelection(.enabled)
                .accessibilityIdentifier("hosting.details.configuredURL")
        }

        if store.options.bindAddress == HostingOptions.allInterfacesBindAddress {
            if store.lanAddresses.isEmpty {
                Text("No active private LAN address was found. This Mac can still connect through 127.0.0.1.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Other devices on your LAN")
                        .font(.callout.weight(.medium))
                    ForEach(store.lanAddresses, id: \.self) { address in
                        Text("http://\(address):\(store.options.port)/v1")
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("hosting.details.lanURLs")
            }
        } else if store.options.bindScope == .specificInterface {
            Text("For another device: http://\(store.options.bindAddress):\(store.options.port)/v1")
                .textSelection(.enabled)
                .accessibilityIdentifier("hosting.details.lanURL")
        }

        Button("Copy bearer token") {
            _ = store.copyBearerTokenToPasteboard()
        }
        .disabled(!store.canCopyBearerToken)
        .accessibilityIdentifier("hosting.details.copyToken")
        Text("The address reflects the settings above, not a live health check. The token is read from the provider's protected local file only when you choose Copy; Darkbloom Control never displays or saves it.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var standaloneEndpointDetails: some View {
        Button(store.isFetchingEndpointDetails ? "Checking…" : "Check for a running standalone endpoint") {
            Task { await store.fetchEndpointDetails() }
        }
        .accessibilityIdentifier("hosting.details.refresh")
        .disabled(store.isFetchingEndpointDetails)

        switch store.endpointDetails {
        case .some(.none):
            Text("No standalone local endpoint is advertised right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .some(.live(let record)):
            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL: \(record.baseURL)")
                Text("Reachable at \(record.host):\(record.port)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !record.hasBearerToken {
                    Text("Bearer authentication appears to be disabled on this endpoint; it was not started by these settings.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Copy bearer token") {
                _ = store.copyBearerTokenToPasteboard()
            }
            .disabled(!store.canCopyBearerToken)
            .accessibilityIdentifier("hosting.details.copyToken")
            Text("The token is read on demand from the provider's discovery record. It is never shown, logged, or saved by Darkbloom Control.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            Text("Check on demand to see whether a standalone provider advertises a live local endpoint.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeBinding: Binding<HostingEndpointMode> {
        Binding(
            get: { store.options.mode },
            set: { store.setMode($0) }
        )
    }

    private var bindBinding: Binding<String> {
        Binding(
            get: { store.options.bindAddress },
            set: { store.setBindAddress($0) }
        )
    }

    private var lanConfirmationBinding: Binding<Bool> {
        Binding(
            get: { store.pendingLANConfirmation != nil },
            set: { if !$0 { store.cancelPendingLANConfirmation() } }
        )
    }

    private var calloutWeighted: Font {
        .callout.weight(.medium)
    }
}
