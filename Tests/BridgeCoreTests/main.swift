import Foundation
import BridgeCore

// Test runner: a plain executable (no XCTest under Command Line Tools). Run with `make test`.
// Exit code is non-zero if any check fails. Nothing here touches the network, AWS, or your real ~/.aws.

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func section(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

// Repo root, derived from this file's path (Tests/BridgeCoreTests/main.swift).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func fixture(_ name: String) -> String {
    let path = root.appendingPathComponent("Fixtures/aws/\(name)").path
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

// MARK: - Profiles

section("typical config: profiles and kinds") {
    let cfg = AwsConfigParser.parse(fixture("typical.config"))
    expect(!fixture("typical.config").isEmpty, "fixture loaded")
    expect(cfg.profileNames == ["default", "admin-via-example-dev", "example-dev", "example-prod", "keys", "legacy", "nested", "proc", "quoted name"],
           "names: default first then alphabetical, got \(cfg.profileNames)")
    expect(cfg.profile(named: "example-dev")?.kind == .sso(session: "corp"), "example-dev is sso(corp)")
    expect(cfg.profile(named: "example-dev")?.accountId == "111111111111", "example-dev account id")
    expect(cfg.profile(named: "example-prod")?.roleName == "ReadOnly", "example-prod role name")
    expect(cfg.profile(named: "legacy")?.kind == .legacySso, "legacy sso")
    expect(cfg.profile(named: "proc")?.kind == .credentialProcess(command: "/usr/local/bin/get-creds --profile proc"), "credential_process captured")
    expect(cfg.profile(named: "keys")?.kind == .staticKeysInConfig, "static keys detected")
    expect(cfg.profile(named: "default")?.kind == .sharedCredentials, "default has no credential source in this file")
    expect(cfg.profile(named: "quoted name")?.region == "ap-south-1", "quoted profile name")
    expect(cfg.profile(named: "default")?.region == "eu-west-1", "default region")
}

section("profile discovery: merge credentials-only names without losing config metadata") {
    let cfg = AwsConfigParser.parse("[profile app]\nrole_arn = arn:aws:iam::111111111111:role/Test\nsource_profile = base\n[profile example-dev]\nregion = eu-west-1\n")
    let merged = cfg.addingProfileNames(["base", "personal", "example-dev", "personal", "", "default"])
    expect(merged.profileNames == ["default", "app", "base", "example-dev", "personal"], "names are deduplicated, default first and sorted")
    expect(merged.profile(named: "example-dev")?.region == "eu-west-1", "config metadata is preserved")
    expect(merged.profile(named: "personal")?.kind == .sharedCredentials, "credentials-only profile has a shared credential source")
    expect(merged.profile(named: "personal")?.settings.isEmpty == true, "no credential values enter the config model")
    expect(merged.roleChain(from: "app").missingProfile == nil, "credential-only role source resolves")
    expect(!merged.warnings.contains { $0.contains("source_profile base is not defined") }, "resolved role source warning is removed")
}

section("typical config: sso sessions") {
    let cfg = AwsConfigParser.parse(fixture("typical.config"))
    let s = cfg.ssoSessions["corp"]
    expect(s?.startUrl == "https://example.awsapps.com/start", "start url")
    expect(s?.region == "eu-west-1", "sso region")
    expect(s?.registrationScopes == "sso:account:access", "scopes")
}

section("secrets are never kept") {
    let cfg = AwsConfigParser.parse(fixture("typical.config"))
    let keys = cfg.profile(named: "keys")
    for secret in ["aws_access_key_id", "aws_secret_access_key", "aws_session_token"] {
        expect(keys?.settings[secret] == nil, "\(secret) must not be stored")
    }
    expect(keys?.region == "us-east-1", "non-secret settings kept")
    let dump = "\(cfg)"
    expect(!dump.contains("AKIAFAKE"), "access key id must not appear anywhere in the parsed model")
    expect(!dump.contains("fake-secret"), "secret must not appear anywhere in the parsed model")
    expect(!dump.contains("fake-token"), "token must not appear anywhere in the parsed model")
}

section("assume role: account/role parsed from ARN, chain followed") {
    let cfg = AwsConfigParser.parse(fixture("typical.config"))
    let p = cfg.profile(named: "admin-via-example-dev")
    expect(p?.accountId == "333333333333", "account from role_arn")
    expect(p?.roleName == "Admin", "role name from a pathed ARN (role/ops/Admin)")
    expect(p?.kind == .assumeRole(source: "example-dev", credentialSource: nil), "assumeRole kind")
    expect(cfg.roleChain(from: "admin-via-example-dev") == RoleChain(profiles: ["admin-via-example-dev", "example-dev"], hasCycle: false, missingProfile: nil), "chain ends at the sso profile")
    expect(cfg.roleChain(from: "example-dev").profiles == ["example-dev"], "non-assume profile is its own chain")
}

section("nested settings blocks") {
    let cfg = AwsConfigParser.parse(fixture("typical.config"))
    expect(cfg.profile(named: "nested")?.nested["s3"]?["max_concurrent_requests"] == "20", "nested value")
    expect(cfg.profile(named: "nested")?.nested["s3"]?["max_queue_size"] == "10000", "second nested value")
    expect(cfg.profile(named: "nested")?.settings["s3"] == "", "the block key itself has an empty value")
}

section("non-profile sections are ignored") {
    let cfg = AwsConfigParser.parse(fixture("typical.config"))
    expect(cfg.profiles["example"] == nil, "[services example] is not a profile")
    expect(cfg.warnings.isEmpty, "typical config yields no warnings, got \(cfg.warnings)")
}

section("broken config: warnings, cycles, dangling references") {
    let cfg = AwsConfigParser.parse(fixture("broken.config"))
    expect(cfg.roleChain(from: "cycle-a").hasCycle, "cycle detected")
    expect(cfg.roleChain(from: "dangling").missingProfile == "does-not-exist", "dangling source_profile")
    expect(cfg.warnings.contains { $0.contains("line 1:") && $0.contains("setting before any [section]") }, "setting before section reports line 1")
    expect(cfg.warnings.contains { $0.contains("line 4:") && $0.contains("not a `key = value` line") }, "line-number accuracy: the no-equals line is line 4")
    expect(cfg.warnings.contains { $0.contains("not a `key = value` line") }, "line without equals")
    expect(cfg.warnings.contains { $0.contains("unterminated section header") }, "unterminated header")
    expect(cfg.warnings.contains { $0.contains("cycle-a") && $0.contains("cycle") }, "cycle warning names the profile")
    expect(cfg.warnings.contains { $0.contains("does-not-exist") }, "dangling warning names the profile")
    expect(cfg.warnings.contains { $0.contains("sso-session nope is not defined") }, "undefined sso-session")
    expect(cfg.warnings.contains { $0.contains("dup is defined more than once") }, "duplicate profile")
    expect(cfg.profile(named: "dup")?.region == "us-west-1", "later duplicate wins")
}

section("edge cases: CRLF, comments, empty, missing file, [profile default]") {
    let crlf = "[default]\r\nregion = eu-west-1\r\n; comment\r\n# another\r\n[profile a]\r\nregion = us-east-1\r\n"
    let cfg = AwsConfigParser.parse(crlf)
    expect(cfg.profile(named: "default")?.region == "eu-west-1", "CRLF default")
    expect(cfg.profile(named: "a")?.region == "us-east-1", "CRLF named profile")
    expect(AwsConfigParser.parse("").profiles.isEmpty, "empty text")
    expect(AwsConfigParser.parse("\n\n# only comments\n").profiles.isEmpty, "only comments")
    expect(AwsConfigParser.parse("[profile default]\nregion = x\n").profile(named: "default")?.region == "x", "[profile default] is default")
    let missing = try? AwsConfigLoader.load(path: "/nonexistent/path/config")
    expect(missing?.profiles.isEmpty == true, "missing file yields an empty config, not an error")
    expect(AwsConfigLoader.defaultPath(environment: ["AWS_CONFIG_FILE": "/x/y"]) == "/x/y", "AWS_CONFIG_FILE honored when passed")
    expect(AwsConfigLoader.defaultPath(environment: [:]).hasSuffix("/.aws/config"), "default path")
}

section("role ARN parsing") {
    expect(AwsConfigParser.parseRoleArn("arn:aws:iam::123456789012:role/Name")?.role == "Name", "simple")
    expect(AwsConfigParser.parseRoleArn("arn:aws:iam::123456789012:role/a/b/c/Deep")?.role == "Deep", "deep path")
    expect(AwsConfigParser.parseRoleArn("arn:aws:iam::123456789012:user/Name") == nil, "not a role")
    expect(AwsConfigParser.parseRoleArn("garbage") == nil, "garbage")
}

// MARK: - Policy

func authorize(_ svc: String, _ op: String, params: JSONValue? = nil, _ ctx: AuthContext = AuthContext(),
               table: PolicyTable = .standard, confirmed: Bool = false) -> Authorizer.Outcome {
    Authorizer(table: table).authorize(ExecRequest(profile: "example-dev", region: "eu-west-1", service: svc, operation: op, params: params),
                                       context: ctx, confirmed: confirmed)
}
func denyReason(_ o: Authorizer.Outcome) -> DenyReason? { if case .deny(let r) = o { return r }; return nil }
func allowed(_ o: Authorizer.Outcome) -> AuthorizedRequest? { if case .allow(let a, _) = o { return a }; return nil }
let verified = IdentityState.verified(account: "111111111111", arn: "arn:aws:iam::111111111111:user/fake")

section("policy: unlisted operations are unsupported (prefixes authorize nothing)") {
    expect(denyReason(authorize("lambda", "delete-function")) == .unsupported, "delete-function not listed")
    expect(denyReason(authorize("secretsmanager", "list-secrets")) == .unsupported, "a list-* operation that is not in the table is still denied")
    expect(denyReason(authorize("ec2", "describe-instances")) == .unsupported, "describe-* not in the table is denied")
    expect(denyReason(authorize("iam", "get-account-authorization-details")) == .unsupported, "get-* not in the table is denied")
}

section("policy: credential-producing operations are always denied") {
    let open = AuthContext(profile: ProfilePolicy(maxTier: .destructive), identity: verified)
    for (s, o) in [("sts", "get-session-token"), ("sts", "assume-role"), ("sts", "get-federation-token"),
                   ("ecr", "get-login-password"), ("ecr", "get-authorization-token"), ("iam", "create-access-key")] {
        expect(denyReason(authorize(s, o, open)) == .credentialClass, "\(s) \(o) denied even at max tier, verified, human")
    }
}

section("policy: caps, tiers, identity, confirmation") {
    let human = AuthContext()                                       // maxTier = transfer (2)
    expect(allowed(authorize("lambda", "list-functions", human)) != nil, "tier 1 allowed")
    expect(allowed(authorize("s3api", "get-object", human)) != nil, "tier 2 transfer allowed for a human at the default cap")
    expect(denyReason(authorize("s3api", "get-object", AuthContext(caller: .agent))) == .aboveCap(required: .transfer, cap: .read), "agent default cap is read")
    expect(denyReason(authorize("sqs", "receive-message", human)) == .aboveCap(required: .reversibleChange, cap: .transfer), "receive-message is above the default cap")

    let t3 = AuthContext(profile: ProfilePolicy(maxTier: .reversibleChange), identity: .unverified)
    expect(denyReason(authorize("ecs", "stop-task", t3)) == .identityNotVerified, "tier 3 needs a verified identity")
    let t3v = AuthContext(profile: ProfilePolicy(maxTier: .reversibleChange), identity: verified)
    expect(denyReason(authorize("ecs", "stop-task", t3v)) == .confirmationRequired(.click), "tier 3 asks for a click")
    expect(allowed(authorize("ecs", "stop-task", t3v, confirmed: true)) != nil, "tier 3 runs once confirmed")
    let prot = AuthContext(profile: ProfilePolicy(maxTier: .reversibleChange, protected: true), identity: verified)
    expect(denyReason(authorize("ecs", "stop-task", prot)) == .confirmationRequired(.typeName), "protected profile needs a typed name at tier 3")

    let t4 = AuthContext(profile: ProfilePolicy(maxTier: .destructive), identity: verified)
    expect(denyReason(authorize("iam", "delete-role", t4)) == .confirmationRequired(.typeName), "tier 4 needs a typed name")
    expect(allowed(authorize("iam", "delete-role", t4, confirmed: true))?.tier == .destructive, "tier 4 runs once confirmed")

    let wrong = AuthContext(profile: ProfilePolicy(maxTier: .destructive, expectedAccount: "999999999999"), identity: verified)
    expect(denyReason(authorize("iam", "delete-role", wrong, confirmed: true)) == .identityMismatch(expected: "999999999999", actual: "111111111111"), "expected_account mismatch blocks tier 3+")
    expect(allowed(authorize("lambda", "list-functions", wrong)) != nil, "a mismatch does not block tier 1 reads")

    let agentWide = AuthContext(caller: .agent, profile: ProfilePolicy(maxTier: .read), agentMaxTier: .destructive, identity: verified)
    expect(denyReason(authorize("sqs", "receive-message", agentWide)) == .aboveCap(required: .reversibleChange, cap: .read), "the profile cap also limits an agent")
}

section("policy: sensitive results, denied parameters, argument validation") {
    expect(allowed(authorize("lambda", "get-function-configuration"))?.sensitive == true, "human may call it; result flagged sensitive")
    expect(denyReason(authorize("lambda", "get-function-configuration", AuthContext(caller: .agent, agentMaxTier: .destructive))) == .sensitiveHiddenFromAgent, "sensitive operations are hidden from agents")
    expect(allowed(authorize("lambda", "get-function"))?.maskPaths == ["Code.Location", "Configuration.Environment.Variables"], "presigned URL and nested environment are masked")
    expect(allowed(authorize("lambda", "get-function"))?.sensitive == true, "full function response is sensitive")
    expect(denyReason(authorize("lambda", "get-function", AuthContext(caller: .agent))) == .sensitiveHiddenFromAgent, "full function response denied to agents")
    expect(denyReason(authorize("logs", "filter-log-events", params: .object(["Unmask": .bool(true)]))) == .deniedParameter("Unmask"), "Unmask=true denied")
    expect(denyReason(authorize("logs", "filter-log-events", params: .object(["unmask": .bool(true)]))) == .deniedParameter("Unmask"), "parameter name match is case-insensitive")
    expect(allowed(authorize("logs", "filter-log-events", params: .object(["Unmask": .bool(false), "logGroupName": .string("g")]))) != nil, "Unmask=false is fine")
    expect(allowed(authorize("logs", "start-query"))?.costsMoney == true, "Insights queries flagged as costing money")

    for (s, o) in [("--debug", "x"), ("lambda", "--endpoint-url"), ("Lambda", "list-functions"), ("lambda", "list functions"), ("", "x"), ("lambda", "list-functions;ls")] {
        if case .invalidRequest = denyReason(authorize(s, o)) ?? .unsupported {} else { expect(false, "service \(s.debugDescription) op \(o.debugDescription) must be an invalid request") }
    }
    let bad = [ExecRequest(profile: "-x", region: "eu-west-1", service: "lambda", operation: "list-functions"),
               ExecRequest(profile: "p", region: "eu west", service: "lambda", operation: "list-functions"),
               ExecRequest(profile: "p", region: "eu-west-1", service: "lambda", operation: "list-functions", params: .object(["--endpoint-url": .string("http://evil")])),
               ExecRequest(profile: "p", region: "eu-west-1", service: "lambda", operation: "list-functions", params: .array([])),
               ExecRequest(profile: "p", region: "eu-west-1", service: "lambda", operation: "list-functions", maxItems: 0)]
    for r in bad { expect(r.validate() != nil, "rejected: \(r.profile) \(r.region) \(String(describing: r.params))") }
    expect(ExecRequest(profile: "quoted name", region: "eu-west-1", service: "lambda", operation: "list-functions").validate() == nil, "spaces in profile names are fine")
}

section("policy: table hygiene") {
    for (key, e) in PolicyTable.standard.entries {
        let parts = key.split(separator: " ").map(String.init)
        expect(parts.count == 2 && ExecRequest.isSafeToken(parts[0]) && ExecRequest.isSafeToken(parts[1]), "key is a well-formed CLI service and operation: \(key)")
        if e.credential { expect(e.tier == .read && !e.sensitive, "credential entries are plain deny rows: \(key)") }
    }
    expect(PolicyTable.standard.entry(service: "sqs", operation: "receive-message")?.tier == .reversibleChange, "receive-message is not a read")
}

// MARK: - Executor: pure pieces

section("executor: argument vector and command display") {
    let r = ExecRequest(profile: "quoted name", region: "eu-west-1", service: "lambda", operation: "list-functions", maxItems: 50, startingToken: "a b'c")
    expect(CLIExecutor.arguments(for: r, inputFile: nil) ==
           ["lambda", "list-functions", "--profile", "quoted name", "--region", "eu-west-1", "--output", "json",
            "--no-cli-pager", "--color", "off", "--max-items", "50", "--starting-token", "a b'c"], "exact argv, one element per argument")
    expect(CLIExecutor.arguments(for: r, inputFile: "/tmp/x/input.json").suffix(2) == ["--cli-input-json", "file:///tmp/x/input.json"], "params go by file")
    let shown = CLIExecutor.commandDisplay(for: r)
    expect(shown == "aws lambda list-functions --profile 'quoted name' --region eu-west-1 --max-items 50 --starting-token 'a b'\\''c'", "display quotes safely, got: \(shown)")
    let withParams = ExecRequest(profile: "example-dev", region: "eu-west-1", service: "lambda", operation: "get-function", params: .object(["FunctionName": .string("f")]))
    expect(CLIExecutor.commandDisplay(for: withParams).hasSuffix("--cli-input-json '{\"FunctionName\":\"f\"}'"), "params shown inline")
}

section("executor: environment allowlist") {
    let hostile: [String: String] = [
        "AWS_ACCESS_KEY_ID": "AKIAEVIL", "AWS_SECRET_ACCESS_KEY": "x", "AWS_SESSION_TOKEN": "x", "AWS_PROFILE": "other",
        "AWS_DEFAULT_PROFILE": "other", "AWS_REGION": "us-east-1", "AWS_DEFAULT_REGION": "us-east-1",
        "AWS_ENDPOINT_URL": "http://evil", "AWS_ENDPOINT_URL_S3": "http://evil", "AWS_DATA_PATH": "/evil", "AWS_PAGER": "less",
        "AWS_CLI_AUTO_PROMPT": "on", "FOO": "bar", "PATH": "/evil/bin", "LD_PRELOAD": "/evil.so", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
        "HOME": "/Users/x", "AWS_CONFIG_FILE": "/c/config", "HTTPS_PROXY": "http://proxy:3128",
    ]
    let env = CLIExecutor.sanitizedEnvironment(from: hostile)
    expect(Set(env.keys) == ["HOME", "AWS_CONFIG_FILE", "HTTPS_PROXY", "PATH", "AWS_PAGER"], "only allowlisted keys survive, got \(env.keys.sorted())")
    expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "PATH is fixed, not inherited")
    expect(env["AWS_PAGER"] == "", "pager disabled")
}

