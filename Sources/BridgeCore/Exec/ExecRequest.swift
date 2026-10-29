import Foundation

/// A request to run one AWS CLI operation. `service` and `operation` are CLI names
/// (`lambda`, `list-functions`; S3's API commands are `s3api`). `params` use API parameter names
/// (`FunctionName`), nested as needed, and travel via `--cli-input-json`.
///
/// There is deliberately no field for `--profile`-style global options other than profile and region:
/// the executor owns every other global option (docs/technical.md 4.4).
public struct ExecRequest: Equatable, Sendable {
    public var profile: String
    public var region: String
    public var service: String
    public var operation: String
    public var params: JSONValue?
    public var maxItems: Int?
    public var startingToken: String?
    public var timeout: TimeInterval
    public var requestId: UUID

    public init(profile: String, region: String, service: String, operation: String, params: JSONValue? = nil,
                maxItems: Int? = nil, startingToken: String? = nil, timeout: TimeInterval = 60, requestId: UUID = UUID()) {
        self.profile = profile
        self.region = region
        self.service = service
        self.operation = operation
        self.params = params
        self.maxItems = maxItems
        self.startingToken = startingToken
        self.timeout = timeout
        self.requestId = requestId
    }

    /// Returns a description of the first problem, or nil if the request is well formed.
    /// This is argument-injection protection: nothing that reaches the argument vector may look like a flag.
    public func validate() -> String? {
        if !Self.isSafeToken(service) { return "invalid service name: \(service.debugDescription)" }
        if !Self.isSafeToken(operation) { return "invalid operation name: \(operation.debugDescription)" }
        if !Self.isSafeToken(region) { return "invalid region: \(region.debugDescription)" }
        if !Self.isSafeProfileName(profile) { return "invalid profile name: \(profile.debugDescription)" }
        if let p = params {
            guard case .object(let o) = p else { return "params must be a JSON object" }
            if let bad = o.keys.first(where: { $0.isEmpty || $0.hasPrefix("-") }) { return "invalid parameter name: \(bad.debugDescription)" }
        }
        if let m = maxItems, m <= 0 { return "maxItems must be positive" }
        if let t = startingToken, t.isEmpty || t.hasPrefix("-") { return "invalid starting token" }
        if timeout <= 0 { return "timeout must be positive" }
        return nil
    }

    /// Profile names come from the user's own config and may contain spaces, but never a leading "-"
    /// (it could be read as a flag) or control characters.
    public static func isSafeProfileName(_ p: String) -> Bool {
        !p.isEmpty && !p.hasPrefix("-") && p.count <= 128
            && !p.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    /// Lowercase letters, digits and hyphens, starting with a letter or digit.
    public static func isSafeToken(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !s.isEmpty, s.count <= 64 else { return false }
        func lowerAlnum(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "0" && c <= "9") }
        guard lowerAlnum(first) else { return false }
        return s.unicodeScalars.allSatisfy { lowerAlnum($0) || $0 == "-" }
    }
}

public struct ExecResult: Sendable {
    public var request: ExecRequest
    public var commandDisplay: String
    public var json: JSONValue?
    public var nextToken: String?
    public var stderr: String
    public var durationMs: Double
    public var fetchedAt: Date
    /// True when the operation is classed sensitive: callers must not cache, log or persist `json`.
    public var sensitive: Bool

    public init(request: ExecRequest, commandDisplay: String, json: JSONValue?, nextToken: String?, stderr: String,
                durationMs: Double, fetchedAt: Date, sensitive: Bool) {
        self.request = request
        self.commandDisplay = commandDisplay
        self.json = json
        self.nextToken = nextToken
        self.stderr = stderr
        self.durationMs = durationMs
        self.fetchedAt = fetchedAt
        self.sensitive = sensitive
    }
}

public enum ExecError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case spawnFailed(errno: Int32)
    case timedOut(seconds: Double)
    case outputTooLarge(limitBytes: Int)
    case invalidJSON(String)
    /// The SSO session or token expired or is missing. Heuristic match on stderr text `[unverified]`.
    case authExpired(stderr: String)
    case commandFailed(status: Int32, stderr: String)

    /// Classify a failed run from its stderr. Patterns are from memory of the CLI's messages and are
    /// unverified against current CLI versions; a wrong guess only affects which message the UI shows.
    static func fromFailure(status: Int32, stderr: String) -> ExecError {
        let s = stderr.lowercased()
        let expiredHints = ["token has expired", "sso session associated with this profile has expired",
                            "error loading sso token", "expiredtoken", "the sso session", "refresh token has expired",
                            "unable to locate credentials"]
        if expiredHints.contains(where: { s.contains($0) }) { return .authExpired(stderr: stderr) }
        return .commandFailed(status: status, stderr: stderr)
    }
}
