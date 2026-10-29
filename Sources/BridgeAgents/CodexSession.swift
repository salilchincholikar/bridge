import BridgeCore
import Foundation

// Codex adapter. Everything here was verified against the installed Codex CLI (0.164.0, 2026-10-28):
//  - `codex debug prompt-input` renders the tool list the model would see, locally, with no model call;
//  - `--disable shell_tool --disable unified_exec` removes the shell (`exec_command`, `write_stdin`), `--disable view_image`
//    removes image reading, `--disable apps` removes account connectors, and `-c web_search="disabled"` removes web access;
//  - `-c mcp_servers.<name>.command/args/env` registers an MCP server for one run, and
//    `-c mcp_servers.<name>.default_tools_approval_mode="approve"` pre-approves its tools (without it every call fails with
//    "MCP tool call requires approval, but approval policy is never");
//  - one live turn with a stub tool confirmed the server connects, the tool is called, and the model itself reported no shell or web tool.
// Residual capabilities that cannot be removed by flag (documented in docs/technical.md 6.5): `apply_patch` (kept harmless by the
// read-only sandbox, and any file change aborts the run), the JavaScript `exec` runner (its own capabilities are unverified),
// multi-agent helpers, and MCP resource helpers. `CodexLockdown.verify` re-checks the tool list so an update that adds a
// shell, web or any unknown tool makes Bridge refuse to use Codex.

public enum CodexLockdown {
    public static let disabledFeatures = ["shell_tool", "unified_exec", "apps", "view_image", "plugins", "hooks", "memories",
                                          "image_generation", "computer_use", "browser_use", "browser_use_external", "in_app_browser", "standalone_web_search"]

    /// Tools Bridge accepts being present. Anything else in the tool list makes `verify` fail.
    public static let allowedNestedTools: Set<String> = ["apply_patch", "list_mcp_resource_templates", "list_mcp_resources", "read_mcp_resource", "clock__curr_time"]

    /// Event item types that mean a forbidden capability was used. The run is killed on sight.
    public static let forbiddenItemTypes: Set<String> = ["command_execution", "file_change", "web_search", "patch_apply", "exec_command"]

