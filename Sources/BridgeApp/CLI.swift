import Foundation
import BridgeCore
import BridgeAgents

/// `bridge <command>`: a command-line front end over the same core and the same policy as the app.
/// It exists to test the core against real profiles without the UI. It never bypasses the policy.
///
///   bridge profiles
///   bridge identity <profile> [--region R]
///   bridge run <profile> <service> <operation> [--region R] [--params file|-] [--max-items N] [--agent]
///   bridge download <profile> <bucket> <key> <folder> [--region R] [--overwrite]
///   bridge sso-login <profile> [--no-browser]
///   bridge policy <service> <operation>
enum CLI {
    static func run(_ args: [String]) -> Never {
        Task {
            let code = await main(args)
            fflush(stdout); fflush(stderr)
            exit(code)
        }
        dispatchMain()
    }

    static func out(_ s: String) { print(s) }
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// Options after the positional arguments: `--region R`, `--params F`, `--max-items N`, flags.
    struct Parsed {
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
    }
    static func parse(_ args: [String], valued: Set<String>) -> Parsed {
        var p = Parsed()
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                if valued.contains(a), i + 1 < args.count { p.options[a] = args[i + 1]; i += 2; continue }
                p.flags.insert(a)
            } else { p.positional.append(a) }
            i += 1
        }
        return p
    }

    static func main(_ args: [String]) async -> Int32 {
        guard let command = args.first else { return usage() }
        let rest = Array(args.dropFirst())
        let rt = BridgeRuntime.load()
        for w in rt.settingsWarnings { err("settings: \(w)") }

        switch command {
        case "help", "--help", "-h": return usage(exitCode: 0)
        case "profiles": return profiles(await rt.discoveringProfiles())
        case "policy": return policy(rest)
        case "trust-credential-process": return trustCredentialProcess(rest)
        case "identity": return await identity(rt, rest)
        case "run": return await runOperation(rt, rest)
        case "download": return await download(rt, rest)
        case "sso-login": return await ssoLogin(rt, rest)
        case "mcp": return await mcp()
        default:
            err("unknown command: \(command)")
            return usage()
        }
    }

    @discardableResult
    static func usage(exitCode: Int32 = 2) -> Int32 {
        let text = """
        bridge: AWS workbench (command line)

          bridge profiles                                list local AWS profiles (names and kinds only)
          bridge identity <profile> [--region R]         verify which account and principal a profile resolves to
          bridge run <profile> <service> <operation> [--region R] [--params file|-] [--max-items N] [--agent]
                                                         run one allowed operation (CLI names, e.g. lambda list-functions)
          bridge download <profile> <bucket> <key> <folder> [--region R] [--overwrite]
          bridge sso-login <profile> [--no-browser]      sign in to IAM Identity Center
          bridge policy <service> <operation>            show how the policy classifies an operation
          bridge trust-credential-process <profile> [--approve-sha256 HASH]
                                                         review a helper; approve its exact displayed hash
          bridge mcp                                     (internal) MCP server used by the assistant panel

        Exit codes: 0 ok, 1 failed, 2 usage, 3 denied by policy.
        Run with no arguments to open the app.
        """
        (exitCode == 0 ? out : err)(text)
        return exitCode
    }

    // MARK: Commands

    static func trustCredentialProcess(_ args: [String]) -> Int32 {
        let p = parse(args, valued: ["--approve-sha256"])
        guard p.positional.count == 1, p.flags.isEmpty else { return usage() }
        let env = ProcessInfo.processInfo.environment
        do {
            guard let approval = try CredentialProcessTrust.requiredApproval(profile: p.positional[0], environment: env) else {
                out("No unapproved credential helper in this profile chain."); return 0
            }
            guard let hash = p.options["--approve-sha256"] else {
                out("Profile: \(approval.profile)\nCommand: \(approval.command)\nSHA-256: \(approval.hash)\n\nReview the command, then repeat with --approve-sha256 and the exact hash to allow it. This does not execute the helper.")
                return 0
            }
            guard hash == approval.hash else { err("The helper changed or the hash does not match. Review it again."); return 3 }
            let path = env["BRIDGE_SETTINGS"].flatMap { $0.isEmpty ? nil : $0 } ?? SettingsStore.defaultPath()
            let loaded = SettingsStore.load(path: path)
            guard !loaded.fileWasCorrupt else { throw CredentialTrustError.unreadableConfiguration }
            try SettingsStore.save(loaded.settings.confirmingCredentialProcess(profile: approval.profile, command: approval.command), path: path)
            out("Approved the reviewed helper. Repeat the review if another helper is required by the source-profile chain.")
            return 0
        } catch { return report(error) }
    }

    static func profiles(_ rt: BridgeRuntime) -> Int32 {
        if rt.config.profiles.isEmpty { out("no profiles found in \(AwsConfigLoader.defaultPath())"); return 0 }
        for name in rt.config.profileNames {
            guard let p = rt.config.profile(named: name) else { continue }
            let policy = rt.settings.policy(for: name)
            var kind: String
            switch p.kind {
            case .sso(let s): kind = "sso(\(s))"
            case .legacySso: kind = "sso(legacy)"
            case .assumeRole(let src, _): kind = "assume-role" + (src.map { " via \($0)" } ?? "")
            case .credentialProcess: kind = "credential_process"
            case .staticKeysInConfig: kind = "static keys in config"
            case .sharedCredentials: kind = "shared credentials"
            }
            out("\(name)\t\(kind)\tregion=\(p.region ?? "-")\taccount=\(p.accountId ?? "-")\tmax_tier=\(policy.maxTier.rawValue)\(policy.protected ? "\tPROTECTED" : "")")
        }
        for w in rt.config.warnings { err("config: \(w)") }
        return 0
    }

    static func policy(_ args: [String]) -> Int32 {
        guard args.count == 2 else { return usage() }
        guard let e = PolicyTable.standard.entry(service: args[0], operation: args[1]) else {
            out("\(args[0]) \(args[1]): NOT SUPPORTED (not in the policy table, so it is denied)")
            return 0
        }
        out("\(args[0]) \(args[1]): tier \(e.tier.rawValue) (\(e.tier))"
            + (e.credential ? ", CREDENTIAL-PRODUCING (always denied)" : "")
            + (e.sensitive ? ", sensitive (hidden from agents, never cached)" : "")
            + (e.costsMoney ? ", may cost money" : "")
            + (e.deniedParams.isEmpty ? "" : ", denied parameters: \(e.deniedParams.joined(separator: ", "))")
            + (e.maskPaths.isEmpty ? "" : ", mask: \(e.maskPaths.joined(separator: ", "))")
            + (e.note.map { "\n  note: \($0)" } ?? ""))
        return 0
    }

    static func needRuntime(_ rt: BridgeRuntime) -> DataService.Type? { nil }

    static func region(_ rt: BridgeRuntime, profile: String, _ p: Parsed) -> String? {
        let r = rt.region(for: profile, explicit: p.options["--region"])
        if r == nil { err("no region: pass --region, or set one on the profile") }
        return r
    }

    static func identity(_ rt: BridgeRuntime, _ args: [String]) async -> Int32 {
        let p = parse(args, valued: ["--region"])
        guard p.positional.count == 1 else { return usage() }
        guard let executor = rt.executor else { err("aws CLI not found (set BRIDGE_AWS_PATH or aws_path in settings)"); return 1 }
        guard let region = region(rt, profile: p.positional[0], p) else { return 2 }
        do {
            let id = try await IdentityProbe.verify(profile: p.positional[0], region: region, executor: executor)
            out("account \(id.account)\nprincipal \(id.arn)\nuser id \(id.userId)")
            return 0
        } catch { return report(error) }
    }

    static func runOperation(_ rt: BridgeRuntime, _ args: [String]) async -> Int32 {
        let p = parse(args, valued: ["--region", "--params", "--max-items"])
        guard p.positional.count == 3 else { return usage() }
        guard let region = region(rt, profile: p.positional[0], p) else { return 2 }
        guard let service = await rt.makeDataService() else { err("aws CLI not found (set BRIDGE_AWS_PATH or aws_path in settings)"); return 1 }

        var params: JSONValue?
        if let source = p.options["--params"] {
            let data = source == "-" ? FileHandle.standardInput.readDataToEndOfFile() : (FileManager.default.contents(atPath: source) ?? Data())
            guard let v = try? JSONValue.parse(data), case .object = v else { err("--params must be a JSON object (file or - for stdin)"); return 2 }
            params = v
        }
        let request = ExecRequest(profile: p.positional[0], region: region, service: p.positional[1], operation: p.positional[2],
                                  params: params, maxItems: p.options["--max-items"].flatMap { Int($0) })
        do {
            let fetched = try await service.fetch(request, tab: UUID(), caller: p.flags.contains("--agent") ? .agent : .human)
            err("$ \(fetched.result.commandDisplay)")
            err("tier \(fetched.tier.rawValue) \(fetched.tier)\(fetched.result.sensitive ? ", SENSITIVE (not cached)" : "")\(fetched.costsMoney ? ", may cost money" : "")"
                + "\(fetched.identity.map { " · account \($0.account)" } ?? "") · \(Int(fetched.result.durationMs)) ms")
            if let json = fetched.result.json, let data = try? json.data(pretty: true) { out(String(decoding: data, as: UTF8.self)) }
            if let t = fetched.result.nextToken { err("more results: --starting-token \(t) (not yet exposed by this command)") }
            return 0
        } catch { return report(error) }
    }

    static func download(_ rt: BridgeRuntime, _ args: [String]) async -> Int32 {
        let p = parse(args, valued: ["--region"])
        guard p.positional.count == 4 else { return usage() }
        let (profile, bucket, key, folder) = (p.positional[0], p.positional[1], p.positional[2], p.positional[3])
        guard let region = region(rt, profile: profile, p) else { return 2 }
        guard let aws = rt.awsPath, let service = await rt.makeDataService() else { err("aws CLI not found"); return 1 }
        do {
            // Verify identity and authorize through the same path as everything else.
            let id = try await service.identityStore().identity(for: profile, region: region)
            let ctx = AuthContext(profile: rt.settings.policy(for: profile), identity: .verified(account: id.account, arn: id.arn))
            let req = S3Workflow.download(profile: profile, region: region, bucket: bucket, key: key)
            switch Authorizer().authorize(req, context: ctx) {
            case .deny(let reason): err("denied: \(describe(reason))"); return 3
            case .allow(let authorized, _):
                let result = try await S3Downloader(awsPath: aws).download(authorized, to: URL(fileURLWithPath: folder), overwrite: p.flags.contains("--overwrite")) { bytes in
                    FileHandle.standardError.write(Data("\r\(bytes) bytes".utf8))
                }
                err("")
                out("saved \(result.finalPath) (\(result.bytes) bytes, \(Int(result.durationMs)) ms)\n$ \(result.commandDisplay)")
                return 0
            }
        } catch { return report(error) }
    }

    static func ssoLogin(_ rt: BridgeRuntime, _ args: [String]) async -> Int32 {
        let p = parse(args, valued: [])
        guard p.positional.count == 1 else { return usage() }
        guard let aws = rt.awsPath else { err("aws CLI not found"); return 1 }
        do {
            try await SsoLogin(awsPath: aws).login(profile: p.positional[0], noBrowser: p.flags.contains("--no-browser"),
                                                    onText: { FileHandle.standardError.write(Data($0.utf8)) })
            out("signed in: \(p.positional[0])")
            return 0
        } catch { return report(error) }
    }

    /// `bridge mcp`: the MCP server an agent harness launches. It does NOTHING itself: every call is forwarded to the
    /// running Bridge app over the session's private socket, where the policy is enforced.
    static func mcp() async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env["BRIDGE_AGENT_SOCKET"], let token = env["BRIDGE_AGENT_TOKEN"], !socket.isEmpty, !token.isEmpty else {
            err("bridge mcp is started by the assistant panel inside Bridge; it is not meant to be run by hand.")
            return 2
        }
        let server = McpServer(name: "bridge", version: "0.1.0", instructions: AgentBackend.instructions, backend: AgentIPCClient(path: socket, token: token))
        await server.serve()
        return 0
    }

    // MARK: Reporting

    static func describe(_ r: DenyReason) -> String {
        switch r {
        case .unsupported: return "this operation is not in the supported set"
        case .credentialClass: return "credential-producing operations are never allowed"
        case .aboveCap(let need, let cap): return "needs tier \(need.rawValue) (\(need)) but the limit is tier \(cap.rawValue) (\(cap)); raise max_tier for this profile in \(SettingsStore.defaultPath())"
        case .identityNotVerified: return "the account could not be verified"
        case .identityMismatch(let e, let a): return "expected account \(e) but the profile resolves to \(a)"
        case .sensitiveHiddenFromAgent: return "sensitive results are not available to agents"
        case .deniedParameter(let p): return "parameter \(p) is not allowed"
        case .confirmationRequired(let c): return "needs confirmation (\(c))"
        case .invalidRequest(let m): return "invalid request: \(m)"
        }
    }

    static func report(_ error: Error) -> Int32 {
        switch error {
        case let error as CredentialTrustError: err(error.localizedDescription); return 3
        case DataError.denied(let r): err("denied: \(describe(r))"); return 3
        case IdentityError.denied(let r): err("denied: \(describe(r))"); return 3
        case ExecError.authExpired(let s): err("not signed in or session expired: run `bridge sso-login <profile>`\n\(s)"); return 1
        case ExecError.commandFailed(let st, let s): err("aws failed (exit \(st)): \(s)"); return 1
        case ExecError.timedOut(let n): err("timed out after \(Int(n)) s"); return 1
        case ExecError.outputTooLarge(let n): err("output larger than \(n) bytes"); return 1
        case ExecError.spawnFailed(let n): err("could not start aws (errno \(n))"); return 1
        case ExecError.invalidRequest(let m): err("invalid request: \(m)"); return 2
        case let t as TransferError: err("download failed: \(t)"); return t == .notATransfer ? 2 : 1
        case let s as SsoLoginError: err("sso login failed: \(s)"); return 1
        default: err("error: \(error)"); return 1
        }
    }
}