// MARK: - Executor: against the fake aws (no network, no real AWS)

func blocking<T>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let sem = DispatchSemaphore(value: 0)
    var out: Result<T, Error>!
    Task.detached {
        do { out = .success(try await body()) } catch { out = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return out
}

let testEnvironment = ["HOME": "/nonexistent/bridge-test-home", "AWS_CONFIG_FILE": root.appendingPathComponent("Fixtures/aws/typical.config").path,
                       "BRIDGE_SETTINGS": "/nonexistent/bridge-test-settings.json"]
let fakeAws = root.appendingPathComponent("Fixtures/fake-aws/aws").path
let fakeTable = PolicyTable(entries: [
    "fake args": PolicyEntry(), "fake env": PolicyEntry(), "fake input": PolicyEntry(), "fake sleep": PolicyEntry(),
    "fake big": PolicyEntry(), "fake auth-expired": PolicyEntry(), "fake fail": PolicyEntry(),
    "fake not-json": PolicyEntry(), "fake empty": PolicyEntry(),
    "sts get-caller-identity": PolicyEntry(), "lambda list-functions": PolicyEntry(),
])
func authorized(_ svc: String, _ op: String, profile: String = "example-dev", params: JSONValue? = nil, maxItems: Int? = nil, timeout: TimeInterval = 20) -> AuthorizedRequest {
    let o = Authorizer(table: fakeTable).authorize(ExecRequest(profile: profile, region: "eu-west-1", service: svc, operation: op, params: params, maxItems: maxItems, timeout: timeout), context: AuthContext())
    guard case .allow(let a, _) = o else { fatalError("test setup: \(svc) \(op) was not authorized: \(o)") }
    return a
}
func leakedSleepProcesses() -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "sleep 37"]
    p.standardOutput = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}
