import Foundation

// CloudWatch metrics (for charts) and alarms.

public struct MetricSpec: Equatable, Sendable {
    public var namespace: String
    public var name: String
    public var dimensions: [(name: String, value: String)]
    public var stat: String
    public var label: String

    public init(namespace: String, name: String, dimensions: [(name: String, value: String)], stat: String, label: String? = nil) {
        self.namespace = namespace; self.name = name; self.dimensions = dimensions; self.stat = stat; self.label = label ?? name
    }
    public static func == (a: MetricSpec, b: MetricSpec) -> Bool {
        a.namespace == b.namespace && a.name == b.name && a.stat == b.stat && a.label == b.label
            && a.dimensions.map { "\($0.name)=\($0.value)" } == b.dimensions.map { "\($0.name)=\($0.value)" }
    }
}

public struct MetricPoint: Equatable, Sendable {
    public var time: Date
    public var value: Double
    public init(time: Date, value: Double) { self.time = time; self.value = value }
}

public struct MetricSeries: Equatable, Sendable {
    public var id: String
    public var label: String
    public var points: [MetricPoint]
}

public struct AlarmSummary: Equatable, Sendable {
    public var name: String
    public var state: String
    public var reason: String?
    public var updated: Date?
    public var isComposite: Bool
}

public enum MetricsWorkflow {
    /// Period in seconds for a window, chosen so a chart gets a useful number of points while staying inside
    /// the API's datapoint limit. (Retention rules for 1-minute data are `[unverified]` here: very old windows
    /// may need coarser periods than this picks.)
    public static func period(for window: TimeWindow) -> Int {
        let span = window.end.timeIntervalSince(window.start)
        if span <= 3 * 3600 { return 60 }
        if span <= 12 * 3600 { return 300 }
        if span <= 3 * 86400 { return 900 }
        return 3600
    }

    public static func query(profile: String, region: String, window: TimeWindow, specs: [MetricSpec]) -> ExecRequest {
        let period = period(for: window)
        let queries: [JSONValue] = specs.enumerated().map { i, s in
            .object([
                "Id": .string("m\(i)"),
                "Label": .string(s.label),
                "ReturnData": .bool(true),
                "MetricStat": .object([
                    "Metric": .object([
                        "Namespace": .string(s.namespace), "MetricName": .string(s.name),
                        "Dimensions": .array(s.dimensions.map { .object(["Name": .string($0.name), "Value": .string($0.value)]) }),
                    ]),
                    "Period": .number(Double(period)), "Stat": .string(s.stat),
                ]),
            ])
        }
        return ExecRequest(profile: profile, region: region, service: "cloudwatch", operation: "get-metric-data",
                           params: .object(["MetricDataQueries": .array(queries), "StartTime": .string(AwsDate.iso(window.start)),
                                            "EndTime": .string(AwsDate.iso(window.end)), "ScanBy": .string("TimestampAscending")]),
                           maxItems: 5000, timeout: 60)
    }

    public static func lambdaSpecs(function: String) -> [MetricSpec] {
        let dim = [(name: "FunctionName", value: function)]
        return [MetricSpec(namespace: "AWS/Lambda", name: "Invocations", dimensions: dim, stat: "Sum"),
                MetricSpec(namespace: "AWS/Lambda", name: "Errors", dimensions: dim, stat: "Sum"),
                MetricSpec(namespace: "AWS/Lambda", name: "Throttles", dimensions: dim, stat: "Sum"),
                MetricSpec(namespace: "AWS/Lambda", name: "Duration", dimensions: dim, stat: "Average", label: "Duration avg (ms)")]
    }

    public static func sqsSpecs(queueName: String) -> [MetricSpec] {
        let dim = [(name: "QueueName", value: queueName)]
        return [MetricSpec(namespace: "AWS/SQS", name: "ApproximateNumberOfMessagesVisible", dimensions: dim, stat: "Maximum", label: "Visible messages"),
                MetricSpec(namespace: "AWS/SQS", name: "ApproximateAgeOfOldestMessage", dimensions: dim, stat: "Maximum", label: "Oldest message age (s)")]
    }

    public static func parseSeries(_ json: JSONValue?) -> [MetricSeries] {
        (json?.array("MetricDataResults") ?? []).map { r in
            let times = r.array("Timestamps").map { AwsDate.parse($0) }
            let values = r.array("Values").map { $0.doubleValue }
            let points = zip(times, values).compactMap { t, v -> MetricPoint? in
                guard let t, let v else { return nil }
                return MetricPoint(time: t, value: v)
            }.sorted { $0.time < $1.time }
            return MetricSeries(id: r.string("Id") ?? "", label: r.string("Label") ?? r.string("Id") ?? "", points: points)
        }
    }

    // MARK: Alarms

    public static func alarmsInAlarm(profile: String, region: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "cloudwatch", operation: "describe-alarms",
                    params: .object(["StateValue": .string("ALARM")]), maxItems: 200)
    }

    public static func parseAlarms(_ json: JSONValue?) -> [AlarmSummary] {
        func make(_ a: JSONValue, composite: Bool) -> AlarmSummary? {
            guard let n = a.string("AlarmName") else { return nil }
            return AlarmSummary(name: n, state: a.string("StateValue") ?? "?", reason: a.string("StateReason"),
                                updated: AwsDate.parse(a["StateUpdatedTimestamp"]), isComposite: composite)
        }
        return ((json?.array("MetricAlarms") ?? []).compactMap { make($0, composite: false) }
                + (json?.array("CompositeAlarms") ?? []).compactMap { make($0, composite: true) })
            .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }
}
