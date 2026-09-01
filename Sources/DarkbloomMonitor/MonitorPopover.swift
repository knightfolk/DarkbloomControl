import DarkbloomTelemetry
import SwiftUI

struct MonitorPopover: View {
    @ObservedObject var store: MonitorStore

    @State private var showAllEvents = false
    @State private var advancedExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HeaderSection(snapshot: store.snapshot)
                PrimaryMetricsSection(snapshot: store.snapshot)
                ModelsAndSlotsSection(snapshot: store.snapshot)
                MemoryAndProcessSection(snapshot: store.snapshot)
                TrustSection(snapshot: store.snapshot)
                RecentEventsSection(snapshot: store.snapshot, showAll: $showAllEvents)
                AdvancedSection(snapshot: store.snapshot, isExpanded: $advancedExpanded)
                FooterSection(refresh: store.refresh, quit: store.quit)
            }
            .padding(16)
        }
        .frame(width: 420)
        .frame(maxHeight: 680)
    }
}

private struct HeaderSection: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Darkbloom")
                        .font(.title2.weight(.semibold))
                    Text(providerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(providerName)
                }
                Spacer(minLength: 8)
                if let state = snapshot.state.value {
                    StatusBadge(
                        text: state.trust.status,
                        tone: trustTone(state.trust.status),
                        accessibilityLabel: "Darkbloom trust status \(state.trust.status)"
                    )
                } else {
                    StatusBadge(
                        text: "Unavailable",
                        tone: .neutral,
                        accessibilityLabel: stateUnavailableText
                    )
                }
            }

            HStack(spacing: 12) {
                Label(inferenceText, systemImage: inferenceSymbol)
                    .font(.caption.weight(.medium))
                Spacer(minLength: 8)
                Text(stateAgeText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .stale(_, _, let reason) = snapshot.state {
                Text("State stale — \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .stale(_, _, let reason) = snapshot.status {
                Text("CLI status stale — \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerName: String {
        switch snapshot.status {
        case .available(let status, _), .stale(let status, _, _):
            guard let name = status.providerName, !name.isEmpty else {
                return TelemetryFormatting.unavailable("provider not reported by Darkbloom status")
            }
            return name
        case .unavailable(let reason):
            return TelemetryFormatting.unavailable(reason)
        }
    }

    private var stateAgeText: String {
        guard let state = snapshot.state.value else { return stateUnavailableText }
        let age = TelemetryDeriver.snapshotAge(
            state: state,
            now: snapshot.capturedAt.timeIntervalSince1970
        )
        return "State age: \(TelemetryFormatting.duration(age))"
    }

    private var stateUnavailableText: String {
        guard case .unavailable(let reason) = snapshot.state else {
            return TelemetryFormatting.unavailable("structured state not available")
        }
        return TelemetryFormatting.unavailable(reason)
    }

    private var inferenceText: String {
        guard let state = snapshot.state.value else { return stateUnavailableText }
        return state.inferenceActive ? "Active" : "Idle"
    }

    private var inferenceSymbol: String {
        guard let state = snapshot.state.value else { return "questionmark.circle" }
        return state.inferenceActive ? "bolt.fill" : "pause.circle.fill"
    }

    private func trustTone(_ status: String) -> StatusBadge.Tone {
        switch status {
        case "online": .online
        case "offline": .offline
        default: .stale
        }
    }
}

private struct PrimaryMetricsSection: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Primary metrics")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    MetricCard(title: "Current model", value: stateValue(\.currentModel), detail: stateDetail)
                    MetricCard(
                        title: "Token rate",
                        value: TelemetryFormatting.tokenRate(snapshot.tokenRate),
                        detail: "Counter delta over state-write time"
                    )
                }
                GridRow {
                    MetricCard(
                        title: "Requests served",
                        value: stateValue { TelemetryFormatting.integer($0.stats.requestsServed) },
                        detail: stateDetail
                    )
                    MetricCard(
                        title: "Tokens generated",
                        value: stateValue { TelemetryFormatting.integer($0.stats.tokensGenerated) },
                        detail: stateDetail
                    )
                }
            }

            HStack(spacing: 6) {
                Text("Usage gaps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(usageGapsText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(hasUsageGaps ? .orange : .primary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var usageGapsText: String {
        stateValue { TelemetryFormatting.integer($0.stats.usageGaps) }
    }

    private var hasUsageGaps: Bool {
        guard let value = snapshot.state.value?.stats.usageGaps else { return false }
        return value > 0
    }

    private var stateDetail: String? {
        guard case .stale(_, _, let reason) = snapshot.state else { return nil }
        return "State stale — \(reason)"
    }

    private func stateValue(_ keyPath: KeyPath<DaemonState, String>) -> String {
        stateValue { $0[keyPath: keyPath] }
    }

    private func stateValue(_ transform: (DaemonState) -> String) -> String {
        switch snapshot.state {
        case .available(let state, _), .stale(let state, _, _):
            transform(state)
        case .unavailable(let reason):
            TelemetryFormatting.unavailable(reason)
        }
    }
}

private struct ModelsAndSlotsSection: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Models and slots")
            valueRow("Loaded models", loadedModelsText)
            valueRow("Warm models", warmModelsText)

            if case .stale(_, _, let reason) = snapshot.loadedModels {
                Text("Loaded-model state stale — \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let state = snapshot.state.value {
                if state.slots.isEmpty {
                    valueRow("Slots", "None reported")
                } else {
                    ForEach(Array(state.slots.enumerated()), id: \.offset) { index, slot in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Slot \(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            SlotCard(slot: slot)
                        }
                    }
                }
            } else {
                valueRow("Slots", unavailable(snapshot.state))
            }
        }
    }

    private var loadedModelsText: String {
        switch snapshot.loadedModels {
        case .available(let loaded, _), .stale(let loaded, _, _):
            TelemetryFormatting.modelList(loaded.models)
        case .unavailable(let reason):
            TelemetryFormatting.unavailable(reason)
        }
    }

    private var warmModelsText: String {
        guard let state = snapshot.state.value else { return unavailable(snapshot.state) }
        return TelemetryFormatting.modelList(state.warmModels)
    }
}

