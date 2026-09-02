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
    static let width: CGFloat = 72
    static let height: CGFloat = 18

    let text: String?

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if let text {
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .frame(width: Self.width, height: Self.height, alignment: .leading)
    }
}

struct MenuBarLabel: View {
    let presentation: MenuBarPresentation
    let uptime: ObservedUptimeValue

    var body: some View {
        HStack(spacing: 8) {
            DarkbloomLogo(
                image: DarkbloomLogoAsset.menuBarImage(tint: statusNSColor),
                tint: statusColor
            )
            .frame(width: 16, height: 18)

            MenuBarMetric(text: presentation.metricText)
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
