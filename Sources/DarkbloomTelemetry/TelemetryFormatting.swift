import Foundation

/// Locale-stable, presentation-only formatting for telemetry values.
public enum TelemetryFormatting {
    private static let locale = Locale(identifier: "en_US_POSIX")

    public static func tokenRate(_ rate: TokenRate) -> String {
        switch rate {
        case .available(let tokensPerSecond, let label):
            return String(format: "%.1f tok/s · %@", locale: locale, tokensPerSecond, label)
        case .unavailable(let reason):
            return unavailable(reason)
        }
    }

    public static func duration(_ duration: DerivedDuration) -> String {
        switch duration {
        case .available(let seconds, let label):
            return "\(compactDuration(seconds)) · \(label)"
        case .unavailable(let reason):
            return unavailable(reason)
        }
    }

    public static func gibibytes(_ value: Double) -> String {
        String(format: "%.2f GiB", locale: locale, value)
    }

    public static func memoryFraction(active: Double, total: Double) -> Double? {
        guard total.isFinite, total > 0, active.isFinite else { return nil }
        return min(max(active / total, 0), 1)
    }

    public static func modelList(_ models: [String]) -> String {
        models.isEmpty ? "None reported" : models.joined(separator: ", ")
    }

    public static func integer(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func timestamp(_ date: Date?) -> String {
        guard let date else { return unavailable("Timestamp unavailable") }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: date)
    }

    public static func unavailable(_ reason: String) -> String {
        "Unavailable — \(reason)"
    }

    private static func compactDuration(_ seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        let days = wholeSeconds / 86_400
        let hours = (wholeSeconds % 86_400) / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainder = wholeSeconds % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
        }
        return "\(remainder)s"
    }
}
