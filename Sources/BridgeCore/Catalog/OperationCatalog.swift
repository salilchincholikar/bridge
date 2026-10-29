import Foundation

public struct OperationField: Sendable {
    public let name: String
    public let type: String
    public let required: Bool
    public let choices: [String]
    public let children: [OperationField]
}
public struct CatalogOperation: Sendable {
    public let service: String
    public let operation: String
    public let fields: [OperationField]
    public let collection: String?
    public let paginated: Bool
    public var title: String { service + " " + operation }

    public func parameters(_ values: [String: String]) throws -> JSONValue {
        var out: [String: JSONValue] = [:]
        for f in fields {
            let raw = (values[f.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                if f.required { throw ExecError.invalidRequest("\(f.name) is required") }; continue
            }
            let value: JSONValue
            if ["structure", "list", "map", "boolean", "integer", "long", "float", "double"].contains(f.type) {
                guard let parsed = try? JSONValue.parse(Data(raw.utf8)) else { throw ExecError.invalidRequest("\(f.name) needs valid \(f.type) JSON") }
                switch f.type {
                case "structure", "map": guard parsed.objectValue != nil else { throw ExecError.invalidRequest("\(f.name) needs an object") }
                case "list": guard parsed.arrayValue != nil else { throw ExecError.invalidRequest("\(f.name) needs an array") }
                case "boolean": guard parsed.boolValue != nil else { throw ExecError.invalidRequest("\(f.name) needs true or false") }
                default:
                    guard parsed.doubleValue != nil, !["integer", "long"].contains(f.type) || parsed.intValue != nil else { throw ExecError.invalidRequest("\(f.name) needs a \(f.type) number") }
                }
                value = parsed
            } else {
                guard f.choices.isEmpty || f.choices.contains(raw) else { throw ExecError.invalidRequest("\(f.name) must be one of \(f.choices.joined(separator: ", "))") }
                value = .string(raw)
            }
            out[f.name] = value
        }
        return .object(out)
    }
}

/// Offline model metadata is for forms only. The explicit policy table remains the authority.
public enum OperationCatalog {
    public static func discover() -> String? {
        let fm = FileManager.default
        func dirs(_ p: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted().reversed() }
        if let override = ProcessInfo.processInfo.environment["BRIDGE_MODEL_PATH"], fm.fileExists(atPath: override + "/lambda") { return override }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let cellar = prefix + "/Cellar/awscli"
            for version in dirs(cellar) {
                let lib = cellar + "/" + version + "/libexec/lib"
                for python in dirs(lib) where python.hasPrefix("python") {
                    let path = lib + "/" + python + "/site-packages/awscli/botocore/data"
                    if fm.fileExists(atPath: path + "/lambda") { return path }
                }
            }
        }
        for version in dirs("/usr/local/aws-cli/v2") {
            let path = "/usr/local/aws-cli/v2/" + version + "/dist/awscli/botocore/data"
            if fm.fileExists(atPath: path + "/lambda") { return path }
        }
        return nil
    }
    public static func cliName(_ api: String) -> String {
        api.replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1-$2", options: .regularExpression)
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
    }
    public static func load(path: String) -> [CatalogOperation] {
        var all: [CatalogOperation] = []
        let table = PolicyTable.standard
        for service in Set(table.entries.keys.compactMap { $0.split(separator: " ").first.map(String.init) }).sorted() {
            let dir = path + "/" + (service == "s3api" ? "s3" : service)
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().reversed()
            guard let version = versions.first(where: { FileManager.default.fileExists(atPath: dir + "/" + $0 + "/service-2.json") }) else { continue }
            let base = dir + "/" + version
            guard let data = FileManager.default.contents(atPath: base + "/service-2.json"), let model = try? JSONValue.parse(data) else { continue }
            let shapes = model["shapes"]?.objectValue ?? [:]
            let paginator = FileManager.default.contents(atPath: base + "/paginators-1.json").flatMap { try? JSONValue.parse($0) }
            func fields(_ shape: String, stack: [String] = []) -> [OperationField] {
                guard !stack.contains(shape), stack.count < 8, let def = shapes[shape] else { return [] }
                return (def["members"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { name, ref in
                    let key = ref.string("shape") ?? ""
                    let member = shapes[key]
                    return OperationField(name: name, type: member?.string("type") ?? "json", required: def.strings("required").contains(name),
                        choices: member?.strings("enum") ?? [], children: fields(key, stack: stack + [shape]))
                }
            }
            for (api, op) in model["operations"]?.objectValue ?? [:] {
                let name = cliName(api)
                guard let policy = table.entry(service: service, operation: name), policy.tier == .read, !policy.credential,
                      !policy.sensitive, !["start-live-tail", "start-query"].contains(name) else { continue }
                let pagination = paginator?["pagination"]?[api]
                let collection = pagination?["result_key"]?.stringValue ?? pagination?["result_key"]?.arrayValue?.first?.stringValue
                all.append(CatalogOperation(service: service, operation: name, fields: fields(op.string("input.shape") ?? ""), collection: collection, paginated: pagination != nil))
            }
        }
        return all.sorted { $0.title < $1.title }
    }
}
