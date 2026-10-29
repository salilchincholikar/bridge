import BridgeCore
import Foundation
import Darwin

// Local IPC between `bridge mcp` (a child of the agent harness) and the running app (docs/technical.md 6.1).
// A Unix domain socket in a private directory, a per-session random token, and a same-user check on every
// connection. Messages are single JSON lines. No TCP listener exists anywhere.

public enum AgentIPCError: Error, Equatable, Sendable {
    case connectFailed(errno: Int32)
    case badResponse
    case rejected(String)
}

public final class AgentIPCServer: @unchecked Sendable {
    public let path: String
    private let token: String
    private let backend: McpToolBackend
    private var listenFd: Int32 = -1
    private let lock = NSLock()
    private var running = false

    public init(path: String, token: String, backend: McpToolBackend) {
        self.path = path; self.token = token; self.backend = backend
    }

    /// A fresh private socket path (short, because `sockaddr_un` allows about 104 bytes) and a random token.
    public static func makeEndpoint() throws -> (path: String, token: String) {
        let dir = NSTemporaryDirectory() + "bridge-ipc"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        return ("\(dir)/a-\(id).sock", bytes.map { String(format: "%02x", $0) }.joined())
    }

    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentIPCError.connectFailed(errno: errno) }
        unlink(path)
        var addr = Self.address(path)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { let e = errno; close(fd); throw AgentIPCError.connectFailed(errno: e) }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); throw AgentIPCError.connectFailed(errno: e) }
        lock.lock(); listenFd = fd; running = true; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock(); let fd = listenFd; running = false; listenFd = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(path)
    }

    deinit { stop() }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103)) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() where i < raw.count { raw[i] = b } }
        return addr
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            lock.lock(); let alive = running; lock.unlock()
            if !alive { close(client); return }
            Thread.detachNewThread { [weak self] in self?.serve(client: client) }
        }
    }

    private func serve(client fd: Int32) {
        defer { close(fd) }
        // Same user only.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        let reader = LineReader(fd: fd, maxLine: 2 * 1024 * 1024)
        while let line = reader.next() {
            let response = respond(to: line)
            let data = Data((response + "\n").utf8)
            var sent = 0
            data.withUnsafeBytes { raw in
                while sent < data.count {
                    let n = write(fd, raw.baseAddress! + sent, data.count - sent)
                    if n <= 0 { if errno == EINTR { continue }; break }
                    sent += n
                }
            }
        }
    }

    private func respond(to line: String) -> String {
        func fail(_ id: JSONValue, _ msg: String) -> String { JSONValue.object(["id": id, "ok": .bool(false), "error": .string(msg)]).compactString() }
        guard let data = line.data(using: .utf8), let msg = try? JSONValue.parse(data), case .object(let o) = msg else { return fail(.null, "malformed request") }
        let id = o["id"] ?? .null
        guard let given = o["token"]?.stringValue, Self.constantTimeEqual(given, token) else { return fail(id, "unauthorized") }
        let params = o["params"] ?? .object([:])
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let backend = self.backend
        let method = o["method"]?.stringValue
        Task {
            switch method {
            case "tools/list":
                if let tools = try? await backend.listTools() {
                    box.set(.object(["tools": .array(tools.map { .object(["name": .string($0.name), "title": .string($0.title), "description": .string($0.description), "inputSchema": $0.inputSchema]) })]))
                }
            case "tools/call":
                if let name = params.string("name") {
                    let r = await backend.callTool(name: name, arguments: params["arguments"] ?? .object([:]))
                    box.set(.object(["text": .string(r.text), "isError": .bool(r.isError)]))
                }
            default: break
            }
            sem.signal()
        }
        sem.wait()
        guard let result = box.value else { return fail(id, method == nil ? "missing method" : "failed or unknown method") }
        return JSONValue.object(["id": id, "ok": .bool(true), "result": result]).compactString()
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<min(x.count, y.count) { diff |= Int(x[i] ^ y[i]) }
        return diff == 0
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock(); private var v: JSONValue?
        func set(_ x: JSONValue) { lock.lock(); v = x; lock.unlock() }
        var value: JSONValue? { lock.lock(); defer { lock.unlock() }; return v }
    }
}

/// The `bridge mcp` side: forwards tool listing and calls to the running app.
public struct AgentIPCClient: McpToolBackend {
    public let path: String
    public let token: String
    public init(path: String, token: String) { self.path = path; self.token = token }

    public func listTools() async throws -> [McpTool] {
        let result = try await roundTrip(method: "tools/list", params: .object([:]))
        return result.array("tools").compactMap { t in
            guard let n = t.string("name") else { return nil }
            return McpTool(name: n, title: t.string("title") ?? n, description: t.string("description") ?? "", inputSchema: t["inputSchema"] ?? .object(["type": .string("object")]))
        }
    }

    public func callTool(name: String, arguments: JSONValue) async -> McpToolResult {
        do {
            let r = try await roundTrip(method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]))
            return McpToolResult(text: r.string("text") ?? "", isError: r["isError"]?.boolValue ?? false)
        } catch AgentIPCError.connectFailed {
            return McpToolResult(text: "Bridge is not running or this assistant session has ended. Ask the user to reopen the assistant panel in Bridge.", isError: true)
        } catch {
            return McpToolResult(text: "Could not reach Bridge: \(error)", isError: true)
        }
    }

    func roundTrip(method: String, params: JSONValue) async throws -> JSONValue {
        let path = self.path, token = self.token
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { cont.resume(throwing: AgentIPCError.connectFailed(errno: errno)); return }
                defer { close(fd) }
                var addr = AgentIPCServer.address(path)
                let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                guard rc == 0 else { cont.resume(throwing: AgentIPCError.connectFailed(errno: errno)); return }
                let req = JSONValue.object(["id": .number(1), "token": .string(token), "method": .string(method), "params": params]).compactString() + "\n"
                let data = Data(req.utf8)
                var sent = 0
                data.withUnsafeBytes { raw in
                    while sent < data.count {
                        let n = write(fd, raw.baseAddress! + sent, data.count - sent)
                        if n <= 0 { if errno == EINTR { continue }; break }
                        sent += n
                    }
                }
                guard let line = LineReader(fd: fd, maxLine: 8 * 1024 * 1024).next(), let d = line.data(using: .utf8),
                      let resp = try? JSONValue.parse(d) else { cont.resume(throwing: AgentIPCError.badResponse); return }
                if resp["ok"]?.boolValue == true, let r = resp["result"] { cont.resume(returning: r) }
                else { cont.resume(throwing: AgentIPCError.rejected(resp.string("error") ?? "unknown")) }
            }
        }
    }
}
