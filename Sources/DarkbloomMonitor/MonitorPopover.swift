import DarkbloomTelemetry
import SwiftUI

enum PopupModelPresentation: Equatable {
    case models([DashboardModel])
    case unavailable

    static func make(input: PopupModelSourceInput, currentTime: Date = Date()) -> Self {
        let statusEnabledFilter = enabledFilter(from: input.status)
        let lifecycleInput = ProviderLifecycleSourceInput(
            daemonState: input.daemonState,
            status: input.status,
            controlDaemonState: input.controlSnapshot?.sources.daemon,
            currentTime: currentTime
        )

        if lifecycleInput.providerKnownRunning == false {
            return configuredModels(
                filter: controlEnabledFilter(
                    from: input.controlSnapshot,
                    fallback: statusEnabledFilter
                )
            )
        }

        // Provider-control residency is an independent local source. Prefer it
        // over telemetry whenever its two residency records are still fresh so
        // an old daemon snapshot cannot make a pill look authoritative.
        if let control = freshControlResidency(
            from: input.controlSnapshot,
            at: currentTime
        ) {
            return .models(DashboardModelDeriver.models(
                enabledFilter: controlEnabledFilter(
                    from: input.controlSnapshot,
                    fallback: statusEnabledFilter
                ),
                loadedModels: Array(control.residentModelIDs).sorted(),
                warmModels: [],
                slotModels: [],
                currentModel: control.daemonState?.currentModel,
                inferenceActive: control.daemonState?.inferenceActive ?? false
            ))
        }

        // Telemetry remains a valid fallback when both of its model records
        // are fresh. A stale or unavailable record is never promoted to a
        // loaded/active pill merely because the provider status says running.
        if let telemetry = freshTelemetryResidency(
            from: input,
            at: currentTime
        ) {
            return .models(DashboardModelDeriver.models(
                enabledFilter: statusEnabledFilter,
                loadedModels: telemetry.loadedModels,
                warmModels: telemetry.daemonState.warmModels,
                slotModels: telemetry.daemonState.slots.map(\.model),
                currentModel: telemetry.daemonState.currentModel,
                inferenceActive: telemetry.daemonState.inferenceActive
            ))
        }

        return .unavailable
    }

    private struct ControlResidency {
        let residentModelIDs: Set<String>
        let daemonState: DaemonState?
    }

    private struct TelemetryResidency {
        let daemonState: DaemonState
        let loadedModels: [String]
    }

    private static func freshControlResidency(
        from snapshot: ProviderControlSnapshot?,
        at currentTime: Date
    ) -> ControlResidency? {
        guard let snapshot else { return nil }
        let daemonSource = snapshot.sources.daemon.evaluated(
            at: currentTime,
            invalidReason: "Provider activity timestamp is invalid",
            staleReason: "Provider activity is stale",
            futureReason: "Provider activity timestamp is in the future"
        )
        let loadedSource = snapshot.sources.loadedModels.evaluated(
            at: currentTime,
            invalidReason: "Loaded model state timestamp is invalid",
            staleReason: "Loaded model state is stale",
            futureReason: "Loaded model state timestamp is in the future"
        )
        guard daemonSource.isMarkedFresh, loadedSource.isMarkedFresh else {
            return nil
        }
        return ControlResidency(
            residentModelIDs: snapshot.residentModelIDs,
            daemonState: snapshot.daemonState
        )
    }

    private static func freshTelemetryResidency(
        from input: PopupModelSourceInput,
        at currentTime: Date
    ) -> TelemetryResidency? {
        guard case .available(let daemon, let daemonCapturedAt) = input.daemonState,
              case .available(let loaded, let loadedCapturedAt) = input.loadedModels,
              fresh(capturedAt: daemonCapturedAt, at: currentTime),
              fresh(capturedAt: loadedCapturedAt, at: currentTime),
              fresh(timestamp: daemon.writtenAt, at: currentTime),
              loaded.updatedAt.isFinite,
              daemon.startedAt.isFinite,
              loaded.updatedAt >= daemon.startedAt,
              loaded.updatedAt <= currentTime.timeIntervalSince1970
        else { return nil }
        return TelemetryResidency(
            daemonState: daemon,
            loadedModels: loaded.models
        )
    }

    private static func fresh(capturedAt: Date, at currentTime: Date) -> Bool {
        fresh(timestamp: capturedAt.timeIntervalSince1970, at: currentTime)
    }

