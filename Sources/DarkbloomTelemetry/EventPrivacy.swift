import Foundation

/// Conservative known-field filtering, not a guarantee about arbitrary prose.
/// Apply before retention so search, tooltips and accessibility see the same text.
enum EventPrivacy {
    private static let withheld = "[Sensitive log field withheld]"
    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    static func sanitize(_ event: LogEvent) -> LogEvent {
        LogEvent(timestamp: event.timestamp, severity: event.severity,
                 category: text(event.category), message: text(event.message), source: event.source,
                 processID: event.processID, processImage: event.processImage.map(text))
    }

    private static func text(_ raw: String) -> String {
        var value = raw.precomposedStringWithCanonicalMapping
        // Remove terminal control sequences before checking sensitive field names.
        for pattern in [#"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#,
                        #"\x1B\[[0-?]*[ -/]*[@-~]"#, #"\x1B[@-_]"#] {
            value = replacing(pattern, in: value, with: "")
        }
        value = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        })
        let sensitive = #"(?i)\b(?:authorization|bearer|access[_ -]?token|refresh[_ -]?token|auth[_ -]?token|api[_ -]?key|password|secret|provider[_ -]?(?:id|key)|account[_ -]?(?:id|key)|prompt|response|completion|reasoning|messages|request[_ -]?body)\b|\btoken[\"']?\s*[:=]"#
        guard let expression = try? NSRegularExpression(pattern: sensitive) else { return withheld }
        if expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
            return withheld
        }
        value = replacing(#"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#, in: value, with: "[URL withheld]")
        if homePath != "/", !homePath.isEmpty {
            value = value.replacingOccurrences(of: homePath, with: "~")
        }
        return replacing(#"/(?:Users|home)/[^/\s]+"#, in: value, with: "~")
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return withheld }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                                   withTemplate: replacement)
    }
}