    static func toml(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// Flags shared by every Codex invocation (also used for the self-check, minus the MCP server).
    public static func baseFlags() -> [String] {
        var a: [String] = []
        for f in disabledFeatures { a += ["--disable", f] }
        a += ["-c", "web_search=\"disabled\"", "-c", "sandbox_mode=\"read-only\""]
        return a
    }

    public static func mcpFlags(executable: String, socketPath: String, token: String) -> [String] {
        ["-c", "mcp_servers.bridge.command=\(toml(executable))",
         "-c", "mcp_servers.bridge.args=[\"mcp\"]",
         "-c", "mcp_servers.bridge.env={BRIDGE_AGENT_SOCKET=\(toml(socketPath)), BRIDGE_AGENT_TOKEN=\(toml(token))}",
         "-c", "mcp_servers.bridge.default_tools_approval_mode=\"approve\""]
    }

    public struct Report: Equatable, Sendable {
        public var ok: Bool
        public var tools: [String]
        public var unexpected: [String]
        public var problem: String?
    }

    /// Render the tool list Codex would give the model, with the lockdown flags, and check it. No model call, no network.
    public static func verify(codexPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> Report {
        let home = NSTemporaryDirectory() + "bridge-codex-check-" + UUID().uuidString.prefix(8) // empty CODEX_HOME: no user config
        let cwd = NSTemporaryDirectory() + "bridge-codex-check-cwd-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: home); try? FileManager.default.removeItem(atPath: cwd) }
        var env = CodexSession.environment(from: environment, codexPath: codexPath, keepAPIKey: false)
        env["CODEX_HOME"] = home
        guard let out = try? await ProcessRunner.run(executable: codexPath, arguments: ["debug", "prompt-input"] + baseFlags(), environment: env,
                                                     timeout: 60, stdoutCap: 8 * 1024 * 1024, workingDirectory: cwd),
              out.status == 0, let json = try? JSONValue.parse(out.stdout), let items = json.arrayValue else {
            return Report(ok: false, tools: [], unexpected: [], problem: "could not render Codex's tool list (is this a supported Codex version?)")
        }
        var headings: [String] = []
        func walk(_ ts: [JSONValue]) {
            for t in ts {
                if t.string("type") == "namespace" { walk(t.array("tools")) }
                else if t.string("name") == "exec" {
                    let d = t.string("description") ?? ""
                    for line in d.split(separator: "\n") where line.hasPrefix("### `") {
                        if let end = line.dropFirst(5).firstIndex(of: "`") { headings.append(String(line.dropFirst(5)[..<end])) }
                    }
                }
            }
        }
        for item in items where item.string("type") == "additional_tools" { walk(item.array("tools")) }
        let unexpected = headings.filter { !allowedNestedTools.contains($0) }.sorted()
        // Top-level tools are checked too: nothing web-like or shell-like may appear at any level.
        let text = String(decoding: out.stdout, as: UTF8.self)
        var bad = unexpected
        for needle in ["\"web__run\"", "\"name\":\"web\"", "\"name\": \"web\""] where text.contains(needle) { bad.append("web") }
        return Report(ok: bad.isEmpty && !headings.isEmpty, tools: headings.sorted(), unexpected: Array(Set(bad)).sorted(),
                      problem: headings.isEmpty ? "found no tool list to check" : (bad.isEmpty ? nil : "unexpected tools exposed: \(Array(Set(bad)).sorted().joined(separator: ", "))"))
    }
}

public enum CodexStream {
    /// Parses one `codex exec --json` line. Shapes seen in a live run: `thread.started`, `turn.started`, `item.started` and
    /// `item.completed` (items `agent_message`, `mcp_tool_call`), `turn.completed`, `turn.failed`. No partial-text events exist.
    public static func parse(line: String) -> [ClaudeEvent] {
        guard let d = line.data(using: .utf8), let v = try? JSONValue.parse(d), case .object = v, let type = v.string("type") else { return [] }
        let item = v["item"]
        switch type {
        case "thread.started":
            return [.initialized(sessionId: v.string("thread_id"), mcpServers: [:], tools: [])]
        case "item.completed" where item?.string("type") == "agent_message":
            return item?.string("text").map { [.assistantText($0)] } ?? []
        case "item.started" where item?.string("type") == "mcp_tool_call":
            guard let tool = item?.string("tool") else { return [] }
            return [.toolUse(id: item?.string("id") ?? "", name: "mcp__\(item?.string("server") ?? "bridge")__\(tool)", input: item?["arguments"] ?? .object([:]))]
        case "item.completed" where item?.string("type") == "mcp_tool_call":
            let err = item?.string("error.message")
            let text = err ?? (item?.array("result.content").compactMap { $0.string("text") }.joined(separator: "\n") ?? "")
            return [.toolResult(id: item?.string("id") ?? "", text: text, isError: err != nil || item?.string("status") == "failed")]
        case "turn.failed":
            return [.result(text: v.string("error.message") ?? "the turn failed", isError: true, sessionId: nil, costUSD: nil, subtype: "turn.failed")]
        default:
            return []
        }
    }

    /// The name of a forbidden capability if this line shows one being used.
    public static func forbiddenItem(line: String) -> String? {
        guard let d = line.data(using: .utf8), let v = try? JSONValue.parse(d), let t = v.string("item.type") else { return nil }
        return CodexLockdown.forbiddenItemTypes.contains(t) ? t : nil
    }
}

public final class CodexSession: AgentConversation, @unchecked Sendable {
    public private(set) var sessionId: String
    private let launch: AgentLaunch
    private let workDir: String
    private let lock = NSLock()
    private var threadId: String?

    public init(launch: AgentLaunch) throws {
        self.launch = launch
        sessionId = UUID().uuidString.lowercased()
        workDir = NSTemporaryDirectory() + "bridge-agent-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit { close() }
    public func close() { try? FileManager.default.removeItem(atPath: workDir) }

    /// First turn: `exec`. Later turns: `exec resume <thread id>`; `resume` accepts the same override flags (checked with --help).
    public func arguments(prompt: String, resuming thread: String?) -> [String] {
        var a = thread == nil ? ["exec"] : ["exec", "resume"]
        a += ["--json", "--ignore-user-config", "--skip-git-repo-check"]
        if thread == nil { a.append("--ignore-rules") }
        if !launch.persistSessions { a.append("--ephemeral") }
        a += CodexLockdown.baseFlags()
        a += CodexLockdown.mcpFlags(executable: launch.mcpExecutable, socketPath: launch.socketPath, token: launch.token)
        if let m = launch.model { a += ["-m", m] }
        if let t = thread { a.append(t) }
        // The system prompt rides on the first message; stdin is /dev/null (otherwise Codex waits to read piped input).
        a.append(thread == nil ? AgentSession.systemPrompt + "\n\n" + prompt : prompt)
        return a
    }

    public static func environment(from source: [String: String], codexPath: String, keepAPIKey: Bool) -> [String: String] {
        let pass: Set<String> = ["HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "SHELL", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
                                 "SSL_CERT_FILE", "CODEX_HOME", "CODEX_API_KEY"]
        var env = source.filter { pass.contains($0.key) }
        if keepAPIKey, let k = source["OPENAI_API_KEY"] { env["OPENAI_API_KEY"] = k }
        env["PATH"] = [(codexPath as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        return env
    }

    public func send(_ prompt: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                     onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws -> ClaudeEvent {
        let thread = currentThread()
        let collector = AgentSession.LineCollector()
        let state = StreamState()
        let box = TaskBox()
        let args = arguments(prompt: prompt.hasPrefix("-") ? " " + prompt : prompt, resuming: thread)

        func handle(_ line: String) {
            if let bad = CodexStream.forbiddenItem(line: line) { state.forbidden = bad; box.cancel(); return }
            for ev in CodexStream.parse(line: line) {
                switch ev {
                case .initialized(let sid, _, _): if let sid { state.thread = sid }
                case .assistantText(let t): state.lastText = t
                case .result(_, true, _, _, _): state.failure = ev
                default: break
                }
                onEvent(ev)
            }
        }

        let env = Self.environment(from: environment, codexPath: launch.claudePath, keepAPIKey: launch.keepAPIKey)
        let task = Task { () throws -> ProcessOutcome in
            try await ProcessRunner.run(executable: launch.claudePath, arguments: args, environment: env, timeout: launch.turnTimeout,
                                        stdoutCap: 64 * 1024 * 1024, workingDirectory: workDir) { data, isStdout in
                guard isStdout else { return }
                for line in collector.feed(data) { handle(line) }
            }
        }
        box.set(task)
        let outcome: ProcessOutcome
        do { outcome = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch let e as ProcessError {
            switch e { case .spawnFailed(let n), .pipeFailed(let n): throw n == ENOENT ? AgentError.harnessNotFound : AgentError.spawnFailed(errno: n) }
        }
        for line in collector.flush() { handle(line) }

        if let bad = state.forbidden { throw AgentError.forbiddenTool(bad) }
        if outcome.cancelled { throw CancellationError() }
        if outcome.timedOut { throw AgentError.timedOut }
        if let t = state.thread { setThread(t) }
        let stderr = String(decoding: outcome.stderr.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if case .result(let text, _, _, _, _)? = state.failure {
            let l = text.lowercased()
            if l.contains("401") || l.contains("unauthorized") || l.contains("not logged in") || l.contains("log in") || l.contains("sign in") { throw AgentError.notSignedIn }
            throw AgentError.failed(status: outcome.status, message: text)
        }
        if outcome.signaled || outcome.status != 0 {
            let l = stderr.lowercased()
            if l.contains("not logged in") || l.contains("login") && l.contains("required") { throw AgentError.notSignedIn }
            throw AgentError.failed(status: outcome.status, message: stderr.isEmpty ? "the assistant process exited without finishing" : stderr)
        }
        let final = ClaudeEvent.result(text: state.lastText ?? "", isError: false, sessionId: state.thread ?? thread, costUSD: nil, subtype: "success")
        onEvent(final)
        return final
    }

    private func currentThread() -> String? { lock.lock(); defer { lock.unlock() }; return threadId }
    private func setThread(_ t: String) { lock.lock(); threadId = t; lock.unlock() }

    private final class StreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var _thread: String?, _last: String?, _forbidden: String?, _failure: ClaudeEvent?
        var thread: String? { get { lock.lock(); defer { lock.unlock() }; return _thread } set { lock.lock(); _thread = newValue; lock.unlock() } }
        var lastText: String? { get { lock.lock(); defer { lock.unlock() }; return _last } set { lock.lock(); _last = newValue; lock.unlock() } }
        var forbidden: String? { get { lock.lock(); defer { lock.unlock() }; return _forbidden } set { lock.lock(); _forbidden = newValue; lock.unlock() } }
        var failure: ClaudeEvent? { get { lock.lock(); defer { lock.unlock() }; return _failure } set { lock.lock(); _failure = newValue; lock.unlock() } }
    }
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock(); private var t: Task<ProcessOutcome, Error>?
        func set(_ x: Task<ProcessOutcome, Error>) { lock.lock(); t = x; lock.unlock() }
        func cancel() { lock.lock(); let x = t; lock.unlock(); x?.cancel() }
    }
}

public enum CodexHarness {
    public static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let p = environment["BRIDGE_CODEX_PATH"], !p.isEmpty { return p }
        return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(NSHomeDirectory())/.local/bin/codex"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `codex login status` exits 0 when signed in (documented). Local state only.
    public static func isSignedIn(codexPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool? {
        guard let out = try? await ProcessRunner.run(executable: codexPath, arguments: ["login", "status"],
                                                     environment: CodexSession.environment(from: environment, codexPath: codexPath, keepAPIKey: false), timeout: 20, stdoutCap: 65_536) else { return nil }
        return out.status == 0
    }
}
