import DarkbloomTelemetry
import SwiftUI

enum PopupModelPresentation: Equatable {
    case models([DashboardModel])
    case unavailable

    static func make(input: PopupModelSourceInput) -> Self {
        let enabledFilter: String?
        if case .available(let status, _) = input.status {
            enabledFilter = status.enabledModelFilter
        } else {
            enabledFilter = nil
        }

        if runningState(from: input.status) == false {
            return .models(DashboardModelDeriver.models(
                enabledFilter: enabledFilter,
                loadedModels: [],
                warmModels: [],
                slotModels: [],
                currentModel: nil,
                inferenceActive: false
            ))
        }

        let state: DaemonState
        let inferenceActive: Bool
        switch input.daemonState {
        case .available(let value, _):
            state = value
            inferenceActive = value.inferenceActive
        case .stale(let value, _, _)
            where runningState(from: input.status) == true:
            state = value
            inferenceActive = false
        case .stale, .unavailable:
            if enabledFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return .models(DashboardModelDeriver.models(
                    enabledFilter: enabledFilter,
                    loadedModels: [],
                    warmModels: [],
                    slotModels: [],
                    currentModel: nil,
                    inferenceActive: false
                ))
            }
            return .unavailable
        }

        let loadedModels: [String]
        if case .available(let state, _) = input.loadedModels {
            loadedModels = state.models
        } else {
            loadedModels = []
        }

        return .models(DashboardModelDeriver.models(
            enabledFilter: enabledFilter,
            loadedModels: loadedModels,
            warmModels: state.warmModels,
            slotModels: state.slots.map(\.model),
            currentModel: state.currentModel,
            inferenceActive: inferenceActive
        ))
    }

    private static func runningState(
        from availability: SourceAvailability<StatusSnapshot>
    ) -> Bool? {
        guard case .available(let status, _) = availability,
              let daemon = status.daemon?.trimmingCharacters(in: .whitespacesAndNewlines)
                  .lowercased()
        else { return nil }
        if daemon.hasPrefix("running") { return true }
        if daemon.hasPrefix("stopped") || daemon.hasPrefix("not running") { return false }
        return nil
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

struct PopupEarningsMetrics: Equatable {
    let totalUSD: Double
    let perHourUSD: Double

    static func make(from summary: ObservedEarningsWindow?) -> Self? {
        guard let summary,
              summary.microUSD >= 0,
              let perHour = EarningsHourlyRate.derive(
                  microUSD: summary.microUSD,
                  observedSeconds: summary.observedSeconds
              )
        else { return nil }
        return Self(
            totalUSD: Double(summary.microUSD) / 1_000_000,
            perHourUSD: perHour
        )
    }
}

struct PopupWeekEarningsMetric: Equatable {
    let title: String
    let totalUSD: Double

    static func make(from summary: CalendarWeekEarningsSummary?) -> Self? {
        guard let summary, summary.microUSD >= 0 else { return nil }
        return Self(
            title: summary.isComplete ? "This week" : "Observed this week",
            totalUSD: Double(summary.microUSD) / 1_000_000
        )
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(currentTime: context.date)
        }
    }

    private func content(currentTime: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            providerHeader(currentTime: currentTime)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    throughputSection
                    if earningsMetrics != nil || weekEarningsMetric != nil {
                        earningsSection(earningsMetrics, week: weekEarningsMetric)
                    }
                    jobsSection
                    modelsSection
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.visible)
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

    private func providerHeader(currentTime: Date) -> some View {
        HStack {
            Label("Provider", systemImage: "server.rack")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            ProviderLifecycleControls(
                store: controlStore,
                snapshot: store.snapshot,
                currentTime: currentTime
            )
        }
    }

    private var throughputSection: some View {
        DashboardSection(title: "Throughput", systemImage: "speedometer") {
            let breakdown = ModelTokenRatePresentation.breakdown(
                store.modelTokenRateAverages
            )
            if breakdown.isEmpty {
                HStack(spacing: 12) {
                    currentRateCard
                    if let averageTokenRate {
                        InfographicMetricCard(
                            title: "Today's average",
                            unit: "tok/sec",
                            accessibilityValue: "\(averageTokenRate) tokens per second today"
                        ) {
                            Text(
                                averageTokenRate,
                                format: .number.precision(.fractionLength(1))
                            )
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    currentRateCard
                    ModelTokenRatePanel(averages: breakdown)
                }
            }
        }
    }

    private var currentRateCard: some View {
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
    }

    private func earningsSection(
        _ metrics: PopupEarningsMetrics?,
        week: PopupWeekEarningsMetric?
    ) -> some View {
        DashboardSection(title: "Earnings", systemImage: "dollarsign.circle.fill") {
            VStack(alignment: .leading, spacing: 12) {
                if let metrics {
                    HStack(spacing: 12) {
                        InfographicMetricCard(
                            title: "Today",
                            unit: nil,
                            accessibilityValue: "\(metrics.totalUSD) dollars earned today"
                        ) {
                            Text(
                                metrics.totalUSD,
                                format: .currency(code: "USD").precision(.fractionLength(2))
                            )
                        }

                        InfographicMetricCard(
                            title: "Average",
                            unit: "per hour",
                            accessibilityValue: "\(metrics.perHourUSD) dollars per observed hour today"
                        ) {
                            Text(
                                metrics.perHourUSD,
                                format: .currency(code: "USD").precision(.fractionLength(2))
                            )
                        }
                    }
                }

                if let week {
                    InfographicMetricCard(
                        title: week.title,
                        unit: nil,
                        accessibilityValue: "\(week.totalUSD) dollars earned \(week.title.lowercased())"
                    ) {
                        Text(
                            week.totalUSD,
                            format: .currency(code: "USD").precision(.fractionLength(2))
                        )
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

    private var earningsMetrics: PopupEarningsMetrics? {
        PopupEarningsMetrics.make(from: store.todayEarnings)
    }

    private var weekEarningsMetric: PopupWeekEarningsMetric? {
        PopupWeekEarningsMetric.make(from: store.weekEarnings)
    }

    private var modelPresentation: PopupModelPresentation {
        .make(input: PopupModelSourceInput(snapshot: store.snapshot))
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

private struct ModelTokenRatePanel: View {
    let averages: [ModelTokenRateAverage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's average by model")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(averages, id: \.model) { average in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(average.model)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(average.tokensPerSecond, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("tok/sec")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(average.model)
                .accessibilityValue("\(average.tokensPerSecond) tokens per second today")
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
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
