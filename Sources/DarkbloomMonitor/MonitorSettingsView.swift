import DarkbloomTelemetry
import SwiftUI

struct MonitorSettingsView: View {
    @EnvironmentObject private var controlStore: ProviderControlStore
    @AppStorage("menuBarDisplayMode") private var displayModeRaw =
        MenuBarDisplayMode.automatic.rawValue

    var body: some View {
        TabView {
            GeneralSettingsView(displayModeRaw: $displayModeRaw)
                .tabItem { Label("General", systemImage: "gearshape") }

            ModelManagerView(store: controlStore)
                .tabItem { Label("Models", systemImage: "shippingbox") }
        }
        .frame(minWidth: 680, minHeight: 560)
    }
}

private struct GeneralSettingsView: View {
    @Binding var displayModeRaw: String

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Displayed metric", selection: displayModeBinding) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text("Automatic shows token rate while active and rolling 24-hour earnings while idle.")
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
