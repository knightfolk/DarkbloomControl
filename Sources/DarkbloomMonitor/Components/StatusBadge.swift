import SwiftUI

struct StatusBadge: View {
    enum Tone {
        case online
        case stale
        case offline
        case neutral

        fileprivate var color: Color {
            switch self {
            case .online: .green
            case .stale: .orange
            case .offline: .red
            case .neutral: .secondary
            }
        }
    }

    let text: String
    let tone: Tone
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(tone.color)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}
