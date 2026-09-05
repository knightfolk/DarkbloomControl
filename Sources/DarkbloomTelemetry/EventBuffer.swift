import Foundation

public struct EventBuffer: Equatable, Sendable {
    public private(set) var events: [LogEvent]
    public let capacity: Int
    public let maximumPayloadBytes: Int

    /// UTF-8 string payload only; fixed per-event bookkeeping is bounded by capacity.
    public var retainedPayloadBytes: Int { events.reduce(0) { $0 + payloadBytes($1) } }

    public init(capacity: Int, maximumPayloadBytes: Int = 128 * 1_024) {
        self.capacity = min(max(0, capacity), 100)
        self.maximumPayloadBytes = min(max(0, maximumPayloadBytes), 128 * 1_024)
        events = []
    }

    public mutating func insert(_ newEvents: [LogEvent]) {
        guard capacity > 0, maximumPayloadBytes > 0 else {
            events = []
            return
        }

        // Reject oversized raw fields before running privacy matching, then
        // budget the sanitized result as well. Never retain the original text.
        let sanitizedNewEvents = newEvents
            .filter { payloadBytes($0) <= maximumPayloadBytes }
            .map(EventPrivacy.sanitize)
        // Retained events are already sanitized and cannot be mutated externally.
        // Avoid re-running privacy regexes over the full buffer on every insert.
        let sortedEvents = (events + sanitizedNewEvents).sorted(by: newestFirst)
        var keys = Set<EventKey>()
        var retained: [LogEvent] = []
        var remaining = maximumPayloadBytes
        for event in sortedEvents {
            let bytes = payloadBytes(event)
            guard bytes <= remaining, keys.insert(EventKey(event: event)).inserted else { continue }
            retained.append(event)
            remaining -= bytes
            if retained.count == capacity { break }
        }
        events = retained
    }

    mutating func popFirst() -> LogEvent? {
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }
}

private func payloadBytes(_ event: LogEvent) -> Int {
    event.category.utf8.count + event.message.utf8.count + (event.processImage?.utf8.count ?? 0)
}

private struct EventKey: Hashable {
    let timestamp: Date?
    let severity: String
    let category: String
    let message: String
    let source: String
    let processID: Int32?
    let processImage: String?

    init(event: LogEvent) {
        timestamp = event.timestamp
        severity = event.severity.rawValue
        category = event.category
        message = event.message
        source = event.source.rawValue
        processID = event.processID
        processImage = event.processImage
    }
}

private func newestFirst(_ lhs: LogEvent, _ rhs: LogEvent) -> Bool {
    switch (lhs.timestamp, rhs.timestamp) {
    case let (lhsTimestamp?, rhsTimestamp?): lhsTimestamp > rhsTimestamp
    case (_?, nil): true
    case (nil, _?): false
    case (nil, nil): false
    }
}
