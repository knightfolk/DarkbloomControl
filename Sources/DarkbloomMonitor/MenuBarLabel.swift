import DarkbloomTelemetry
import SwiftUI

struct DarkbloomLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 32
        let scaleY = rect.height / 37
        var path = Path()

        func add(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            path.addRect(CGRect(
                x: rect.minX + x * scaleX,
                y: rect.minY + y * scaleY,
                width: width * scaleX,
                height: height * scaleY
            ))
        }

        // Deterministic vector reconstruction of the supplied 32 × 37 pixel mark.
        add(0, 0, 9, 37)
        add(14, 0, 9, 4)
        add(18, 4, 5, 5)
        add(28, 0, 4, 9)
        add(18, 9, 9, 9)
        add(14, 18, 4, 10)
        add(0, 28, 27, 9)
        return path
    }
}

struct MenuBarLabel: View {
    let presentation: MenuBarPresentation

    var body: some View {
        HStack(spacing: 4) {
            DarkbloomLogoShape()
                .fill(statusColor)
                .frame(width: 13, height: 15)

            if let metric = presentation.metricText {
                Text(metric)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .help(helpText)
    }

    private var statusColor: Color {
        switch presentation.health.color {
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        }
    }

    private var helpText: String {
        if let reason = presentation.metricUnavailableReason {
            return "\(presentation.health.reason) · \(reason)"
        }
        return presentation.health.reason
    }
}