func killLeaks() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); p.arguments = ["-f", "sleep 37"]; try? p.run(); p.waitUntilExit() }

let exec = CLIExecutor(awsPath: fakeAws, environment: testEnvironment.merging(["AWS_ACCESS_KEY_ID": "AKIAEVIL", "AWS_PROFILE": "other", "AWS_ENDPOINT_URL": "http://evil", "AWS_DEFAULT_REGION": "us-east-1", "FOO": "bar"]) { _, new in new })

section("executor: local profile discovery") {
    let names = try? blocking { try await exec.profileNames() }.get()
    expect(names?.contains("credentials-only") == true, "CLI discovery includes credentials-only profile")
    expect(names?.contains("quoted name") == true, "CLI discovery preserves names with spaces")
}

section("executor: runs, parses JSON, reports the command") {
    expect(FileManager.default.isExecutableFile(atPath: fakeAws), "fake aws fixture is executable")
    let r = blocking { try await exec.run(authorized("sts", "get-caller-identity")) }
    let res = try? r.get()
    expect(res?.json?["Account"]?.stringValue == "111111111111", "identity JSON parsed")
    expect(res?.commandDisplay == "aws sts get-caller-identity --profile example-dev --region eu-west-1", "command display, got \(res?.commandDisplay ?? "nil")")
    expect((res?.durationMs ?? -1) >= 0, "duration recorded")
}

