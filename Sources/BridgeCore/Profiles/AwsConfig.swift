import Foundation

// Parses ~/.aws/config. The trust checker also supplies a metadata-only projection of the credentials file.
// Read-only: nothing here writes to the file. Secret-bearing keys are dropped at parse time,
// so a parsed AwsConfig can be logged or shown in the UI without leaking key material.

public struct SsoSession: Equatable, Sendable {
    public var name: String
    public var startUrl: String?
    public var region: String?
    public var registrationScopes: String?

    public init(name: String, startUrl: String? = nil, region: String? = nil, registrationScopes: String? = nil) {
        self.name = name; self.startUrl = startUrl; self.region = region; self.registrationScopes = registrationScopes
    }
}

public enum ProfileKind: Equatable, Sendable {
    /// `sso_session = x` (the current IAM Identity Center setup).
    case sso(session: String)
    /// `sso_start_url` directly on the profile (legacy IAM Identity Center setup).
    case legacySso
    /// `role_arn` with either `source_profile` or `credential_source`.
    case assumeRole(source: String?, credentialSource: String?)
    /// `credential_process = <command>`: the CLI runs this command. See docs/technical.md 4.1.
    case credentialProcess(command: String)
    /// Access keys written inside the config file itself (values are NOT kept).
    case staticKeysInConfig
    /// Nothing in this file says where credentials come from (the credentials file or environment may supply them).
    case sharedCredentials
}

public struct AwsProfile: Equatable, Sendable {
    public var name: String
    public var kind: ProfileKind
    public var region: String?
    public var accountId: String?      // sso_account_id, or parsed from role_arn
    public var roleName: String?       // sso_role_name, or parsed from role_arn
    public var roleArn: String?
    public var sourceProfile: String?
    /// All settings except secret-bearing keys.
    public var settings: [String: String]
    /// Sub-settings such as `s3 =` blocks (nested, indented key = value lines).
    public var nested: [String: [String: String]]

    public init(name: String, kind: ProfileKind, region: String? = nil, accountId: String? = nil, roleName: String? = nil,
                roleArn: String? = nil, sourceProfile: String? = nil, settings: [String: String] = [:],
                nested: [String: [String: String]] = [:]) {
        self.name = name; self.kind = kind; self.region = region; self.accountId = accountId; self.roleName = roleName
        self.roleArn = roleArn; self.sourceProfile = sourceProfile; self.settings = settings; self.nested = nested
    }
}

public struct RoleChain: Equatable, Sendable {
    /// Profile names from the starting profile down to the first profile that is not an assume-role profile.
    public var profiles: [String]
    public var hasCycle: Bool
    /// A `source_profile` that does not exist in the file.
    public var missingProfile: String?

    public init(profiles: [String], hasCycle: Bool, missingProfile: String? = nil) {
        self.profiles = profiles
        self.hasCycle = hasCycle
        self.missingProfile = missingProfile
    }
}

public struct AwsConfig: Equatable, Sendable {
    public var profiles: [String: AwsProfile]
    public var ssoSessions: [String: SsoSession]
    /// Problems worth showing to the user (malformed lines, dangling references). Never fatal.
    public var warnings: [String]

    public init(profiles: [String: AwsProfile] = [:], ssoSessions: [String: SsoSession] = [:], warnings: [String] = []) {
        self.profiles = profiles; self.ssoSessions = ssoSessions; self.warnings = warnings
    }

    /// Profile names, `default` first, the rest alphabetical.
    public var profileNames: [String] {
        let rest = profiles.keys.filter { $0 != "default" }.sorted()
        return (profiles["default"] != nil ? ["default"] : []) + rest
    }

    public func profile(named name: String) -> AwsProfile? { profiles[name] }

    /// Merge CLI-discovered names (including credentials-only profiles), preserving config metadata.
    public func addingProfileNames(_ names: [String]) -> AwsConfig {
        var result = self
        for name in names where !name.isEmpty && result.profiles[name] == nil {
            result.profiles[name] = AwsProfile(name: name, kind: .sharedCredentials)
        }
        for name in result.profileNames {
            if case .assumeRole = result.profiles[name]?.kind,
               result.roleChain(from: name).missingProfile == nil {
                result.warnings.removeAll { $0.hasPrefix("profile \(name): source_profile ") && $0.hasSuffix(" is not defined") }
            }
        }
        return result
    }

