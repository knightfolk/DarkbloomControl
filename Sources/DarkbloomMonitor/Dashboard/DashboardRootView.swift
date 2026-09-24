import SwiftUI

enum DashboardDestination: String, CaseIterable, Identifiable {
    case overview = "Overview", activity = "Activity", opportunity = "Opportunity"
    case models = "Models", hosting = "Hosting", health = "Health & Logs", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .activity: "chart.bar"
        case .opportunity: "network"
        case .models: "cpu"
        case .hosting: "antenna.radiowaves.left.and.right"
        case .health: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class DashboardNavigation: ObservableObject {
    private let defaults: UserDefaults
    @Published var selected: DashboardDestination {
        didSet { defaults.set(selected.rawValue, forKey: "dashboard.selectedSection") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: "dashboard.selectedSection").flatMap(DashboardDestination.init(rawValue:)) ?? .overview
    }
}

struct DashboardRootView: View {
    @ObservedObject var store: MonitorStore
    let controlStore: ProviderControlStore?
    var hostingStore: HostingSettingsStore? = nil
    @ObservedObject var navigation: DashboardNavigation
    private var selectedRaw: String { navigation.selected.rawValue }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<DashboardDestination?>(
                get: { DashboardDestination(rawValue: selectedRaw) ?? .overview },
                set: { if let value = $0 { navigation.selected = value } }
            )) {
                ForEach(DashboardDestination.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            if selectedRaw == DashboardDestination.overview.rawValue || DashboardDestination(rawValue: selectedRaw) == nil {
                DashboardOverviewView(store: store, controlStore: controlStore)
            } else if selectedRaw == DashboardDestination.activity.rawValue {
                ActivityView(store: store)
            } else if selectedRaw == DashboardDestination.opportunity.rawValue {
                OpportunityView(store: store, controlStore: controlStore)
            } else if selectedRaw == DashboardDestination.models.rawValue {
                ModelsView(controlStore: controlStore, monitorStore: store) { modelID, date in
                    let network = ModelNetworkContext.labels(modelID: modelID, capacity: store.networkCapacity, pricing: store.publicPricing, now: date)
                    let performance = ModelNetworkContext.performanceLabel(modelID: modelID, averages: store.modelTokenRateAverages, now: date)
                    let work = ModelNetworkContext.workLabel(modelID: modelID, values: store.modelWorkEarnings, now: date)
                    return network + [performance, work].compactMap { $0 }
                }
            } else if navigation.selected == .hosting {
                if let hostingStore {
                    HostingSettingsView(store: hostingStore)
                } else {
                    ContentUnavailableView(
                        "Hosting unavailable",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Provider hosting controls are not available in this session.")
                    )
                }
            } else if navigation.selected == .settings {
                MonitorSettingsView(
                    extrasStore: store.providerExtras,
                    controlStore: controlStore
                )
            } else {
                HealthView(store: store)
            }
        }
        .toolbar {
            Button { navigation.selected = .settings } label: { Label("Settings", systemImage: "gearshape") }
                .help("Open Settings")
        }
        .onChange(of: store.snapshot.status.value?.version) { _, _ in
            hostingStore?.refreshEnvironment()
        }
    }
}
