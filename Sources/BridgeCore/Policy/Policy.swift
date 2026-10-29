import Foundation

// Action policy (docs/technical.md 4.5). Authorization comes from an EXPLICIT table. Operation-name
// prefixes (list-/describe-/get-) are never used to authorize anything: SQS `receive-message` looks like a
// read but changes message visibility, and several get-* calls return secrets.

public enum Tier: Int, Comparable, Sendable, CustomStringConvertible {
    case read = 1              // list/describe/get
    case transfer = 2          // writes a file to local disk (S3 download)
    case reversibleChange = 3  // e.g. stop a task, receive a message
    case destructive = 4       // e.g. delete

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    public var description: String {
        switch self {
        case .read: return "read"
        case .transfer: return "transfer"
        case .reversibleChange: return "reversible change"
        case .destructive: return "destructive"
        }
    }
}

public enum Caller: Equatable, Sendable {
    case human
    case agent
}

public struct PolicyEntry: Equatable, Sendable {
    public var tier: Tier
    /// Returns credentials (access keys, tokens, passwords). Always denied.
    public var credential: Bool
    /// Returns secret material. Never cached or logged, and hidden from agents.
    public var sensitive: Bool
    /// API parameter names that must not be set to a truthy value (e.g. `Unmask`).
    public var deniedParams: [String]
    /// Dotted paths in the result the UI must mask until revealed (e.g. `Code.Location`).
    public var maskPaths: [String]
    public var costsMoney: Bool
    public var note: String?

    public init(tier: Tier = .read, credential: Bool = false, sensitive: Bool = false, deniedParams: [String] = [],
                maskPaths: [String] = [], costsMoney: Bool = false, note: String? = nil) {
        self.tier = tier
        self.credential = credential
        self.sensitive = sensitive
        self.deniedParams = deniedParams
        self.maskPaths = maskPaths
        self.costsMoney = costsMoney
        self.note = note
    }
}

public struct PolicyTable: Sendable {
    public var entries: [String: PolicyEntry]
    public init(entries: [String: PolicyEntry]) { self.entries = entries }

    public static func key(_ service: String, _ operation: String) -> String { "\(service) \(operation)" }
    public func entry(service: String, operation: String) -> PolicyEntry? { entries[Self.key(service, operation)] }
}

/// Per-profile settings that matter to policy (docs/technical.md 4.2).
public struct ProfilePolicy: Equatable, Sendable {
    public var maxTier: Tier
    public var protected: Bool
    public var expectedAccount: String?
    public init(maxTier: Tier = .transfer, protected: Bool = false, expectedAccount: String? = nil) {
        self.maxTier = maxTier
        self.protected = protected
        self.expectedAccount = expectedAccount
    }
}

public enum IdentityState: Equatable, Sendable {
    case unverified
    case verified(account: String, arn: String)
}

public struct AuthContext: Sendable {
    public var caller: Caller
    public var profile: ProfilePolicy
    /// Hard cap for agent calls (default: read only). An approval can raise a single call, never this cap.
    public var agentMaxTier: Tier
    public var identity: IdentityState
    public init(caller: Caller = .human, profile: ProfilePolicy = ProfilePolicy(), agentMaxTier: Tier = .read,
                identity: IdentityState = .unverified) {
        self.caller = caller
        self.profile = profile
        self.agentMaxTier = agentMaxTier
        self.identity = identity
    }
}

public enum Confirmation: Equatable, Sendable {
    case none
    case click
    /// The user must type the resource name (tier 4, or tier 3 on a protected profile).
    case typeName
}

public enum DenyReason: Equatable, Sendable {
    /// Not in the table. The default for every unlisted operation.
    case unsupported
    /// Credential-producing operation (access keys, session tokens, login passwords).
    case credentialClass
    case aboveCap(required: Tier, cap: Tier)
    case identityNotVerified
    case identityMismatch(expected: String, actual: String)
    case sensitiveHiddenFromAgent
    case deniedParameter(String)
    case confirmationRequired(Confirmation)
    case invalidRequest(String)
}

/// Proof that a request passed `Authorizer`. Only this module can create one, and `CLIExecutor` only
/// runs these, so the policy cannot be bypassed by calling the executor directly.
public struct AuthorizedRequest: Sendable {
    public let request: ExecRequest
    public let tier: Tier
    public let sensitive: Bool
    public let maskPaths: [String]
    public let costsMoney: Bool
    init(request: ExecRequest, tier: Tier, sensitive: Bool, maskPaths: [String], costsMoney: Bool) {
        self.request = request
        self.tier = tier
        self.sensitive = sensitive
        self.maskPaths = maskPaths
        self.costsMoney = costsMoney
    }
}

public struct Authorizer: Sendable {
    public var table: PolicyTable
    public init(table: PolicyTable = .standard) { self.table = table }

    public enum Outcome: Sendable {
        case allow(AuthorizedRequest, confirmation: Confirmation)
        case deny(DenyReason)
    }

    /// Decide whether `request` may run. `confirmed` states whether the user already completed whatever
    /// confirmation the returned outcome would require; if not, the result is `deny(.confirmationRequired)`
    /// which tells the UI what to ask for.
    public func authorize(_ request: ExecRequest, context: AuthContext, confirmed: Bool = false) -> Outcome {
        if let problem = request.validate() { return .deny(.invalidRequest(problem)) }
        guard let entry = table.entry(service: request.service, operation: request.operation) else { return .deny(.unsupported) }
        if entry.credential { return .deny(.credentialClass) }

        if case .object(let params) = request.params ?? .null {
            for denied in entry.deniedParams {
                if let v = params.first(where: { $0.key.lowercased() == denied.lowercased() })?.value, v.isTruthy {
                    return .deny(.deniedParameter(denied))
                }
            }
        }

        if context.caller == .agent && entry.sensitive { return .deny(.sensitiveHiddenFromAgent) }

        let cap = context.caller == .agent ? min(context.profile.maxTier, context.agentMaxTier) : context.profile.maxTier
        if entry.tier > cap { return .deny(.aboveCap(required: entry.tier, cap: cap)) }

        if entry.tier >= .reversibleChange {
            switch context.identity {
            case .unverified:
                return .deny(.identityNotVerified)
            case .verified(let account, _):
                if let expected = context.profile.expectedAccount, expected != account {
                    return .deny(.identityMismatch(expected: expected, actual: account))
                }
            }
        }

        let confirmation: Confirmation
        switch entry.tier {
        case .read, .transfer: confirmation = .none
        case .reversibleChange: confirmation = context.profile.protected ? .typeName : .click
        case .destructive: confirmation = .typeName
        }
        if confirmation != .none && !confirmed { return .deny(.confirmationRequired(confirmation)) }

        return .allow(AuthorizedRequest(request: request, tier: entry.tier, sensitive: entry.sensitive,
                                        maskPaths: entry.maskPaths, costsMoney: entry.costsMoney),
                      confirmation: confirmation)
    }
}