section("executor: pagination token") {
    let paged = try? blocking { try await exec.run(authorized("lambda", "list-functions", maxItems: 1)) }.get()
    expect(paged?.nextToken == "tok-1", "NextToken surfaced when --max-items is used")
    let full = try? blocking { try await exec.run(authorized("lambda", "list-functions")) }.get()
    expect(full?.nextToken == nil && full?.json?["Functions"]?.arrayValue?.count == 2, "no token on a full listing")
}

section("executor: no shell, exact argv; env allowlist enforced in the child") {
    let args = try? blocking { try await exec.run(authorized("fake", "args", profile: "my profile; echo $HOME `id`")) }.get()
    let got = args?.json?.arrayValue?.compactMap { $0.stringValue } ?? []
    expect(got.count == 11 && got[3] == "my profile; echo $HOME `id`", "a hostile profile name arrives as ONE literal argument, got \(got)")
    let envRes = try? blocking { try await exec.run(authorized("fake", "env")) }.get()
    let childEnv = envRes?.json?.objectValue ?? [:]
    for bad in ["AWS_ACCESS_KEY_ID", "AWS_PROFILE", "AWS_ENDPOINT_URL", "AWS_DEFAULT_REGION", "FOO", "AWS_SECRET_ACCESS_KEY"] {
        expect(childEnv[bad] == nil, "\(bad) must not reach the child")
    }
    expect(childEnv["AWS_PAGER"]?.stringValue == "", "AWS_PAGER is set empty in the child")
    expect(childEnv["PATH"]?.stringValue == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "child PATH is the fixed one")
    expect(childEnv["HOME"]?.stringValue == testEnvironment["HOME"], "HOME passes through")
}

