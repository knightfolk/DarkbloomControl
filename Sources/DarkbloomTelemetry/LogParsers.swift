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
            message: message,
            source: .legacy,
            processID: nil,
            processImage: nil
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
        lifecycleMessage(message)
    }
}

public enum UnifiedLogParser {
    public static func parse(line: Data) -> LogEvent? {
        guard let record = try? JSONDecoder().decode(UnifiedLogRecord.self, from: line),
              let severity = severity(record.messageType)
        else {
            return nil
        }

        let message = record.eventMessage == "<private>"
            ? "Message unavailable (privacy redacted)"
            : record.eventMessage
        guard severity == .warning || severity == .error || lifecycleMessage(message) else {
            return nil
        }

        return LogEvent(
            timestamp: unifiedLogDate(record.timestamp),
            severity: severity,
            category: record.category,
            message: message,
            source: .unified,
            processID: record.processID,
            processImage: record.processImagePath
        )
    }

    private static func severity(_ value: String) -> LogSeverity? {
        switch value.lowercased() {
        case "debug", "info": .info
        case "notice", "default": .notice
        case "warning", "warn": .warning
        case "error", "fault": .error
        default: nil
        }
    }
}

private struct UnifiedLogRecord: Decodable {
    let timestamp: String
    let messageType: String
    let category: String
    let processID: Int32?
    let processImagePath: String?
    let eventMessage: String
}

private func lifecycleMessage(_ message: String) -> Bool {
    let lower = message.lowercased()
    return [
        "started", "starting", "stopped", "stopping", "loaded", "loading",
        "unloaded", "unloading", "connected", "connecting", "disconnected",
    ].contains { keyword in
        lower.hasPrefix(keyword) || lower.contains(" \(keyword)")
    }
}

private func unifiedLogDate(_ timestamp: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
    return formatter.date(from: timestamp)
}
