import Foundation
import BridgeCore

private actor MemoryBackend: ExecutionBackend {
    private var calls: [String] = []
    nonisolated func checkCredentialTrust(profile: String) throws {}
    nonisolated func version() async -> String { "memory-fixture" }
    func count(_ operation: String) -> Int { calls.filter { $0 == operation }.count }
    func run(_ authorized: AuthorizedRequest) async throws -> ExecResult {
        try Task.checkCancellation()
        let request = authorized.request
        calls.append(request.operation)
        let json: JSONValue
        switch request.operation {
        case "get-caller-identity": json = .object(["Account": .string("111111111111"), "Arn": .string("arn:aws:iam::111111111111:user/example")])
        case "get-function": json = .object(["Configuration": .object(["Environment": .object(["Variables": .object(["FLAG": .string("fixture-value")])])])])
        default: json = .object(["Functions": .array([.object(["FunctionName": .string("example-function")])])])
        }
        // Deliberately false: Core must enforce its own policy regardless of adapter classification.
        return ExecResult(request: request, commandDisplay: "Fixture request", json: json, nextToken: nil, stderr: "", durationMs: 0, fetchedAt: Date(), sensitive: false)
    }
}

func runExecutionBackendTests() {
    section("client backend contract: policy, cache, identity and sensitivity without CLI") {
        let backend = MemoryBackend()
        let client = DataService(executor: backend, cliVersion: "memory-fixture")
        let request = LambdaWorkflow.listFunctions(profile: "example", region: "eu-west-1", maxItems: nil)
        let first = try? blocking { try await client.fetch(request, tab: UUID()) }.get()
        let cached = try? blocking { try await client.fetch(request, tab: UUID()) }.get()
        expect(first?.identity?.account == "111111111111" && LambdaWorkflow.parseFunctions(first?.result.json).first?.name == "example-function", "client verifies identity and returns typed workflow data")
        expect(cached?.fromCache == true && blocking { await backend.count("list-functions") }.successValue == 1, "shared client cache works with another adapter")
        let full = ExecRequest(profile: "example", region: "eu-west-1", service: "lambda", operation: "get-function")
        _ = try? blocking { try await client.fetch(full, tab: UUID()) }.get()
        let again = try? blocking { try await client.fetch(full, tab: UUID()) }.get()
        expect(again?.result.sensitive == true && again?.fromCache == false, "policy overrides an adapter's incorrect sensitivity flag")
        expect(blocking { await backend.count("get-function") }.successValue == 2, "sensitive response never cached across adapters")
        if case .failure(let error) = blocking({ try await client.fetch(full, tab: UUID(), caller: .agent) }) {
            expect(error as? DataError == .denied(.sensitiveHiddenFromAgent), "agent denied before backend execution")
        } else { expect(false, "agent must be denied") }
        expect(blocking { await backend.count("get-function") }.successValue == 2, "denial cannot reach the adapter")
    }
}
