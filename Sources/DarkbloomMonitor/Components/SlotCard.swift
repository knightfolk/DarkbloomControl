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
                if let reason = slot.kvFallbackReasonDescription { slotRow("KV fallback", reason) }
                slotRow("MTP enabled", slot.mtpEnabled ? "Yes" : "No")
                slotRow("Drafting", draftingDescription)
                if slot.mtpReason != nil { slotRow("MTP reason", slot.mtpReasonDescription) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Model slot \(slot.model), effective KV \(slot.kvBackend), requested KV \(slot.requestedKVBackend), drafting \(draftingDescription)"
                + (slot.mtpReason == nil ? "" : ", " + slot.mtpReasonDescription)
                + (slot.kvFallbackReasonDescription.map { ", KV fallback: " + $0 } ?? "")
        )
    }

    private var draftingDescription: String {
        if slot.mtpEnabled && slot.mtpActive && slot.mtpReason == nil { return "Active" }
        return slot.mtpEnabled ? "Inactive" : "Disabled"
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
