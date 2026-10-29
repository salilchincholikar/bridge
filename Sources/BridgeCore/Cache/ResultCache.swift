import Foundation

/// An absolute time window. Relative ranges ("last 15 min") are resolved to one of these when a request
/// is SENT, never when its result arrives (docs/technical.md 4.8).
public struct TimeWindow: Equatable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) { self.start = start; self.end = end }

    /// The last `seconds` up to `now`, rounded DOWN to the minute so repeats within a minute share a cache key.
    public static func last(_ seconds: TimeInterval, now: Date = Date()) -> TimeWindow {
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        return TimeWindow(start: end.addingTimeInterval(-seconds), end: end)
    }
}

/// `(verified account, principal, region, operation, params, window, CLI version)`. Keyed on the VERIFIED
/// identity, never the profile name: a profile can be re-pointed to another account.
public struct CacheKey: Hashable, Sendable {
    public var account: String
    public var principalArn: String
    public var region: String
    public var service: String
    public var operation: String
    public var params: String
    public var windowStart: TimeInterval?
    public var windowEnd: TimeInterval?
    public var cliVersion: String

    public init(request: ExecRequest, identity: VerifiedIdentity, window: TimeWindow? = nil, cliVersion: String) {
        account = identity.account
        principalArn = identity.arn
        region = request.region
        service = request.service
        operation = request.operation
        // Pagination position is part of what was asked for.
        params = (request.params?.compactString() ?? "") + "|\(request.maxItems.map(String.init) ?? "")|\(request.startingToken ?? "")"
        windowStart = window?.start.timeIntervalSince1970
        windowEnd = window?.end.timeIntervalSince1970
        self.cliVersion = cliVersion
    }
}

/// Memory-only cache (nothing is written to disk in the MVP). Sensitive results are never stored, and
/// operations whose results change continuously are never stored either.
public actor ResultCache {
    private struct Entry { var result: ExecResult; var storedAt: Date; var ttl: TimeInterval }
    private var entries: [CacheKey: Entry] = [:]
    private let defaultTTL: TimeInterval
    private let now: @Sendable () -> Date

    public init(defaultTTL: TimeInterval = 45, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaultTTL = defaultTTL
        self.now = now
    }

    /// Time-to-live for an operation; 0 means "never cache".
    public func ttl(service: String, operation: String) -> TimeInterval {
        let live: Set<String> = ["logs get-log-events", "logs filter-log-events", "logs start-live-tail",
                                 "logs start-query", "logs get-query-results", "s3api get-object"]
        return live.contains(PolicyTable.key(service, operation)) ? 0 : defaultTTL
    }

    /// Returns the cached result and its age, or nil if missing or expired.
    public func get(_ key: CacheKey) -> (result: ExecResult, age: TimeInterval)? {
        guard let e = entries[key] else { return nil }
        let age = now().timeIntervalSince(e.storedAt)
        if age > e.ttl { entries[key] = nil; return nil }
        return (e.result, age)
    }

    /// Returns false (and stores nothing) for sensitive results and never-cached operations.
    @discardableResult
    public func put(_ key: CacheKey, _ result: ExecResult) -> Bool {
        let t = ttl(service: key.service, operation: key.operation)
        if result.sensitive || t <= 0 { return false }
        entries[key] = Entry(result: result, storedAt: now(), ttl: t)
        return true
    }

    public func invalidate(account: String) { entries = entries.filter { $0.key.account != account } }
    public func removeAll() { entries.removeAll() }
    public var count: Int { entries.count }
}
