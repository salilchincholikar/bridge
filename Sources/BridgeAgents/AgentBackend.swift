import BridgeCore
import Foundation

/// What one assistant session may touch.
public struct AgentScope: Sendable {
    /// Profiles the assistant may use. Empty means none. Defaults to just the tab's profile (least privilege).
    public var profiles: Set<String>
    /// Largest tool result returned to the agent, in bytes (it becomes prompt text sent to the provider).
    public var outputCapBytes: Int
    public init(profiles: Set<String>, outputCapBytes: Int = 60_000) { self.profiles = profiles; self.outputCapBytes = outputCapBytes }
}

public struct AgentTraceEntry: Identifiable, Sendable {
    public enum Status: String, Sendable { case ok, denied, error }
    public let id = UUID()
    public var time = Date()
    public var tool: String
    public var summary: String
    public var status: Status
    public var bytes: Int
    public var redactions: Int
}

/// The single enforcement point for everything an agent can do (docs/technical.md 6.1 to 6.4). It only offers
/// read-tier tools; the policy table, the profile cap, the sensitive and credential classes, masking, redaction
/// and an output cap all apply, and every call is traced for the user to see.
public final class AgentBackend: McpToolBackend, @unchecked Sendable {
    private let data: DataService
    private let config: AwsConfig
    private let settings: BridgeSettings
    private let scope: AgentScope
    private let tab: UUID
    private let uiContext: @Sendable () async -> String
    private let trace: @Sendable (AgentTraceEntry) -> Void

    public init(data: DataService, config: AwsConfig, settings: BridgeSettings, scope: AgentScope, tab: UUID = UUID(),
                uiContext: @escaping @Sendable () async -> String, trace: @escaping @Sendable (AgentTraceEntry) -> Void) {
        self.data = data; self.config = config; self.settings = settings; self.scope = scope; self.tab = tab
        self.uiContext = uiContext; self.trace = trace
    }

    public static let instructions = """
        Read-only access to the user's AWS accounts through Bridge. Start with get_ui_context to see what the user is looking at, \
        then use aws_read. Only profiles listed by list_profiles are available. Results are capped and may be redacted; if a result \
        is truncated, narrow the request (a filter, a time window, a smaller max_items). You cannot change anything.
        """

    // MARK: Tools

