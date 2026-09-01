import DarkbloomTelemetry
import SwiftUI

enum PopoverSection: String, CaseIterable, Hashable {
    case performance
    case modelsAndSlots
    case memoryAndProcess
    case trust
    case recentEvents
    case advanced
    case menuBarSettings
}

struct PopoverDisclosureDefaults {
    let expandedSections: Set<PopoverSection>

    static let compact = Self(expandedSections: [])
}

struct MonitorPopover: View {
    @ObservedObject var store: MonitorStore
    @Binding var displayMode: MenuBarDisplayMode

    @State private var showAllEvents = false
    @State private var expandedSections = PopoverDisclosureDefaults.compact.expandedSections

    init(
        store: MonitorStore,
        displayMode: Binding<MenuBarDisplayMode> = .constant(.automatic)
    ) {
        self.store = store
        _displayMode = displayMode
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                HeaderSection(
                    snapshot: store.snapshot,
                    presentation: store.menuPresentation(mode: displayMode),
                    earnings: store.earnings,
                    observedUptime: store.observedUptime
                )
                Divider()
                detailDisclosure(.performance, title: "Performance") {
                    PrimaryMetricsSection(snapshot: store.snapshot, earnings: store.earnings)
                }
                detailDisclosure(.modelsAndSlots, title: "Models and slots") {
                    ModelsAndSlotsSection(snapshot: store.snapshot)
                }
                detailDisclosure(.memoryAndProcess, title: "Memory and process") {
                    MemoryAndProcessSection(snapshot: store.snapshot)
                }
                detailDisclosure(.trust, title: "Trust") {
                    TrustSection(snapshot: store.snapshot)
                }
                detailDisclosure(.recentEvents, title: "Recent events") {
                    RecentEventsSection(snapshot: store.snapshot, showAll: $showAllEvents)
                }
                AdvancedSection(
                    snapshot: store.snapshot,
                    isExpanded: expansionBinding(for: .advanced)
                )
                detailDisclosure(.menuBarSettings, title: "Menu-bar settings") {
                    MenuBarSettingsSection(displayMode: $displayMode)
                }
                FooterSection(refresh: store.refresh, quit: store.quit)
            }
            .padding(16)
        }
        .frame(width: 420, height: 680)
    }

    @ViewBuilder
    private func detailDisclosure<Content: View>(
        _ section: PopoverSection,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: section)) {
            content()
                .padding(.top, 8)
        } label: {
            Text(title)
                .font(.headline)
        }
    }

    private func expansionBinding(for section: PopoverSection) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert(section)
                } else {
                    expandedSections.remove(section)
                }
            }
        )
    }
}

private struct HeaderSection: View {
    let snapshot: TelemetrySnapshot
    let presentation: MenuBarPresentation
    let earnings: EarningsPresentationValue
    let observedUptime: ObservedUptimeValue

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                DarkbloomLogo(image: DarkbloomLogoAsset.sourceImage, tint: healthColor)
                    .frame(width: 22, height: 25)
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
                StatusBadge(
                    text: presentation.health.isRoutable ? "Routable" : "Not routable",
                    tone: healthTone,
                    accessibilityLabel: presentation.accessibilityLabel
                )
            }

            Text(presentation.health.reason)
                .font(.caption.weight(presentation.health.isRoutable ? .regular : .semibold))
                .foregroundStyle(healthColor)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                summaryRow("Activity", inferenceText)
                summaryRow("Current model", currentModel)
                summaryRow(summaryMetricLabel, summaryMetricValue)
                summaryRow("Observed uptime · 24h", uptimeSummary)
                summaryRow("Thermal", presentation.thermal.displayName)
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

    private var currentModel: String {
        guard let model = snapshot.state.value?.currentModel, !model.isEmpty else {
            return stateUnavailableText
        }
        return model
    }

    private var summaryMetricLabel: String {
        snapshot.state.value?.inferenceActive == true ? "Token rate" : "Earnings · 24h"
    }

    private var summaryMetricValue: String {
        presentation.metricText ?? "Status only"
    }

    private var uptimeSummary: String {
        switch observedUptime {
        case .available(let percent, let observedSeconds):
            return "\(Int(percent.rounded()))% · \(coverage(observedSeconds)) observed"
        case .warming(let observedSeconds):
            return "Warming up · \(coverage(observedSeconds)) of 5m"
        case .unavailable(let reason):
            return TelemetryFormatting.unavailable(reason)
        }
    }

    private func coverage(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 {
            return String(format: "%.1fh", locale: Locale(identifier: "en_US_POSIX"), seconds / 3_600)
        }
        return "\(Int(seconds / 60))m"
    }

    private var healthColor: Color {
        switch presentation.health.color {
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        }
    }

    private var healthTone: StatusBadge.Tone {
        switch presentation.health.color {
        case .green: .online
        case .yellow, .orange: .stale
        case .red: .offline
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

    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PrimaryMetricsSection: View {
    let snapshot: TelemetrySnapshot
    let earnings: EarningsPresentationValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            valueRow("Authenticated earnings · rolling 24h", earningsText)

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

    private var earningsText: String {
        switch earnings {
        case .available(let microUSD):
            let dollars = Double(microUSD) / 1_000_000
            return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), dollars)
        case .stale(let microUSD, let reason):
            let dollars = Double(microUSD) / 1_000_000
            return String(format: "$%.2f · stale — %@", locale: Locale(identifier: "en_US_POSIX"), dollars, reason)
        case .unavailable(let reason):
            return TelemetryFormatting.unavailable(reason)
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

private struct MenuBarSettingsSection: View {
    @Binding var displayMode: MenuBarDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Displayed metric", selection: $displayMode) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text("Automatic shows token rate while active and rolling 24-hour earnings while idle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
