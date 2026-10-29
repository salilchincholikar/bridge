import BridgeCore
import Foundation

/// The user's informed opt-in to the assistant, per provider. Off until given. Stored apart from settings so that saving settings
/// can never clobber it, and bumping `currentVersion` (when a disclosure changes) asks again.
public struct AgentConsent: Codable, Equatable, Sendable {
    public var version: Int
    /// provider id (`claude-code`, `codex`) to the time it was accepted.
    public var accepted: [String: Date]
    public init(version: Int, accepted: [String: Date]) { self.version = version; self.accepted = accepted }
}

public enum AgentConsentStore {
    public static let currentVersion = 2

    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment["BRIDGE_AGENT_CONSENT"], !p.isEmpty { return p }
        return NSHomeDirectory() + "/.config/bridge/agent-consent.json"
    }

    private static func load(_ path: String) -> AgentConsent? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let c = try? dec.decode(AgentConsent.self, from: data), c.version == currentVersion else { return nil }
        return c
    }

    public static func isGranted(_ provider: AgentProvider, path: String = defaultPath()) -> Bool {
        load(path)?.accepted[provider.rawValue] != nil
    }

    public static func grant(_ provider: AgentProvider, path: String = defaultPath(), now: Date = Date()) throws {
        var c = load(path) ?? AgentConsent(version: currentVersion, accepted: [:])
        c.accepted[provider.rawValue] = now
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = path + ".tmp-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: tmp, contents: try enc.encode(c), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp); throw CocoaError(.fileWriteUnknown) }
    }

    public static func revoke(_ provider: AgentProvider? = nil, path: String = defaultPath()) {
        guard let provider else { try? FileManager.default.removeItem(atPath: path); return }
        guard var c = load(path) else { return }
        c.accepted[provider.rawValue] = nil
        if c.accepted.isEmpty { try? FileManager.default.removeItem(atPath: path); return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(c) { FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) }
    }
}

/// The text the user must read before enabling the assistant. Kept in core so the UI and the docs cannot drift apart.
public enum AgentDisclosure {
    public static func title(_ p: AgentProvider) -> String { "Before you turn on the assistant (\(p.displayName))" }

    public static func points(_ p: AgentProvider) -> [String] {
        var out = [
            "What leaves your computer. Your messages, and whatever the assistant reads from AWS to answer (resource names, ARNs, account ids, configuration, log lines), are sent to \(p.company) by your own installed \(p.displayName). Bridge removes obvious secrets (keys, passwords, tokens) from results as a best effort. That is not a guarantee.",
            "What it can do. It has read-only tools for the profile in this tab (plus any listed under agent.profiles in your settings). Credentials, secrets and sensitive operations are never offered to it, and it cannot change anything in AWS. Every call is listed in the panel.",
        ]
        switch p {
        case .claudeCode:
            out += [
                "Your own login, and Anthropic's terms. Bridge starts the unmodified `claude` you installed and signed in to; it never reads or stores your tokens. Anthropic's documentation says developers building products should use API-key authentication, and its consumer terms restrict automated access except with an API key or where Anthropic permits it. Whether a personal app like this is permitted on your plan is not stated in the documentation, so you are responsible for checking that yourself.",
                "No other tools. Claude Code runs with all of its built-in tools turned off (no shell, no file access, no web) and only Bridge's tools, in an empty private folder.",
                "Local transcripts. Claude Code saves conversation transcripts on your computer, in plain text under ~/.claude/projects/, for 30 days by default. Anything the assistant read is in them.",
            ]
        case .codex:
            out += [
                "Your own login, and OpenAI's terms. Bridge starts the unmodified `codex` you installed and signed in to; it never reads or stores your login. OpenAI's documentation recommends API keys for automation and does not say whether a personal app like this is permitted with a ChatGPT-plan login, so you are responsible for checking that yourself.",
                "Locked down, and checked. Codex runs with its shell, file-viewing, web and connector tools turned off, in a read-only sandbox, in an empty private folder, ignoring your own Codex configuration. Bridge re-checks the tool list each time and refuses to use Codex if an update exposes a shell, web access or any tool it does not know. Some helpers cannot be removed: `apply_patch` (it cannot write in the read-only sandbox, and any file change stops the run), a JavaScript runner whose own abilities Bridge could not verify, and multi-agent helpers.",
                "Local sessions. Codex saves session files on your computer so follow-up messages work. Anything the assistant read is in them.",
            ]
        }
        return out
    }
}
