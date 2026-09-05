import DarkbloomTelemetry
import SwiftUI

struct DashboardOverviewView: View {
    @ObservedObject var store: MonitorStore
    let controlStore: ProviderControlStore?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            overviewContent
        }
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overview").font(.largeTitle.bold())
                        Text("Your provider, at a glance").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(store.snapshot.menuStatus.accessibilityLabel, systemImage: "circle.fill")
                        .font(.callout)
                        .foregroundStyle(store.snapshot.menuStatus == .online ? Color.green : Color.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    DashboardMetric(title: "Current throughput", value: currentRate, unit: "tok/sec")
                    if let value = store.currentDayAverageTokenRate {
                        DashboardMetric(title: "Today's average", value: number(value), unit: "tok/sec")
                    }
                    if let earnings = PopupEarningsMetrics.make(from: store.currentTodayEarnings) {
                        DashboardMetric(title: "Observed today", value: money(earnings.totalUSD), unit: "USD")
                        DashboardMetric(title: "Per observed hour", value: money(earnings.perHourUSD), unit: "USD/hour")
                    }
                    if let week = PopupWeekEarningsMetric.make(from: store.currentWeekEarnings) {
                        DashboardMetric(title: week.title, value: money(week.totalUSD), unit: "USD")
                    }
                    if let jobs = store.currentJobSummary {
                        DashboardMetric(title: "Completed today", value: jobs.completedToday.formatted(), unit: "jobs")
                        if let average = jobs.averagePerDay {
                            DashboardMetric(title: "7-day average", value: number(average), unit: "jobs/day")
                        }
                    }
                }
                if !store.currentModelTokenRateAverages.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Throughput by model").font(.title3.bold())
                        ForEach(store.currentModelTokenRateAverages, id: \.model) { model in
                            HStack {
                                Text(model.model).textSelection(.enabled)
                                Spacer()
                                Text("\(number(model.tokensPerSecond)) tok/sec").monospacedDigit()
                            }
                        }
                        Text("Calendar-day averages from observed, attributable samples.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DashboardModelSummary(store: store, controlStore: controlStore)
                Text("Earnings reflect observed calendar coverage. Missing measurements are omitted; they are not zero.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var currentRate: String {
        guard store.snapshot.state.value?.inferenceActive == true else {
            return store.snapshot.state.value == nil ? "Unavailable" : "Idle"
        }
        guard case .available(let value, _) = store.snapshot.tokenRate, value.isFinite else { return "Unavailable" }
        return number(value)
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
    private func money(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(4))) }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct DashboardModelSummary: View {
    @ObservedObject var store: MonitorStore
    let controlStore: ProviderControlStore?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Text("Models").font(.title3.bold())
                let presentation = PopupModelPresentation.make(
                    input: PopupModelSourceInput(snapshot: store.snapshot, controlSnapshot: controlStore?.snapshot),
                    currentTime: context.date
                )
                if case .models(let models) = presentation {
                    ForEach(models) { model in
                        HStack {
                            Circle().fill(color(model.state)).frame(width: 8, height: 8)
                            Text(model.name).lineLimit(2)
                            Spacer()
                            Text(label(model.state)).font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(color(model.state).opacity(0.12), in: Capsule())
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    Text("Model state is unavailable. Check Health & Logs for source details.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(_ state: DashboardModelState) -> Color {
        switch state { case .active: .green; case .loadedIdle: .yellow; case .availableUnloaded: .gray }
    }
    private func label(_ state: DashboardModelState) -> String {
        switch state { case .active: "Active"; case .loadedIdle: "Loaded · idle"; case .availableUnloaded: "Available" }
    }
}
