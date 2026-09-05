import Foundation

public enum LogExportError: Error { case invalidTimestamp, responseTooLarge }

/// Immutable preview bytes: saving must write exactly what was reviewed.
public struct LogExportSnapshot: Identifiable, Sendable {
    public static let maximumBytes = 256 * 1_024
    public let id = UUID()
    public let data: Data
    public let eventCount: Int
    public let omittedCount: Int
    public var previewText: String { String(decoding: data, as: UTF8.self) }

    public static func make(events: [LogEvent], sourceCapturedAt: Date, sourceIsStale: Bool,
                            createdAt: Date) throws -> Self {
        guard sourceCapturedAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970.isFinite else { throw LogExportError.invalidTimestamp }
        var buffer = EventBuffer(capacity: 100)
        buffer.insert(events)
        var records = buffer.events.map(Record.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        while true {
            let omitted = events.count - records.count
            let document = Document(createdAt: createdAt, sourceCapturedAt: sourceCapturedAt,
                sourceStatus: sourceIsStale ? "last-known" : "available", omittedCount: omitted, events: records)
            let data = try encoder.encode(document)
            if data.count <= maximumBytes {
                return Self(data: data, eventCount: records.count, omittedCount: omitted)
            }
            guard !records.isEmpty else { throw LogExportError.responseTooLarge }
            records.removeLast()
        }
    }

    private struct Document: Encodable {
        let schema = 1
        let privacyNotice = "Known sensitive fields withheld. Review before sharing; unmarked private text may remain. Structured process metadata fields are omitted."
        let createdAt: Date
        let sourceCapturedAt: Date
        let sourceStatus: String
        let omittedCount: Int
        let events: [Record]
    }

    private struct Record: Encodable {
        let timestamp: Date?
        let severity: String
        let source: String
        let category: String
        let message: String

        init(_ event: LogEvent) {
            timestamp = event.timestamp.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
            severity = event.severity.rawValue
            source = event.source.rawValue
            category = event.category
            message = event.message
        }
    }
}
