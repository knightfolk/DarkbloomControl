import Foundation

public struct EventBuffer: Equatable, Sendable {
    public private(set) var events: [LogEvent]
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        events = []
    }

    public mutating func insert(_ newEvents: [LogEvent]) {
        guard capacity > 0 else {
            events = []
            return
        }

        let sortedEvents = (events + newEvents).sorted(by: newestFirst)
        var keys = Set<EventKey>()
        events = sortedEvents.filter { keys.insert(EventKey(event: $0)).inserted }
        if events.count > capacity {
            events.removeLast(events.count - capacity)
        }
    }
}

private struct EventKey: Hashable {
    let timestamp: Date?
    let severity: String
    let category: String
    let message: String

    init(event: LogEvent) {
        timestamp = event.timestamp
        severity = event.severity.rawValue
        category = event.category
        message = event.message
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
