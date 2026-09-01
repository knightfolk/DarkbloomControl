import AppKit
import DarkbloomTelemetry
import SwiftUI

enum DarkbloomLogoAsset {
    static let sourceImage = load(named: "darkbloom-mark")
    private static let menuBarMask = load(named: "darkbloom-menubar")

    static func menuBarImage(tint: NSColor) -> NSImage? {
        guard let mask = menuBarMask else { return nil }

        let image = NSImage(size: mask.size, flipped: false) { rect in
            mask.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func load(named name: String) -> NSImage? {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = true
        return image
    }
}

struct DarkbloomLogo: View {
    let image: NSImage?
    let tint: Color

    var body: some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
        }
    }
}

struct MenuBarMetric: View {
    static let width: CGFloat = 78
    static let height: CGFloat = 21

    let text: String?
    let uptime: ObservedUptimeValue

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .leading) {
                Color.clear
                if let text {
                    Text(text)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }
            }
            .frame(width: Self.width, height: 12, alignment: .leading)

            ObservedUptimeRow(value: uptime)
        }
        .frame(width: Self.width, height: Self.height, alignment: .leading)
    }
}

private struct ObservedUptimeRow: View {
    let value: ObservedUptimeValue

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.28))
                if let fraction = value.fraction {
                    Capsule()
                        .fill(.secondary)
                        .frame(width: 43 * fraction)
                }
            }
            .frame(width: 43, height: 3)

            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .frame(width: 29, alignment: .leading)
        }
        .frame(width: MenuBarMetric.width, height: 8, alignment: .leading)
        .opacity(isUnavailable ? 0 : 1)
    }

    private var label: String {
        switch value {
        case .available:
            value.compactPercent ?? ""
        case .warming:
            "warm"
        case .unavailable:
            ""
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = value { return true }
        return false
    }
}

struct MenuBarLabel: View {
    let presentation: MenuBarPresentation
    let uptime: ObservedUptimeValue

    var body: some View {
        HStack(spacing: 7) {
            DarkbloomLogo(
                image: DarkbloomLogoAsset.menuBarImage(tint: statusNSColor),
                tint: statusColor
            )
            .frame(width: 12.25, height: 14)

            MenuBarMetric(text: presentation.metricText, uptime: uptime)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.accessibilityLabel) \(uptime.accessibilityDescription)")
        .help(helpText)
    }

    private var statusColor: Color {
        Color(nsColor: statusNSColor)
    }

    private var statusNSColor: NSColor {
        switch presentation.health.color {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        }
    }

    private var helpText: String {
        if let reason = presentation.metricUnavailableReason {
            return "\(presentation.health.reason) · \(reason) · \(uptime.accessibilityDescription)"
        }
        return "\(presentation.health.reason) · \(uptime.accessibilityDescription)"
    }
}
