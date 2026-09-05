import Foundation

/// A short-lived indication from the provider's own process-scoped lifecycle
/// stream. Legacy text has no process identity and cannot establish loading.
public enum ModelLoadingEvidence {
    public static func model(events: [LogEvent], pid: Int32, startedAt: Date,
                             warmModels: [String], now: Date) -> String? {
        var loading: String?
        for event in events.sorted(by: { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }) {
            guard event.source == .unified, event.processID == pid,
                  event.category == "loop", let date = event.timestamp,
                  date >= startedAt, (0...60).contains(now.timeIntervalSince(date)) else { continue }
            if event.severity == .error || event.message.hasPrefix("Model loaded:") ||
                event.message.hasPrefix("Unloaded model:") {
                loading = nil
            } else if event.message.hasPrefix("Loading model: "),
                      let separator = event.message.range(of: " from ") {
                let start = event.message.index(event.message.startIndex, offsetBy: "Loading model: ".count)
                let model = String(event.message[start..<separator.lowerBound])
                loading = model.isEmpty ? nil : model
            }
        }
        guard let loading, !warmModels.contains(loading) else { return nil }
        return loading
    }
}
