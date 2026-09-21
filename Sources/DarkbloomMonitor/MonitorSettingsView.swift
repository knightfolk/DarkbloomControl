import DarkbloomTelemetry
import SwiftUI

struct MonitorSettingsView: View {
    var extrasStore: ProviderExtrasStore? = nil
    var controlStore: ProviderControlStore? = nil
    @AppStorage("menuBarDisplayMode") private var displayModeRaw =
        MenuBarDisplayMode.automatic.rawValue

    var body: some View {
        Form {
            GeneralSettingsView(displayModeRaw: $displayModeRaw)
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
                Toggle("Track estimated adapter energy", isOn: $electricityEnabled)
                    .accessibilityIdentifier("settings.electricity.enabled")
                TextField("Price (USD / kWh)", text: $electricityRate)
                    .accessibilityIdentifier("settings.electricity.rate")
                if !electricityRate.isEmpty && ElectricityCost.rate(electricityRate) == nil {
                    Text("Enter a non-negative dollar amount, such as 0.15.")
                        .foregroundStyle(.red)
                }
                Text("Use dollars, not cents. Samples are stored locally every 10 seconds while enabled. This is estimated DC adapter input for the whole Mac, not wall power or Darkbloom-only consumption. Unplugged or missing readings leave gaps. Earnings after electricity requires matching coverage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Menu bar") {
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
            || control.queuedStopState != nil
            || control.draft?.hasChanges == true)
        if let error = control.errorMessage {
            Section { Text(error).foregroundStyle(.orange) }
        }
    }
}