    public func listTools() async throws -> [McpTool] {
        func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
        }
        func str(_ d: String) -> JSONValue { .object(["type": .string("string"), "description": .string(d)]) }
        return [
            McpTool(name: "get_ui_context", title: "What the user is looking at",
                    description: "The profile, region, view, selected resource and time range the user currently has open in Bridge.",
                    inputSchema: schema([:])),
            McpTool(name: "list_profiles", title: "Available AWS profiles",
                    description: "The AWS profiles this assistant may use, with their regions and account ids.", inputSchema: schema([:])),
            McpTool(name: "list_operations", title: "Supported read operations",
                    description: "The AWS CLI services and operations aws_read supports (CLI names, for example lambda list-functions).", inputSchema: schema([:])),
            McpTool(name: "aws_read", title: "Run a read-only AWS operation",
                    description: "Runs one supported read-only AWS CLI operation and returns its JSON. Use list_operations to see what is supported. Parameters use AWS API names (for example FunctionName), not CLI flags.",
                    inputSchema: schema([
                        "profile": str("AWS profile name from list_profiles"),
                        "region": str("AWS region, for example eu-west-1. Defaults to the profile's region."),
                        "service": str("AWS CLI service name, for example lambda, logs, ecs, sqs, iam, s3api, cloudwatch"),
                        "operation": str("AWS CLI operation name, for example list-functions"),
                        "params": .object(["type": .string("object"), "description": .string("Operation parameters as a JSON object using API parameter names")]),
                        "max_items": .object(["type": .string("integer"), "description": .string("Optional: stop after this many items (only for operations that paginate)")]),
                    ], required: ["profile", "service", "operation"])),
        ]
    }

    public func callTool(name: String, arguments: JSONValue) async -> McpToolResult {
        switch name {
        case "get_ui_context":
            let text = await uiContext()
            record("get_ui_context", "", .ok, text, 0)
            return McpToolResult(text: text)
        case "list_profiles": return listProfiles()
        case "list_operations": return listOperations()
        case "aws_read": return await awsRead(arguments)
        default: return McpToolResult(text: "Unknown tool \(name)", isError: true)
        }
    }

    private func listProfiles() -> McpToolResult {
        let items: [JSONValue] = scope.profiles.sorted().map { n in
            let p = config.profile(named: n)
            var o: [String: JSONValue] = ["profile": .string(n)]
            if let r = settings.profiles[n]?.defaultRegion ?? p?.region { o["region"] = .string(r) }
            if let a = p?.accountId { o["account"] = .string(a) }
            return .object(o)
        }
        let text = JSONValue.array(items).compactString()
        record("list_profiles", "", .ok, text, 0)
        return McpToolResult(text: items.isEmpty ? "No profiles are available to the assistant. The user can allow one in Bridge." : text)
    }

    private func listOperations() -> McpToolResult {
        let cap = min(settings.agentMaxTier, .read) // this tool set is read-only by construction
        var byService: [String: [String]] = [:]
        for (key, e) in PolicyTable.standard.entries where !e.credential && !e.sensitive && e.tier <= cap {
            let parts = key.split(separator: " ").map(String.init)
            guard parts.count == 2 else { continue }
            byService[parts[0], default: []].append(parts[1] + (e.costsMoney ? " (may cost money)" : ""))
        }
        let text = byService.keys.sorted().map { "\($0): " + byService[$0]!.sorted().joined(separator: ", ") }.joined(separator: "\n")
        record("list_operations", "", .ok, text, 0)
        return McpToolResult(text: text)
    }

    private func awsRead(_ a: JSONValue) async -> McpToolResult {
        guard let profile = a.string("profile"), let service = a.string("service"), let operation = a.string("operation") else {
            return failure("aws_read", "", .error, "profile, service and operation are required.")
        }
        let summary = "\(service) \(operation) · \(profile)"
        guard scope.profiles.contains(profile) else {
            let avail = scope.profiles.sorted().joined(separator: ", ")
            return failure("aws_read", summary, .denied, "The profile \"\(profile)\" is not available to the assistant in this session. Available: \(avail.isEmpty ? "none" : avail).")
        }
        guard let region = a.string("region") ?? settings.profiles[profile]?.defaultRegion ?? config.profile(named: profile)?.region else {
            return failure("aws_read", summary, .error, "No region given and the profile has no default region. Pass region.")
        }
        var params: JSONValue?
        if let p = a["params"], p != .null {
            guard case .object = p else { return failure("aws_read", summary, .error, "params must be a JSON object.") }
            params = p
        }
        let request = ExecRequest(profile: profile, region: region, service: service, operation: operation, params: params,
                                  maxItems: a.int("max_items").flatMap { $0 > 0 ? min($0, 1000) : nil })
        do {
            let fetched = try await data.fetch(request, tab: tab, window: nil, caller: .agent)
            var json = fetched.result.json ?? .null
            if !fetched.maskPaths.isEmpty { json = Redactor.mask(json, paths: fetched.maskPaths) }
            var text = json.compactString()
            let redacted = Redactor.redact(text)
            text = redacted.text
            var note = ""
            if text.utf8.count > scope.outputCapBytes {
                text = String(decoding: Array(text.utf8.prefix(scope.outputCapBytes)), as: UTF8.self)
                note = "\n[truncated to \(scope.outputCapBytes) bytes: narrow the request with a filter, time window or max_items]"
            }
            if let t = fetched.result.nextToken { note += "\n[more results exist; NextToken \(t) (re-run with a smaller scope)]" }
            record("aws_read", summary, .ok, text, redacted.redactions)
            return McpToolResult(text: text + note)
        } catch DataError.denied(let reason) {
            return failure("aws_read", summary, .denied, "Not allowed: " + Self.describe(reason))
        } catch is CredentialTrustError {
            return failure("aws_read", summary, .denied, "A credential helper requires human review in Bridge before this profile can be used. The assistant cannot approve helpers.")
        } catch ExecError.authExpired {
            return failure("aws_read", summary, .error, "The AWS session for \"\(profile)\" has expired. Ask the user to sign in from Bridge.")
        } catch ExecError.commandFailed(_, let stderr) {
            return failure("aws_read", summary, .error, "AWS reported an error: " + Redactor.redact(String(stderr.prefix(800))).text)
        } catch {
            return failure("aws_read", summary, .error, "The call failed: \(error)")
        }
    }

    // MARK: Helpers

    private func record(_ tool: String, _ summary: String, _ status: AgentTraceEntry.Status, _ text: String, _ redactions: Int) {
        trace(AgentTraceEntry(tool: tool, summary: summary, status: status, bytes: text.utf8.count, redactions: redactions))
    }
    private func failure(_ tool: String, _ summary: String, _ status: AgentTraceEntry.Status, _ message: String) -> McpToolResult {
        record(tool, summary, status, message, 0)
        return McpToolResult(text: message, isError: true)
    }

    /// Plain language for the model (it can relay this to the user).
    public static func describe(_ r: DenyReason) -> String {
        switch r {
        case .unsupported: return "that operation is not in the supported set (use list_operations)."
        case .credentialClass: return "credential-producing operations are never available."
        case .aboveCap(let need, let cap): return "it needs tier \(need.rawValue) (\(need)) and the assistant is limited to tier \(cap.rawValue) (\(cap))."
        case .identityNotVerified: return "the account for this profile could not be verified."
        case .identityMismatch(let e, let a): return "the profile resolves to account \(a), not the expected \(e)."
        case .sensitiveHiddenFromAgent: return "that operation can return secrets, so it is not available to the assistant."
        case .deniedParameter(let p): return "the parameter \(p) is not allowed."
        case .confirmationRequired: return "it would need the user's confirmation."
        case .invalidRequest(let m): return "invalid request: \(m)"
        }
    }
}
