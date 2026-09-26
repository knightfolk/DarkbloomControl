import AppKit
import DarkbloomTelemetry
import SwiftUI

enum DarkbloomLogoAsset {
    static let sourceImage = load(named: "dc-mark")
    private static let menuBarMask = load(named: "dc-menubar")
    private static let modelMasks: [ModelFamilyIcon: NSImage] = {
        var masks: [ModelFamilyIcon: NSImage] = [:]
        for family in ModelFamilyIcon.allCases where family != .darkbloom {
            masks[family] = load(named: "model-\(family.rawValue)")
        }
        return masks
    }()

    static func modelImage(family: ModelFamilyIcon) -> NSImage? {
        guard let source = modelMasks[family] ?? sourceImage else { return nil }
        var bounds = NSRect(x: 0, y: 0, width: 96, height: 96)
        guard let bitmap = source.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { return source }
        return NSImage(cgImage: bitmap, size: NSSize(width: 96, height: 96))
    }

    static func menuBarImage(tint: NSColor, family: ModelFamilyIcon = .darkbloom) -> NSImage? {
        guard let mask = modelMasks[family] ?? menuBarMask else { return nil }

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
            let url = AppResources.url(named: name, extension: "svg"),
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

/// The GPU utilization ring drawn around the menu-bar model logo. The inner
/// logo keeps its provider-health tint; the arc is whole-Mac GPU use, tinted
/// by GPU die temperature when a fresh reading exists. The parent
/// `MenuBarLabel` owns accessibility text for the whole unit.
struct MenuBarGPURingView: View {
    static let diameter: CGFloat = 18
    static let lineWidth: CGFloat = 1

    let ring: MenuBarGPURing
    let family: ModelFamilyIcon
    let statusNSColor: NSColor

    var body: some View {
        ZStack {
            Circle()
                .stroke(Self.trackColor, lineWidth: Self.lineWidth)
            Circle()
                .trim(from: 0, to: ring.progress)
                .stroke(arcColor, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            DarkbloomLogo(
                image: DarkbloomLogoAsset.menuBarImage(tint: statusNSColor, family: family),
                tint: Color(nsColor: statusNSColor)
            )
            .frame(width: 11, height: 11)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityHidden(true)
    }

    private static var trackColor: Color {
        Color(nsColor: .labelColor).opacity(0.2)
    }

    private var arcColor: Color {
        switch ring.tint {
        case .green: Color(nsColor: .systemGreen)
        case .yellow: Color(nsColor: .systemYellow)
        case .red: Color(nsColor: .systemRed)
        case .neutral: Color(nsColor: .labelColor).opacity(0.55)
        }
    }
}

struct MenuBarLabel: View {
    let presentation: MenuBarPresentation
    let uptime: ObservedUptimeValue
    var family: ModelFamilyIcon = .darkbloom
    var ring: MenuBarGPURing? = nil

    var body: some View {
        HStack(spacing: 8) {
            logo
                .frame(width: 16, height: 18)

            MenuBarMetric(text: presentation.metricText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .help(helpText)
    }

    @ViewBuilder
    private var logo: some View {
        if let ring {
            MenuBarGPURingView(ring: ring, family: family, statusNSColor: statusNSColor)
        } else {
            DarkbloomLogo(
                image: DarkbloomLogoAsset.menuBarImage(tint: statusNSColor, family: family),
                tint: statusColor
            )
        }
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

    private var accessibilityText: String {
        var text = "\(presentation.accessibilityLabel) \(uptime.accessibilityDescription)"
        if let detail = ring?.accessibilityDetail {
            text += " \(detail)"
        }
        return text
    }

    private var helpText: String {
        var text: String
        if let reason = presentation.metricUnavailableReason {
            text = "\(presentation.health.reason) · \(reason) · \(uptime.accessibilityDescription)"
        } else {
            text = "\(presentation.health.reason) · \(uptime.accessibilityDescription)"
        }
        if let detail = ring?.accessibilityDetail {
            text += " · \(detail)"
        }
        return text
    }
}