    private static func fresh(timestamp: TimeInterval, at currentTime: Date) -> Bool {
        guard timestamp.isFinite,
              currentTime.timeIntervalSince1970.isFinite
        else { return false }
        let age = currentTime.timeIntervalSince1970 - timestamp
        return age.isFinite && age >= 0 && age <= ProviderControlSourceState.maximumEvidenceAge
    }

    private static func configuredModels(filter: String?) -> Self {
        guard filter?.split(separator: ",").contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) == true else { return .unavailable }
        return .models(DashboardModelDeriver.models(
            enabledFilter: filter,
            loadedModels: [],
            warmModels: [],
            slotModels: [],
            currentModel: nil,
            inferenceActive: false
        ))
    }

    private static func enabledFilter(
        from availability: SourceAvailability<StatusSnapshot>
    ) -> String? {
        guard case .available(let status, _) = availability else { return nil }
        return status.enabledModelFilter
    }

    private static func controlEnabledFilter(
        from snapshot: ProviderControlSnapshot?,
        fallback: String?
    ) -> String? {
        guard let snapshot else { return fallback }
        // Enabled is independent from Downloaded. Include enabled rows from
        // both settings sections so a configured model does not disappear
        // from the popup merely because its weights are not local yet.
        let catalogModels = (snapshot.inventory.myCatalog + snapshot.inventory.available)
            .filter(\.isEnabled)
            .map(\.catalogID)
        if !catalogModels.isEmpty {
            return catalogModels.joined(separator: ",")
        }
        let savedModels = snapshot.draft.original.enabled
        return savedModels.isEmpty ? fallback : savedModels.joined(separator: ",")
    }

}

struct PopupModelSourceInput: Equatable {
    let daemonState: SourceAvailability<DaemonState>
    let loadedModels: SourceAvailability<LoadedModelsState>
    let status: SourceAvailability<StatusSnapshot>
    let controlSnapshot: ProviderControlSnapshot?

    init(
        snapshot: TelemetrySnapshot,
        controlSnapshot: ProviderControlSnapshot? = nil
    ) {
        daemonState = snapshot.state
        loadedModels = snapshot.loadedModels
        status = snapshot.status
        self.controlSnapshot = controlSnapshot
    }

