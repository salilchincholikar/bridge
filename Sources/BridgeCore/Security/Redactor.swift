import Foundation

/// Best-effort removal of secret-looking text before anything is returned to an agent (docs/technical.md 6.4).
/// This REDUCES leakage; it does not guarantee it. The real protections are the policy (sensitive and credential
/// operations are never offered to agents) and the profile allowlist.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
        return [
            (rx(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#), "[redacted private key]"),
            (rx(#"\b(AKIA|ASIA)[A-Z0-9]{16}\b"#), "[redacted AWS access key id]"),
            (rx(#"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#), "[redacted JWT]"),
            (rx(#"bearer\s+[A-Za-z0-9._~+/\-]{20,}=*"#, .caseInsensitive), "Bearer [redacted]"),
            // key = value / "key": "value" for secret-looking key names; keeps the key, replaces the value.
            (rx(#"(?i)((?:aws_?)?secret_?(?:access_?)?key|session_?token|password|passwd|pwd|api_?key|client_?secret|auth_?token|access_?token|private_?key)(["'\\\s]*[:=]["'\\\s]*)([^\s"'\\,;}\]]{6,})"#), "$1$2[redacted]"),
            // Deliberately NOT included: a catch-all for any long base64-looking run. It would mangle legitimate ids and log content.
        ]
    }()

    public struct Result: Equatable, Sendable {
        public var text: String
        public var redactions: Int
        public init(text: String, redactions: Int) { self.text = text; self.redactions = redactions }
    }

    public static func redact(_ s: String) -> Result {
        var text = s
        var count = 0
        for (regex, template) in rules {
            let range = NSRange(text.startIndex..., in: text)
            let n = regex.numberOfMatches(in: text, range: range)
            if n > 0 {
                count += n
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
            }
        }
        return Result(text: text, redactions: count)
    }

    /// Replace the values at dotted `paths` (for example `Code.Location`) with a marker.
    public static func mask(_ json: JSONValue, paths: [String]) -> JSONValue {
        var out = json
        for p in paths { out = replacing(out, path: p.split(separator: ".").map(String.init)) }
        return out
    }

    private static func replacing(_ v: JSONValue, path: [String]) -> JSONValue {
        guard let head = path.first else { return .string("[masked]") }
        switch v {
        case .object(var o):
            guard let child = o[head] else { return v }
            o[head] = replacing(child, path: Array(path.dropFirst()))
            return .object(o)
        case .array(let a):
            return .array(a.map { replacing($0, path: path) }) // apply the same path to every element
        default:
            return v
        }
    }
}
