import DarkbloomTelemetry
import SwiftUI

struct MonitorSettingsView: View {
    @AppStorage("menuBarDisplayMode") private var displayModeRaw =
        MenuBarDisplayMode.automatic.rawValue

    var body: some View {
        GeneralSettingsView(displayModeRaw: $displayModeRaw)
    }
}

private struct GeneralSettingsView: View {
    @Binding var displayModeRaw: String
    @AppStorage("electricity.usdPerKWh") private var electricityRate = ""
    @AppStorage("electricity.enabled") private var electricityEnabled = false

    var body: some View {
        Form {
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

                Text("Automatic shows token rate when available, otherwise today's earnings. An asterisk marks partial-day earnings coverage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var displayModeBinding: Binding<MenuBarDisplayMode> {
        Binding(
            get: { MenuBarDisplayMode(rawValue: displayModeRaw) ?? .automatic },
            set: { displayModeRaw = $0.rawValue }
        )
    }
}
