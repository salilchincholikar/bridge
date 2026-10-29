import Foundation

// W6: SQS. Metrics and attributes ONLY. There is deliberately no receive-message here: receiving hides messages
// from real consumers for the visibility timeout (see the policy table, where it is tier 3 and not shipped).

public struct SqsQueue: Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
    public var name: String { String(url.split(separator: "/").last ?? "") }
}

public struct SqsQueueAttributes: Equatable, Sendable {
    public var visible: Int?
    public var inFlight: Int?
    public var delayed: Int?
    public var visibilityTimeoutSeconds: Int?
    public var retentionSeconds: Int?
    public var arn: String?
    public var deadLetterTargetArn: String?
    public var maxReceiveCount: Int?
    public var isFifo: Bool
    public var created: Date?

    /// Name of the dead-letter queue, from its ARN (`arn:aws:sqs:region:account:name`).
    public var deadLetterQueueName: String? { deadLetterTargetArn.flatMap { $0.split(separator: ":").last.map(String.init) } }
}

public enum SqsWorkflow {
    public static func listQueues(profile: String, region: String, prefix: String? = nil) -> ExecRequest {
        var p: [String: JSONValue] = [:]
        if let prefix, !prefix.isEmpty { p["QueueNamePrefix"] = .string(prefix) }
        return ExecRequest(profile: profile, region: region, service: "sqs", operation: "list-queues",
                           params: p.isEmpty ? nil : .object(p), maxItems: 200)
    }

    public static func getAttributes(profile: String, region: String, queueUrl: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "sqs", operation: "get-queue-attributes",
                    params: .object(["QueueUrl": .string(queueUrl), "AttributeNames": .array([.string("All")])]))
    }

    public static func parseQueues(_ json: JSONValue?) -> [SqsQueue] {
        (json?.strings("QueueUrls") ?? []).map { SqsQueue(url: $0) }
    }

    /// SQS returns every attribute value as a string, including the JSON `RedrivePolicy`.
    public static func parseAttributes(_ json: JSONValue?) -> SqsQueueAttributes? {
        guard let attrs = json?["Attributes"]?.objectValue else { return nil }
        func int(_ k: String) -> Int? { attrs[k]?.stringValue.flatMap { Int($0) } ?? attrs[k]?.intValue }
        var dlq: String?
        var maxReceive: Int?
        if let raw = attrs["RedrivePolicy"]?.stringValue, let data = raw.data(using: .utf8), let policy = try? JSONValue.parse(data) {
            dlq = policy.string("deadLetterTargetArn")
            maxReceive = policy.int("maxReceiveCount") ?? policy.string("maxReceiveCount").flatMap { Int($0) }
        }
        return SqsQueueAttributes(
            visible: int("ApproximateNumberOfMessages"), inFlight: int("ApproximateNumberOfMessagesNotVisible"),
            delayed: int("ApproximateNumberOfMessagesDelayed"), visibilityTimeoutSeconds: int("VisibilityTimeout"),
            retentionSeconds: int("MessageRetentionPeriod"), arn: attrs["QueueArn"]?.stringValue,
            deadLetterTargetArn: dlq, maxReceiveCount: maxReceive,
            isFifo: attrs["FifoQueue"]?.stringValue == "true", created: int("CreatedTimestamp").map { Date(timeIntervalSince1970: Double($0)) })
    }
}
