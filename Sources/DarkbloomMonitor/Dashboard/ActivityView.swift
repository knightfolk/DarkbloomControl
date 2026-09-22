import Charts
import DarkbloomTelemetry
import SwiftUI

struct ActivityView: View {
    @ObservedObject var store: MonitorStore
    @State private var period = ActivityPeriod.today
    @State private var selectedDate = Date()
    @State private var endDate = Date()
    @State private var buckets: [ActivityBucket] = []
    @State private var modelWorkByBucket: [Date: [String: Int64]] = [:]
    @State private var modelHourlyAverages: [ModelHourlyEarningsAverage] = []
    @State private var showsModelHourlyAverages = true
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
                    Text("All models by color + rewards").tag(String?.none)
                    ForEach(models, id: \.self) { Text($0).tag(Optional($0)) }
                    if let model, !models.contains(model) { Text(model).tag(Optional(model)) }
                }
                .frame(maxWidth: 400, alignment: .leading)
            }
            Text(model == nil
                 ? "Each model has its own color; base rewards are separate. Gaps mean no verified measurement, not zero. Recorded totals may be incomplete."
                 : "Work attributed to the selected model only; account base rewards are excluded. Gaps are unknown, and totals may be incomplete.")
                .font(.callout).foregroundStyle(.secondary)
            if loading {
                ProgressView("Reading local history…")
            } else if let message {
                ContentUnavailableView("History unavailable", systemImage: "chart.bar", description: Text(message))
            } else if let range = query.range {
                let yAxis = ActivityChartAxis.yAxis(maximum: chartSegments.map(\.endUSD).max() ?? 0)
                Chart(chartSegments) { segment in
                    RectangleMark(
                        xStart: .value("Start", segment.interval.start.addingTimeInterval(segment.interval.duration * 0.1)),
                        xEnd: .value("End", segment.interval.end.addingTimeInterval(-segment.interval.duration * 0.1)),
                        yStart: .value("USD", segment.startUSD),
                        yEnd: .value("USD", segment.endUSD)
                    )
                    .foregroundStyle(by: .value("Earnings", segment.series))
                }
                .chartXScale(domain: range.start...range.end)
                .chartYScale(domain: 0...yAxis.upperBound)
                .chartXAxis {
                    AxisMarks(values: ActivityChartAxis.xValues(in: range, unit: query.unit, calendar: query.calendar)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.22))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.7))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                if query.unit == .hour {
                                    Text(date, format: .dateTime.hour())
                                } else {
                                    Text(date, format: .dateTime.month(.abbreviated).day())
                                }
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: yAxis.values) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.7))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount, format: .currency(code: "USD").precision(.fractionLength(yAxis.fractionDigits)))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale(domain: chartStyleDomain, range: chartStyleRange)
                .chartLegend(model == nil ? .visible : .hidden)
                .frame(height: 205)
                .accessibilityLabel("Recorded earnings. Full values and coverage are available in the table below.")
                if !visibleModelHourlyAverages.isEmpty {
                    DisclosureGroup(isExpanded: $showsModelHourlyAverages) {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
                                ForEach(visibleModelHourlyAverages) { average in
                                    HStack(spacing: 8) {
                                        Circle().fill(modelColor(average.model)).frame(width: 8, height: 8)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 8) {
                                                Text(average.model).lineLimit(1).truncationMode(.middle)
                                                Spacer(minLength: 4)
                                                Text(average.averageWorkUSDPerEarningHour
                                                    .formatted(.currency(code: "USD").precision(.fractionLength(4))) + " / hr")
                                                    .monospacedDigit()
                                            }
                                            Text("\(average.earningHours.formatted()) recorded earning \(average.earningHours == 1 ? "hour" : "hours")")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                                    .help("Gross recorded model work divided by hours with earnings ledger entries. Electricity and idle hours are not included.")
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                        .frame(maxHeight: 128)
                        .padding(.top, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Average work earnings per model-hour").font(.headline)
                            Text("Gross recorded work; excludes electricity and hours without earnings.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
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

    private var chartSegments: [ActivityChartSegment] {
        ActivityChartData.segments(
            buckets: buckets,
            models: models,
            modelWorkByBucket: modelWorkByBucket,
            selectedModel: model
        )
    }

    private var visibleModelHourlyAverages: [ModelHourlyEarningsAverage] {
        guard let model else { return modelHourlyAverages }
        return modelHourlyAverages.filter { $0.model == model }
    }

    private var chartColors: [String: Color] {
        if model != nil {
            return ["Work": .green]
        }
        var colors = Dictionary(uniqueKeysWithValues: models.map { name in
            (name, modelColor(name))
        })
        colors["Work"] = .green
        colors["Base rewards"] = .blue
        return colors
    }

    private var chartStyleDomain: [String] {
        guard model == nil else { return ["Work"] }
        var series = models
        if chartSegments.contains(where: { $0.series == "Work" }) { series.append("Work") }
        series.append("Base rewards")
        return series
    }

    private var chartStyleRange: [Color] {
        chartStyleDomain.map { chartColors[$0] ?? .green }
    }

    private func modelColor(_ model: String) -> Color {
        // FNV-1a keeps a model's color stable when the visible date range changes.
        let hash = model.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let hue = Double(hash % 10_000_019) / 10_000_019
        return Color(hue: hue, saturation: 0.72, brightness: 0.9)
    }

    private func load(query: ActivityQuery) async {
        guard !Task.isCancelled else { return }
        loading = true
        message = nil
        buckets = []
        modelWorkByBucket = [:]
        modelHourlyAverages = []
        tokenRates = [:]
        guard let range = query.range else {
            message = "Choose an end date on or after the start date, with no more than 366 calendar days."
            loading = false
            return
        }
        do {
            let availableModels = try await store.activityModels(in: range)
            let result = try await store.activity(in: range, unit: query.unit, calendar: query.calendar, model: query.model)
            let modelHistory = try await store.activityByModel(in: range, unit: query.unit, calendar: query.calendar) ?? []
            let averages = (try? await store.modelHourlyEarningsAverages(in: range)) ?? []
            let perModel = Dictionary(grouping: modelHistory, by: \.interval.start).mapValues { values in
                Dictionary(uniqueKeysWithValues: values.map { ($0.model, $0.workMicroUSD) })
            }
            let rates: [ModelRateBucket]?
            if let model = query.model {
                rates = try? await store.activityTokenRates(in: range, unit: query.unit, calendar: query.calendar, model: model)
            } else { rates = nil }
            guard !Task.isCancelled else { return }
            models = availableModels
            modelWorkByBucket = perModel
            modelHourlyAverages = averages
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
