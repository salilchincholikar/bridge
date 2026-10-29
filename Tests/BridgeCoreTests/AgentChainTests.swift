import Foundation
import BridgeCore
import BridgeAgents

// Backend, IPC, stream parser, session and end-to-end tests for the assistant integration.
// Nothing here contacts any AI provider or real AWS: the harness is Fixtures/fake-claude and aws is Fixtures/fake-aws.

final class TraceBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [AgentTraceEntry] = []
    func add(_ e: AgentTraceEntry) { lock.lock(); items.append(e); lock.unlock() }
    var all: [AgentTraceEntry] { lock.lock(); defer { lock.unlock() }; return items }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock(); private var items: [ClaudeEvent] = []
    func add(_ e: ClaudeEvent) { lock.lock(); items.append(e); lock.unlock() }
    var all: [ClaudeEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

func fixtureText(_ name: String) -> String {
    (try? String(contentsOfFile: root.appendingPathComponent("Fixtures/aws/\(name)").path, encoding: .utf8)) ?? ""
}

func makeBackend(profiles: Set<String> = ["example-dev"], cap: Int = 60_000, trace: TraceBox = TraceBox()) -> (AgentBackend, TraceBox) {
    let service = DataService(executor: CLIExecutor(awsPath: fakeAws, environment: testEnvironment), cliVersion: "2.99.9")
    let cfg = AwsConfigParser.parse(fixtureText("typical.config"))
    let backend = AgentBackend(data: service, config: cfg, settings: BridgeSettings(), scope: AgentScope(profiles: profiles, outputCapBytes: cap),
                               uiContext: { "profile example-dev, region eu-west-1, view Lambda" }, trace: { trace.add($0) })
    return (backend, trace)
}

func toolCall(_ b: AgentBackend, _ name: String, _ args: JSONValue = .object([:])) -> McpToolResult {
    blocking { await b.callTool(name: name, arguments: args) }.successValue ?? McpToolResult(text: "<no result>", isError: true)
}

func read(_ b: AgentBackend, _ profile: String, _ service: String, _ op: String, params: JSONValue? = nil) -> McpToolResult {
    var a: [String: JSONValue] = ["profile": .string(profile), "service": .string(service), "operation": .string(op), "region": .string("eu-west-1")]
    if let params { a["params"] = params }
    return toolCall(b, "aws_read", .object(a))
}

func runAgentChainTests() {
    section("agent backend: the policy applies to every call") {
        let (b, trace) = makeBackend()
        let ok = read(b, "example-dev", "lambda", "list-functions")
        expect(!ok.isError && ok.text.contains("FunctionName"), "an allowed read returns data")
        let other = read(b, "example-prod", "lambda", "list-functions")
        expect(other.isError && other.text.contains("not available to the assistant"), "a profile outside the scope is refused and the model is told what is available")
        expect(read(b, "example-dev", "lambda", "get-function-configuration", params: .object(["FunctionName": .string("f")])).text.contains("can return secrets"), "sensitive operations are not available to agents")
        expect(read(b, "example-dev", "sqs", "receive-message").text.contains("limited to tier 1"), "above-cap operations are refused with the tier explained")
        expect(read(b, "example-dev", "s3api", "get-object", params: .object(["Bucket": .string("b"), "Key": .string("k")])).text.contains("tier 2"), "downloads are not available to agents by default")
        expect(read(b, "example-dev", "sts", "get-session-token").text.contains("credential-producing"), "credential operations never")
        expect(read(b, "example-dev", "ec2", "describe-instances").text.contains("not in the supported set"), "unlisted operations refused")
        expect(toolCall(b, "aws_read", .object(["profile": .string("example-dev")])).isError, "missing required arguments is an error result")
        expect(toolCall(b, "aws_read", .object(["profile": .string("example-dev"), "service": .string("lambda"), "operation": .string("list-functions"), "params": .array([])])).isError, "params must be an object")
        let t = trace.all
        expect(t.count >= 8 && t.filter { $0.status == .ok }.count == 1 && t.filter { $0.status == .denied }.count >= 5, "every call is traced with its outcome (\(t.map(\.status.rawValue)))")
        expect(t.first?.tool == "aws_read" && t.first?.summary == "lambda list-functions · example-dev" && (t.first?.bytes ?? 0) > 0, "trace entries say what was asked and how much came back")
    }

    section("agent backend: masking, redaction, truncation") {
        let (b, trace) = makeBackend()
        let fn = read(b, "example-dev", "lambda", "get-function", params: .object(["FunctionName": .string("f")]))
        expect(fn.isError && fn.text.contains("can return secrets") && !fn.text.contains("synthetic-private-value") && !fn.text.contains("X-Amz-Signature"), "full function response never reaches the assistant")
        let logs = read(b, "example-dev", "logs", "get-log-events", params: .object(["logGroupName": .string("g"), "logStreamName": .string("s")]))
        expect(!logs.text.contains("hunter2hunter2") && !logs.text.contains("AKIAABCDEFGHIJKLMNOP"), "secret-looking text in logs is redacted")
        expect(logs.text.contains("connect failed") && logs.text.contains("bob"), "the rest of the log line is kept")
        expect((trace.all.last?.redactions ?? 0) >= 2, "the trace records how many redactions were applied")
        let (small, _) = makeBackend(cap: 120)
        let cut = read(small, "example-dev", "logs", "get-log-events", params: .object(["logGroupName": .string("g"), "logStreamName": .string("s")]))
        expect(cut.text.contains("[truncated to 120 bytes"), "oversized results are cut and the model is told how to narrow")
    }

    section("agent backend: tools, profiles and operations listings") {
        let (b, _) = makeBackend(profiles: ["example-dev", "legacy"])
        let tools = (try? blocking { try await b.listTools() }.get()) ?? []
        expect(tools.map(\.name) == ["get_ui_context", "list_profiles", "list_operations", "aws_read"], "exactly four tools, all read-only: \(tools.map(\.name))")
        expect(tools.allSatisfy { $0.inputSchema.string("type") == "object" }, "every inputSchema is a JSON Schema object")
        expect(toolCall(b, "get_ui_context").text == "profile example-dev, region eu-west-1, view Lambda", "UI context comes from the app")
        let profs = toolCall(b, "list_profiles").text
        expect(profs.contains("example-dev") && profs.contains("legacy") && !profs.contains("example-prod") && profs.contains("111111111111"), "only scoped profiles, with account ids")
        let ops = toolCall(b, "list_operations").text
        expect(ops.contains("lambda: ") && ops.contains("list-functions") && ops.contains("start-query (may cost money)"), "supported reads listed")
        expect(!ops.contains("get-function-configuration") && !ops.contains("get-object") && !ops.contains("get-session-token") && !ops.contains("receive-message"), "sensitive, tier 2+, credential and change operations are not listed")
        let (none, _) = makeBackend(profiles: [])
        expect(toolCall(none, "list_profiles").text.contains("No profiles are available"), "an empty scope says so")
        expect(toolCall(b, "bogus").isError, "unknown tool is an error")
    }

    section("ipc: private socket, token, same-user, round trip") {
        guard let ep = try? AgentIPCServer.makeEndpoint() else { expect(false, "endpoint created"); return }
        expect(ep.path.utf8.count < 100 && ep.token.count == 64, "socket path fits sockaddr_un (\(ep.path.utf8.count) bytes) and the token has 256 bits")
        let (b, _) = makeBackend()
        let server = AgentIPCServer(path: ep.path, token: ep.token, backend: b)
        do { try server.start() } catch { expect(false, "server started: \(error)"); return }
        defer { server.stop() }
        let perms = ((try? FileManager.default.attributesOfItem(atPath: ep.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        expect(perms == 0o600, "socket is 0600, got \(String(perms, radix: 8))")
        let dirPerms = ((try? FileManager.default.attributesOfItem(atPath: (ep.path as NSString).deletingLastPathComponent))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        expect(dirPerms == 0o700, "socket directory is 0700, got \(String(dirPerms, radix: 8))")

        let client = AgentIPCClient(path: ep.path, token: ep.token)
        let tools = (try? blocking { try await client.listTools() }.get()) ?? []
        expect(tools.count == 4 && tools.last?.name == "aws_read", "tools/list through the socket")
        let call = blocking { await client.callTool(name: "aws_read", arguments: .object(["profile": .string("example-dev"), "service": .string("lambda"), "operation": .string("list-functions"), "region": .string("eu-west-1")])) }.successValue
        expect(call?.isError == false && call?.text.contains("FunctionName") == true, "tools/call through the socket")
        let denied = blocking { await client.callTool(name: "aws_read", arguments: .object(["profile": .string("example-prod"), "service": .string("lambda"), "operation": .string("list-functions")])) }.successValue
        expect(denied?.isError == true, "a policy refusal arrives as an error result")

        let wrong = AgentIPCClient(path: ep.path, token: String(repeating: "0", count: 64))
        if case .failure(let e) = blocking({ try await wrong.listTools() }), let ie = e as? AgentIPCError, case .rejected(let m) = ie { expect(m == "unauthorized", "a wrong token is rejected") } else { expect(false, "wrong token must be rejected") }
        let wrongCall = blocking { await wrong.callTool(name: "aws_read", arguments: .object([:])) }.successValue
        expect(wrongCall?.isError == true, "a wrong token cannot call tools")
        expect(AgentIPCServer.constantTimeEqual("abc", "abc") && !AgentIPCServer.constantTimeEqual("abc", "abd") && !AgentIPCServer.constantTimeEqual("abc", "abcd"), "token comparison")

        server.stop()
        let gone = blocking { await client.callTool(name: "get_ui_context", arguments: .object([:])) }.successValue
        expect(gone?.isError == true && gone?.text.contains("not running") == true, "after the session ends, calls fail with a clear message")
        expect(!FileManager.default.fileExists(atPath: ep.path), "the socket file is removed on stop")
    }

    section("claude stream parser") {
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s1","tools":["mcp__bridge__aws_read"],"mcp_servers":[{"name":"bridge","status":"connected"}]}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#,
            #"{"type":"stream_event","event":{"type":"message_start"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"},{"type":"tool_use","id":"t1","name":"mcp__bridge__aws_read","input":{"service":"lambda"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"data"}],"is_error":false}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"plain","is_error":true}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Done","session_id":"s1","total_cost_usd":0.5}"#,
            #"{"type":"result","subtype":"error_max_turns","errors":["too many turns"],"session_id":"s1"}"#,
        ]
        let ev = lines.map { ClaudeStream.parse(line: $0) }
        expect(ev[0] == [.initialized(sessionId: "s1", mcpServers: ["bridge": "connected"], tools: ["mcp__bridge__aws_read"])], "init event with the MCP server status")
        expect(ev[1] == [.textDelta("Hel")] && ev[2].isEmpty, "text deltas, other stream events ignored")
        expect(ev[3] == [.assistantText("Hello"), .toolUse(id: "t1", name: "mcp__bridge__aws_read", input: .object(["service": .string("lambda")]))], "assistant text and tool_use blocks")
        expect(ev[4] == [.toolResult(id: "t1", text: "data", isError: false)] && ev[5] == [.toolResult(id: "t2", text: "plain", isError: true)], "tool results as array or string content")
        expect(ev[6] == [.result(text: "Done", isError: false, sessionId: "s1", costUSD: 0.5, subtype: "success")], "success result")
        expect(ev[7] == [.result(text: "too many turns", isError: true, sessionId: "s1", costUSD: nil, subtype: "error_max_turns")], "error result carries the errors")
        for junk in ["", "not json", "[]", #"{"type":"mystery"}"#, #"{"no":"type"}"#] { expect(ClaudeStream.parse(line: junk).isEmpty, "tolerant of: \(junk.prefix(20))") }
    }

    section("agent session: command line and environment") {
        let launch = AgentLaunch(claudePath: "/Users/x/.local/bin/claude", mcpExecutable: "/path/to/bridge", socketPath: "/tmp/s.sock", token: "tok")
        guard let session = try? AgentSession(launch: launch) else { expect(false, "session created"); return }
        defer { session.close() }
        let first = session.arguments(prompt: "hi", turn: 0), second = session.arguments(prompt: "again", turn: 1)
        func value(_ a: [String], _ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        expect(value(first, "--tools") == "" && first.contains("--strict-mcp-config"), "built-in tools disabled and only our MCP config used")
        expect(value(first, "--allowedTools") == "mcp__bridge__*" && value(first, "--setting-sources") == "user", "our tools pre-approved; project settings not loaded")
        expect(value(first, "--session-id") == session.sessionId && !first.contains("--resume"), "the first turn creates the session")
        expect(value(second, "--resume") == session.sessionId && !second.contains("--session-id"), "later turns resume it")
        expect(value(first, "--output-format") == "stream-json" && first.contains("--verbose") && first.contains("--include-partial-messages"), "streaming flags")
        expect(!first.contains("--no-session-persistence"), "persistence on by default so follow-ups work")
        var noPersist = launch; noPersist.persistSessions = false
        expect((try? AgentSession(launch: noPersist))?.arguments(prompt: "x", turn: 0).contains("--no-session-persistence") == true, "persistence can be turned off")
        let cfgText = (try? String(contentsOfFile: value(first, "--mcp-config") ?? "", encoding: .utf8)) ?? ""
        expect(cfgText.contains("BRIDGE_AGENT_SOCKET") && cfgText.contains("\"mcp\"") && !cfgText.contains("aws_access"), "the MCP config names only the bridge server")
        let cfgPerms = ((try? FileManager.default.attributesOfItem(atPath: value(first, "--mcp-config") ?? ""))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        expect(cfgPerms == 0o600, "the config (it holds the token) is 0600")

        let env = AgentSession.environment(from: ["HOME": "/h", "AWS_ACCESS_KEY_ID": "AKIA", "AWS_PROFILE": "p", "ANTHROPIC_API_KEY": "sk", "CLAUDE_CODE_OAUTH_TOKEN": "tok", "FOO": "bar", "HTTPS_PROXY": "p:1"], launch: launch)
        expect(env["AWS_ACCESS_KEY_ID"] == nil && env["AWS_PROFILE"] == nil && env["FOO"] == nil, "no AWS variable and nothing unlisted reaches the harness")
        expect(env["ANTHROPIC_API_KEY"] == nil, "an API key in the environment is not passed by default (it would override the subscription login)")
        expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "tok" && env["HOME"] == "/h" && env["HTTPS_PROXY"] == "p:1", "the user's own auth token, HOME and proxy settings pass")
        var keep = launch; keep.keepAPIKey = true
        expect(AgentSession.environment(from: ["ANTHROPIC_API_KEY": "sk"], launch: keep)["ANTHROPIC_API_KEY"] == "sk", "the API key passes only when the user opts in")
        expect(env["PATH"]?.hasPrefix("/Users/x/.local/bin:") == true, "PATH is fixed and includes the harness's directory")
    }

    let fakeClaude = root.appendingPathComponent("Fixtures/fake-claude/claude").path
    let hostile = ["HOME": NSHomeDirectory(), "AWS_ACCESS_KEY_ID": "AKIAEVIL", "AWS_PROFILE": "evil", "ANTHROPIC_API_KEY": "sk-evil", "FOO": "bar"]
    func session(socket: String = "/tmp/x.sock", token: String = "t", exe: String = "/nonexistent/bridge") -> AgentSession? {
        try? AgentSession(launch: AgentLaunch(claudePath: fakeClaude, mcpExecutable: exe, socketPath: socket, token: token))
    }

    section("agent session: streaming, follow-up, failures (fake claude)") {
        expect(blocking { await AgentHarness.isSignedIn(claudePath: fakeClaude) }.successValue == true, "claude auth status: signed in")
        guard let s = session() else { expect(false, "session"); return }
        defer { s.close() }
        let ev = Events()
        let r = blocking { try await s.send("hello there", environment: hostile) { ev.add($0) } }
        if case .success(let final) = r, case .result(let text, let isErr, let sid, _, _) = final { expect(text == "Hello from the fake assistant." && !isErr && sid == s.sessionId, "final result") } else { expect(false, "send succeeded: \(r)") }
        let all = ev.all
        expect(all.first == .initialized(sessionId: s.sessionId, mcpServers: ["bridge": "connected"], tools: ["mcp__bridge__aws_read"]), "init event first")
        let streamed = all.compactMap { e -> String? in if case .textDelta(let t) = e { return t }; return nil }.joined()
        expect(streamed == "Hello from the fake assistant.", "text streamed in pieces: \(streamed)")
        expect(all.contains(.assistantText("Hello from the fake assistant.")), "completed assistant text arrives too")
        let second = blocking { try await s.send("and again", environment: hostile) { _ in } }
        if case .success = second {} else { expect(false, "the second turn (resume) is accepted by the harness: \(second)") }

        let env = Events()
        _ = blocking { try await s.send("DUMP_ENV", environment: hostile) { env.add($0) } }
        let dump = env.all.compactMap { e -> String? in if case .assistantText(let t) = e { return t }; return nil }.first ?? ""
        expect(!dump.contains("AWS_") && !dump.contains("ANTHROPIC_API_KEY") && !dump.contains("FOO"), "the harness process sees none of the hostile variables")
        expect(dump.contains("cwd: ") && dump.contains("bridge-agent-"), "the harness runs in Bridge's own empty working directory")

        if case .failure(let e) = blocking({ try await s.send("FAIL_AUTH", environment: hostile) { _ in } }), let ae = e as? AgentError { expect(ae == .notSignedIn, "a not-signed-in result is recognised") } else { expect(false, "not signed in must be reported") }
        let missing = try? AgentSession(launch: AgentLaunch(claudePath: "/nonexistent/claude", mcpExecutable: "", socketPath: "", token: ""))
        if let missing, case .failure(let e) = blocking({ try await missing.send("x") { _ in } }), let ae = e as? AgentError { expect(ae == .harnessNotFound, "missing harness") } else { expect(false, "missing harness reported") }
    }

    section("agent session: cancel kills the harness process tree") {
        func harnessRunning() -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "Fixtures/fake-claude/claude"]
            p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0
        }
        guard let s = session() else { expect(false, "session"); return }
        defer { s.close() }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<ClaudeEvent, Error>?
        let task = Task.detached { () -> Void in
            do { result = .success(try await s.send("SLOW", environment: hostile) { _ in }) } catch { result = .failure(error) }
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 1.0)
        expect(harnessRunning(), "the harness is running before the cancel")
        let c0 = ProcessInfo.processInfo.systemUptime
        task.cancel(); sem.wait()
        if case .failure(let e)? = result, e is CancellationError { expect(ProcessInfo.processInfo.systemUptime - c0 < 4, "cancel returned promptly") } else { expect(false, "cancel surfaces CancellationError, got \(String(describing: result))") }
        Thread.sleep(forTimeInterval: 0.3)
        expect(!harnessRunning(), "no harness process is left after the cancel")
    }

    // The full chain: fake claude -> real `bridge mcp` -> private socket -> backend -> policy -> fake aws.
    let bridgeBinary = root.appendingPathComponent(".build/release/BridgeApp").path
    section("end to end: harness, bridge mcp, socket, policy, aws") {
        guard FileManager.default.isExecutableFile(atPath: bridgeBinary) else { print("     (skipped: run `swift build -c release --product BridgeApp` first)"); return }
        guard let ep = try? AgentIPCServer.makeEndpoint() else { expect(false, "endpoint"); return }
        let (b, trace) = makeBackend()
        let server = AgentIPCServer(path: ep.path, token: ep.token, backend: b)
        guard (try? server.start()) != nil else { expect(false, "server started"); return }
        defer { server.stop() }
        guard let s = session(socket: ep.path, token: ep.token, exe: bridgeBinary) else { expect(false, "session"); return }
        defer { s.close() }

        let ev = Events()
        let ok = blocking { try await s.send(#"CALL aws_read {"profile":"example-dev","service":"lambda","operation":"list-functions","region":"eu-west-1"}"#, environment: hostile) { ev.add($0) } }
        guard case .success(let final) = ok, case .result(let text, _, _, _, _) = final else { expect(false, "end-to-end turn succeeded: \(ok)"); return }
        expect(text.contains("tools=get_ui_context,list_profiles,list_operations,aws_read"), "the harness discovered the four tools through the real handshake: \(text.prefix(120))")
        expect(text.contains("isError=False") && text.contains("FunctionName"), "the read went through the whole chain and returned data")
        expect(ev.all.contains { if case .toolUse(_, let n, _) = $0 { return n == "mcp__bridge__aws_read" }; return false }, "tool_use and tool_result events are surfaced")
        let refused = blocking { try await s.send(#"CALL aws_read {"profile":"example-prod","service":"lambda","operation":"list-functions"}"#, environment: hostile) { _ in } }
        if case .success(.result(let t, _, _, _, _)) = refused { expect(t.contains("isError=True") && t.contains("not available to the assistant"), "a profile outside the scope is refused across the whole chain") } else { expect(false, "refusal turn ran") }
        let sens = blocking { try await s.send(#"CALL aws_read {"profile":"example-dev","service":"lambda","operation":"get-function-configuration","params":{"FunctionName":"x"}}"#, environment: hostile) { _ in } }
        if case .success(.result(let t, _, _, _, _)) = sens { expect(t.contains("isError=True") && t.contains("can return secrets"), "a sensitive operation is refused across the whole chain") } else { expect(false, "sensitive turn ran") }
        let entries = trace.all.filter { $0.tool == "aws_read" }
        expect(entries.map(\.status) == [.ok, .denied, .denied], "the app-side trace saw all three calls: \(entries.map(\.status.rawValue))")
    }
}
