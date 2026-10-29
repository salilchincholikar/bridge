import Foundation
import BridgeCore
import BridgeAgents

// Codex adapter, per-provider consent and disclosure. The harness is Fixtures/fake-codex (no provider is contacted).
// The stream lines in the parser test were captured from a LIVE `codex exec --json` run on 2026-10-28 (stub tool, no AWS data).

func runCodexTests() {
    let fakeCodex = root.appendingPathComponent("Fixtures/fake-codex/codex").path
    let fakeUnsafe = root.appendingPathComponent("Fixtures/fake-codex/codex-unsafe").path
    let hostile = ["HOME": NSHomeDirectory(), "AWS_ACCESS_KEY_ID": "AKIAEVIL", "AWS_PROFILE": "evil", "OPENAI_API_KEY": "sk-evil", "ANTHROPIC_API_KEY": "sk-evil", "FOO": "bar"]
    func launch(path: String = fakeCodex, socket: String = "/tmp/x.sock", token: String = "t", exe: String = "/nonexistent/bridge") -> AgentLaunch {
        AgentLaunch(claudePath: path, mcpExecutable: exe, socketPath: socket, token: token)
    }

    section("codex stream parser (events captured from a live run)") {
        let lines = [
            #"{"type": "thread.started", "thread_id": "01a1827f-c52a-75d2-b2ae-fc9cb0954d65"}"#,
            #"{"type": "turn.started"}"#,
            #"{"type": "item.completed", "item": {"id": "item_0", "type": "agent_message", "text": "I’ll locate the bridge echo tool.\n"}}"#,
            #"{"type": "item.started", "item": {"id": "item_1", "type": "mcp_tool_call", "server": "bridge", "tool": "echo", "arguments": {"text": "ping"}, "result": null, "error": null, "status": "in_progress"}}"#,
            #"{"type": "item.completed", "item": {"id": "item_1", "type": "mcp_tool_call", "server": "bridge", "tool": "echo", "arguments": {"text": "ping"}, "result": null, "error": {"message": "MCP tool call requires approval, but approval policy is never"}, "status": "failed"}}"#,
            #"{"type": "item.completed", "item": {"id": "item_1", "type": "mcp_tool_call", "server": "bridge", "tool": "echo", "arguments": {"text": "ping"}, "result": {"content": [{"type": "text", "text": "echo:ping"}], "structured_content": null}, "error": null, "status": "completed"}}"#,
            #"{"type": "turn.completed", "usage": {"input_tokens": 49007, "output_tokens": 233}}"#,
            #"{"type": "turn.failed", "error": {"message": "boom"}}"#,
        ]
        let ev = lines.map { CodexStream.parse(line: $0) }
        expect(ev[0] == [.initialized(sessionId: "01a1827f-c52a-75d2-b2ae-fc9cb0954d65", mcpServers: [:], tools: [])], "thread.started carries the thread id")
        expect(ev[1].isEmpty && ev[6].isEmpty, "turn.started and turn.completed produce no event of their own")
        expect(ev[2] == [.assistantText("I\u{2019}ll locate the bridge echo tool.\n")], "agent_message text (including unicode escapes)")
        expect(ev[3] == [.toolUse(id: "item_1", name: "mcp__bridge__echo", input: .object(["text": .string("ping")]))], "mcp_tool_call start becomes a tool use")
        expect(ev[4] == [.toolResult(id: "item_1", text: "MCP tool call requires approval, but approval policy is never", isError: true)], "a failed call carries its error")
        expect(ev[5] == [.toolResult(id: "item_1", text: "echo:ping", isError: false)], "a completed call carries its text")
        expect(ev[7] == [.result(text: "boom", isError: true, sessionId: nil, costUSD: nil, subtype: "turn.failed")], "turn.failed is an error result")
        for junk in ["", "nope", #"{"type":"item.completed","item":{"type":"reasoning"}}"#, #"{"type":"error","message":"reconnecting"}"#] { expect(CodexStream.parse(line: junk).isEmpty, "ignores: \(junk.prefix(30))") }
        expect(CodexStream.forbiddenItem(line: #"{"type":"item.started","item":{"type":"command_execution"}}"#) == "command_execution", "a command is recognised as forbidden")
        expect(CodexStream.forbiddenItem(line: #"{"type":"item.completed","item":{"type":"file_change"}}"#) == "file_change", "a file change is forbidden")
        expect(CodexStream.forbiddenItem(line: #"{"type":"item.started","item":{"type":"web_search"}}"#) == "web_search", "web search is forbidden")
        expect(CodexStream.forbiddenItem(line: #"{"type":"item.started","item":{"type":"mcp_tool_call"}}"#) == nil, "MCP calls are fine")
    }

    section("codex command line: the lockdown, exactly") {
        guard let s = try? CodexSession(launch: launch()) else { expect(false, "session"); return }
        defer { s.close() }
        let first = s.arguments(prompt: "hello", resuming: nil)
        func pairs(_ a: [String], _ flag: String) -> [String] { a.indices.filter { a[$0] == flag && $0 + 1 < a.count }.map { a[$0 + 1] } }
        expect(first.first == "exec" && !first.contains("resume"), "first turn is `codex exec`")
        for f in ["--json", "--ignore-user-config", "--skip-git-repo-check", "--ignore-rules"] { expect(first.contains(f), "first turn passes \(f)") }
        let disables = pairs(first, "--disable")
        for f in ["shell_tool", "unified_exec", "view_image", "apps", "plugins", "hooks", "memories", "computer_use", "browser_use", "standalone_web_search"] { expect(disables.contains(f), "feature \(f) is disabled") }
        let configs = pairs(first, "-c")
        expect(configs.contains(#"web_search="disabled""#) && configs.contains(#"sandbox_mode="read-only""#), "web search off and a read-only sandbox, as -c overrides")
        expect(configs.contains(#"mcp_servers.bridge.default_tools_approval_mode="approve""#), "our MCP tools are pre-approved (otherwise every call fails)")
        expect(configs.contains(#"mcp_servers.bridge.command="/nonexistent/bridge""#) && configs.contains(#"mcp_servers.bridge.args=["mcp"]"#), "the one MCP server")
        expect(configs.contains { $0.hasPrefix("mcp_servers.bridge.env={BRIDGE_AGENT_SOCKET=\"/tmp/x.sock\", BRIDGE_AGENT_TOKEN=\"t\"}") }, "its environment")
        expect(!first.contains("-s") && !first.contains("--sandbox"), "the sandbox goes through -c so `resume` accepts it too")
        expect(first.last?.hasPrefix("You are the assistant inside Bridge") == true && first.last?.hasSuffix("hello") == true, "the system prompt rides on the first message")
        expect(!first.contains("--ephemeral"), "sessions persist by default so follow-ups work")

        let resume = s.arguments(prompt: "again", resuming: "thread-123")
        expect(Array(resume.prefix(2)) == ["exec", "resume"] && resume[resume.count - 2] == "thread-123" && resume.last == "again", "later turns resume the thread with the plain prompt")
        expect(pairs(resume, "--disable").contains("shell_tool") && pairs(resume, "-c").contains(#"web_search="disabled""#), "the lockdown applies to resumed turns too")
        expect(!resume.contains("--ignore-rules"), "resume does not take --ignore-rules (checked against --help)")
        var eph = launch(); eph.persistSessions = false
        expect((try? CodexSession(launch: eph))?.arguments(prompt: "x", resuming: nil).contains("--ephemeral") == true, "persistence can be turned off")
        var tricky = launch(socket: "/tmp/we\"ird\\path.sock", token: "t\"k")
        tricky.model = "gpt-x"
        let ta = (try? CodexSession(launch: tricky))?.arguments(prompt: "x", resuming: nil) ?? []
        expect(ta.contains { $0.contains(#"BRIDGE_AGENT_SOCKET="/tmp/we\"ird\\path.sock""#) }, "quotes and backslashes are TOML-escaped")
        expect(pairs(ta, "-m") == ["gpt-x"], "model override")

        let env = CodexSession.environment(from: hostile.merging(["CODEX_HOME": "/h/.codex", "HTTPS_PROXY": "p:1"]) { $1 }, codexPath: "/opt/homebrew/bin/codex", keepAPIKey: false)
        expect(env["AWS_ACCESS_KEY_ID"] == nil && env["AWS_PROFILE"] == nil && env["FOO"] == nil && env["OPENAI_API_KEY"] == nil && env["ANTHROPIC_API_KEY"] == nil, "no AWS variable or API key reaches the harness")
        expect(env["CODEX_HOME"] == "/h/.codex" && env["HOME"] == NSHomeDirectory() && env["HTTPS_PROXY"] == "p:1", "the user's own login location, HOME and proxy pass")
        expect(CodexSession.environment(from: ["OPENAI_API_KEY": "k"], codexPath: "/x/codex", keepAPIKey: true)["OPENAI_API_KEY"] == "k", "an API key passes only on opt-in")
    }

    section("codex lockdown check (tool list rendered locally, no model call)") {
        let ok = blocking { await CodexLockdown.verify(codexPath: fakeCodex) }.successValue
        expect(ok?.ok == true && ok?.unexpected.isEmpty == true, "a locked-down tool list passes: \(String(describing: ok))")
        expect(ok?.tools == ["apply_patch", "clock__curr_time", "list_mcp_resource_templates", "list_mcp_resources", "read_mcp_resource"], "the known residual tools are listed: \(ok?.tools ?? [])")
        let bad = blocking { await CodexLockdown.verify(codexPath: fakeUnsafe) }.successValue
        expect(bad?.ok == false && bad?.unexpected.contains("exec_command") == true && bad?.unexpected.contains("web") == true, "a Codex that exposes a shell and web access is REFUSED: \(String(describing: bad))")
        let missing = blocking { await CodexLockdown.verify(codexPath: "/nonexistent/codex") }.successValue
        expect(missing?.ok == false && missing?.problem != nil, "a missing or unsupported Codex is refused, not trusted")
        expect(blocking { await CodexHarness.isSignedIn(codexPath: fakeCodex) }.successValue == true, "codex login status: signed in")
    }

    section("codex session: streaming, resume, failures, watchdog (fake codex)") {
        guard let s = try? CodexSession(launch: launch()) else { expect(false, "session"); return }
        defer { s.close() }
        let ev = Events()
        let r = blocking { try await s.send("hello there", environment: hostile) { ev.add($0) } }
        guard case .success(let final) = r, case .result(let text, let isErr, let sid, _, _) = final else { expect(false, "first turn succeeded: \(r)"); return }
        expect(text == "Hello from the fake codex." && !isErr && sid?.hasPrefix("01a1827f") == true, "final result carries the last message and the thread id")
        expect(ev.all.contains(.assistantText("Hello from the fake codex.")), "the whole message arrives as one event (Codex has no partial text)")
        let second = blocking { try await s.send("and again", environment: hostile) { _ in } }
        if case .success = second {} else { expect(false, "the second turn resumes the same thread and the harness accepts it: \(second)") }

        let env = Events()
        _ = blocking { try await s.send("DUMP_ENV", environment: hostile) { env.add($0) } }
        let dump = env.all.compactMap { e -> String? in if case .assistantText(let t) = e { return t }; return nil }.first ?? ""
        expect(!dump.contains("AWS_") && !dump.contains("OPENAI_API_KEY") && !dump.contains("FOO"), "the harness process sees none of the hostile variables")
        expect(dump.contains("bridge-agent-"), "the harness runs in Bridge's own empty working directory")

        if case .failure(let e) = blocking({ try await s.send("FAIL_AUTH", environment: hostile) { _ in } }), let ae = e as? AgentError { expect(ae == .notSignedIn, "a 401 is recognised as not signed in") } else { expect(false, "not signed in must be reported") }
        let missing = try? CodexSession(launch: launch(path: "/nonexistent/codex"))
        if let missing, case .failure(let e) = blocking({ try await missing.send("x", environment: hostile) { _ in } }), let ae = e as? AgentError { expect(ae == .harnessNotFound, "missing harness") } else { expect(false, "missing harness reported") }
    }

    section("codex session: a forbidden capability stops the run; cancel kills the tree") {
        func harnessRunning() -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "Fixtures/fake-codex/codex"]
            p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0
        }
        guard let s = try? CodexSession(launch: launch()) else { expect(false, "session"); return }
        defer { s.close() }
        let t0 = ProcessInfo.processInfo.systemUptime
        let r = blocking { try await s.send("FORBIDDEN please", environment: hostile) { _ in } }
        if case .failure(let e) = r, let ae = e as? AgentError { expect(ae == .forbiddenTool("command_execution"), "an attempted command stops the run") } else { expect(false, "forbidden tool must stop the run, got \(r)") }
        expect(ProcessInfo.processInfo.systemUptime - t0 < 10, "it stopped promptly instead of waiting for the harness")
        Thread.sleep(forTimeInterval: 0.3)
        expect(!harnessRunning(), "the harness was killed")

        let sem = DispatchSemaphore(value: 0)
        var result: Result<ClaudeEvent, Error>?
        let task = Task.detached { () -> Void in
            do { result = .success(try await s.send("SLOW", environment: hostile) { _ in }) } catch { result = .failure(error) }
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 1.0)
        expect(harnessRunning(), "the harness is running before the cancel")
        task.cancel(); sem.wait()
        if case .failure(let e)? = result, e is CancellationError {} else { expect(false, "cancel surfaces CancellationError, got \(String(describing: result))") }
        Thread.sleep(forTimeInterval: 0.3)
        expect(!harnessRunning(), "no harness process is left after the cancel")
    }

    let bridgeBinary = root.appendingPathComponent(".build/release/BridgeApp").path
    section("codex end to end: harness, bridge mcp, socket, policy, aws") {
        guard FileManager.default.isExecutableFile(atPath: bridgeBinary) else { print("     (skipped: run `swift build -c release --product BridgeApp` first)"); return }
        guard let ep = try? AgentIPCServer.makeEndpoint() else { expect(false, "endpoint"); return }
        let (b, trace) = makeBackend()
        let server = AgentIPCServer(path: ep.path, token: ep.token, backend: b)
        guard (try? server.start()) != nil else { expect(false, "server started"); return }
        defer { server.stop() }
        guard let s = try? CodexSession(launch: launch(socket: ep.path, token: ep.token, exe: bridgeBinary)) else { expect(false, "session"); return }
        defer { s.close() }
        let ev = Events()
        let ok = blocking { try await s.send(#"CALL aws_read {"profile":"example-dev","service":"lambda","operation":"list-functions","region":"eu-west-1"}"#, environment: hostile) { ev.add($0) } }
        guard case .success(.result(let text, _, _, _, _)) = ok else { expect(false, "end-to-end turn succeeded: \(ok)"); return }
        expect(text.contains("tools=get_ui_context,list_profiles,list_operations,aws_read") && text.contains("isError=False") && text.contains("FunctionName"), "the harness read real data through the whole chain: \(text.prefix(100))")
        expect(ev.all.contains { if case .toolUse(_, let n, _) = $0 { return n == "mcp__bridge__aws_read" }; return false }, "tool use is surfaced")
        expect(ev.all.contains { if case .toolResult(_, _, let e) = $0 { return !e }; return false }, "tool result is surfaced")
        let refused = blocking { try await s.send(#"CALL aws_read {"profile":"example-prod","service":"lambda","operation":"list-functions"}"#, environment: hostile) { _ in } }
        if case .success(.result(let t, _, _, _, _)) = refused { expect(t.contains("isError=True") && t.contains("not available to the assistant"), "a profile outside the scope is refused") } else { expect(false, "refusal turn ran") }
        let sens = blocking { try await s.send(#"CALL aws_read {"profile":"example-dev","service":"lambda","operation":"get-function-configuration","params":{"FunctionName":"x"}}"#, environment: hostile) { _ in } }
        if case .success(.result(let t, _, _, _, _)) = sens { expect(t.contains("can return secrets"), "a sensitive operation is refused") } else { expect(false, "sensitive turn ran") }
        expect(trace.all.filter { $0.tool == "aws_read" }.map(\.status) == [.ok, .denied, .denied], "the app-side trace saw all three calls")
    }

    section("consent is per provider and versioned; disclosures say what they must") {
        let dir = NSTemporaryDirectory() + "bridge-consent-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/agent-consent.json"
        expect(!AgentConsentStore.isGranted(.claudeCode, path: path) && !AgentConsentStore.isGranted(.codex, path: path), "nothing is granted by default")
        try? AgentConsentStore.grant(.claudeCode, path: path)
        expect(AgentConsentStore.isGranted(.claudeCode, path: path) && !AgentConsentStore.isGranted(.codex, path: path), "granting one provider does not grant the other")
        try? AgentConsentStore.grant(.codex, path: path)
        expect(AgentConsentStore.isGranted(.codex, path: path) && AgentConsentStore.isGranted(.claudeCode, path: path), "both can be granted")
        let perms = ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        expect(perms == 0o600, "consent file is 0600")
        AgentConsentStore.revoke(.claudeCode, path: path)
        expect(!AgentConsentStore.isGranted(.claudeCode, path: path) && AgentConsentStore.isGranted(.codex, path: path), "revoking one leaves the other")
        AgentConsentStore.revoke(.codex, path: path)
        expect(!FileManager.default.fileExists(atPath: path), "revoking the last removes the file")
        try? Data(#"{"version":1,"accepted":{"claude-code":"2026-10-28T00:00:00Z"}}"#.utf8).write(to: URL(fileURLWithPath: path))
        expect(!AgentConsentStore.isGranted(.claudeCode, path: path), "an older disclosure version asks again")

        let c = AgentDisclosure.points(.claudeCode).joined(separator: " "), x = AgentDisclosure.points(.codex).joined(separator: " ")
        expect(c.contains("Anthropic") && !c.contains("OpenAI") && c.contains("API-key") && c.contains("responsible for checking"), "the Claude disclosure names Anthropic and the unresolved terms question")
        expect(x.contains("OpenAI") && !x.contains("Anthropic") && x.contains("API keys") && x.contains("responsible for checking"), "the Codex disclosure names OpenAI and the unresolved terms question")
        expect(x.contains("apply_patch") && x.contains("could not verify") && x.contains("refuses to use Codex"), "the Codex disclosure states the residual tools and the refusal rule")
        for p in AgentProvider.allCases { expect(AgentDisclosure.points(p).joined().contains("send") || AgentDisclosure.points(p).joined().contains("sent"), "\(p.displayName): says what is sent") }
        expect(AgentDisclosure.title(.codex).contains("Codex") && AgentDisclosure.title(.claudeCode).contains("Claude Code"), "titles name the provider")
    }
}
