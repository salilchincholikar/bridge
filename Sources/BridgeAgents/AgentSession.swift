import BridgeCore
import Foundation

// Claude Code adapter. Facts used here come from Anthropic's Claude Code documentation and the installed CLI's `--help`
// (checked 2026-10-28, v2.1.312); anything not documented is marked `[unverified]` in docs/technical.md 6.5.
// Codex has its own adapter (CodexSession.swift). Its docs do not show how to disable the built-in shell, but the installed CLI does
// (`--disable shell_tool`), verified by rendering its tool list; see docs/technical.md 6.5.

public enum ClaudeEvent: Equatable, Sendable {
    case initialized(sessionId: String?, mcpServers: [String: String], tools: [String])
    case textDelta(String)
    case assistantText(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, text: String, isError: Bool)
    case result(text: String, isError: Bool, sessionId: String?, costUSD: Double?, subtype: String?)
}

public enum ClaudeStream {
    /// Parses one line of `--output-format stream-json`. Tolerant: unknown shapes yield no events, never an error.
    /// Event shapes: `system/init`, `stream_event` (partial text), `assistant`, `user` (tool results), `result`.
    public static func parse(line: String) -> [ClaudeEvent] {
        guard let d = line.data(using: .utf8), let v = try? JSONValue.parse(d), case .object = v, let type = v.string("type") else { return [] }
        switch type {
        case "system":
            guard v.string("subtype") == "init" else { return [] }
            var servers: [String: String] = [:]
            for s in v.array("mcp_servers") { if let n = s.string("name") { servers[n] = s.string("status") ?? "?" } }
            return [.initialized(sessionId: v.string("session_id"), mcpServers: servers, tools: v.strings("tools"))]
        case "stream_event":
            if v.string("event.type") == "content_block_delta", v.string("event.delta.type") == "text_delta", let t = v.string("event.delta.text") { return [.textDelta(t)] }
            return []
        case "assistant":
            return v.array("message.content").compactMap { b in
                switch b.string("type") {
                case "text": return b.string("text").map { .assistantText($0) }
                case "tool_use": return b.string("name").map { .toolUse(id: b.string("id") ?? "", name: $0, input: b["input"] ?? .object([:])) }
                default: return nil
                }
            }
        case "user":
            return v.array("message.content").compactMap { b in
                guard b.string("type") == "tool_result" else { return nil }
                let text: String
                if let s = b.string("content") { text = s }
                else { text = b.array("content").compactMap { $0.string("text") }.joined(separator: "\n") }
                return .toolResult(id: b.string("tool_use_id") ?? "", text: text, isError: b["is_error"]?.boolValue ?? false)
            }
        case "result":
            return [.result(text: v.string("result") ?? (v.strings("errors").joined(separator: "; ")), isError: v["is_error"]?.boolValue ?? (v.string("subtype") != "success"),
                            sessionId: v.string("session_id"), costUSD: v.double("total_cost_usd"), subtype: v.string("subtype"))]
        default:
            return []
        }
    }
}

/// One assistant conversation with a coding-agent CLI (Claude Code or Codex).
public protocol AgentConversation: AnyObject, Sendable {
    var sessionId: String { get }
    func send(_ prompt: String, environment: [String: String], onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws -> ClaudeEvent
    func close()
}

public enum AgentProvider: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex = "codex"
    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    public var company: String { self == .claudeCode ? "Anthropic" : "OpenAI" }
}

public enum AgentError: Error, Equatable, Sendable {
    /// The run used (or tried to use) a capability Bridge forbids; it was stopped.
    case forbiddenTool(String)
    case harnessNotFound
    case notSignedIn
    case failed(status: Int32, message: String)
    case timedOut
    case spawnFailed(errno: Int32)
}

public struct AgentLaunch: Sendable {
    public var claudePath: String
    public var mcpExecutable: String
    public var socketPath: String
    public var token: String
    public var model: String?
    /// Keep ANTHROPIC_API_KEY in the child's environment. Default false: the user's subscription login is used, and an
    /// API key in the environment would take over in print mode (documented), changing who is billed.
    public var keepAPIKey: Bool
    /// Let Claude Code save the session transcript (locally, plaintext, under ~/.claude/projects/) so follow-up messages work.
    public var persistSessions: Bool
    public var turnTimeout: TimeInterval

    public init(claudePath: String, mcpExecutable: String, socketPath: String, token: String, model: String? = nil,
                keepAPIKey: Bool = false, persistSessions: Bool = true, turnTimeout: TimeInterval = 600) {
        self.claudePath = claudePath; self.mcpExecutable = mcpExecutable; self.socketPath = socketPath; self.token = token
        self.model = model; self.keepAPIKey = keepAPIKey; self.persistSessions = persistSessions; self.turnTimeout = turnTimeout
    }
}

public final class AgentSession: AgentConversation, @unchecked Sendable {
    public let sessionId = UUID().uuidString.lowercased()
    private let launch: AgentLaunch
    private let workDir: String
    private let lock = NSLock()
    private var turns = 0

    public static let systemPrompt = """
        You are the assistant inside Bridge, a local AWS workbench. You have read-only tools for the user's AWS accounts and no other tools. \
        Use get_ui_context first to see what the user is looking at. Be concrete: cite the resource names, ids and times you found. \
        If a tool says something is not allowed, tell the user plainly; do not try to work around it. Never ask for or repeat credentials or secrets.
        """

