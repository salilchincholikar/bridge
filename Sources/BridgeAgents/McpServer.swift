import BridgeCore
import Foundation

// A minimal MCP server over stdio (JSON-RPC 2.0, newline-delimited). It speaks only what a coding-agent
// client needs: initialize, ping, tools/list and tools/call. Behavior follows the MCP specification pages
// read for this project (2025-11-25 revision); whether the newest revision's handshake-less flow is needed
// by current clients is `[unverified]`.

public struct McpTool: Equatable, Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, title: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema
    }
}

public struct McpToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    public init(text: String, isError: Bool = false) { self.text = text; self.isError = isError }
}

public protocol McpToolBackend: Sendable {
    func listTools() async throws -> [McpTool]
    /// Tool failures (denied, AWS error) are returned as `isError` results, not thrown, so the model can read them.
    func callTool(name: String, arguments: JSONValue) async -> McpToolResult
}

public final class McpServer: @unchecked Sendable {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private let name: String
    private let version: String
    private let instructions: String?
    private let backend: McpToolBackend

    public init(name: String = "bridge", version: String = "0.1.0", instructions: String? = nil, backend: McpToolBackend) {
        self.name = name; self.version = version; self.instructions = instructions; self.backend = backend
    }

    /// One incoming line in, at most one outgoing line out (notifications produce none).
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8), let msg = try? JSONValue.parse(data), case .object(let obj) = msg else {
            return encode(error: -32700, message: "Parse error", id: .null)
        }
        let id = obj["id"]
        guard let method = obj["method"]?.stringValue else {
            // A response or something else; nothing to do (we send no requests to the client).
            return nil
        }
        let isNotification = id == nil
        let params = obj["params"] ?? .object([:])

        switch method {
        case "initialize":
            let requested = params.string("protocolVersion")
            let chosen = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(chosen),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(name), "title": .string("Bridge (read-only AWS)"), "version": .string(version)]),
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return encode(result: .object(result), id: id ?? .null)

        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "ping":
            return isNotification ? nil : encode(result: .object([:]), id: id ?? .null)

        case "tools/list":
            guard !isNotification else { return nil }
            do {
                let tools = try await backend.listTools().map { t -> JSONValue in
                    .object(["name": .string(t.name), "title": .string(t.title), "description": .string(t.description), "inputSchema": t.inputSchema])
                }
                return encode(result: .object(["tools": .array(tools)]), id: id ?? .null)
            } catch {
                return encode(error: -32603, message: "Could not list tools: \(error)", id: id ?? .null)
            }

        case "tools/call":
            guard !isNotification else { return nil }
            guard let toolName = params.string("name") else { return encode(error: -32602, message: "Missing tool name", id: id ?? .null) }
            let known = (try? await backend.listTools().map(\.name)) ?? []
            guard known.contains(toolName) else { return encode(error: -32602, message: "Unknown tool: \(toolName)", id: id ?? .null) }
            let result = await backend.callTool(name: toolName, arguments: params["arguments"] ?? .object([:]))
            return encode(result: .object(["content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
                                           "isError": .bool(result.isError)]), id: id ?? .null)

        default:
            return isNotification ? nil : encode(error: -32601, message: "Method not found: \(method)", id: id ?? .null)
        }
    }

    private func encode(result: JSONValue, id: JSONValue) -> String {
        line(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
    private func encode(error code: Int, message: String, id: JSONValue) -> String {
        line(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }
    /// Compact JSON: string contents escape newlines, so the line never contains a raw newline (stdio framing rule).
    private func line(_ v: JSONValue) -> String { v.compactString() }

    /// Serve stdio until stdin closes. Logs go to stderr only; stdout carries nothing but protocol messages.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        let reader = LineReader(handle: input)
        while let line = reader.next() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let response = await handle(line: trimmed) {
                output.write(Data((response + "\n").utf8))
            }
        }
    }
}

/// Blocking newline-delimited reader over a file handle (used for stdio and sockets).
public final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    private let maxLine: Int

    public init(handle: FileHandle, maxLine: Int = 4 * 1024 * 1024) { self.fd = handle.fileDescriptor; self.maxLine = maxLine }
    public init(fd: Int32, maxLine: Int = 4 * 1024 * 1024) { self.fd = fd; self.maxLine = maxLine }

    /// The next line without its newline, or nil at end of input (or if a line exceeds `maxLine`).
    public func next() -> String? {
        while true {
            if let i = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                return String(decoding: lineData, as: UTF8.self)
            }
            if buffer.count > maxLine { return nil }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(chunk, count: n) }
            else if n == 0 { if buffer.isEmpty { return nil }; let rest = buffer; buffer.removeAll(); return String(decoding: rest, as: UTF8.self) }
            else if errno == EINTR { continue }
            else { return nil }
        }
    }
}
