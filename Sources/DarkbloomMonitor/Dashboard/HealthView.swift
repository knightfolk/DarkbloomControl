import SwiftUI
import DarkbloomTelemetry

struct HealthView: View {
    @ObservedObject var store: MonitorStore
    @State private var showsLogs = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Health & Logs").font(.largeTitle.bold())
            Picker("View", selection: $showsLogs) {
                Text("Source health").tag(false)
                Text("Logs").tag(true)
            }
            .pickerStyle(.segmented)
            if showsLogs {
                LogsView(feed: store.snapshot.eventFeed)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(store.snapshot.menuStatus.accessibilityLabel)
                            .font(.headline)
                        Label("Mac thermal state: \(store.thermalState.displayName)", systemImage: "thermometer.medium")
                            .font(.headline)
                            .accessibilityLabel("Mac thermal state, \(store.thermalState.displayName), reported by macOS")
                        Text("Thermal state is reported by macOS, independently of provider health.")
                            .font(.caption).foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            if let warning = HealthPresentation.daemonWarning(store.snapshot.state, at: context.date) {
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                        }
                        if let state = store.snapshot.state.value {
                            Text("Daemon snapshot written \(TelemetryFormatting.timestamp(Date(timeIntervalSince1970: state.writtenAt)))")
                                .font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 12) {
                                ForEach(HealthPresentation.daemonRows(state)) { row in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                                        Text(row.value).font(.headline).monospacedDigit().textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            Text("Memory values are daemon-reported GPU allocations, not free system RAM. Reported slots are not a configured capacity limit.")
                                .font(.caption).foregroundStyle(.secondary)
                            if !state.slots.isEmpty {
                                Text("Reported model slots").font(.headline)
                                Text("KV is the attention-cache backend. MTP is multi-token prediction; enabled and active are separate daemon-reported states.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(state.slots.enumerated()), id: \.offset) { _, slot in
                                    SlotCard(slot: slot)
                                }
                            }
                        }
                        AdvancedSection(snapshot: store.snapshot, isExpanded: $expanded)
                    }
                }
                Text("Read-only diagnostics from the shared collector. Missing or stale sources are not treated as healthy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
