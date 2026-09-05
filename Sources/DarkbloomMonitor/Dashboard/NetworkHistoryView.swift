import Charts
import DarkbloomTelemetry
import SwiftUI

private enum NetworkHistoryMetric: String, CaseIterable, Identifiable {
    case requests = "Requests", prompt = "Input tokens", completion = "Output tokens"
    var id: String { rawValue }
    func value(_ bucket: NetworkSeriesBucket) -> Int64 {
        switch self {
        case .requests: bucket.requests
        case .prompt: bucket.promptTokens
        case .completion: bucket.completionTokens
        }
    }
}

struct NetworkHistoryView: View {
    let source: SourceAvailability<NetworkSeriesSnapshot>
    @State private var metric = NetworkHistoryMetric.requests

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Text("Network history").font(.largeTitle.bold())
                Text("Network-wide totals, not your provider or a particular model. This is the API’s 24-hour window; your earnings remain calendar-based.")
                    .font(.callout).foregroundStyle(.secondary)
                if let series = source.value {
                    let stale = isStale(series, at: context.date)
                    HStack {
                        Text(stale ? "Stale history · last-known values" : "Network source updated")
                        Spacer()
                        Text(series.updatedAt, style: .relative)
                    }
                    .font(.caption).foregroundStyle(stale ? Color.orange : Color.secondary)
                    Picker("Metric", selection: $metric) {
                        ForEach(NetworkHistoryMetric.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Chart(series.buckets) { bucket in
                        RectangleMark(
                            xStart: .value("Start", bucket.timestamp),
                            xEnd: .value("End", bucket.timestamp.addingTimeInterval(Double(series.bucketSeconds))),
                            yStart: .value("Zero", 0), yEnd: .value(metric.rawValue, metric.value(bucket))
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                    }
                    .chartXScale(domain: series.startAt...series.endAt)
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let count = value.as(Double.self) {
                                    Text(count, format: .number.notation(.compactName))
                                }
                            }
                        }
                    }
                    .frame(height: 160)
                    Text("Each bar covers \(series.bucketSeconds / 60) minutes. Missing buckets remain gaps; no missing totals are estimated.")
                        .font(.caption).foregroundStyle(.secondary)
                    Table(series.buckets) {
                        TableColumn("Period") { Text($0.timestamp, format: .dateTime.month().day().hour().minute()) }.width(130)
                        TableColumn("Requests") { Text($0.requests, format: .number) }.width(85)
                        TableColumn("Input tokens") { Text($0.promptTokens, format: .number) }.width(110)
                        TableColumn("Output tokens") { Text($0.completionTokens, format: .number) }.width(110)
                    }
                    .frame(minHeight: 160)
                } else {
                    ContentUnavailableView("Network history unavailable", systemImage: "chart.bar",
                                           description: Text("The shared collector has not returned usable history. Local monitoring continues independently."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func isStale(_ series: NetworkSeriesSnapshot, at now: Date) -> Bool {
        guard case .available = source else { return true }
        let age = now.timeIntervalSince(series.updatedAt)
        return !age.isFinite || age < -60 || age > 900
    }
}
