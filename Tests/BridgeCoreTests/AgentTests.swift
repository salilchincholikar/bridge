import Foundation
import BridgeCore
import BridgeAgents

struct StubBackend: McpToolBackend {
    func listTools() async throws -> [McpTool] {
        [McpTool(name: "echo", title: "Echo", description: "Echoes text", inputSchema: .object(["type": .string("object"), "properties": .object(["text": .object(["type": .string("string")])])]))]
    }
    func callTool(name: String, arguments: JSONValue) async -> McpToolResult {
        name == "echo" ? McpToolResult(text: "echo: \(arguments.string("text") ?? "")\nsecond line") : McpToolResult(text: "?", isError: true)
    }
}

func runAgentTests() {
    section("redactor: secrets are removed, ordinary text is kept") {
        let cases: [(String, [String], [String])] = [
            ("key AKIAABCDEFGHIJKLMNOP and ASIAABCDEFGHIJKLMNOP here", ["AKIAABCDEFGHIJKLMNOP", "ASIAABCDEFGHIJKLMNOP"], ["key", "here"]),
            (#"{"password":"hunter2hunter2","user":"bob"}"#, ["hunter2hunter2"], [#""user":"bob""#, "password"]),
            ("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", ["wJalrXUtnFEMI"], ["aws_secret_access_key"]),
            ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789", ["abcdefghijklmnopqrstuvwxyz0123456789"], ["Authorization"]),
            ("token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnopqrstuv end", ["eyJhbGciOiJIUzI1NiJ9"], ["token", "end"]),
            ("-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----", ["MIIEowIBAAKCAQEA"], []),
            (#"escaped \"api_key\": \"sk_live_1234567890abcdef\" inside a log line"#, ["sk_live_1234567890abcdef"], ["inside a log line"]),
        ]
        for (input, gone, kept) in cases {
            let r = Redactor.redact(input)
            for g in gone { expect(!r.text.contains(g), "removed \(g.prefix(24)) from: \(r.text.prefix(80))") }
            for k in kept { expect(r.text.contains(k), "kept \(k)") }
            expect(r.redactions >= 1, "counted a redaction for: \(input.prefix(30))")
        }
        let plain = "Task timed out after 30.00 seconds; RequestId: 1f2e3d4c; function example-workload-orders-handler; account 111111111111"
        expect(Redactor.redact(plain) == Redactor.Result(text: plain, redactions: 0), "log text without secrets is untouched")
        let arn = "arn:aws:iam::111111111111:role/service-role/example-workload-orders-handler-role"
        expect(Redactor.redact(arn).text == arn, "ARNs and ids are untouched")
    }

    section("redactor: masking JSON paths") {
        let v: JSONValue = .object(["Code": .object(["Location": .string("https://signed.example/x?X-Amz-Signature=abc"), "RepositoryType": .string("S3")]), "Other": .string("keep")])
        let m = Redactor.mask(v, paths: ["Code.Location"])
        expect(m.string("Code.Location") == "[masked]" && m.string("Code.RepositoryType") == "S3" && m.string("Other") == "keep", "only the named path is masked")
        let arr: JSONValue = .object(["Items": .array([.object(["Secret": .string("a"), "Id": .string("1")]), .object(["Secret": .string("b"), "Id": .string("2")])])])
        let ma = Redactor.mask(arr, paths: ["Items.Secret"])
        expect(ma.array("Items").allSatisfy { $0.string("Secret") == "[masked]" } && ma.array("Items").map { $0.string("Id") } == ["1", "2"], "a path applies to every array element")
        expect(Redactor.mask(v, paths: ["Nope.Missing"]) == v, "an absent path changes nothing")
    }

    section("mcp server: handshake, tools, errors, framing") {
        let server = McpServer(backend: StubBackend())
        func call(_ s: String) -> JSONValue? { blocking { await server.handle(line: s) }.successValue.flatMap { $0 }.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONValue.parse($0) } }
        func raw(_ s: String) -> String? { blocking { await server.handle(line: s) }.successValue.flatMap { $0 } }

        let ini = call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        expect(ini?.string("result.protocolVersion") == "2025-06-18", "echoes a supported client version")
        expect(ini?.value(at: "result.capabilities.tools") != nil && ini?.string("result.serverInfo.name") == "bridge", "declares tools capability and server info")
        expect(call(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)?.string("result.protocolVersion") == "2025-11-25", "an unknown version gets the server's own")
        expect(raw(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "notifications get no response")
        expect(call(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)?.value(at: "result") == .object([:]), "ping answers with an empty result")

        let list = call(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        expect(list?.array("result.tools").first?.string("name") == "echo" && list?.array("result.tools").first?.value(at: "inputSchema.type") == .string("object"), "tools/list with an inputSchema object")

        let ok = call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        expect(ok?.array("result.content").first?.string("text") == "echo: hi\nsecond line" && ok?.value(at: "result.isError") == .bool(false), "tools/call returns text content, isError false")
        let okRaw = raw(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#) ?? ""
        expect(!okRaw.contains("\n"), "responses never contain a raw newline (stdio framing)")

        expect(call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#)?.value(at: "error.code") == .number(-32602), "unknown tool is a protocol error (-32602)")
        expect(call(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}}"#)?.value(at: "error.code") == .number(-32602), "missing tool name is -32602")
        expect(call(#"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#)?.value(at: "error.code") == .number(-32601), "unknown method is -32601")
        let bad = call("{ not json")
        expect(bad?.value(at: "error.code") == .number(-32700) && bad?["id"] == .null, "malformed JSON is -32700 with a null id")
        expect(call(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)?["id"] == .string("abc"), "string ids are echoed back")
    }

    runAgentChainTests()
}