private struct MemoryAndProcessSection: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Memory and process")
            if let state = snapshot.state.value {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    detailRow("Active GPU", TelemetryFormatting.gibibytes(state.capacity.gpuMemoryActiveGB))
                    detailRow("GPU cache", TelemetryFormatting.gibibytes(state.capacity.gpuMemoryCacheGB))
                    detailRow("Total memory", TelemetryFormatting.gibibytes(state.capacity.totalMemoryGB))
                    detailRow("PID", String(state.pid))
                    detailRow("Process start identity", TelemetryFormatting.integer(state.processIdentity.startTimeMicros))
                    detailRow("Provider started", TelemetryFormatting.timestamp(Date(timeIntervalSince1970: state.startedAt)))
                    detailRow("Uptime", TelemetryFormatting.duration(TelemetryDeriver.uptime(
                        state: state,
                        now: snapshot.capturedAt.timeIntervalSince1970
                    )))
                    detailRow("Darkbloom version", state.version)
                }

                if let fraction = TelemetryFormatting.memoryFraction(
                    active: state.capacity.gpuMemoryActiveGB,
                    total: state.capacity.totalMemoryGB
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: fraction)
                        Text(
                            "Active \(TelemetryFormatting.gibibytes(state.capacity.gpuMemoryActiveGB)) of \(TelemetryFormatting.gibibytes(state.capacity.totalMemoryGB)) total"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    valueRow("Active memory fraction", TelemetryFormatting.unavailable("active or total memory is invalid"))
                }
            } else {
                valueRow("Memory and process", unavailable(snapshot.state))
            }
        }
    }
}

private struct TrustSection: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Trust")
            if let state = snapshot.state.value {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    detailRow("Level", state.trust.level)
                    detailRow("Status", state.trust.status)
                    detailRow("Coordinator reason", state.trust.reason)
                    detailRow("Receipt time", TelemetryFormatting.timestamp(
                        Date(timeIntervalSince1970: state.trust.receivedAt)
                    ))
                    detailRow("Trust age", TelemetryFormatting.duration(TelemetryDeriver.trustAge(
                        state: state,
                        now: snapshot.capturedAt.timeIntervalSince1970
                    )))
                }
            } else {
                valueRow("Trust", unavailable(snapshot.state))
            }
        }
    }
}

private struct RecentEventsSection: View {
    let snapshot: TelemetrySnapshot
    @Binding var showAll: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Recent events")
                Spacer()
                if availableEvents.count > 20 {
                    Button(showAll ? "Show recent" : "Show all") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            showAll.toggle()
                        }
                    }
                    .font(.caption)
                }
            }

            if case .stale(_, _, let reason) = snapshot.eventFeed {
                Text("Logs stale — \(reason)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let emptyMessage = snapshot.eventFeed.eventEmptyMessage {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                ForEach(Array(visibleEvents.enumerated()), id: \.offset) { index, event in
                    if index > 0 { Divider() }
                    EventRow(event: event)
                }
            }
        }
    }

    private var availableEvents: [LogEvent] {
        Array((snapshot.eventFeed.value?.events ?? []).prefix(100))
    }

    private var visibleEvents: [LogEvent] {
        Array(availableEvents.prefix(showAll ? 100 : 20))
    }
}

private struct FooterSection: View {
    let refresh: () -> Void
    let quit: () async -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Refresh Now", action: refresh)
            Spacer()
            Text("Monitor version: development")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Quit") {
                Task { await quit() }
            }
            .keyboardShortcut("q")
        }
        .padding(.top, 2)
    }
}

@ViewBuilder
private func sectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.headline)
}

@ViewBuilder
private func valueRow(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(value)
            .font(.subheadline)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .help(value)
    }
    .accessibilityElement(children: .combine)
}

@ViewBuilder
private func detailRow(_ label: String, _ value: String) -> some View {
    GridRow {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(value)
            .font(.caption)
            .monospacedDigit()
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .help(value)
    }
    .accessibilityElement(children: .combine)
}

private func unavailable<Value>(_ availability: SourceAvailability<Value>) -> String
where Value: Equatable & Sendable {
    guard case .unavailable(let reason) = availability else {
        return TelemetryFormatting.unavailable("source value unavailable")
    }
    return TelemetryFormatting.unavailable(reason)
}
