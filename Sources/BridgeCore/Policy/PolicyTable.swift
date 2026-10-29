import Foundation

// The standard policy table: one explicit row per supported operation (CLI service and operation names).
// Unlisted operations are denied as `.unsupported`. Adding a service is adding rows here.

extension PolicyTable {
    public static let standard: PolicyTable = {
        var e: [String: PolicyEntry] = [:]
        func add(_ service: String, _ ops: [String], _ entry: PolicyEntry = PolicyEntry()) {
            for op in ops { e[PolicyTable.key(service, op)] = entry }
        }

        // Identity
        add("sts", ["get-caller-identity"])

        // Lambda
        add("lambda", ["list-functions", "list-versions-by-function", "list-event-source-mappings"])
        add("lambda", ["get-function"], PolicyEntry(sensitive: true, maskPaths: ["Code.Location", "Configuration.Environment.Variables"],
                                                    note: "contains environment values and a presigned code download URL"))
        add("lambda", ["get-function-configuration"], PolicyEntry(sensitive: true, maskPaths: ["Environment.Variables"],
                                                                  note: "environment variable values may be secrets"))

        // CloudWatch Logs
        add("logs", ["describe-log-groups", "describe-log-streams", "get-log-events", "start-live-tail", "get-query-results"])
        add("logs", ["filter-log-events"], PolicyEntry(deniedParams: ["Unmask"], note: "unmask needs logs:Unmask and reveals masked data"))
        add("logs", ["start-query"], PolicyEntry(costsMoney: true, note: "Logs Insights queries are billed by data scanned"))

        // CloudWatch metrics and alarms
        add("cloudwatch", ["describe-alarms", "get-metric-data", "list-metrics"])

        // Billing queries are read-only, but Cost Explorer API requests may incur charges.
        add("ce", ["get-cost-and-usage", "get-cost-forecast"], PolicyEntry(costsMoney: true))

        // ECS
        add("ecs", ["list-clusters", "describe-clusters", "list-services", "describe-services", "list-tasks",
                    "describe-tasks", "describe-task-definition"])
        add("ecs", ["stop-task"], PolicyEntry(tier: .reversibleChange))

        // IAM
        add("iam", ["list-roles", "get-role", "list-attached-role-policies", "list-role-policies", "get-role-policy",
                    "get-policy", "get-policy-version"])
        add("iam", ["delete-role"], PolicyEntry(tier: .destructive))

        // S3 (API-level commands are `s3api`)
        add("s3api", ["list-buckets", "list-objects-v2", "head-object"])
        add("s3api", ["get-object"], PolicyEntry(tier: .transfer, note: "writes object content to local disk"))

        // SQS: metrics and attributes only in v1. receive-message hides messages from real consumers.
        add("sqs", ["list-queues", "get-queue-url", "get-queue-attributes"])
        add("sqs", ["receive-message"], PolicyEntry(tier: .reversibleChange,
                                                    note: "hides messages from real consumers for the visibility timeout; not shipped in v1"))
        add("sqs", ["delete-message", "purge-queue"], PolicyEntry(tier: .destructive))

        // Secret-returning, kept for completeness (not in v1 views): sensitive, never shown to agents.
        add("secretsmanager", ["get-secret-value"], PolicyEntry(sensitive: true, maskPaths: ["SecretString", "SecretBinary"]))
        add("ssm", ["get-parameter"], PolicyEntry(sensitive: true, maskPaths: ["Parameter.Value"],
                                                  note: "value is plaintext for String types and decrypted for SecureString with WithDecryption"))

        // Credential-producing: always denied (docs/technical.md 4.5, class 2).
        add("sts", ["get-session-token", "assume-role", "get-federation-token", "assume-role-with-saml",
                    "assume-role-with-web-identity"],
            PolicyEntry(credential: true))
        add("ecr", ["get-login-password", "get-authorization-token"], PolicyEntry(credential: true))
        add("iam", ["create-access-key"], PolicyEntry(credential: true))

        return PolicyTable(entries: e)
    }()
}
