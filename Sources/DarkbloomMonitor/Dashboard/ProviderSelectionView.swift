import DarkbloomTelemetry
import SwiftUI

struct ProviderSelectionView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var controlStore: ProviderControlStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            VStack(alignment: .leading, spacing: 10) {
                Text("Selections").font(.headline)
                if let control = controlStore.snapshot {
                    let saved = control.inventory.myCatalog.filter(\.isEnabled).map(\.catalogID)
                    row("Saved selection", ids: saved)
                    Text("Settings last read " + control.capturedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if case .available(let state, _) = store.snapshot.state,
                       (0...10).contains(context.date.timeIntervalSince1970 - state.writtenAt),
                       let advertised = state.advertisedModels {
                        row("Advertised now", ids: advertised)
                        row("Loaded now", ids: state.warmModels)
                        if Set(saved) != Set(advertised) {
                            Label("Restart applies a different saved selection", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.callout)
                        }
                        let onDemand = Set(advertised).subtracting(state.warmModels).sorted()
                        if !onDemand.isEmpty {
                            Text("Advertised, not loaded: " + onDemand.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("These models can be requested on demand. Absence alone does not establish why they are unloaded.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Running selection is not currently verified").foregroundStyle(.secondary)
                    }
                    if controlStore.draft?.hasChanges == true {
                        Text("Unsaved model edits are separate from the saved selection above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Refresh model controls to compare selections").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(_ title: String, ids: [String]) -> some View {
        LabeledContent(title) {
            Text(ids.isEmpty ? "None" : ids.sorted().map { id in controlStore.snapshot?.inventory.myCatalog.first(where: { $0.catalogID == id })?.displayName ?? id }.joined(separator: ", "))
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}
