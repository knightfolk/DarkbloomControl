import Foundation

public enum LegacyLogParser {
    public static func parse(_ text: String, limit: Int) -> [LogEvent] {
        guard limit > 0 else { return [] }
        let events = text.split(whereSeparator: \.isNewline).compactMap(parseLine)
        return Array(events.suffix(limit))
    }

    private static func parseLine(_ line: Substring) -> LogEvent? {
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard fields.count == 4, let severity = severity(String(fields[1])) else { return nil }

        let rawCategory = String(fields[2])
        let category = rawCategory.hasSuffix(":") ? String(rawCategory.dropLast()) : rawCategory
        let message = String(fields[3])
        guard severity == .warning || severity == .error || isLifecycle(message) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return LogEvent(
            timestamp: formatter.date(from: String(fields[0])),
            severity: severity,
            category: category,
            message: message
        )
    }

    private static func severity(_ value: String) -> LogSeverity? {
        switch value.lowercased() {
        case "info": .info
        case "notice": .notice
        case "warning", "warn": .warning
        case "error", "fault": .error
        default: nil
        }
    }

    private static func isLifecycle(_ message: String) -> Bool {
        let lower = message.lowercased()
        return [" started", " starting", " stopped", " stopping", " loaded", " loading", " unloaded", " unloading", " connected", " connecting", " disconnected"]
            .contains(where: lower.contains)
    }
}
