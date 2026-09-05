import Foundation

/// Branding is separate from routing health and must not imply activity while idle.
public enum ModelFamilyIcon: String, Equatable, Sendable {
    case darkbloom, qwen, openai, google

    public static func select(snapshot: TelemetrySnapshot, now: Date) -> Self {
        guard snapshot.menuStatus == .online,
              case .available(let state, _) = snapshot.state,
              (0...10).contains(now.timeIntervalSince1970 - state.writtenAt) else { return .darkbloom }
        if state.inferenceActive {
            return select(status: .online, activeModel: state.currentModel)
        }
        guard case .available(let feed, _) = snapshot.eventFeed else { return .darkbloom }
        let loading = ModelLoadingEvidence.model(events: feed.events, pid: state.pid,
            startedAt: Date(timeIntervalSince1970: state.startedAt), warmModels: state.warmModels, now: now)
        return select(status: .online, activeModel: loading)
    }

    public static func select(status: MenuPresentationStatus, activeModel: String?) -> Self {
        guard status == .online, let activeModel else { return .darkbloom }
        let name = activeModel.split(separator: "/").last?.lowercased() ?? ""
        if name.hasPrefix("qwen") { return .qwen }
        if name.hasPrefix("gemma-") || name.hasPrefix("gemma2") || name.hasPrefix("gemma3") {
            return .google
        }
        if name.hasPrefix("gpt-oss-") { return .openai }
        return .darkbloom
    }
}
