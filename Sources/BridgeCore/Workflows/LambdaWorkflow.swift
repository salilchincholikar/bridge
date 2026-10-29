import Foundation

// W1: Lambda. Request builders return ExecRequests (CLI names, API parameter names). Parsers are defensive.

public struct LambdaFunction: Equatable, Sendable {
    public var name: String
    public var arn: String?
    public var runtime: String?
    public var handler: String?
    public var memoryMB: Int?
    public var timeoutSeconds: Int?
    public var roleArn: String?
    public var lastModified: Date?
    public var description: String?
    /// Environment variable NAMES only. Values are sensitive (see `environment`).
    public var environmentKeys: [String]
    /// Environment variable VALUES. Only present for a human caller; the UI masks them until revealed.
    public var environment: [String: String]
    public var logGroup: String
    public var layers: [String]
}

public enum LambdaWorkflow {
    public static func listFunctions(profile: String, region: String, maxItems: Int? = 200, startingToken: String? = nil) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "lambda", operation: "list-functions", maxItems: maxItems, startingToken: startingToken)
    }

    public static func getConfiguration(profile: String, region: String, function: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "lambda", operation: "get-function-configuration",
                    params: .object(["FunctionName": .string(function)]))
    }

    public static func eventSourceMappings(profile: String, region: String, function: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "lambda", operation: "list-event-source-mappings",
                    params: .object(["FunctionName": .string(function)]))
    }

    /// Every function that consumes one event source (for example a queue): one call, filtered server-side.
    public static func eventSourceMappings(profile: String, region: String, sourceArn: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "lambda", operation: "list-event-source-mappings",
                    params: .object(["EventSourceArn": .string(sourceArn)]))
    }

    public static func parseFunctions(_ json: JSONValue?) -> [LambdaFunction] {
        (json?.array("Functions") ?? []).compactMap(parseFunction)
    }

    /// Works for both list items and `get-function-configuration`, which share one shape.
    public static func parseFunction(_ f: JSONValue) -> LambdaFunction? {
        guard let name = f.string("FunctionName") else { return nil }
        let env = f.value(at: "Environment.Variables")?.objectValue?.compactMapValues { $0.stringValue } ?? [:]
        return LambdaFunction(
            name: name, arn: f.string("FunctionArn"), runtime: f.string("Runtime"), handler: f.string("Handler"),
            memoryMB: f.int("MemorySize"), timeoutSeconds: f.int("Timeout"), roleArn: f.string("Role"),
            lastModified: AwsDate.parse(f["LastModified"]), description: f.string("Description").flatMap { $0.isEmpty ? nil : $0 },
            environmentKeys: env.keys.sorted(), environment: env,
            // Newer functions can name a custom log group; otherwise the default is /aws/lambda/<name>.
            logGroup: f.string("LoggingConfig.LogGroup") ?? "/aws/lambda/\(name)",
            layers: f.array("Layers").compactMap { $0.string("Arn") })
    }

    /// Event source mappings: which queues/streams feed this function.
    public struct EventSource: Equatable, Sendable {
        public var arn: String
        public var state: String?
        public var batchSize: Int?
        public var functionArn: String?
        public init(arn: String, state: String?, batchSize: Int?, functionArn: String? = nil) {
            self.arn = arn; self.state = state; self.batchSize = batchSize; self.functionArn = functionArn
        }
        /// `arn:aws:lambda:region:acct:function:name[:alias]` gives `name`.
        public var functionName: String? {
            let p = (functionArn ?? "").split(separator: ":", omittingEmptySubsequences: false)
            return p.count >= 7 && p[5] == "function" ? String(p[6]) : nil
        }
        /// For an SQS source ARN (`arn:aws:sqs:region:acct:queue-name`), the queue name; otherwise nil.
        public var sqsQueueName: String? {
            let p = arn.split(separator: ":", omittingEmptySubsequences: false)
            return p.count == 6 && p[2] == "sqs" ? String(p[5]) : nil
        }
    }

    public static func parseEventSources(_ json: JSONValue?) -> [EventSource] {
        (json?.array("EventSourceMappings") ?? []).compactMap { m in
            guard let arn = m.string("EventSourceArn") else { return nil }
            return EventSource(arn: arn, state: m.string("State"), batchSize: m.int("BatchSize"), functionArn: m.string("FunctionArn"))
        }
    }
}
