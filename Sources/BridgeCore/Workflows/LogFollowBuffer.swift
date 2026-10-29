import Foundation

/// Bounded overlap buffer: event IDs distinguish identical messages; a full tuple is the fallback.
public struct LogFollowBuffer: Sendable {
    public private(set) var events: [LogEvent] = []
    public let capacity: Int
    public init(capacity: Int = 2000) { self.capacity = max(1, capacity) }
    public mutating func append(_ incoming: [LogEvent]) {
        func key(_ e: LogEvent) -> String { e.eventId ?? "\(e.timestamp.timeIntervalSince1970)\u{1f}\(e.stream)\u{1f}\(e.message)" }
        var seen = Set(events.map(key))
        events.append(contentsOf: incoming.filter { seen.insert(key($0)).inserted })
        events.sort { $0.timestamp < $1.timestamp }
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }
}
