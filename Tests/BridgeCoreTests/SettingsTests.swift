import Foundation
import BridgeCore

func runSettingsTests() {
    section("settings: defaults, tiers, protected, expected account") {
        let s = BridgeSettings()
        expect(s.policy(for: "anything") == ProfilePolicy(maxTier: .transfer, protected: false, expectedAccount: nil), "defaults: tier 2, not protected")
        expect(s.agentMaxTier == .read, "agent defaults to read-only")
        expect(s.agentProfiles.isEmpty, "agent has no profiles by default")

        var cfg = BridgeSettings(defaultMaxTier: 1)
        cfg.profiles["example-prod"] = ProfileSettings(protected: true, maxTier: 2, expectedAccount: "222222222222")
        cfg.profiles["example-dev"] = ProfileSettings(maxTier: 3)
        expect(cfg.policy(for: "unlisted").maxTier == .read, "default_max_tier applies to unlisted profiles")
        expect(cfg.policy(for: "example-dev").maxTier == .reversibleChange, "per-profile tier")
        expect(cfg.policy(for: "example-prod") == ProfilePolicy(maxTier: .transfer, protected: true, expectedAccount: "222222222222"), "protected + expected account carried")
    }

    section("settings: out-of-range values never fail open") {
        let json = #"{"default_max_tier": 9, "agent": {"max_tier": 7, "profiles": ["dev"]}, "profiles": {"p": {"max_tier": 0, "expected_account": "12ab"}}}"#
        let s = try! JSONDecoder().decode(BridgeSettings.self, from: Data(json.utf8))
        expect(s.policy(for: "p").maxTier == .transfer, "invalid profile tier falls back to the built-in default, not to a high tier")
        expect(s.agentMaxTier == .read, "invalid agent tier falls back to read")
        expect(s.agentProfiles == ["dev"], "agent profiles read")
        let problems = s.validate()
        expect(problems.count == 4, "four problems reported, got \(problems)")
        expect(problems.contains { $0.contains("expected_account") }, "bad expected_account reported")
    }

    section("settings: tolerant decoding") {
        let s = try? JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"future_field": {"a": 1}, "profiles": {"x": {"label": "X", "unknown": true}}}"#.utf8))
        expect(s?.profiles["x"]?.label == "X", "unknown keys are ignored")
        let empty = try? JSONDecoder().decode(BridgeSettings.self, from: Data("{}".utf8))
        expect(empty == BridgeSettings(), "an empty object is the default settings")
        let wrongTypes = try? JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"profiles": 5, "agent": "x", "default_max_tier": "two"}"#.utf8))
        expect(wrongTypes == BridgeSettings(), "wrong types fall back to defaults instead of failing")
    }

    section("settings: file round trip, permissions, corruption") {
        let dir = NSTemporaryDirectory() + "bridge-settings-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/nested/config.json"
        expect(SettingsStore.load(path: path).settings == BridgeSettings() && !SettingsStore.load(path: path).fileWasCorrupt, "missing file: defaults, not corrupt")

        var s = BridgeSettings(defaultMaxTier: 2, awsPath: "/opt/homebrew/bin/aws")
        s.profiles["example-prod"] = ProfileSettings(label: "PROD", color: "red", protected: true, maxTier: 1, defaultRegion: "eu-west-1", expectedAccount: "222222222222")
        s.agent = AgentSettings(maxTier: 1, profiles: ["example-dev"])
        try? SettingsStore.save(s, path: path)
        let back = SettingsStore.load(path: path)
        expect(back.settings == s && back.warnings.isEmpty, "round trip equal, no warnings")
        func perms(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        expect(perms(path) == 0o600, "file is 0600, got \(String(perms(path), radix: 8))")
        expect(perms(dir + "/nested") == 0o700, "directory is 0700, got \(String(perms(dir + "/nested"), radix: 8))")
        expect(((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains("\"max_tier\""), "snake_case keys on disk")

        try? Data("{ this is not json".utf8).write(to: URL(fileURLWithPath: path))
        let bad = SettingsStore.load(path: path)
        expect(bad.fileWasCorrupt && bad.settings == BridgeSettings() && bad.warnings.count == 1, "corrupt file: defaults + one warning + corrupt flag")
        expect((try? String(contentsOfFile: path, encoding: .utf8)) == "{ this is not json", "loading never rewrites a corrupt file")
    }

    section("settings: credential_process trust is per profile and per command") {
        let s = BridgeSettings()
        expect(s.needsCredentialProcessConfirmation(profile: "proc", command: "/usr/local/bin/get-creds --profile proc"), "first use needs confirmation")
        let trusted = s.confirmingCredentialProcess(profile: "proc", command: "/usr/local/bin/get-creds --profile proc")
        expect(!trusted.needsCredentialProcessConfirmation(profile: "proc", command: "/usr/local/bin/get-creds --profile proc"), "confirmed command is trusted")
        expect(trusted.needsCredentialProcessConfirmation(profile: "proc", command: "/usr/local/bin/get-creds --profile proc --evil"), "ANY change to the command needs confirmation again")
        expect(trusted.needsCredentialProcessConfirmation(profile: "other", command: "/usr/local/bin/get-creds --profile proc"), "trust does not transfer between profiles")
        let stored = trusted.confirmedCredentialProcess["proc"] ?? ""
        expect(stored.count == 64 && !stored.contains("get-creds"), "only a SHA-256 hash is stored, never the command")
        expect(BridgeSettings.commandHash("a") == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb", "hash is standard SHA-256")
    }

    section("settings: production-looking names are suggestions only") {
        expect(BridgeSettings.looksLikeProduction("example-prod") && BridgeSettings.looksLikeProduction("Prod-EU") && BridgeSettings.looksLikeProduction("acme-production"), "prod-like names detected")
        expect(!BridgeSettings.looksLikeProduction("example-dev") && !BridgeSettings.looksLikeProduction("dev") && !BridgeSettings.looksLikeProduction("sandbox"), "others not")
        expect(BridgeSettings().policy(for: "example-prod").protected == false, "never automatically protected")
    }
}
