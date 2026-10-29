import Foundation
import CryptoKit

// Bridge settings (docs/technical.md 4.2). JSON at ~/.config/bridge/config.json. No credentials, ever.
// There is ONE permission knob per profile: `max_tier`. There is no separate "writes" flag.

public struct ProfileSettings: Codable, Equatable, Sendable {
    public var label: String?
    public var color: String?              // "red", "orange", ... used by the UI for the environment strip
    public var protected: Bool?
    public var maxTier: Int?               // 1...4
    public var defaultRegion: String?
    public var expectedAccount: String?    // 12 digits; a mismatch with the verified identity blocks tier 3+

    public init(label: String? = nil, color: String? = nil, protected: Bool? = nil, maxTier: Int? = nil,
                defaultRegion: String? = nil, expectedAccount: String? = nil) {
        self.label = label; self.color = color; self.protected = protected; self.maxTier = maxTier
        self.defaultRegion = defaultRegion; self.expectedAccount = expectedAccount
    }

    enum CodingKeys: String, CodingKey {
        case label, color, protected
        case maxTier = "max_tier"
        case defaultRegion = "default_region"
        case expectedAccount = "expected_account"
    }
}

public struct AgentSettings: Codable, Equatable, Sendable {
    public var maxTier: Int?
    public var profiles: [String]?
    public init(maxTier: Int? = nil, profiles: [String]? = nil) { self.maxTier = maxTier; self.profiles = profiles }
    enum CodingKeys: String, CodingKey { case maxTier = "max_tier", profiles }
}

public struct BridgeSettings: Codable, Equatable, Sendable {
    public var version: Int
    public var defaultMaxTier: Int?
    public var profiles: [String: ProfileSettings]
    public var agent: AgentSettings
    /// profile name -> SHA-256 of the `credential_process` command the user already approved.
    public var confirmedCredentialProcess: [String: String]
    /// Overrides the discovered `aws` binary.
    public var awsPath: String?

    public init(version: Int = 1, defaultMaxTier: Int? = nil, profiles: [String: ProfileSettings] = [:],
                agent: AgentSettings = AgentSettings(), confirmedCredentialProcess: [String: String] = [:], awsPath: String? = nil) {
        self.version = version; self.defaultMaxTier = defaultMaxTier; self.profiles = profiles; self.agent = agent
        self.confirmedCredentialProcess = confirmedCredentialProcess; self.awsPath = awsPath
    }

    enum CodingKeys: String, CodingKey {
        case version, profiles, agent
        case defaultMaxTier = "default_max_tier"
        case confirmedCredentialProcess = "confirmed_credential_process"
        case awsPath = "aws_path"
    }

    // Tolerant decoding: every field optional, unknown keys ignored, so an older or hand-edited file still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        defaultMaxTier = try? c.decode(Int.self, forKey: .defaultMaxTier)
        profiles = (try? c.decode([String: ProfileSettings].self, forKey: .profiles)) ?? [:]
        agent = (try? c.decode(AgentSettings.self, forKey: .agent)) ?? AgentSettings()
        confirmedCredentialProcess = (try? c.decode([String: String].self, forKey: .confirmedCredentialProcess)) ?? [:]
        awsPath = try? c.decode(String.self, forKey: .awsPath)
    }

    public static let builtInDefaultTier: Tier = .transfer
    public static let builtInAgentTier: Tier = .read

    static func tier(_ raw: Int?) -> Tier? { raw.flatMap { Tier(rawValue: $0) } }

    /// The effective policy for a profile. An out-of-range tier falls back to the default rather than failing open.
    public func policy(for profile: String) -> ProfilePolicy {
        let p = profiles[profile]
        let fallback = Self.tier(defaultMaxTier) ?? Self.builtInDefaultTier
        return ProfilePolicy(maxTier: Self.tier(p?.maxTier) ?? fallback, protected: p?.protected ?? false,
                             expectedAccount: p?.expectedAccount)
    }

    /// Hard cap for agent calls.
    public var agentMaxTier: Tier { Self.tier(agent.maxTier) ?? Self.builtInAgentTier }

    /// Profiles an agent session may use by default (empty means none).
    public var agentProfiles: [String] { agent.profiles ?? [] }

    /// The UI may suggest marking a profile protected when its name suggests production (never automatic).
    public static func looksLikeProduction(_ profileName: String) -> Bool {
        let n = profileName.lowercased()
        return n.contains("prod") || n.hasSuffix("-prd") || n.contains("production")
    }

    /// Problems found in values that were out of range or malformed.
    public func validate() -> [String] {
        var out: [String] = []
        if let t = defaultMaxTier, Tier(rawValue: t) == nil { out.append("default_max_tier \(t) is not 1-4; using \(Self.builtInDefaultTier.rawValue)") }
        if let t = agent.maxTier, Tier(rawValue: t) == nil { out.append("agent.max_tier \(t) is not 1-4; using \(Self.builtInAgentTier.rawValue)") }
        for (name, p) in profiles.sorted(by: { $0.key < $1.key }) {
            if let t = p.maxTier, Tier(rawValue: t) == nil { out.append("profile \(name): max_tier \(t) is not 1-4; using the default") }
            if let a = p.expectedAccount, !(a.count == 12 && a.allSatisfy(\.isNumber)) { out.append("profile \(name): expected_account must be 12 digits") }
        }
        return out
    }

    // MARK: credential_process trust (docs/technical.md 4.1)

    /// The CLI runs `credential_process` commands from the config file. The first use per profile, and any change
    /// to the command, needs a one-time confirmation. Only a hash of the command is stored.
    public static func commandHash(_ command: String) -> String {
        SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func needsCredentialProcessConfirmation(profile: String, command: String) -> Bool {
        confirmedCredentialProcess[profile] != Self.commandHash(command)
    }
    public func confirmingCredentialProcess(profile: String, command: String) -> BridgeSettings {
        var s = self
        s.confirmedCredentialProcess[profile] = Self.commandHash(command)
        return s
    }
}

public enum SettingsStore {
    public static func defaultPath() -> String { NSHomeDirectory() + "/.config/bridge/config.json" }

    public struct Loaded: Sendable {
        public var settings: BridgeSettings
        public var warnings: [String]
        /// True when the file existed but could not be parsed. Callers must NOT overwrite it blindly.
        public var fileWasCorrupt: Bool
    }

    /// A missing file yields defaults. A corrupt file yields defaults plus a warning and `fileWasCorrupt`.
    public static func load(path: String = defaultPath()) -> Loaded {
        guard FileManager.default.fileExists(atPath: path) else {
            return Loaded(settings: BridgeSettings(), warnings: [], fileWasCorrupt: false)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return Loaded(settings: BridgeSettings(), warnings: ["could not read \(path)"], fileWasCorrupt: true)
        }
        do {
            let s = try JSONDecoder().decode(BridgeSettings.self, from: data)
            return Loaded(settings: s, warnings: s.validate(), fileWasCorrupt: false)
        } catch {
            return Loaded(settings: BridgeSettings(), warnings: ["\(path) is not valid JSON; using defaults (the file was left untouched)"], fileWasCorrupt: true)
        }
    }

    /// Atomic write (temp file + rename) into a 0700 directory, file mode 0600.
    public static func save(_ settings: BridgeSettings, path: String = defaultPath()) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(settings)
        let tmp = path + ".tmp-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp); throw CocoaError(.fileWriteUnknown) }
    }
}
