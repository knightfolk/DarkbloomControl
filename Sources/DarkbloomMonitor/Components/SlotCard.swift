import DarkbloomTelemetry
import SwiftUI

struct SlotCard: View {
    let slot: ModelSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(slot.model)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(slot.model)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                slotRow("Effective KV", slot.kvBackend)
                slotRow("Requested KV", slot.requestedKVBackend)
                slotRow("MTP enabled", slot.mtpEnabled ? "Yes" : "No")
                slotRow("MTP active", slot.mtpActive ? "Yes" : "No")
                slotRow("MTP reason", slot.displayMTPReason)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Model slot \(slot.model), effective KV \(slot.kvBackend), requested KV \(slot.requestedKVBackend), MTP enabled \(slot.mtpEnabled ? "yes" : "no"), MTP active \(slot.mtpActive ? "yes" : "no"), MTP reason \(slot.displayMTPReason)"
        )
    }

    @ViewBuilder
    private func slotRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(value)
        }
    }
}
