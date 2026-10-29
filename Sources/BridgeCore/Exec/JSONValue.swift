import Foundation

/// A small, Sendable JSON value. Used for request parameters and AWS CLI output.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: any)
    }

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            // NSNumber also bridges Bool; tell them apart by CF type.
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundationObject }
        case .object(let o): return o.mapValues { $0.foundationObject }
        }
    }

    /// Compact JSON with sorted keys (stable, so it is usable in cache keys).
    public func data(pretty: Bool = false) throws -> Data {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        if pretty { opts.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: foundationObject, options: opts)
    }

    public func compactString() -> String {
        (try? data()).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Dotted path lookup: `value["Code.Location"]` style, via `value(at:)`.
    public func value(at path: String) -> JSONValue? {
        var cur: JSONValue? = self
        for part in path.split(separator: ".") { cur = cur?[String(part)] }
        return cur
    }

    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var intValue: Int? {
        if case .number(let n) = self, n == n.rounded(), abs(n) < 9.0e15 { return Int(n) }
        return nil
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    // Path helpers for parsing AWS responses defensively: a missing or wrongly typed field yields nil/empty,
    // never a crash, because response shapes are only as reliable as our memory of them.
    public func string(_ path: String) -> String? { value(at: path)?.stringValue }
    public func int(_ path: String) -> Int? { value(at: path)?.intValue }
    public func double(_ path: String) -> Double? { value(at: path)?.doubleValue }
    public func array(_ path: String) -> [JSONValue] { value(at: path)?.arrayValue ?? [] }
    public func strings(_ path: String) -> [String] { array(path).compactMap { $0.stringValue } }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isEmptyContainer: Bool {
        switch self {
        case .object(let o): return o.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }

    /// "Truthy" for deny-parameter checks: anything except null, false, "" and empty containers.
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .string(let s): return !s.isEmpty
        case .number: return true
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }
}