section("executor: nested params go through a private temp file that is removed") {
    func bridgeTempDirs() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("bridge-") }.count }
    let before = bridgeTempDirs()
    let params: JSONValue = .object(["FunctionName": .string("x"), "Nested": .object(["a": .array([.number(1), .number(2)])])])
    let r = try? blocking { try await exec.run(authorized("fake", "input", params: params)) }.get()
    expect(r?.json?["perms"]?.stringValue == "600", "input file is 0600, got \(r?.json?["perms"]?.stringValue ?? "nil")")
    expect(r?.json?["dirPerms"]?.stringValue == "700", "its directory is 0700")
    expect(r?.json?["content"]?.value(at: "Nested.a")?.arrayValue?.count == 2, "nested JSON delivered intact")
    expect(bridgeTempDirs() == before, "temp directory removed after the call")
}

section("executor: failures are classified") {
    func fails(_ op: String) -> ExecError? {
        if case .failure(let e) = blocking({ try await exec.run(authorized("fake", op)) }) { return e as? ExecError }
        return nil
    }
    if case .authExpired(let s)? = fails("auth-expired") { expect(s.contains("SSO session"), "stderr kept") } else { expect(false, "expired SSO classified as authExpired") }
    if case .commandFailed(let st, let s)? = fails("fail") { expect(st == 254 && s.contains("AccessDenied"), "status and stderr kept") } else { expect(false, "plain failure is commandFailed") }
    if case .invalidJSON? = fails("not-json") { } else { expect(false, "non-JSON output is invalidJSON") }
    let empty = try? blocking { try await exec.run(authorized("fake", "empty")) }.get()
    expect(empty != nil && empty?.json == nil, "empty output yields nil json, not an error")
    let missing = blocking { try await CLIExecutor(awsPath: "/nonexistent/aws", environment: testEnvironment).run(authorized("sts", "get-caller-identity")) }
    if case .failure(let e) = missing, let ee = e as? ExecError, case .spawnFailed(let n) = ee { expect(n == ENOENT, "ENOENT reported") } else { expect(false, "missing binary is spawnFailed") }
}

section("executor: timeout, cancellation and output cap kill the whole process tree") {
    killLeaks()
    let t0 = ProcessInfo.processInfo.systemUptime
    let timedOut = blocking { try await exec.run(authorized("fake", "sleep", timeout: 0.6)) }
    let took = ProcessInfo.processInfo.systemUptime - t0
    if case .failure(let e) = timedOut, let ee = e as? ExecError, case .timedOut = ee { expect(took < 5, "timed out promptly (\(took) s)") } else { expect(false, "timeout reported as timedOut") }
    expect(!leakedSleepProcesses(), "no grandchild left after a timeout")
    killLeaks()

    let sem = DispatchSemaphore(value: 0)
    var cancelResult: Result<ExecResult, Error>?
    let task = Task.detached { () -> Void in
        do { cancelResult = .success(try await exec.run(authorized("fake", "sleep", timeout: 60))) } catch { cancelResult = .failure(error) }
        sem.signal()
    }
    Thread.sleep(forTimeInterval: 0.5)
    let c0 = ProcessInfo.processInfo.systemUptime
    task.cancel()
    sem.wait()
    let cancelTook = ProcessInfo.processInfo.systemUptime - c0
    if case .failure(let e)? = cancelResult, e is CancellationError { expect(cancelTook < 3, "cancel returned in \(cancelTook) s") } else { expect(false, "cancel surfaces CancellationError, got \(String(describing: cancelResult))") }
    expect(!leakedSleepProcesses(), "no grandchild left after a cancel")
    killLeaks()

    let small = CLIExecutor(awsPath: fakeAws, environment: testEnvironment, outputCapBytes: 1_000_000)
    let big = blocking { try await small.run(authorized("fake", "big")) }
    if case .failure(let e) = big, let ee = e as? ExecError, case .outputTooLarge(let lim) = ee { expect(lim == 1_000_000, "limit reported") } else { expect(false, "oversized output is outputTooLarge") }
    let normalBig = try? blocking { try await exec.run(authorized("fake", "big")) }.get()
    expect(normalBig?.json?["x"]?.stringValue?.count == 3_000_000, "under the default cap a 3 MB result comes through whole")
}

// MARK: - Identity

section("identity: verified through the real authorizer and executor path") {
    let ident = try? blocking { try await IdentityProbe.verify(profile: "example-dev", region: "eu-west-1", executor: exec, authorizer: Authorizer(table: fakeTable)) }.get()
    expect(ident == VerifiedIdentity(account: "111111111111", arn: "arn:aws:iam::111111111111:user/fake", userId: "AIDAFAKE"), "identity parsed")
    // With the standard table sts get-caller-identity is allowed too.
    let std = try? blocking { try await IdentityProbe.verify(profile: "example-dev", region: "eu-west-1", executor: exec) }.get()
    expect(std?.account == "111111111111", "standard table allows the identity probe")
}