    /// Follows `source_profile` links. Detects cycles and dangling references.
    public func roleChain(from name: String) -> RoleChain {
        var chain: [String] = []
        var seen = Set<String>()
        var current: String? = name
        while let n = current {
            if seen.contains(n) { return RoleChain(profiles: chain, hasCycle: true, missingProfile: nil) }
            guard let p = profiles[n] else { return RoleChain(profiles: chain, hasCycle: false, missingProfile: n) }
            seen.insert(n)
            chain.append(n)
            if case .assumeRole(let source, _) = p.kind { current = source } else { current = nil }
        }
        return RoleChain(profiles: chain, hasCycle: false, missingProfile: nil)
    }
}

public enum AwsConfigParser {
    /// Keys whose values are secrets. They are never stored.
    static let secretKeys: Set<String> = ["aws_access_key_id", "aws_secret_access_key", "aws_session_token"]

    private struct RawSection {
        var header: String
        var items: [(key: String, value: String)] = []
        var nested: [String: [String: String]] = [:]
        var lastIndent = Int.max
    }

    public static func parse(_ text: String) -> AwsConfig {
        var warnings: [String] = []
        var sections: [RawSection] = []

        var lineNo = 0
        // `isNewline` also matches "\r\n", which Swift treats as ONE Character (splitting on "\n" misses CRLF files).
        // (Blank lines are kept so the line numbers in warnings match the file.)
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            lineNo += 1
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]") else {
                    warnings.append("line \(lineNo): unterminated section header: \(trimmed)")
                    sections.append(RawSection(header: "?invalid"))
                    continue
                }
                let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                sections.append(RawSection(header: inner))
                continue
            }

            guard !sections.isEmpty else {
                warnings.append("line \(lineNo): setting before any [section]")
                continue
            }
            let idx = sections.count - 1
            let indented = line.first == " " || line.first == "\t"
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count

            if indented, indent > sections[idx].lastIndent, let last = sections[idx].items.last {
                if last.value.isEmpty, let eq = trimmed.firstIndex(of: "=") {
                    // Nested block:  s3 =\n  max_concurrent_requests = 20
                    let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    sections[idx].nested[last.key, default: [:]][k] = v
                } else {
                    // Continuation of a multi-line value.
                    sections[idx].items[sections[idx].items.count - 1].value += "\n" + trimmed
                }
                continue
            }

            guard let eq = trimmed.firstIndex(of: "=") else {
                warnings.append("line \(lineNo): not a `key = value` line: \(trimmed)")
                continue
            }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            sections[idx].items.append((key: key, value: value))
            sections[idx].lastIndent = indent
        }

        var profileSettings: [String: [String: String]] = [:]
        var profileNested: [String: [String: [String: String]]] = [:]
        var profileHasKeys: Set<String> = []
        var sso: [String: [String: String]] = [:]

        func unquote(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
                return String(t.dropFirst().dropLast())
            }
            return t
        }

        for s in sections {
            var profileName: String?
            var ssoName: String?
            if s.header == "default" || s.header == "profile default" {
                profileName = "default"
            } else if s.header.hasPrefix("profile ") {
                profileName = unquote(String(s.header.dropFirst("profile ".count)))
            } else if s.header.hasPrefix("sso-session ") {
                ssoName = unquote(String(s.header.dropFirst("sso-session ".count)))
            } else {
                continue // [services x], [plugins], invalid headers, ...: not profiles
            }

            if let name = profileName {
                if profileSettings[name] != nil { warnings.append("profile \(name) is defined more than once; later values win") }
                for (k, v) in s.items {
                    if secretKeys.contains(k) { profileHasKeys.insert(name); continue }
                    profileSettings[name, default: [:]][k] = v
                }
                if profileSettings[name] == nil { profileSettings[name] = [:] }
                for (k, v) in s.nested { profileNested[name, default: [:]][k] = v }
            } else if let name = ssoName {
                if sso[name] != nil { warnings.append("sso-session \(name) is defined more than once; later values win") }
                for (k, v) in s.items { sso[name, default: [:]][k] = v }
                if sso[name] == nil { sso[name] = [:] }
            }
        }

        var sessions: [String: SsoSession] = [:]
        for (name, d) in sso {
            sessions[name] = SsoSession(name: name, startUrl: d["sso_start_url"], region: d["sso_region"],
                                        registrationScopes: d["sso_registration_scopes"])
            if d["sso_start_url"] == nil || d["sso_region"] == nil {
                warnings.append("sso-session \(name) is missing sso_start_url or sso_region")
            }
        }

        var profiles: [String: AwsProfile] = [:]
        for (name, d) in profileSettings {
            let kind = classify(d, hasStaticKeys: profileHasKeys.contains(name))
            let arn = d["role_arn"]
            let parsed = arn.flatMap(parseRoleArn)
            profiles[name] = AwsProfile(
                name: name, kind: kind, region: d["region"],
                accountId: d["sso_account_id"] ?? parsed?.account,
                roleName: d["sso_role_name"] ?? parsed?.role,
                roleArn: arn, sourceProfile: d["source_profile"],
                settings: d, nested: profileNested[name] ?? [:])
        }

        let cfg = AwsConfig(profiles: profiles, ssoSessions: sessions, warnings: warnings)
        return cfg.withDanglingReferenceWarnings()
    }

    static func classify(_ d: [String: String], hasStaticKeys: Bool) -> ProfileKind {
        if let cp = d["credential_process"] { return .credentialProcess(command: cp) }
        if let s = d["sso_session"] { return .sso(session: s) }
        if d["sso_start_url"] != nil { return .legacySso }
        if d["role_arn"] != nil { return .assumeRole(source: d["source_profile"], credentialSource: d["credential_source"]) }
        if hasStaticKeys { return .staticKeysInConfig }
        return .sharedCredentials
    }

    /// `arn:aws:iam::123456789012:role/path/Name` -> (account, "Name")
    public static func parseRoleArn(_ arn: String) -> (account: String, role: String)? {
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 6, parts[0] == "arn", parts[2] == "iam", parts[5].hasPrefix("role/") else { return nil }
        let name = parts[5...].joined(separator: ":").split(separator: "/").last.map(String.init) ?? ""
        return (String(parts[4]), name)
    }
}

