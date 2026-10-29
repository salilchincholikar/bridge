import Foundation

/// Approval is for one exact command on one profile. Never include the command in diagnostics/history.
public struct CredentialProcessApproval: Equatable, Sendable {
    public let profile: String
    public let command: String
    public var hash: String { BridgeSettings.commandHash(command) }
}

public enum CredentialTrustError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case approvalRequired(CredentialProcessApproval)
    case unreadableConfiguration
    case invalidChain

    public var description: String { errorDescription ?? "Credential helper approval failed." }

    public var errorDescription: String? {
        switch self {
        case .approvalRequired(let approval):
            return "The credential helper for profile \(approval.profile) needs approval. Open this profile in Bridge, or review it with bridge trust-credential-process <profile>."
        case .unreadableConfiguration: return "Could not read AWS configuration or Bridge trust settings. No AWS process was started."
        case .invalidChain: return "The AWS source-profile chain is invalid. No AWS process was started."
        }
    }
}

/// Re-reads configuration before each credential-using child process, rather than trusting startup metadata.
/// This protects against accidental first use/changed helpers, not a hostile process editing files concurrently.
public enum CredentialProcessTrust {
    /// Keep only execution-related metadata. Credential values never enter the parsed trust model.
    private static func metadata(path: String, credentialsFile: Bool) throws -> AwsConfig {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return AwsConfig() }
        guard let text = String(data: data, encoding: .utf8) else { throw CredentialTrustError.unreadableConfiguration }
        let keys: Set<String> = ["credential_process", "source_profile", "role_arn"]
        var kept: [String] = []
        var aliases: [String: String] = [:]
        var relevant = false
        var previousIndent = Int.max
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(raw), trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            if trimmed.hasPrefix("[") {
                relevant = false; previousIndent = Int.max
                guard trimmed.hasSuffix("]") else { throw CredentialTrustError.unreadableConfiguration }
                // Never silently miss a profile whose escaped header this parser cannot resolve
                // exactly like the CLI. Literal credentials-file names use aliases below.
                guard credentialsFile || !trimmed.contains("\\") else { throw CredentialTrustError.unreadableConfiguration }
                if credentialsFile {
                    let name = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    // Credentials section names are literal; config profile headers are shell-unquoted.
                    // Parse through neutral aliases so a literal quote in a credentials name is preserved.
                    let alias = aliases[name] ?? "credentials-\(aliases.count)"
                    aliases[name] = alias
                    kept.append("[profile \(alias)]")
                } else { kept.append(trimmed) }
                continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if indent > previousIndent {
                if relevant { kept.append(line) }
                continue
            }
            previousIndent = indent
            guard let eq = trimmed.firstIndex(of: "=") else { throw CredentialTrustError.unreadableConfiguration }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            relevant = keys.contains(key)
            if relevant { kept.append(line) }
        }
        let parsed = AwsConfigParser.parse(kept.joined(separator: "\n"))
        guard !parsed.warnings.contains(where: { $0.hasPrefix("line ") || $0.contains("defined more than once") }) else {
            throw CredentialTrustError.unreadableConfiguration
        }
        if !credentialsFile { return parsed }
        var result = AwsConfig()
        for (name, alias) in aliases {
            if var profile = parsed.profiles[alias] {
                profile.name = name
                result.profiles[name] = profile
            }
        }
        return result
    }

    public static func requiredApproval(profile: String, config: AwsConfig, settings: BridgeSettings) throws -> CredentialProcessApproval? {
        var seen = Set<String>()
        var current: String? = profile
        while let name = current {
            guard seen.insert(name).inserted else { throw CredentialTrustError.invalidChain }
            // A missing config section can be a credentials-only profile. The CLI resolves it.
            guard let p = config.profiles[name] else { return nil }
            if let command = p.settings["credential_process"],
               settings.needsCredentialProcessConfirmation(profile: name, command: command) {
                return CredentialProcessApproval(profile: name, command: command)
            }
            current = p.sourceProfile
        }
        return nil
    }

    public static func requiredApproval(profile: String, environment: [String: String]) throws -> CredentialProcessApproval? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let configPath = environment["AWS_CONFIG_FILE"] ?? home + "/.aws/config"
        let credentialsPath = environment["AWS_SHARED_CREDENTIALS_FILE"] ?? home + "/.aws/credentials"
        let settingsPath = environment["BRIDGE_SETTINGS"].flatMap { $0.isEmpty ? nil : $0 } ?? SettingsStore.defaultPath()
        let loaded = SettingsStore.load(path: settingsPath)
        guard !loaded.fileWasCorrupt else { throw CredentialTrustError.unreadableConfiguration }
        do {
            var config = try metadata(path: configPath, credentialsFile: false)
            let credentials = try metadata(path: credentialsPath, credentialsFile: true)
            // Match botocore's credentials-file precedence without retaining access keys/tokens.
            for (name, metadata) in credentials.profiles {
                var profile = config.profiles[name] ?? metadata
                profile.settings.merge(metadata.settings) { _, new in new }
                profile.sourceProfile = metadata.settings["source_profile"] ?? profile.sourceProfile
                config.profiles[name] = profile
            }
            return try requiredApproval(profile: profile, config: config, settings: loaded.settings)
        } catch let error as CredentialTrustError { throw error }
        catch { throw CredentialTrustError.unreadableConfiguration }
    }

    public static func check(profile: String, environment: [String: String]) throws {
        if let approval = try requiredApproval(profile: profile, environment: environment) {
            throw CredentialTrustError.approvalRequired(approval)
        }
    }
}
