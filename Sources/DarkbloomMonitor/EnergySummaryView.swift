import DarkbloomTelemetry
import SwiftUI

struct EnergySummaryView: View {
    let reading: EnergyReading?
    let earnings: EnergyEarnings?
    let now: Date
    var waitingMessage: String = "Collecting matched earnings data"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reading, (0...30).contains(now.timeIntervalSince(reading.date)) {
                Text("Adapter \(reading.watts, specifier: "%.1f") W · estimated DC input")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let earnings {
                HStack(spacing: 20) {
                    amount("Electricity est.", earnings.electricityUSD)
                    amount("After electricity est.", earnings.afterElectricityUSD)
                }
                Text("Matched \(earnings.coveredSeconds / 3600, specifier: "%.1f") hours today · partial")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("After electricity")
                    .font(.caption).foregroundStyle(.secondary)
                Text(waitingMessage)
                    .font(.callout)
                Text("Requires a complete earnings hour with uninterrupted power readings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("Whole-Mac DC adapter input, not wall power or Darkbloom-only consumption. Earnings after electricity includes only completed earnings intervals with uninterrupted energy readings. Excludes adapter losses, other expenses and unmeasured intervals.")
    }

    private func amount(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}
