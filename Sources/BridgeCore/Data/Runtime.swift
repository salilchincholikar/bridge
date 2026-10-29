import Foundation

/// Everything the app and the command line need, assembled in one place from the user's files.
/// Dev overrides (all optional): `BRIDGE_AWS_PATH` (use another `aws`, e.g. the test fake),
/// `BRIDGE_SETTINGS` (settings file), `AWS_CONFIG_FILE` (the AWS config to read).
public struct BridgeRuntime: Sendable {
    public var settings: BridgeSettings
    public var settingsWarnings: [String]
    public var settingsPath: String
    public var config: AwsConfig
    public var awsPath: String?
    public var executor: CLIExecutor?

    public static func awsPath(settings: BridgeSettings, environment: [String: String]) -> String? {
        if let p = environment["BRIDGE_AWS_PATH"], !p.isEmpty { return p }
        if let p = settings.awsPath, FileManager.default.isExecutableFile(atPath: p) { return p }
        return CLIExecutor.discoverAwsPath()
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgeRuntime {
        let settingsPath = environment["BRIDGE_SETTINGS"].flatMap { $0.isEmpty ? nil : $0 } ?? SettingsStore.defaultPath()
        let loaded = SettingsStore.load(path: settingsPath)
        let configPath = AwsConfigLoader.defaultPath(environment: environment)
        let config = (try? AwsConfigLoader.load(path: configPath)) ?? AwsConfigParser.parse("")
        let aws = awsPath(settings: loaded.settings, environment: environment)
        return BridgeRuntime(settings: loaded.settings, settingsWarnings: loaded.warnings, settingsPath: settingsPath, config: config,
                             awsPath: aws, executor: aws.map { CLIExecutor(awsPath: $0, environment: environment) })
    }

    /// Ask the CLI for the complete local profile list without reading credential material in Bridge.
    public func discoveringProfiles() async -> BridgeRuntime {
        guard let executor else { return self }
        var result = self
        do { result.config = config.addingProfileNames(try await executor.profileNames()) }
        catch { result.settingsWarnings.append("Could not discover all AWS profiles; showing config profiles only.") }
        return result
    }

    /// A data service wired to this runtime's settings. Nil if no `aws` binary was found.
    public func makeDataService() async -> DataService? {
        guard let executor else { return nil }
        let version = await executor.version()
        let snapshot = settings
        return DataService(executor: executor, settings: { snapshot }, cliVersion: version)
    }

    /// The region to use for a profile: explicit, then Bridge settings, then the AWS profile, then the default profile.
    public func region(for profile: String, explicit: String? = nil) -> String? {
        explicit ?? settings.profiles[profile]?.defaultRegion ?? config.profile(named: profile)?.region ?? config.profile(named: "default")?.region
    }
}
