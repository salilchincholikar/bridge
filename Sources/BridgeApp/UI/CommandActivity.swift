import Foundation
import BridgeCore

/// Bounded, memory-only trace for one tab. Raw sensitive results never enter this model.
@MainActor
final class CommandActivity {
    struct Entry {
        let id: UUID
        let title: String
        let command: String
        let started: Date
        var status = "Running"
        var output = "Waiting for the AWS CLI…"
        var running = true
    }
    private(set) var entries: [Entry] = []
    private(set) var selectedID: UUID?
    private var followLatest = true
    var onChange: (() -> Void)?
    var selected: Entry? { entries.first { $0.id == selectedID } }
    var runningCount: Int { entries.filter(\.running).count }

    @discardableResult
    func begin(_ request: ExecRequest) -> UUID {
        let id = UUID()
        let command = Self.preview(Redactor.redact(CLIExecutor.commandDisplay(for: request)).text)
        entries.append(Entry(id: id, title: request.service + " " + request.operation, command: command, started: Date()))
        if entries.count > 20 { entries.removeFirst(entries.count - 20) }
        if followLatest || selected == nil { selectedID = id }
        onChange?()
        return id
    }
    func finish(_ id: UUID, result: ExecResult, cached: Bool = false, maskPaths: [String] = []) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.running }) else { return }
        let output: String
        if result.sensitive {
            output = "Sensitive response omitted from history. Inspect it in the service view."
        } else if let json = result.json {
            let masked = Redactor.mask(json, paths: maskPaths + ["Configuration.Environment.Variables", "Environment.Variables"])
            let text = (try? masked.data(pretty: true)).map { String(decoding: $0, as: UTF8.self) } ?? "No JSON output."
            output = Self.preview(Redactor.redact(text).text)
        } else { output = "Completed with no JSON output." }
        entries[index].output = output
        entries[index].status = cached ? "Cached" : "Exit 0 · \(Int(result.durationMs.rounded())) ms"
        entries[index].running = false
        onChange?()
    }
    func fail(_ id: UUID, error: Error) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.running }) else { return }
        if error is CancellationError {
            entries[index].status = "Cancelled"; entries[index].output = "Request cancelled."
        } else {
            if case ExecError.commandFailed(let code, _) = error { entries[index].status = "Exit \(code)" }
            else { entries[index].status = "Failed" }
            entries[index].output = Self.preview(Redactor.redact(ErrorText.describe(error).message).text)
        }
        entries[index].running = false
        onChange?()
    }
    func select(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        selectedID = id; followLatest = id == entries.last?.id; onChange?()
    }
    func clear() { entries.removeAll(); selectedID = nil; followLatest = true; onChange?() }
    func cancelRunning() {
        for index in entries.indices where entries[index].running {
            entries[index].running = false; entries[index].status = "Cancelled"; entries[index].output = "Request cancelled."
        }
        onChange?()
    }
    private static func preview(_ text: String) -> String {
        text.count > 32_768 ? String(text.prefix(32_768)) + "\n[Preview truncated]" : text
    }
}
