import DarkbloomTelemetry
import SwiftUI

struct MonitorSettingsView: View {
    var extrasStore: ProviderExtrasStore? = nil
    var controlStore: ProviderControlStore? = nil
    var hostingStore: HostingSettingsStore? = nil
    @AppStorage("menuBarDisplayMode") private var displayModeRaw =
        MenuBarDisplayMode.automatic.rawValue

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings").font(.largeTitle.bold())
                    Text("App preferences apply immediately. Provider settings below show saved choices.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            ControlAppUpdateSettings()
            CLIUpdateNoticeView(store: CLIUpdateStatusStore.shared)
            GeneralSettingsView(displayModeRaw: $displayModeRaw)
            if let hostingStore {
                HostingSettingsView(store: hostingStore)
            }
            if let extrasStore, let controlStore {
                ProviderAdvancedSettingsHost(extras: extrasStore, control: controlStore)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettingsView: View {
    @Binding var displayModeRaw: String
    @AppStorage("electricity.usdPerKWh") private var electricityRate = ""
    @AppStorage("electricity.enabled") private var electricityEnabled = false

    var body: some View {
        Group {
            Section("Electricity") {
                Toggle(isOn: $electricityEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Estimate electricity use")
                        Text(electricityEnabled ? "On · Records available readings locally" : "Off · Not recording")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Estimate electricity use")
                .accessibilityIdentifier("settings.electricity.enabled")
                TextField("Price (USD / kWh)", text: $electricityRate)
                    .accessibilityIdentifier("settings.electricity.rate")
                    .disabled(!electricityEnabled)
                if !electricityRate.isEmpty && ElectricityCost.rate(electricityRate) == nil {
                    Text("Enter a non-negative dollar amount, such as 0.15.")
                        .foregroundStyle(.red)
                }
                DisclosureGroup("About electricity estimates") {
                    Text("Enter dollars, not cents. Estimates cover the whole Mac’s DC adapter input, not wall power or Darkbloom alone. Readings are stored locally every 10 seconds. Unplugged or missing readings leave gaps; net earnings require matching coverage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Menu bar · Applies immediately") {
                Picker("Displayed metric", selection: displayModeBinding) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text("Automatic shows Working or today's model average during activity, and today's earnings while idle. An asterisk marks partial-day earnings coverage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displayModeBinding: Binding<MenuBarDisplayMode> {
        Binding(
            get: { MenuBarDisplayMode(rawValue: displayModeRaw) ?? .automatic },
            set: { displayModeRaw = $0.rawValue }
        )
    }
}


private struct ProviderAdvancedSettingsHost: View {
    @ObservedObject var extras: ProviderExtrasStore
    @ObservedObject var control: ProviderControlStore
    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider settings").font(.title2.bold())
                    if let capturedAt = extras.snapshot?.capturedAt {
                        Text("Last checked \(capturedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(extras.isRefreshing ? "Refreshing…" : "Refresh") {
                    Task { await extras.refresh() }
                }
                .disabled(extras.isRefreshing || extras.mutationInFlight)
            }
        }
        if control.draft?.hasChanges == true {
            Section {
                Text("Save or discard your model edits before changing idle-memory or beta settings.")
                    .foregroundStyle(.orange)
            }
        }
        ProviderAdvancedSettingsView(store: extras, performMutation: { label, mutation in
            await control.performSettingsMutation(label, mutation: mutation)
        })
        .disabled(control.operation != .idle
            || control.pendingConfirmation != nil
            || control.draft?.hasChanges == true)
        if let error = control.errorMessage {
            Section { Text(error).foregroundStyle(.orange) }
        }
    }
}