    init(
        daemonState: SourceAvailability<DaemonState>,
        loadedModels: SourceAvailability<LoadedModelsState>,
        status: SourceAvailability<StatusSnapshot>,
        controlSnapshot: ProviderControlSnapshot? = nil
    ) {
        self.daemonState = daemonState
        self.loadedModels = loadedModels
        self.status = status
        self.controlSnapshot = controlSnapshot
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

struct PopupNetworkDemandRow: Equatable, Identifiable {
    let id: String
    let band: NetworkDemandBand
    let activeRequests: Int
    let queuedRequests: Int
    let warmProviders: Int
}

enum PopupNetworkDemandPresentation {
    enum Freshness: Equatable {
        case current
        case stale
    }

    static func freshness(
        of availability: SourceAvailability<NetworkCapacitySnapshot>,
        at now: Date
    ) -> Freshness? {
        switch availability {
        case .available(let capacity, _):
            return capacity.isFresh(at: now) ? .current : .stale
        case .stale:
            return .stale
        case .unavailable:
            return nil
        }
    }

    static func rows(
        capacity: NetworkCapacitySnapshot,
        enabledModelIDs: [String]
    ) -> [PopupNetworkDemandRow] {
        let enabled = Set(enabledModelIDs)
        return capacity.models
            .filter { enabled.contains($0.id) }
            .map {
                PopupNetworkDemandRow(
                    id: $0.id,
                    band: $0.demandBand,
                    activeRequests: $0.activeRequests,
                    queuedRequests: $0.queuedRequests,
                    warmProviders: $0.warmProviders
                )
            }
            .sorted {
                let left = rank($0.band)
                let right = rank($1.band)
                if left != right { return left < right }
                let leftWork = Double($0.activeRequests) + Double($0.queuedRequests)
                let rightWork = Double($1.activeRequests) + Double($1.queuedRequests)
                if leftWork != rightWork { return leftWork > rightWork }
                return $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
    }

    private static func rank(_ band: NetworkDemandBand) -> Int {
        switch band {
        case .urgent: 0
        case .high: 1
        case .moderate: 2
        case .low: 3
        }
    }
}

struct MonitorPopover: View {
    @ObservedObject var store: MonitorStore
    @EnvironmentObject private var controlStore: ProviderControlStore
    let openSettings: () -> Void
    let openDashboard: () -> Void

    init(
        store: MonitorStore,
        openSettings: @escaping () -> Void = {},
        openDashboard: @escaping () -> Void = {}
    ) {
        self.store = store
        self.openSettings = openSettings
        self.openDashboard = openDashboard
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(currentTime: context.date)
        }
    }

    private func content(currentTime: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            providerHeader(currentTime: currentTime)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    compactModels(currentTime: currentTime)
                    if earningsMetrics != nil || weekEarningsMetric != nil {
                        compactEarnings
                    }
                    compactJobs
                    if UserDefaults.standard.bool(forKey: "electricity.enabled") {
                        EnergySummaryView(reading: store.currentEnergyReading,
                                          earnings: store.currentEnergyEarnings, now: currentTime,
                                          waitingMessage: store.energy?.issue ?? "Collecting matched earnings data")
                    }

                }
                .padding(.trailing, 4)
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }


    private func compactModels(currentTime: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            switch modelPresentation(at: currentTime) {
            case .models(let models):
                ForEach(models) { model in
                    HStack(spacing: 8) {
                        ModelStatusPill(model: model)
                        if PopupNetworkDemandPresentation.freshness(of: store.networkCapacity, at: currentTime) == .current,
                           let demand = networkDemandRows(at: currentTime).first(where: { $0.id == model.name }) {
                            Text(demand.band.rawValue.capitalized)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .foregroundStyle(demandColor(demand.band))
                                .background(demandColor(demand.band).opacity(0.15), in: Capsule())
                                .help("Current network demand")
                                .accessibilityLabel("\(demand.band.rawValue) network demand")
                        }
                        Spacer(minLength: 4)
                        if let average = store.currentModelTokenRateAverages.first(where: { $0.model == model.name }) {
                            VStack(alignment: .trailing, spacing: 1) {
                            if model.state == .active {
                                Text("Working").font(.caption).foregroundStyle(.primary)
                            }
                            Text("\(average.tokensPerSecond, specifier: "%.1f") t/s avg")
                                .help("Today's average tokens per second")
                            }
                        } else if model.state == .active {
                            Text("Working")
                                .help("The official CLI does not expose streaming token throughput")
                        }
                    }
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            case .unavailable:
                Text("Model state unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private var compactEarnings: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let metrics = earningsMetrics {
                compactAmount("Today", value: metrics.totalUSD)
                compactAmount("Avg / hour", value: metrics.perHourUSD)
            }
            if let week = weekEarningsMetric {
                compactAmount(week.title, value: week.totalUSD)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func demandColor(_ band: NetworkDemandBand) -> Color {
        switch band {
        case .urgent: .red
        case .high: .orange
        case .moderate: .blue
        case .low: .secondary
        }
    }

    private func compactAmount(_ label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .currency(code: "USD").precision(.fractionLength(2)))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var compactJobs: some View {
        if let summary = jobSummary {
            HStack {
                Text("\(summary.completedToday) jobs today")
                Spacer()
                if let averageJobsPerDay {
                    Text("\(averageJobsPerDay, specifier: "%.1f") / day avg")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
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

            Button(action: openDashboard) {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.bordered)
            .help("Open Dashboard")
            .accessibilityLabel("Open Dashboard")

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
        HStack(alignment: .top) {
            Label("Provider", systemImage: "server.rack")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                ProviderLifecycleControls(
                    store: controlStore,
                    snapshot: store.snapshot,
                    currentTime: currentTime
                )
                if let feedback = ProviderLifecycleFeedbackPresentation.make(
                    operation: controlStore.operation,
                    errorMessage: controlStore.errorMessage
                ) {
                    Text(feedback.message)
                        .font(.caption)
                        .foregroundStyle(feedback.isError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var throughputSection: some View {
        DashboardSection(title: "Throughput", systemImage: "speedometer") {
            let breakdown = ModelTokenRatePresentation.breakdown(
                store.currentModelTokenRateAverages
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
            title: "Activity",
            unit: nil,
            accessibilityValue: currentActivityLabel
        ) {
            Text(currentActivityLabel)
        }
    }

    private var currentActivityLabel: String {
        guard let state = store.snapshot.state.value else { return "Unavailable" }
        return state.inferenceActive ? "Working" : "Idle"
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

    private func modelsSection(currentTime: Date) -> some View {
        DashboardSection(title: "Models", systemImage: "cpu") {
            switch modelPresentation(at: currentTime) {
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
                        HStack(spacing: 8) {
                            ModelStatusPill(model: model)
                            Spacer(minLength: 6)
                        }
                    }
                }
            }
        }
    }

    private func networkDemandSection(currentTime: Date) -> some View {
        DashboardSection(title: "Network demand", systemImage: "network") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(networkDemandRows(at: currentTime)) { row in
                    NetworkDemandRow(
                        row: row,
                        isRecommended: opportunityRecommendation(at: currentTime)?.modelID == row.id
                    )
                }
                if PopupNetworkDemandPresentation.freshness(
                    of: store.networkCapacity,
                    at: currentTime
                ) == .stale {
                    Text("Last known network sample · stale")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func networkDemandRows(at _: Date) -> [PopupNetworkDemandRow] {
        guard let capacity = store.networkCapacity.value else { return [] }
        return PopupNetworkDemandPresentation.rows(
            capacity: capacity,
            enabledModelIDs: enabledNetworkModelIDs
        )
    }

    private func opportunityRecommendation(at currentTime: Date) -> ModelOpportunityRecommendation? {
        guard case .available(let capacity, _) = store.networkCapacity,
              capacity.isFresh(at: currentTime)
        else { return nil }
        return ModelOpportunityRanker.recommend(
            capacity: capacity,
            enabledModelIDs: enabledNetworkModelIDs,
            observedWork: store.modelWorkEarnings,
            tokenRates: store.modelTokenRateAverages,
            now: currentTime,
            calendar: .current
        )
    }

    private var enabledNetworkModelIDs: [String] {
        if let inventory = controlStore.snapshot?.inventory.myCatalog {
            return inventory.filter(\.isEnabled).map(\.catalogID)
        }
        return models.map(\.name)
    }

    private var averageTokenRate: Double? {
        store.currentDayAverageTokenRate
    }

    private var jobSummary: JobCompletionSummary? {
        store.currentJobSummary
    }

    private var averageJobsPerDay: Double? {
        jobSummary?.averagePerDay
    }

    private var earningsMetrics: PopupEarningsMetrics? {
        PopupEarningsMetrics.make(from: store.currentTodayEarnings)
    }

    private var weekEarningsMetric: PopupWeekEarningsMetric? {
        PopupWeekEarningsMetric.make(from: store.currentWeekEarnings)
    }

    private func modelPresentation(at currentTime: Date = Date()) -> PopupModelPresentation {
        .make(
            input: PopupModelSourceInput(
                snapshot: store.snapshot,
                controlSnapshot: controlStore.snapshot
            ),
            currentTime: currentTime
        )
    }

    private var models: [DashboardModel] {
        guard case .models(let models) = modelPresentation() else { return [] }
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

private struct NetworkDemandRow: View {
    let row: PopupNetworkDemandRow
    let isRecommended: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(row.id)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
            if isRecommended {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help("Demand-first suggestion; ties use fresh observed work per job and throughput when available. Partial observations are not a profitability or hardware-fit guarantee.")
                    .accessibilityLabel("Demand-first suggestion, not a profitability guarantee")
            }
            Spacer(minLength: 6)
            Text(row.band.rawValue.capitalized)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(bandColor.opacity(0.16), in: Capsule())
                .foregroundStyle(bandColor)
            Text("\(row.activeRequests) active")
                .font(.caption.monospacedDigit())
            if row.queuedRequests > 0 {
                Text("\(row.queuedRequests) queued")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text("\(row.warmProviders) warm")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.id)
        .accessibilityValue(
            "\(row.band.rawValue) demand, \(row.activeRequests) active requests, "
                + "\(row.queuedRequests) queued requests, \(row.warmProviders) warm providers"
        )
    }

    private var bandColor: Color {
        switch row.band {
        case .low: .secondary
        case .moderate: .blue
        case .high: .orange
        case .urgent: .red
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

            Text(PopupModelName.short(model.name))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
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

enum PopupModelName {
    static func short(_ id: String) -> String {
        switch id {
        case "EigenLabs/Qwen3.8-27B-4bit-mtp": return "Qwen 3.8 · 27B"
        case "gemma-4-26b-qat-4bit": return "Gemma 4 · 26B"
        case "qwen3-vl-30b-a3b-instruct": return "Qwen VL · 30B"
        case "qwen3.5-35b-a3b": return "Qwen 3.5 · 35B"
        case "qwen3.6-35b-a3b-vl-mtp-mxfp8": return "Qwen 3.6 · 35B"
        case "gpt-oss-20b": return "OSS · 20B"
        default: return id
        }
    }
}