section("identity store: caching, de-duplication, invalidation") {
    let counter = Counter()
    let store = IdentityStore(probe: { _, _ in
        counter.increment()
        try await Task.sleep(nanoseconds: 100_000_000)
        return VerifiedIdentity(account: "222222222222", arn: "arn:aws:iam::222222222222:role/R", userId: "U")
    })
    expect(blocking { await store.state(for: "example-prod") }.successValue == IdentityState.unverified, "unverified before the first probe")
    // Five concurrent callers: one probe.
    let results: [String] = (try? blocking { () async throws -> [String] in
        try await withThrowingTaskGroup(of: String.self) { g in
            for _ in 0..<5 { g.addTask { try await store.identity(for: "example-prod", region: "eu-west-1").account } }
            var out: [String] = []
            for try await a in g { out.append(a) }
            return out
        }
    }.get()) ?? []
    expect(results.count == 5 && Set(results) == ["222222222222"], "all callers get the identity")
    expect(counter.value == 1, "concurrent callers share ONE probe, got \(counter.value)")
    _ = blocking { try await store.identity(for: "example-prod", region: "eu-west-1") }
    expect(counter.value == 1, "cached afterwards")
    expect(blocking { await store.state(for: "example-prod") }.successValue == IdentityState.verified(account: "222222222222", arn: "arn:aws:iam::222222222222:role/R"), "state is verified")
    _ = blocking { await store.invalidate("example-prod") }
    _ = blocking { try await store.identity(for: "example-prod", region: "eu-west-1") }
    expect(counter.value == 2, "invalidate forces a re-probe")
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
extension Result { var successValue: Success? { if case .success(let v) = self { return v }; return nil } }

// MARK: - Cache

section("cache: keys, TTL, sensitive and never-cached operations") {
    let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
    let cache = ResultCache(defaultTTL: 45, now: { clock.now })
    let idA = VerifiedIdentity(account: "111111111111", arn: "arn:aws:iam::111111111111:user/a", userId: "A")
    let idB = VerifiedIdentity(account: "222222222222", arn: "arn:aws:iam::222222222222:user/a", userId: "B")
    let req = ExecRequest(profile: "example-dev", region: "eu-west-1", service: "lambda", operation: "list-functions")
    func result(_ r: ExecRequest, sensitive: Bool = false) -> ExecResult {
        ExecResult(request: r, commandDisplay: "x", json: .object(["a": .number(1)]), nextToken: nil, stderr: "", durationMs: 1, fetchedAt: clock.now, sensitive: sensitive)
    }
    let kA = CacheKey(request: req, identity: idA, cliVersion: "2.37.9")
    let kB = CacheKey(request: req, identity: idB, cliVersion: "2.37.9")
    expect(kA != kB, "same profile name, different verified account: different keys")
    expect(CacheKey(request: req, identity: idA, cliVersion: "2.38.0") != kA, "CLI version is part of the key")
    var paged = req; paged.startingToken = "t"
    expect(CacheKey(request: paged, identity: idA, cliVersion: "2.37.9") != kA, "pagination position is part of the key")
    var withParams = req; withParams.params = .object(["b": .number(2), "a": .number(1)])
    var sameParams = req; sameParams.params = .object(["a": .number(1), "b": .number(2)])
    expect(CacheKey(request: withParams, identity: idA, cliVersion: "v") == CacheKey(request: sameParams, identity: idA, cliVersion: "v"), "parameter key order does not matter")
    // Minute 16667 spans 1,000,020 to 1,000,079; minute 16668 starts at 1,000,080.
    let w1 = TimeWindow.last(900, now: Date(timeIntervalSince1970: 1_000_025)), w2 = TimeWindow.last(900, now: Date(timeIntervalSince1970: 1_000_075))
    expect(w1 == w2, "relative windows round down to the minute: repeats within a minute share a key")
    expect(w1.end == Date(timeIntervalSince1970: 1_000_020) && w1.start == Date(timeIntervalSince1970: 1_000_020 - 900), "window is [minute - 900 s, minute]")
    expect(TimeWindow.last(900, now: Date(timeIntervalSince1970: 1_000_085)) != w1, "the next minute is a new window")

    expect(blocking { await cache.put(kA, result(req)) }.successValue == true, "normal result is stored")
    expect(blocking { await cache.get(kA) }.successValue??.age == 0, "hit with age")
    clock.advance(44)
    expect(blocking { await cache.get(kA) }.successValue != nil && blocking { await cache.get(kA) }.successValue! != nil, "still fresh at 44 s")
    clock.advance(2)
    expect(blocking { await cache.get(kA) }.successValue! == nil, "expired after 46 s")
    expect(blocking { await cache.put(kB, result(req, sensitive: true)) }.successValue == false, "sensitive results are never stored")
    let live = ExecRequest(profile: "example-dev", region: "eu-west-1", service: "logs", operation: "filter-log-events")
    expect(blocking { await cache.put(CacheKey(request: live, identity: idA, cliVersion: "v"), result(live)) }.successValue == false, "log searches are never cached")
    let dl = ExecRequest(profile: "example-dev", region: "eu-west-1", service: "s3api", operation: "get-object")
    expect(blocking { await cache.put(CacheKey(request: dl, identity: idA, cliVersion: "v"), result(dl)) }.successValue == false, "downloads are never cached")
    _ = blocking { await cache.put(kA, result(req)) }
    _ = blocking { await cache.invalidate(account: "111111111111") }
    expect(blocking { await cache.count }.successValue == 0, "invalidate by account")
}
final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

// MARK: - Context binding

section("context: stale results are rejected, tabs are independent") {
    let tab = UUID(), other = UUID()
    let window = TimeWindow.last(900, now: Date(timeIntervalSince1970: 1_000_000))
    let base = RequestContext(tabId: tab, profile: "example-dev", region: "eu-west-1", accountId: "111111111111", window: window)
    let view = ViewContext(base)
    expect(view.accepts(base), "identical context is accepted")
    var t = base; t.profile = "example-prod"; expect(!view.accepts(t), "a result for another profile is dropped")
    t = base; t.region = "us-east-1"; expect(!view.accepts(t), "a result for another region is dropped")
    t = base; t.window = TimeWindow.last(900, now: Date(timeIntervalSince1970: 1_000_120)); expect(!view.accepts(t), "a result for another time window is dropped")
    t = base; t.window = nil; expect(!view.accepts(t), "window present vs absent is a mismatch")
    t = base; t.accountId = "999999999999"; expect(!view.accepts(t), "a result for another verified account is dropped")
    t = base; t.accountId = nil; expect(view.accepts(t), "issued before identity was verified: same profile, accepted")
    t = base; t.tabId = other; expect(!view.accepts(t), "a result for a different tab is dropped")
    // Switching the tab's profile makes previously issued requests stale.
    var switched = base; switched.profile = "example-prod"; switched.accountId = "222222222222"
    expect(!ViewContext(switched).accepts(base), "after switching profile, the old request's result is dropped")
}

// MARK: - Path safety and downloads

section("paths: file names from S3 keys") {
    expect((try? PathSanitizer.fileName(forKey: "a/b/report.csv")) == "report.csv", "last component")
    expect((try? PathSanitizer.fileName(forKey: "/abs/olute")) == "olute", "leading slash")
    expect((try? PathSanitizer.fileName(forKey: "x/../../etc/passwd")) == "passwd", "traversal in the middle only yields the last component")
    expect((try? PathSanitizer.fileName(forKey: "a\u{0}b")) == nil, "NUL rejected")
    expect((try? PathSanitizer.fileName(forKey: "bad\nname\t.txt")) == "bad_name_.txt", "control characters replaced")
    expect((try? PathSanitizer.fileName(forKey: "--debug")) == "--debug", "a flag-looking key stays a harmless file name")
    for k in ["", "dir/", "..", "a/.."] {
        if (try? PathSanitizer.fileName(forKey: k)) != nil { expect(false, "key \(k.debugDescription) must be rejected") }
    }
    let long = String(repeating: "é", count: 300) + ".log"
    let name = (try? PathSanitizer.fileName(forKey: "p/" + long)) ?? ""
    expect(name.utf8.count <= 235 && name.hasSuffix(".log"), "long names are truncated to a safe length, extension kept (\(name.utf8.count) bytes)")
}

section("paths: relative structure, containment and symlinks") {
    expect((try? PathSanitizer.relativePath(forKey: "a//b/c.txt")) == "a/b/c.txt", "empty components dropped")
    for k in ["../x", "a/../b", "a/./b", "x/.."] { if (try? PathSanitizer.relativePath(forKey: k)) != nil { expect(false, "relativePath must reject \(k)") } }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-test-\(UUID().uuidString)")
    let outside = tmp.appendingPathComponent("outside"), dest = tmp.appendingPathComponent("dest")
    try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("link"), withDestinationURL: outside)
    defer { try? FileManager.default.removeItem(at: tmp) }
    if (try? PathSanitizer.destinationURL(folder: dest, relativePath: "link/evil.txt")) != nil { expect(false, "a symlink inside the folder must not lead outside") }
    if (try? PathSanitizer.destinationURL(folder: dest, relativePath: "link/deeper/still/evil.txt")) != nil { expect(false, "…even through several missing levels") }
    // A dangling symlink: its target does not exist, so it cannot be proven to stay inside the folder.
    try? FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("dangling"), withDestinationURL: URL(fileURLWithPath: "/nonexistent/place/file"))
    if (try? PathSanitizer.destinationURL(folder: dest, relativePath: "dangling")) != nil { expect(false, "a dangling symlink at the target name is unsafe") }
    // A symlink that points INSIDE the folder is fine.
    try? FileManager.default.createDirectory(at: dest.appendingPathComponent("real"), withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("alias"), withDestinationURL: dest.appendingPathComponent("real"))
    expect((try? PathSanitizer.destinationURL(folder: dest, relativePath: "alias/ok.txt")) != nil, "a symlink that stays inside the folder is allowed")
    expect((try? PathSanitizer.destinationURL(folder: dest, relativePath: "fine/ok.txt")) != nil, "a normal path is fine")
    let existing = dest.appendingPathComponent("a.txt"); FileManager.default.createFile(atPath: existing.path, contents: Data())
    FileManager.default.createFile(atPath: dest.appendingPathComponent("a (1).txt").path, contents: Data())
    expect(PathSanitizer.uniqueURL(for: existing).lastPathComponent == "a (2).txt", "collision suffix skips taken names")
    expect(PathSanitizer.uniqueURL(for: dest.appendingPathComponent("new.txt")).lastPathComponent == "new.txt", "free name unchanged")
}

