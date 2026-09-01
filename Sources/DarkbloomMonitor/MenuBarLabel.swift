import DarkbloomTelemetry
import SwiftUI

struct MenuBarLabel: View {
    let status: MenuPresentationStatus

    var body: some View {
        Image(systemName: status.symbolName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(statusColor, .secondary)
            .accessibilityLabel(status.accessibilityLabel)
    }

    private var statusColor: Color {
        switch status {
        case .online:
            .green
        case .stale:
            .orange
        case .offline:
            .red
        case .unavailable:
            .secondary
        }
    }
}
