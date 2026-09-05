import SwiftUI

/// Hosts the model editor and its staged draft; opening this route does
/// not acquire data, reset edits, or create a second control service.
struct ModelsView: View {
    let controlStore: ProviderControlStore?
    var networkContext: (String, Date) -> [String] = { _, _ in [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Models").font(.largeTitle.bold())
                Text("Enable, preload, and manage downloaded models. Save Changes applies your staged configuration.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            if let controlStore {
                ModelManagerView(store: controlStore, networkContext: networkContext)
            } else {
                ContentUnavailableView("Model controls unavailable", systemImage: "cpu",
                                       description: Text("The provider control service is not available. Monitoring continues independently."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
