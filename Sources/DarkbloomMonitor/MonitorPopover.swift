import DarkbloomTelemetry
import SwiftUI

struct MonitorPopover: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    sourceReason("Daemon state", availability: store.snapshot.state)
                    sourceReason("Loaded models", availability: store.snapshot.loadedModels)
                    sourceReason("CLI status", availability: store.snapshot.status)
                    sourceReason("Events", availability: store.snapshot.eventFeed)
                }

                Divider()

                HStack {
                    Button("Refresh Now") {
                        store.refresh()
                    }

                    Spacer()

                    Button("Quit") {
                        Task {
                            await store.quit()
                        }
                    }
                    .keyboardShortcut("q")
                }
            }
            .padding(20)
        }
        .frame(width: 420)
        .frame(maxHeight: 680)
    }

    private var header: some View {
        HStack(spacing: 8) {
            MenuBarLabel(status: store.snapshot.menuStatus)
            Text("Darkbloom Monitor")
                .font(.headline)
            Spacer()
            Text(store.snapshot.menuStatus.accessibilityLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sourceReason<Value>(
        _ source: String,
        availability: SourceAvailability<Value>
    ) -> some View where Value: Equatable & Sendable {
        if let reason = unavailableReason(availability) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source)
                    .font(.subheadline.weight(.medium))
                Text(TelemetryFormatting.unavailable(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func unavailableReason<Value>(
        _ availability: SourceAvailability<Value>
    ) -> String? where Value: Equatable & Sendable {
        guard case .unavailable(let reason) = availability else { return nil }
        return reason
    }
}
