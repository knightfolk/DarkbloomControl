import Charts
import DarkbloomTelemetry
import SwiftUI

struct ActivityView: View {
    @ObservedObject var store: MonitorStore
    @State private var period = ActivityPeriod.today
    @State private var selectedDate = Date()
    @State private var endDate = Date()
    @State private var buckets: [ActivityBucket] = []
    @State private var message: String?
    @State private var loading = false
    @State private var refreshID = 0
    @State private var model: String?
    @State private var models: [String] = []
    @State private var tokenRates: [Date: ModelRateBucket] = [:]

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(query: ActivityQuery(
                period: period, selectedDate: selectedDate, endDate: endDate, now: context.date,
                calendar: .current, model: model, revision: store.activityRevision, refreshID: refreshID
            ))
        }
    }

    private func content(query: ActivityQuery) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Activity").font(.largeTitle.bold())
                Spacer()
                Picker("Calendar period", selection: $period) {
                    ForEach(ActivityPeriod.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().accessibilityLabel("Calendar period").frame(width: 130)
                Button { refreshID += 1 } label: { Label("Refresh history", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
            }
            if period == .date || period == .dateRange {
                HStack {
                    DatePicker(period == .dateRange ? "From" : "Date", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    if period == .dateRange {
                        DatePicker("Through", selection: $endDate, in: ...Date(), displayedComponents: .date)
                    }
                    Spacer(minLength: 0)
                }
            }
            Text("Recorded ledger events · \(Calendar.current.timeZone.identifier)")
                .foregroundStyle(.secondary)
            if !models.isEmpty || model != nil {
                Picker("Model", selection: $model) {
                    Text("All models + rewards").tag(String?.none)
                    ForEach(models, id: \.self) { Text($0).tag(Optional($0)) }
                    if let model, !models.contains(model) { Text(model).tag(Optional(model)) }
                }
                .frame(maxWidth: 400, alignment: .leading)
            }
            Text(model == nil
                 ? "Work and base rewards are separate. Gaps mean no verified measurement, not zero. Recorded totals may be incomplete."
                 : "Work attributed to the selected model only; account base rewards are excluded. Gaps are unknown, and totals may be incomplete.")
                .font(.callout).foregroundStyle(.secondary)
            if loading {
                ProgressView("Reading local history…")
            } else if let message {
                ContentUnavailableView("History unavailable", systemImage: "chart.bar", description: Text(message))
            } else if let range = query.range {
                Chart(buckets) { bucket in
                    if let totals = bucket.totals {
                        RectangleMark(xStart: .value("Start", bucket.interval.start.addingTimeInterval(bucket.interval.duration * 0.1)), xEnd: .value("End", bucket.interval.end.addingTimeInterval(-bucket.interval.duration * 0.1)), yStart: .value("USD", 0.0), yEnd: .value("USD", Double(totals.workMicroUSD) / 1_000_000))
                            .foregroundStyle(by: .value("Earnings", "Work"))
                        if model == nil {
                            RectangleMark(xStart: .value("Start", bucket.interval.start.addingTimeInterval(bucket.interval.duration * 0.1)), xEnd: .value("End", bucket.interval.end.addingTimeInterval(-bucket.interval.duration * 0.1)), yStart: .value("USD", Double(totals.workMicroUSD) / 1_000_000), yEnd: .value("USD", Double(totals.workMicroUSD) / 1_000_000 + Double(totals.rewardMicroUSD) / 1_000_000))
                                .foregroundStyle(by: .value("Earnings", "Base rewards"))
                        }
                    }
                }
                .chartXScale(domain: range.start...range.end)
                .chartForegroundStyleScale(["Work": Color.green, "Base rewards": Color.blue])
                .chartLegend(model == nil ? .visible : .hidden)
                .frame(height: 180)
                .accessibilityLabel("Recorded earnings. Full values and coverage are available in the table below.")
                Table(buckets) {
                    TableColumn("Period") { bucket in
                        Text(bucket.interval.start, format: .dateTime.month().day().hour().timeZone())
                    }.width(130)
                    TableColumn("Work USD") { bucket in Text(amount(bucket.totals?.workMicroUSD)) }
                        .width(65)
                    TableColumn(model == nil ? "Rewards USD" : "Avg tok/sec") { bucket in
                        if model == nil {
                            Text(amount(bucket.totals?.rewardMicroUSD))
                        } else if let rate = tokenRates[bucket.id], let average = rate.average {
                            Text(average, format: .number.precision(.fractionLength(1)))
                                .help(rateDescription(rate))
                                .accessibilityLabel(rateDescription(rate))
                        } else {
                            Text("—").accessibilityLabel("No attributed throughput samples")
                        }
                    }.width(80)
                    TableColumn("Jobs") { bucket in Text(bucket.totals.map { $0.jobs.formatted() } ?? "—") }
                        .width(35)
                    TableColumn("Coverage") { bucket in
                        Text(coverage(bucket.coverage)).foregroundStyle(.secondary)
                    }.width(85)
                }
                .frame(minHeight: 220, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: query) { await load(query: query) }
    }

    private func load(query: ActivityQuery) async {
        guard !Task.isCancelled else { return }
        loading = true
        message = nil
        buckets = []
        tokenRates = [:]
        guard let range = query.range else {
            message = "Choose an end date on or after the start date, with no more than 366 calendar days."
            loading = false
            return
        }
        do {
            let availableModels = try await store.activityModels(in: range)
            let result = try await store.activity(in: range, unit: query.unit, calendar: query.calendar, model: query.model)
            let rates: [ModelRateBucket]?
            if let model = query.model {
                rates = try? await store.activityTokenRates(in: range, unit: query.unit, calendar: query.calendar, model: model)
            } else { rates = nil }
            guard !Task.isCancelled else { return }
            models = availableModels
            tokenRates = Dictionary(uniqueKeysWithValues: (rates ?? []).map { ($0.id, $0) })
            if let result { buckets = result } else { message = "Local earnings storage is unavailable." }
        } catch {
            guard !Task.isCancelled else { return }
            message = "Could not read local earnings history. Try refreshing."
        }
        loading = false
    }

    private func amount(_ value: Int64?) -> String {
        value.map { (Double($0) / 1_000_000).formatted(.number.precision(.fractionLength(4))) } ?? "—"
    }

    private func rateDescription(_ rate: ModelRateBucket) -> String {
        guard let average = rate.average, let minimum = rate.minimum, let maximum = rate.maximum else {
            return "No attributed throughput samples"
        }
        return "Average \(average.formatted(.number.precision(.fractionLength(1)))) tok/sec; sampled range \(minimum.formatted(.number.precision(.fractionLength(1)))) to \(maximum.formatted(.number.precision(.fractionLength(1)))); \(rate.sampleCount) samples. Up to 31 days retained."
    }

    private func coverage(_ value: ActivityCoverage) -> String {
        switch value {
        case .recorded: "Recorded"
        case .unavailable: "Unknown"
        case .boundaryUncertain: "Boundary unknown"
        }
    }
}