extension AwsConfig {
    fileprivate func withDanglingReferenceWarnings() -> AwsConfig {
        var out = self
        for name in profileNames {
            guard let p = profiles[name] else { continue }
            switch p.kind {
            case .sso(let session):
                if ssoSessions[session] == nil { out.warnings.append("profile \(name): sso-session \(session) is not defined") }
                if p.accountId == nil || p.roleName == nil { out.warnings.append("profile \(name): sso_account_id or sso_role_name is missing") }
            case .legacySso:
                for key in ["sso_region", "sso_account_id", "sso_role_name"] where p.settings[key] == nil {
                    out.warnings.append("profile \(name): legacy SSO setting \(key) is missing")
                }
            case .assumeRole:
                let chain = roleChain(from: name)
                if chain.hasCycle { out.warnings.append("profile \(name): source_profile chain has a cycle") }
                if let missing = chain.missingProfile, missing != name { out.warnings.append("profile \(name): source_profile \(missing) is not defined") }
            default: break
            }
        }
        return out
    }
}

public enum AwsConfigLoader {
    /// `AWS_CONFIG_FILE` if given, else `~/.aws/config`. The environment is passed in explicitly so callers
    /// (and tests) decide what to honor; the executor's own env allowlist is separate.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment["AWS_CONFIG_FILE"], !p.isEmpty { return p }
        return NSHomeDirectory() + "/.aws/config"
    }

    /// A missing file is not an error: it yields an empty config.
    public static func load(path: String) throws -> AwsConfig {
        guard FileManager.default.fileExists(atPath: path) else { return AwsConfigParser.parse("") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return AwsConfigParser.parse(String(decoding: data, as: UTF8.self))
    }
}
