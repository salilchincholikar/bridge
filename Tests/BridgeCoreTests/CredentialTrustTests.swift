import Foundation
import BridgeCore
import BridgeAgents

func runCredentialTrustTests() {
    section("credential trust: chain traversal, exact command, cycles") {
        let config = AwsConfigParser.parse("""
        [profile role]
        role_arn = arn:aws:iam::111111111111:role/Test
        source_profile = helper
        [profile helper]
        credential_process = /usr/bin/helper --test
        """)
        let approval = try? CredentialProcessTrust.requiredApproval(profile: "role", config: config, settings: BridgeSettings())
        expect(approval?.profile == "helper" && approval?.command == "/usr/bin/helper --test", "approval follows source profile")
        let indented = AwsConfigParser.parse("[profile helper]\n    region = eu-west-1\n    credential_process = /usr/bin/helper --test\n")
        expect((try? CredentialProcessTrust.requiredApproval(profile: "helper", config: indented, settings: BridgeSettings()))?.command == "/usr/bin/helper --test", "indented sibling settings cannot hide a helper")
        let uppercase = AwsConfigParser.parse("[profile helper]\nREGION = eu-west-1\nCREDENTIAL_PROCESS = /usr/bin/helper --test\nAWS_SECRET_ACCESS_KEY = synthetic-secret\n")
        expect((try? CredentialProcessTrust.requiredApproval(profile: "helper", config: uppercase, settings: BridgeSettings()))?.command == "/usr/bin/helper --test", "AWS option names are case-insensitive for trust checks")
        expect(!String(describing: uppercase).contains("synthetic-secret"), "uppercase credential keys are discarded too")
        let trusted = BridgeSettings().confirmingCredentialProcess(profile: "helper", command: "/usr/bin/helper --test")
        expect((try? CredentialProcessTrust.requiredApproval(profile: "role", config: config, settings: trusted)) == nil, "unchanged helper is trusted")
        let cycle = AwsConfigParser.parse("[profile a]\nrole_arn = arn:aws:iam::111111111111:role/A\nsource_profile = b\n[profile b]\nrole_arn = arn:aws:iam::111111111111:role/B\nsource_profile = a\n")
        do { _ = try CredentialProcessTrust.requiredApproval(profile: "a", config: cycle, settings: trusted); expect(false, "cycle must fail closed") }
        catch { expect(error as? CredentialTrustError == .invalidChain, "cycle blocked") }
    }

    section("credential trust: probes, cached reads and transfers cannot bypass approval") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-trust-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config"), settings = dir.appendingPathComponent("settings.json")
        func writeConfig(_ command: String) { try! "[profile example-dev]\ncredential_process = \(command)\nregion = eu-west-1\n".write(to: config, atomically: true, encoding: .utf8) }
        writeConfig("/usr/bin/first-helper")
        let env = ["HOME": dir.path, "AWS_CONFIG_FILE": config.path, "BRIDGE_SETTINGS": settings.path]
        // A missing executable proves denial occurs before any attempt to spawn the AWS CLI.
        let missing = CLIExecutor(awsPath: "/nonexistent/aws", environment: env)
        func assertBlocked<T>(_ result: Result<T, Error>, _ message: String) {
            if case .failure(let error) = result, case CredentialTrustError.approvalRequired(let approval) = error {
                expect(approval.profile == "example-dev", message)
                expect(!error.localizedDescription.contains("/usr/bin/"), "diagnostic omits helper command")
                expect(!String(describing: error).contains("/usr/bin/"), "generic errors and agent diagnostics omit helper command")
            } else { expect(false, message) }
        }
        assertBlocked(blocking { try await IdentityProbe.verify(profile: "example-dev", region: "eu-west-1", executor: missing) }, "STS blocked before spawning")
        let request = LambdaWorkflow.listFunctions(profile: "example-dev", region: "eu-west-1", maxItems: nil)
        let data = DataService(executor: CLIExecutor(awsPath: fakeAws, environment: env))
        assertBlocked(blocking { try await data.fetch(request, tab: UUID()) }, "data service blocked")
        let agent = AgentBackend(data: data, config: AwsConfigParser.parse(""), settings: BridgeSettings(), scope: AgentScope(profiles: ["example-dev"]), uiContext: { "" }, trace: { _ in })
        let refused = blocking { await agent.callTool(name: "aws_read", arguments: .object(["profile": .string("example-dev"), "region": .string("eu-west-1"), "service": .string("lambda"), "operation": .string("list-functions")])) }.successValue
        expect(refused?.isError == true && refused?.text.contains("human review") == true, "assistant cannot approve helpers")
        expect(refused?.text.contains("/usr/bin/first-helper") == false, "helper command never reaches assistant diagnostics")
        let auth = Authorizer().authorize(S3Workflow.download(profile: "example-dev", region: "eu-west-1", bucket: "b", key: "k"), context: AuthContext())
        if case .allow(let a, _) = auth {
            assertBlocked(blocking { try await S3Downloader(awsPath: "/nonexistent/aws", environment: env).download(a, to: dir) }, "transfer blocked before spawning")
        } else { expect(false, "test transfer authorized") }
        try! SettingsStore.save(BridgeSettings().confirmingCredentialProcess(profile: "example-dev", command: "/usr/bin/first-helper"), path: settings.path)
        let first = try? blocking { try await data.fetch(request, tab: UUID()) }.get()
        expect(first?.result.json != nil, "approved unchanged helper permits fake CLI")
        expect((try? blocking { try await data.fetch(request, tab: UUID()) }.get())?.fromCache == true, "cache populated")
        writeConfig("/usr/bin/changed-helper")
        assertBlocked(blocking { try await data.fetch(request, tab: UUID()) }, "changed helper denied even with cached identity and result")
        let credentials = dir.appendingPathComponent("credentials")
        let mergedEnvironment = env.merging(["AWS_SHARED_CREDENTIALS_FILE": credentials.path]) { _, new in new }
        try! "[example-dev]\naws_secret_access_key = ignored-secret-value\ncredential_process = /usr/bin/credentials-helper\n".write(to: credentials, atomically: true, encoding: .utf8)
        let override = try? CredentialProcessTrust.requiredApproval(profile: "example-dev", environment: mergedEnvironment)
        expect(override?.command == "/usr/bin/credentials-helper", "credentials-file helper overrides config helper")
        expect(!String(describing: override).contains("ignored-secret-value"), "credential values never enter trust metadata")
        try! "[only-in-credentials]\nCREDENTIAL_PROCESS = /usr/bin/credentials-only\n".write(to: credentials, atomically: true, encoding: .utf8)
        let only = try? CredentialProcessTrust.requiredApproval(profile: "only-in-credentials", environment: mergedEnvironment)
        expect(only?.command == "/usr/bin/credentials-only", "credentials-only helper cannot bypass approval")
        try! "[\"literal quotes\"]\ncredential_process = /usr/bin/quoted-helper\n".write(to: credentials, atomically: true, encoding: .utf8)
        let quoted = try? CredentialProcessTrust.requiredApproval(profile: "\"literal quotes\"", environment: mergedEnvironment)
        expect(quoted?.command == "/usr/bin/quoted-helper", "literal quote characters in credentials profile names are preserved")
        let directoryConfig = env.merging(["AWS_CONFIG_FILE": dir.path]) { _, new in new }
        do { _ = try CredentialProcessTrust.requiredApproval(profile: "example-dev", environment: directoryConfig); expect(false, "unreadable config must fail closed") }
        catch { expect(error as? CredentialTrustError == .unreadableConfiguration, "unreadable configuration blocks execution") }
        try! "[profile escaped\\ name]\ncredential_process = /usr/bin/ambiguous-helper\n".write(to: config, atomically: true, encoding: .utf8)
        do { _ = try CredentialProcessTrust.requiredApproval(profile: "escaped name", environment: env); expect(false, "ambiguous escaped profile header must fail closed") }
        catch { expect(error as? CredentialTrustError == .unreadableConfiguration, "unsupported escaped headers cannot bypass helper trust") }
        try! "{broken".write(to: settings, atomically: true, encoding: .utf8)
        if case .failure(let error) = blocking({ try await missing.run(authorized("sts", "get-caller-identity")) }) {
            expect(error as? CredentialTrustError == .unreadableConfiguration, "corrupt trust settings fail closed")
        } else { expect(false, "corrupt trust settings blocked") }
    }
}
