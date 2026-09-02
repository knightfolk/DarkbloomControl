import DarkbloomTelemetry
import SwiftUI

enum PopupModelPresentation: Equatable {
    case models([DashboardModel])
    case unavailable

    static func make(
        input: PopupModelSourceInput,
        controlSources: ProviderControlSourceStates?
    ) -> Self {
        guard case .available(let state, _) = input.daemonState,
              case .available(let loadedModels, _) = input.loadedModels,
              controlSources?.daemon.isMarkedFresh == true,
              controlSources?.loadedModels.isMarkedFresh == true
        else { return .unavailable }

        let enabledFilter: String?
        if case .available(let status, _) = input.status {
            enabledFilter = status.enabledModelFilter
        } else {
            enabledFilter = nil
        }
        return .models(DashboardModelDeriver.models(
            enabledFilter: enabledFilter,
            loadedModels: loadedModels.models,
            warmModels: state.warmModels,
            slotModels: state.slots.map(\.model),
            currentModel: state.currentModel,
            inferenceActive: state.inferenceActive
        ))
    }
}

struct PopupModelSourceInput: Equatable {
    let daemonState: SourceAvailability<DaemonState>
    let loadedModels: SourceAvailability<LoadedModelsState>
    let status: SourceAvailability<StatusSnapshot>

    init(snapshot: TelemetrySnapshot) {
        daemonState = snapshot.state
        loadedModels = snapshot.loadedModels
        status = snapshot.status
    }

    init(
        daemonState: SourceAvailability<DaemonState>,
        loadedModels: SourceAvailability<LoadedModelsState>,
        status: SourceAvailability<StatusSnapshot>
    ) {
        self.daemonState = daemonState
        self.loadedModels = loadedModels
        self.status = status
    }
}

struct MonitorPopover: View {
    @ObservedObject var store: MonitorStore
    @EnvironmentObject private var controlStore: ProviderControlStore
    let openSettings: () -> Void

    init(
        store: MonitorStore,
        openSettings: @escaping () -> Void = {}
    ) {
        self.store = store
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            providerHeader
            throughputSection
            jobsSection
            modelsSection
        }
        .padding(20)
        .frame(width: 400, height: 600, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            DarkbloomLogo(
                image: DarkbloomLogoAsset.sourceImage,
                tint: logoColor
            )
            .frame(width: 22, height: 25)

            Text("Darkbloom")
                .font(.title2.weight(.bold))

            Spacer()

            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityIdentifier("dashboard.settings")

            Button(role: .destructive) {
                Task { await store.quit() }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Quit Darkbloom Monitor")
            .accessibilityLabel("Quit Darkbloom Monitor")
            .accessibilityIdentifier("dashboard.quit")
        }
    }

    private var providerHeader: some View {
        HStack {
            Label("Provider", systemImage: "server.rack")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            ProviderLifecycleControls(store: controlStore, snapshot: store.snapshot)
        }
    }

    private var throughputSection: some View {
        DashboardSection(title: "Throughput", systemImage: "speedometer") {
            HStack(spacing: 12) {
                InfographicMetricCard(
                    title: "Current",
                    unit: currentTokenRate == nil ? nil : "tok/sec",
                    accessibilityValue: currentTokenRate.map { "\($0) tokens per second" }
                        ?? currentTokenFallback
                ) {
                    if let currentTokenRate {
                        Text(
                            currentTokenRate,
                            format: .number.precision(.fractionLength(1))
                        )
                    } else {
                        Text(currentTokenFallback)
                    }
                }

                InfographicMetricCard(
                    title: "Session average",
                    unit: averageTokenRate == nil ? nil : "tok/sec",
                    accessibilityValue: averageTokenRate.map { "\($0) tokens per second" }
                        ?? "Not available"
                ) {
                    if let averageTokenRate {
                        Text(
                            averageTokenRate,
                            format: .number.precision(.fractionLength(1))
                        )
                    } else {
                        Text("—")
                    }
                }
            }
        }
    }

    private var jobsSection: some View {
        DashboardSection(title: "Completed jobs", systemImage: "checkmark.circle.fill") {
            HStack(spacing: 12) {
                InfographicMetricCard(
                    title: "Today",
                    unit: nil,
                    accessibilityValue: jobSummary.map { "\($0.completedToday) jobs" }
                        ?? "Not available"
                ) {
                    if let summary = jobSummary {
                        Text(summary.completedToday, format: .number.grouping(.automatic))
                    } else {
                        Text("—")
                    }
                }

                InfographicMetricCard(
                    title: "7-day average",
                    unit: averageJobsPerDay == nil ? nil : "per day",
                    accessibilityValue: averageJobsPerDay.map { "\($0) jobs per day" }
                        ?? "Not available"
                ) {
                    if let averageJobsPerDay {
                        Text(
                            averageJobsPerDay,
                            format: .number.precision(.fractionLength(1))
                        )
                    } else {
                        Text("—")
                    }
                }
            }
        }
    }

    private var modelsSection: some View {
        DashboardSection(title: "Models", systemImage: "cpu") {
            switch modelPresentation {
            case .unavailable:
                Text("Model state unavailable")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            case .models(let models) where models.isEmpty:
                Text("No models reported")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            case .models(let models):
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(models) { model in
                        ModelStatusPill(model: model)
                    }
                }
            }
        }
    }

    private var currentTokenRate: Double? {
        guard store.snapshot.state.value?.inferenceActive == true,
              case .available(let value, _) = store.snapshot.tokenRate,
              value.isFinite
        else { return nil }
        return value
    }

    private var currentTokenFallback: String {
        guard let state = store.snapshot.state.value else { return "—" }
        return state.inferenceActive ? "—" : "Idle"
    }

    private var averageTokenRate: Double? {
        guard case .available(let value, _) = store.averageTokenRate,
              value.isFinite
        else { return nil }
        return value
    }

    private var jobSummary: JobCompletionSummary? {
        store.jobSummary.value
    }

    private var averageJobsPerDay: Double? {
        jobSummary?.averagePerDay
    }

    private var modelPresentation: PopupModelPresentation {
        .make(
            input: PopupModelSourceInput(snapshot: store.snapshot),
            controlSources: controlStore.snapshot?.sources
        )
    }

    private var models: [DashboardModel] {
        guard case .models(let models) = modelPresentation else { return [] }
        return models
    }

    private var logoColor: Color {
        switch models.first?.state {
        case .active: .green
        case .loadedIdle: .yellow
        case .availableUnloaded, nil: .secondary
        }
    }

}

private struct DashboardSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InfographicMetricCard<Value: View>: View {
    let title: String
    let unit: String?
    let accessibilityValue: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                value()
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let unit {
                    Text(unit)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(12)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}

private struct ModelStatusPill: View {
    let model: DashboardModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)

            Text(model.name)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(backgroundOpacity), in: Capsule())
        .help("\(model.name) — \(statusName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.name), \(statusName)")
    }

    private var color: Color {
        switch model.state {
        case .active: .green
        case .loadedIdle: .yellow
        case .availableUnloaded: .gray
        }
    }

    private var backgroundOpacity: Double {
        model.state == .availableUnloaded ? 0.12 : 0.18
    }

    private var statusName: String {
        switch model.state {
        case .active: "active"
        case .loadedIdle: "loaded but idle"
        case .availableUnloaded: "available but not loaded"
        }
    }
}