    public init(launch: AgentLaunch) throws {
        self.launch = launch
        workDir = NSTemporaryDirectory() + "bridge-agent-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // The MCP config names Bridge as the ONLY server; the token lives in a 0600 file removed at the end of the session.
        let cfg: JSONValue = .object(["mcpServers": .object(["bridge": .object([
            "command": .string(launch.mcpExecutable), "args": .array([.string("mcp")]),
            "env": .object(["BRIDGE_AGENT_SOCKET": .string(launch.socketPath), "BRIDGE_AGENT_TOKEN": .string(launch.token)]),
        ])])])
        FileManager.default.createFile(atPath: workDir + "/mcp.json", contents: try cfg.data(pretty: true), attributes: [.posixPermissions: 0o600])
    }

    deinit { close() }
    public func close() { try? FileManager.default.removeItem(atPath: workDir) }

    private func nextTurn() -> Int { lock.lock(); defer { lock.unlock() }; let t = turns; turns += 1; return t }

    /// The exact command line (testable). First turn creates the session id; later turns resume it.
    public func arguments(prompt: String, turn: Int) -> [String] {
        var a = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                 "--mcp-config", workDir + "/mcp.json", "--strict-mcp-config",
                 "--tools", "",                          // no built-in tools: no shell, no file access, no web
                 "--allowedTools", "mcp__bridge__*",     // our tools run without a permission prompt (print mode would deny otherwise)
                 "--setting-sources", "user",            // not the project's settings (the working directory is empty anyway)
                 "--append-system-prompt", Self.systemPrompt]
        a += turn == 0 ? ["--session-id", sessionId] : ["--resume", sessionId]
        if !launch.persistSessions { a.append("--no-session-persistence") }
        if let m = launch.model { a += ["--model", m] }
        return a
    }

    /// The child's environment: an allowlist. No AWS_* variable ever reaches the harness.
    public static func environment(from source: [String: String], launch: AgentLaunch) -> [String: String] {
        let pass: Set<String> = ["HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "SHELL", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
                                 "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
                                 "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "DISABLE_FEEDBACK_COMMAND"]
        var env = source.filter { pass.contains($0.key) }
        if launch.keepAPIKey, let k = source["ANTHROPIC_API_KEY"] { env["ANTHROPIC_API_KEY"] = k }
        let claudeDir = (launch.claudePath as NSString).deletingLastPathComponent
        env["PATH"] = [claudeDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        return env
    }

    /// Send one message. `onEvent` streams parsed events (from background threads). Returns the final result event.
    public func send(_ prompt: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                     onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws -> ClaudeEvent {
        let turn = nextTurn()
        let safePrompt = prompt.hasPrefix("-") ? " " + prompt : prompt
        let collector = LineCollector()
        var final: ClaudeEvent?
        let finalBox = FinalBox()

        let outcome: ProcessOutcome
        do {
            outcome = try await ProcessRunner.run(
                executable: launch.claudePath, arguments: arguments(prompt: safePrompt, turn: turn),
                environment: Self.environment(from: environment, launch: launch),
                timeout: launch.turnTimeout, stdoutCap: 64 * 1024 * 1024, workingDirectory: workDir) { data, isStdout in
                    guard isStdout else { return }
                    for line in collector.feed(data) {
                        for ev in ClaudeStream.parse(line: line) {
                            if case .result = ev { finalBox.set(ev) }
                            onEvent(ev)
                        }
                    }
                }
        } catch let e as ProcessError {
            switch e { case .spawnFailed(let n), .pipeFailed(let n): throw n == ENOENT ? AgentError.harnessNotFound : AgentError.spawnFailed(errno: n) }
        }
        for line in collector.flush() { for ev in ClaudeStream.parse(line: line) { if case .result = ev { finalBox.set(ev) }; onEvent(ev) } }
        if outcome.cancelled { throw CancellationError() }
        if outcome.timedOut { throw AgentError.timedOut }
        final = finalBox.value
        let stderr = String(decoding: outcome.stderr.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if case .result(let text, let isError, _, _, _)? = final {
            if isError {
                let lower = text.lowercased()
                if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("authentication") || lower.contains("log in") { throw AgentError.notSignedIn }
                throw AgentError.failed(status: outcome.status, message: text)
            }
            return final!
        }
        if outcome.signaled || outcome.status != 0 { throw AgentError.failed(status: outcome.status, message: stderr.isEmpty ? "the assistant process exited without a result" : stderr) }
        throw AgentError.failed(status: outcome.status, message: "the assistant produced no result")
    }

    private final class FinalBox: @unchecked Sendable {
        private let lock = NSLock(); private var v: ClaudeEvent?
        func set(_ e: ClaudeEvent) { lock.lock(); v = e; lock.unlock() }
        var value: ClaudeEvent? { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// Splits streamed bytes into lines.
    final class LineCollector: @unchecked Sendable {
        private let lock = NSLock(); private var buffer = Data()
        func feed(_ d: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            buffer.append(d)
            var out: [String] = []
            while let i = buffer.firstIndex(of: 0x0a) {
                out.append(String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...i)
            }
            return out
        }
        func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            defer { buffer.removeAll() }
            return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
        }
    }
}

public enum AgentHarness {
    /// `claude` at fixed, common install locations (never resolved from the caller's PATH). `BRIDGE_CLAUDE_PATH` overrides (tests).
    public static func discoverClaude(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let p = environment["BRIDGE_CLAUDE_PATH"], !p.isEmpty { return p }
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `claude auth status` (documented: JSON, exit 0 when signed in). Local state only; no prompt is sent anywhere.
    public static func isSignedIn(claudePath: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool? {
        let launch = AgentLaunch(claudePath: claudePath, mcpExecutable: "", socketPath: "", token: "")
        guard let out = try? await ProcessRunner.run(executable: claudePath, arguments: ["auth", "status"],
                                                     environment: AgentSession.environment(from: environment, launch: launch), timeout: 20, stdoutCap: 65_536) else { return nil }
        if out.status == 0 { return true }
        return out.status == 1 ? false : nil
    }
}
