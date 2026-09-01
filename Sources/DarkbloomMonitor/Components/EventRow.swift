import DarkbloomTelemetry
import SwiftUI

struct EventRow: View {
    let event: LogEvent

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 3) {
                Image(systemName: severitySymbol)
                    .foregroundStyle(severityColor)
                Text(event.severity.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 46)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.category)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .help(event.category)
                    Spacer(minLength: 8)
                    Text(TelemetryFormatting.timestamp(event.timestamp))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text(event.message)
                    .font(.caption)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(event.message)

                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(metadata)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(event.severity.rawValue.capitalized) event, \(TelemetryFormatting.timestamp(event.timestamp)), category \(event.category), \(event.message), \(metadata)"
        )
    }

    private var metadata: String {
        var values = [event.source.rawValue.capitalized]
        if let processImage {
            values.append(processImage)
        }
        if let processID = event.processID {
            values.append("PID \(processID)")
        }
        return values.joined(separator: " · ")
    }

    private var processImage: String? {
        guard let value = event.processImage, !value.isEmpty else { return nil }
        return value
    }

    private var severitySymbol: String {
        switch event.severity {
        case .info: "info.circle.fill"
        case .notice: "bell.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var severityColor: Color {
        switch event.severity {
        case .info: .blue
        case .notice: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