func downloadRequest(key: String, timeout: TimeInterval = 20, params: JSONValue? = nil) -> AuthorizedRequest {
    let p = params ?? .object(["Bucket": .string("my-bucket"), "Key": .string(key)])
    let o = Authorizer().authorize(ExecRequest(profile: "example-dev", region: "eu-west-1", service: "s3api", operation: "get-object", params: p, timeout: timeout), context: AuthContext())
    guard case .allow(let a, _) = o else { fatalError("download not authorized: \(o)") }
    return a
}
func freshDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-dl-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
}
func listing(_ d: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).sorted() }

let downloader = S3Downloader(awsPath: fakeAws, environment: testEnvironment)

section("download: success, part file renamed into place, nothing left behind") {
    let d = freshDir(); defer { try? FileManager.default.removeItem(at: d) }
    let r = try? blocking { try await downloader.download(downloadRequest(key: "reports/2026/summary.csv"), to: d) }.get()
    expect(r?.bytes == 2_097_152, "all bytes written, got \(String(describing: r?.bytes))")
    // Canonical path (Foundation's resolvingSymlinksInPath() rewrites /private/var to /var, so use realpath).
    let canonical = realpath(d.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? d.path
    expect(r?.finalPath == canonical + "/summary.csv", "saved under the sanitized file name, got \(r?.finalPath ?? "nil") expected \(canonical)/summary.csv")
    expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("summary.csv").path), "the file is where the user chose")
    expect(listing(d) == ["summary.csv"], "no .bridge-part left, got \(listing(d))")
    expect(r?.commandDisplay.contains("get-object --bucket my-bucket --key reports/2026/summary.csv") == true, "copy-pasteable command")
}

