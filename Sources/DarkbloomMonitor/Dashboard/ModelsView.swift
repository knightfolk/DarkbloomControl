import SwiftUI

/// Hosts the model editor and its staged draft; opening this route does
/// not acquire data, reset edits, or create a second control service.
struct ModelsView: View {
    let controlStore: ProviderControlStore?
    var monitorStore: MonitorStore? = nil
    var networkContext: (String, Date) -> [String] = { _, _ in [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Models").font(.largeTitle.bold())
                Text("Choose your models and how much work this Mac takes on.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            if let controlStore {
                if let monitorStore {
                    DisclosureGroup("Running and saved selection") {
                        ProviderSelectionView(store: monitorStore, controlStore: controlStore)
                    }.padding(.horizontal, 24).padding(.bottom, 16)
                }
                ModelManagerView(store: controlStore, networkContext: networkContext)
            } else {
                ContentUnavailableView("Model controls unavailable", systemImage: "cpu",
                                       description: Text("The provider control service is not available. Monitoring continues independently."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
