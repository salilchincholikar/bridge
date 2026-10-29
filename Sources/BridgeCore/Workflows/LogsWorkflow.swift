import Foundation

// W5: CloudWatch Logs search. Live tail (`start-live-tail`, an event stream) is not wired yet.

public struct LogGroup: Equatable, Sendable {
    public var name: String
    public var arn: String?
    public var storedBytes: Int?
    public var retentionDays: Int?
    public var created: Date?
}

public struct LogEvent: Equatable, Sendable {
    public enum Level: String, Sendable { case error, warn, info, debug, unknown }
    public var stream: String
    public var timestamp: Date
    public var message: String
    public var eventId: String?

    /// A heuristic for colouring only; it never affects what is shown.
    public var level: Level {
        let m = message.prefix(200).uppercased()
        if m.contains("ERROR") || m.contains("FATAL") || m.contains("EXCEPTION") || m.contains("TIMED OUT") || m.contains("TASK TIMED OUT") { return .error }
        if m.contains("WARN") { return .warn }
        if m.contains("INFO") { return .info }
        if m.contains("DEBUG") { return .debug }
        return .unknown
    }
}

public enum LogsWorkflow {
    public static func describeGroups(profile: String, region: String, prefix: String? = nil, pattern: String? = nil,
                                      maxItems: Int? = 200, startingToken: String? = nil) -> ExecRequest {
        var p: [String: JSONValue] = [:]
        if let prefix, !prefix.isEmpty { p["logGroupNamePrefix"] = .string(prefix) }
        // `logGroupNamePattern` (substring match) and `logGroupNamePrefix` cannot be combined by the API.
        if let pattern, !pattern.isEmpty, p["logGroupNamePrefix"] == nil { p["logGroupNamePattern"] = .string(pattern) }
        return ExecRequest(profile: profile, region: region, service: "logs", operation: "describe-log-groups",
                           params: p.isEmpty ? nil : .object(p), maxItems: maxItems, startingToken: startingToken)
    }

    public static func parseGroups(_ json: JSONValue?) -> [LogGroup] {
        (json?.array("logGroups") ?? []).compactMap { g in
            guard let name = g.string("logGroupName") else { return nil }
            return LogGroup(name: name, arn: g.string("arn"), storedBytes: g.int("storedBytes"),
                            retentionDays: g.int("retentionInDays"), created: g.double("creationTime").map(AwsDate.fromEpoch))
        }
    }

    /// Search one log group. `pattern` uses CloudWatch filter syntax (for example `ERROR` or `"timed out"`).
    public static func filterEvents(profile: String, region: String, group: String, pattern: String? = nil,
                                    window: TimeWindow, limit: Int = 500, startingToken: String? = nil) -> ExecRequest {
        var p: [String: JSONValue] = [
            "logGroupName": .string(group),
            "startTime": .number(Double(AwsDate.epochMillis(window.start))),
            "endTime": .number(Double(AwsDate.epochMillis(window.end))),
            "limit": .number(Double(limit)),
        ]
        if let pattern, !pattern.isEmpty { p["filterPattern"] = .string(pattern) }
        return ExecRequest(profile: profile, region: region, service: "logs", operation: "filter-log-events",
                           params: .object(p), startingToken: startingToken, timeout: 90)
    }

    /// Events in ascending time order (the API does not guarantee it across streams).
    public static func parseEvents(_ json: JSONValue?) -> [LogEvent] {
        (json?.array("events") ?? []).compactMap { e -> LogEvent? in
            guard let ts = e.double("timestamp"), let msg = e.string("message") else { return nil }
            return LogEvent(stream: e.string("logStreamName") ?? "", timestamp: AwsDate.fromEpoch(ts),
                            message: msg.hasSuffix("\n") ? String(msg.dropLast()) : msg, eventId: e.string("eventId"))
        }.sorted { $0.timestamp < $1.timestamp }
    }
}