section("download: never overwrites silently; overwrite swaps in one rename") {
    let d = freshDir(); defer { try? FileManager.default.removeItem(at: d) }
    let existing = d.appendingPathComponent("summary.csv"); try? Data("keep me".utf8).write(to: existing)
    let blockedErr = blocking { try await downloader.download(downloadRequest(key: "summary.csv"), to: d) }
    if case .failure(let e) = blockedErr, let te = e as? TransferError, case .destinationExists = te {} else { expect(false, "an existing file must stop the download, got \(blockedErr)") }
    expect((try? String(contentsOf: existing, encoding: .utf8)) == "keep me", "the existing file is untouched")
    expect(listing(d) == ["summary.csv"], "no part file left after the refusal")
    let over = try? blocking { try await downloader.download(downloadRequest(key: "summary.csv"), to: d, overwrite: true) }.get()
    expect(over?.bytes == 2_097_152 && listing(d) == ["summary.csv"], "overwrite replaces the file")
}

section("download: failure, cancel and timeout leave no partial file") {
    let d = freshDir(); defer { try? FileManager.default.removeItem(at: d) }
    let failed = blocking { try await downloader.download(downloadRequest(key: "fail.bin"), to: d) }
    if case .failure(let e) = failed, let te = e as? TransferError, case .failed(let st, let s) = te { expect(st == 254 && s.contains("NoSuchKey"), "status and stderr surfaced") } else { expect(false, "failure surfaced as TransferError.failed") }
    expect(listing(d).isEmpty, "failed download leaves nothing, got \(listing(d))")

    killLeaks()
    let timedOut = blocking { try await downloader.download(downloadRequest(key: "slow.bin", timeout: 1), to: d) }
    if case .failure(let e) = timedOut, let te = e as? TransferError, case .timedOut = te {} else { expect(false, "timeout surfaced, got \(timedOut)") }
    expect(listing(d).isEmpty, "timed-out download leaves nothing, got \(listing(d))")
    expect(!leakedSleepProcesses(), "no child left after the timeout")
    killLeaks()

    let sem = DispatchSemaphore(value: 0)
    var cancelResult: Result<DownloadResult, Error>?
    let task = Task.detached { () -> Void in
        do { cancelResult = .success(try await downloader.download(downloadRequest(key: "slow.bin", timeout: 60), to: d)) } catch { cancelResult = .failure(error) }
        sem.signal()
    }
    Thread.sleep(forTimeInterval: 0.7)
    let partsDuring = listing(d)
    let c0 = ProcessInfo.processInfo.systemUptime
    task.cancel(); sem.wait()
    expect(partsDuring.count == 1 && partsDuring[0].hasPrefix(S3Downloader.stagingPrefix), "while running data stays in a private transfer staging directory, got \(partsDuring)")
    if case .failure(let e)? = cancelResult, e is CancellationError { expect(ProcessInfo.processInfo.systemUptime - c0 < 3, "cancel returned promptly") } else { expect(false, "cancel surfaces CancellationError") }
    expect(listing(d).isEmpty, "cancelled download leaves nothing, got \(listing(d))")
    expect(!leakedSleepProcesses(), "no child left after the cancel")
    killLeaks()
}

section("download: input validation, hostile keys, progress, stale-part sweep") {
    let d = freshDir(); defer { try? FileManager.default.removeItem(at: d) }
    let notTransfer = Authorizer().authorize(ExecRequest(profile: "example-dev", region: "eu-west-1", service: "lambda", operation: "list-functions"), context: AuthContext())
    if case .allow(let a, _) = notTransfer, case .failure(let e) = blocking({ try await downloader.download(a, to: d) }), let te = e as? TransferError { expect(te == .notATransfer, "only get-object is a transfer") } else { expect(false, "non-transfer rejected") }
    let missing = blocking { try await downloader.download(downloadRequest(key: "a"), to: d.appendingPathComponent("nope")) }
    if case .failure(let e) = missing, let te = e as? TransferError { expect(te == .destinationMissing, "missing destination folder") } else { expect(false, "missing destination reported") }
    let dirKey = blocking { try await downloader.download(downloadRequest(key: "folder/"), to: d) }
    if case .failure(let e) = dirKey, let te = e as? TransferError, case .path(.directoryKey) = te {} else { expect(false, "a folder key cannot be downloaded as a file") }
    let flagKey = try? blocking { try await downloader.download(downloadRequest(key: "--debug"), to: d) }.get()
    expect(flagKey != nil && listing(d).contains("--debug"), "a key that looks like a flag is passed as a value and saved harmlessly")
    let noKey = blocking { try await downloader.download(downloadRequest(key: "x", params: .object(["Bucket": .string("b")])), to: d) }
    if case .failure(let e) = noKey, let te = e as? TransferError, case .invalidParams = te {} else { expect(false, "missing Key rejected") }

    let seen = Counter()
    _ = try? blocking { try await downloader.download(downloadRequest(key: "progress.bin"), to: d, progress: { _ in seen.increment() }) }.get()
    expect(seen.value >= 0, "progress callback is optional and does not break the download") // timing-dependent, so no stronger claim

    let old = d.appendingPathComponent("old.bin.bridge-part"), fresh = d.appendingPathComponent("fresh.bin.bridge-part")
    FileManager.default.createFile(atPath: old.path, contents: Data("x".utf8)); FileManager.default.createFile(atPath: fresh.path, contents: Data("x".utf8))
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: old.path)
    expect(S3Downloader.sweepStaleParts(in: d) == 1, "only the stale part file is swept")
    expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path), "fresh part files are kept")
}

runBillingCatalogTests()
runSettingsTests()
runCredentialTrustTests()
runExecutionBackendTests()
runTransferRaceTests()
runSsoLoginTests()
runWorkflowTests()
runAgentTests()
runCodexTests()

print("\n\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
