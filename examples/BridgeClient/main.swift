import Foundation
import BridgeCore

// A separate consumer of BridgeCore. Runs entirely in memory: no AWS credentials or external tools.
struct ExampleBackend: ExecutionBackend {
    func checkCredentialTrust(profile: String) throws {}
    func version() async -> String { "example" }
    func run(_ authorized: AuthorizedRequest) async throws -> ExecResult {
        let r = authorized.request
        let json: JSONValue = r.service == "sts"
            ? .object(["Account": .string("111111111111"), "Arn": .string("arn:aws:iam::111111111111:user/example")])
            : .object(["Functions": .array([.object(["FunctionName": .string("example-function"), "Runtime": .string("python3.12")])])])
        return ExecResult(request: r, commandDisplay: "In-memory example", json: json, nextToken: nil, stderr: "", durationMs: 0, fetchedAt: Date(), sensitive: authorized.sensitive)
    }
}

Task {
    do {
        let client = DataService(executor: ExampleBackend(), cliVersion: "example")
        let request = LambdaWorkflow.listFunctions(profile: "example", region: "eu-west-1", maxItems: nil)
        let fetched = try await client.fetch(request, tab: UUID())
        for function in LambdaWorkflow.parseFunctions(fetched.result.json) { print("\(function.name) · \(function.runtime ?? "unknown")") }
        print("Verified synthetic account: \(fetched.identity?.account ?? "unknown")")
        exit(0)
    } catch { print("Example failed: \(error)"); exit(1) }
}
dispatchMain()
