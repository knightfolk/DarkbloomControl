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
    @State private var modelHourlyProfits: [ModelHourlyProfit] = []
    @State private var modelHourlyProfitAverages: [ModelHourlyProfitAverage] = []
    @State private var showsModelHourlyAverages = true
    @State private var message: String?
    @State private var loading = false
    @State private var refreshID = 0
    @State private var model: String?
    @State private var chartMetric = ActivityChartMetric.earnings
    @State private var chartStyle = ActivityChartStyle.bars
    @State private var barArrangement = ActivityBarArrangement.stacked
    @State private var showsBaseRewards = true
    @State private var models: [String] = []
    @State private var tokenRates: [Date: ModelRateBucket] = [:]

    init(
        store: MonitorStore,
        initialModelFilter: String? = nil,
        initialChartStyle: ActivityChartStyle = .bars,
        initialBarArrangement: ActivityBarArrangement = .stacked,
        initialChartMetric: ActivityChartMetric = .earnings
    ) {
        self.store = store
        _model = State(initialValue: initialModelFilter)
        _chartStyle = State(initialValue: initialChartStyle)
        _barArrangement = State(initialValue: initialBarArrangement)
        _chartMetric = State(initialValue: initialChartMetric)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(query: ActivityQuery(
                period: period, selectedDate: selectedDate, endDate: endDate, now: context.date,
                calendar: .current, model: model, revision: store.activityRevision, refreshID: refreshID,
                metric: chartMetric,
                energyRevision: chartMetric == .estimatedProfit ? store.energy?.reading?.date : nil
            ))
        }
    }

    private func content(query: ActivityQuery) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                activityHeader
                if period == .date || period == .dateRange { dateControls }
                Text("Recorded ledger events · \(Calendar.current.timeZone.identifier)")
                    .foregroundStyle(.secondary)
                modelFilters
                chartControls
                Text(chartMetric == .estimatedProfit
                     ? "Estimated per earning model-hour. Whole-Mac electricity is shared evenly among models with recorded work; other Mac use is included. Incomplete power hours are omitted."
                     : model == nil
                        ? "Company shades stay related; base rewards are separate. Gaps are unknown, not zero. Recorded totals may be incomplete."
                        : "Showing recorded work for this model only. Base rewards are excluded; gaps are unknown, not zero.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: 900, alignment: .leading)
                if loading {
                    ProgressView("Reading local history…")
                } else if let message {
                    ContentUnavailableView("History unavailable", systemImage: "chart.bar", description: Text(message))
                } else if let range = query.range {
                    if chartMetric == .estimatedProfit && chartValues.isEmpty {
                        ContentUnavailableView(
                            "No covered profit hours",
                            systemImage: "bolt.horizontal",
                            description: Text("Profit estimates need saved whole-Mac power readings for a complete hour with recorded model work. Enable electricity cost in Settings and allow readings to accumulate.")
                        )
                    } else {
                        activityChart(query: query, range: range)
                    }
                    if chartMetric == .estimatedProfit && !visibleModelHourlyProfitAverages.isEmpty {
                        profitAveragesDisclosure
                    } else if chartMetric == .earnings && !visibleModelHourlyAverages.isEmpty {
                        earningsAveragesDisclosure
                    }
                    activityTable
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.automatic)
        .task(id: query) { await load(query: query) }
    }

    private var activityHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Activity").font(.largeTitle.bold())
                Spacer(minLength: 8)
                periodPicker
                refreshButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Activity").font(.largeTitle.bold())
                    Spacer(minLength: 8)
                    refreshButton
                }
                HStack { Spacer(minLength: 0); periodPicker }
            }
        }
    }

    private var periodPicker: some View {
        Picker("Calendar period", selection: $period) {
            ForEach(ActivityPeriod.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel("Calendar period")
        .frame(width: 130)
    }

    private var refreshButton: some View {
        Button { refreshID += 1 } label: { Label("Refresh history", systemImage: "arrow.clockwise") }
            .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private var dateControls: some View {
        let from = DatePicker(period == .dateRange ? "From" : "Date", selection: $selectedDate,
                              in: ...Date(), displayedComponents: .date)
        if period == .dateRange {
            let through = DatePicker("Through", selection: $endDate, in: ...Date(), displayedComponents: .date)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { from; through }
                VStack(alignment: .leading, spacing: 8) { from; through }
            }
        } else {
            from
        }
    }

    @ViewBuilder
    private var modelFilters: some View {
        if !models.isEmpty || model != nil {
            VStack(alignment: .leading, spacing: 7) {
                Text("Filter by model").font(.headline)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 155, maximum: 255), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    modelFilterChip(
                        title: "All models",
                        color: .secondary,
                        isSelected: model == nil,
                        accessibilityLabel: chartMetric == .earnings
                            ? "Show all models and base rewards"
                            : "Show all model results"
                    ) { model = nil }
                    ForEach(models, id: \.self) { name in
                        modelFilterChip(
                            title: name,
                            color: modelColor(name),
                            isSelected: model == name,
                            accessibilityLabel: model == name ? "Selected model \(name)" : "Filter to model \(name)"
                        ) {
                            model = model == name ? nil : name
                        }
                    }
                    if model == nil && chartMetric == .earnings {
                        modelFilterChip(
                            title: "Base rewards",
                            color: chartColor(for: "Base rewards"),
                            isSelected: showsBaseRewards,
                            accessibilityLabel: showsBaseRewards ? "Base rewards shown" : "Show base rewards"
                        ) { showsBaseRewards.toggle() }
                    }
                }
                .frame(maxWidth: 1_020, alignment: .leading)
                .accessibilityLabel("Model filters")
            }
        }
    }

    private var chartControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            chartControlRow("Measure") {
                Picker("Activity measure", selection: $chartMetric) {
                    ForEach(ActivityChartMetric.allCases) { metric in Text(metric.rawValue).tag(metric) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            chartControlRow("Chart") {
                Picker("Chart style", selection: $chartStyle) {
                    ForEach(ActivityChartStyle.allCases) { style in Text(style.rawValue).tag(style) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            if chartStyle == .bars {
                chartControlRow("Layout") {
                    Picker("Bar layout", selection: $barArrangement) {
                        ForEach(ActivityBarArrangement.allCases) { arrangement in Text(arrangement.rawValue).tag(arrangement) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private func chartControlRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(width: 82, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profitAveragesDisclosure: some View {
        DisclosureGroup(isExpanded: $showsModelHourlyAverages) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(visibleModelHourlyProfitAverages) { average in
                        VStack(alignment: .leading, spacing: 5) {
                            averageModelLabel(average.model)
                            Text(average.profitUSDPerHour
                                .formatted(.currency(code: "USD").precision(.fractionLength(4))) + " profit / hour")
                                .monospacedDigit()
                            Text("\(average.coveredHours.formatted()) covered earning \(average.coveredHours == 1 ? "hour" : "hours")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 230, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        .help("Estimated recorded model work minus an equal share of measured whole-Mac electricity in complete earning hours. Includes other Mac use, so it is not provider-only power cost.")
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.automatic)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Average estimated profit per model-hour").font(.headline)
                Text("Whole-Mac electricity is divided evenly across active earning models; hours with power gaps are left out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var earningsAveragesDisclosure: some View {
        DisclosureGroup(isExpanded: $showsModelHourlyAverages) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(visibleModelHourlyAverages) { average in
                        VStack(alignment: .leading, spacing: 5) {
                            averageModelLabel(average.model)
                            Text(average.averageWorkUSDPerEarningHour
                                .formatted(.currency(code: "USD").precision(.fractionLength(4))) + " per hour")
                                .monospacedDigit()
                            Text("\(average.earningHours.formatted()) recorded earning \(average.earningHours == 1 ? "hour" : "hours")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 230, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        .help("Gross recorded model work divided by hours with earnings ledger entries. Electricity and idle hours are not included.")
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.automatic)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Average work earnings per model-hour").font(.headline)
                Text("Gross recorded work; excludes electricity and hours without earnings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func averageModelLabel(_ name: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(modelColor(name)).frame(width: 8, height: 8).padding(.top, 4)
            Text(name)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activityTable: some View {
        GeometryReader { geometry in
            activityTable(compact: geometry.size.width < 620)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 300)
    }

    private func activityTable(compact: Bool) -> some View {
        Table(buckets) {
            TableColumn("Period") { bucket in
                if compact {
                    Text(bucket.interval.start, format: .dateTime.month(.abbreviated).day().hour())
                } else {
                    Text(bucket.interval.start, format: .dateTime.month().day().hour().timeZone())
                }
            }.width(compact ? 100 : 130)
            TableColumn("Work USD") { bucket in Text(amount(bucket.totals?.workMicroUSD)) }
                .width(compact ? 58 : 65)
            TableColumn(compact ? (model == nil ? "Rewards" : "Tok/s") : (model == nil ? "Rewards USD" : "Avg tok/sec")) { bucket in
                if model == nil {
                    Text(amount(bucket.totals?.rewardMicroUSD))
                } else if let rate = tokenRates[bucket.id], let average = rate.average {
                    Text(average, format: .number.precision(.fractionLength(1)))
                        .help(rateDescription(rate))
                        .accessibilityLabel(rateDescription(rate))
                } else {
                    Text("—").accessibilityLabel("No attributed throughput samples")
                }
            }.width(compact ? 68 : 80)
            TableColumn("Jobs") { bucket in Text(bucket.totals.map { $0.jobs.formatted() } ?? "—") }
                .width(compact ? 36 : 35)
            TableColumn(compact ? "Status" : "Coverage") { bucket in
                Text(compact ? compactCoverage(bucket.coverage) : coverage(bucket.coverage))
                    .foregroundStyle(.secondary)
                    .help(coverage(bucket.coverage))
            }.width(compact ? 60 : 85)
        }
    }

    private var chartValues: [ActivityChartValue] {
        if chartMetric == .estimatedProfit {
            return ActivityChartData.profitValues(hourly: modelHourlyProfits, buckets: buckets, selectedModel: model)
        }
        return ActivityChartData.values(buckets: buckets, models: models, modelWorkByBucket: modelWorkByBucket,
                                        selectedModel: model, includeRewards: showsBaseRewards)
    }

    private var visibleModelHourlyAverages: [ModelHourlyEarningsAverage] {
        guard let model else { return modelHourlyAverages }
        return modelHourlyAverages.filter { $0.model == model }
    }

    private var visibleModelHourlyProfitAverages: [ModelHourlyProfitAverage] {
        guard let model else { return modelHourlyProfitAverages }
        return modelHourlyProfitAverages.filter { $0.model == model }
    }

    private var chartStyleDomain: [String] {
        ActivityChartData.colorScaleDomain(models: models)
    }

    private var chartStyleRange: [Color] {
        chartStyleDomain.map(chartColor(for:))
    }

    private func modelColor(_ model: String) -> Color {
        let components = ActivityChartPalette.components(for: model)
        return Color(hue: components.hue, saturation: components.saturation, brightness: components.brightness)
    }

    private func chartColor(for series: String) -> Color {
        switch series {
        case "Base rewards": Color(hue: 0.12, saturation: 0.30, brightness: 0.88)
        case "Work": Color(hue: 0.52, saturation: 0.25, brightness: 0.88)
        default: modelColor(series)
        }
    }

    private func modelFilterChip(
        title: String,
        color: Color,
        isSelected: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? color.opacity(0.22) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? color.opacity(0.95) : Color.secondary.opacity(0.24),
                                  lineWidth: isSelected ? 1.4 : 0.8)
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func activityChart(query: ActivityQuery, range: DateInterval) -> some View {
        let stacked = chartStyle == .area || (chartStyle == .bars && barArrangement == .stacked)
        let yAxis: ActivityChartYAxis
        if chartMetric == .estimatedProfit {
            let bounds = ActivityChartData.profitBounds(values: chartValues, stacked: stacked)
            yAxis = ActivityChartAxis.signedYAxis(minimum: bounds.minimum, maximum: bounds.maximum)
        } else {
            let maximum = ActivityChartData.maximumUSD(values: chartValues, stacked: stacked)
            yAxis = ActivityChartAxis.yAxis(maximum: maximum)
        }

        return VStack(alignment: .leading, spacing: 2) {
            Text(chartMetric == .estimatedProfit
                 ? "Estimated profit per earning model-hour · USD"
                 : "Gross recorded earnings · USD")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Chart { chartMarks(query: query) }
                .id(query.model)
                .chartXScale(domain: range.start...range.end)
                .chartYScale(domain: yAxis.lowerBound...yAxis.upperBound)
                .chartXAxisLabel("Local time")
                .chartXAxis {
                    AxisMarks(values: ActivityChartAxis.xValues(in: range, unit: query.unit, calendar: query.calendar)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.38))
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
                            .foregroundStyle(Color.secondary.opacity(0.38))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.7))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount, format: .currency(code: "USD").precision(.fractionLength(yAxis.fractionDigits)))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .chartForegroundStyleScale(domain: chartStyleDomain, range: chartStyleRange)
                .chartLegend(.hidden)
                .frame(height: 242)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chartMetric == .estimatedProfit
            ? "Estimated net profit per earning model-hour in US dollars by local time, with positive and negative values around zero. Model filter chips identify each series."
            : "Recorded gross earnings in US dollars by local time. Filter chips identify the series. Full values and coverage are in the table below.")
    }

    @ChartContentBuilder
    private func chartMarks(query: ActivityQuery) -> some ChartContent {
        if chartStyle == .bars && barArrangement == .stacked {
            ForEach(displayedSegments) { segment in
                RectangleMark(
                    xStart: .value("Start", segment.interval.start.addingTimeInterval(segment.interval.duration * 0.08)),
                    xEnd: .value("End", segment.interval.end.addingTimeInterval(-segment.interval.duration * 0.08)),
                    yStart: .value("Recorded USD", segment.startUSD),
                    yEnd: .value("Recorded USD", segment.endUSD)
                )
                .foregroundStyle(by: .value("Series", segment.series))
            }
        } else {
            ForEach(chartValues) { value in
                chartMark(value, query: query)
            }
        }
    }

    private var chartSegments: [ActivityChartSegment] {
        ActivityChartData.segments(
            buckets: buckets,
            models: models,
            modelWorkByBucket: modelWorkByBucket,
            selectedModel: model,
            includeRewards: showsBaseRewards
        )
    }

    private var displayedSegments: [ActivityChartSegment] {
        chartMetric == .estimatedProfit
            ? ActivityChartData.profitSegments(values: chartValues)
            : chartSegments
    }

    @ChartContentBuilder
    private func chartMark(_ value: ActivityChartValue, query: ActivityQuery) -> some ChartContent {
        switch chartStyle {
        case .bars:
            barMark(value, query: query)
        case .lines:
            LineMark(
                x: .value("Period", value.interval.start),
                y: .value("Recorded USD", value.amountUSD),
                series: .value("Series run", value.runKey)
            )
            .foregroundStyle(by: .value("Series", value.series))
            .symbol(.circle)
            .interpolationMethod(.linear)
        case .area:
            AreaMark(
                x: .value("Period", value.interval.start),
                y: .value("Recorded USD", value.amountUSD),
                series: .value("Series run", value.runKey),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Series", value.series))
            .opacity(0.78)
        }
    }

    @ChartContentBuilder
    private func barMark(_ value: ActivityChartValue, query: ActivityQuery) -> some ChartContent {
        let unit: Calendar.Component = query.unit == .hour ? .hour : .day
        BarMark(
            x: .value("Period", value.interval.start, unit: unit),
            y: .value("Recorded USD", value.amountUSD),
            stacking: .unstacked
        )
        .position(by: .value("Series", value.series))
        .foregroundStyle(by: .value("Series", value.series))
    }

    private func load(query: ActivityQuery) async {
        guard !Task.isCancelled else { return }
        loading = true
        message = nil
        buckets = []
        modelWorkByBucket = [:]
        modelHourlyAverages = []
        modelHourlyProfits = []
        modelHourlyProfitAverages = []
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
            let powerIntervals = store.energy?.intervals ?? []
            let hourlyProfits: [ModelHourlyProfit]
            if query.metric == .estimatedProfit,
               let powerRange = rangeCoveredByEnergy(range, intervals: powerIntervals) {
                let hourlyActivity = try await store.activityByModel(in: powerRange, unit: .hour, calendar: query.calendar) ?? []
                hourlyProfits = ModelProfitability.hourlyProfits(activity: hourlyActivity, energy: powerIntervals)
            } else {
                hourlyProfits = []
            }
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
            modelHourlyProfits = hourlyProfits
            modelHourlyProfitAverages = ModelProfitability.averages(hourlyProfits)
            tokenRates = Dictionary(uniqueKeysWithValues: (rates ?? []).map { ($0.id, $0) })
            if let result { buckets = result } else { message = "Local earnings storage is unavailable." }
        } catch {
            guard !Task.isCancelled else { return }
            message = "Could not read local earnings history. Try refreshing."
        }
        loading = false
    }

    private func rangeCoveredByEnergy(_ range: DateInterval, intervals: [EnergyInterval]) -> DateInterval? {
        guard let first = intervals.first, let last = intervals.last else { return nil }
        let start = max(range.start, first.start)
        let end = min(range.end, last.end)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
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

    private func compactCoverage(_ value: ActivityCoverage) -> String {
        switch value {
        case .recorded: "Recorded"
        case .unavailable: "Unknown"
        case .boundaryUncertain: "Partial"
        }
    }
}
