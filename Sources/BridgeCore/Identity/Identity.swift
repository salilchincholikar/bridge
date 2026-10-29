import Foundation

/// The account and principal a profile REALLY resolves to, from `sts get-caller-identity`
/// (docs/technical.md 4.3). Shown on every view and used by the policy and the cache.
public struct VerifiedIdentity: Equatable, Sendable {
    public var account: String
    public var arn: String
    public var userId: String

    public init(account: String, arn: String, userId: String) {
        self.account = account
        self.arn = arn
        self.userId = userId
    }
}

public enum IdentityError: Error, Equatable, Sendable {
    case denied(DenyReason)
    case malformedResponse
}

public enum IdentityProbe {
    /// Runs `sts get-caller-identity` through the same authorizer and executor as everything else.
    public static func verify(profile: String, region: String, executor: any ExecutionBackend,
                              authorizer: Authorizer = Authorizer()) async throws -> VerifiedIdentity {
        let request = ExecRequest(profile: profile, region: region, service: "sts", operation: "get-caller-identity", timeout: 30)
        switch authorizer.authorize(request, context: AuthContext()) {
        case .deny(let reason): throw IdentityError.denied(reason)
        case .allow(let authorized, _):
            try executor.checkCredentialTrust(profile: profile)
            let result = try await executor.run(authorized)
            guard let account = result.json?["Account"]?.stringValue, let arn = result.json?["Arn"]?.stringValue,
                  account.count == 12, account.allSatisfy(\.isNumber), arn.hasPrefix("arn:") else { throw IdentityError.malformedResponse }
            return VerifiedIdentity(account: account, arn: arn, userId: result.json?["UserId"]?.stringValue ?? "")
        }
    }
}

/// Remembers verified identities per profile and de-duplicates concurrent probes for the same profile.
public actor IdentityStore {
    private var verified: [String: VerifiedIdentity] = [:]
    private var inflight: [String: Task<VerifiedIdentity, Error>] = [:]
    private let probe: @Sendable (String, String) async throws -> VerifiedIdentity

    public init(probe: @escaping @Sendable (String, String) async throws -> VerifiedIdentity) { self.probe = probe }

    public init(executor: any ExecutionBackend, authorizer: Authorizer = Authorizer()) {
        self.probe = { profile, region in try await IdentityProbe.verify(profile: profile, region: region, executor: executor, authorizer: authorizer) }
    }

    public func state(for profile: String) -> IdentityState {
        if let v = verified[profile] { return .verified(account: v.account, arn: v.arn) }
        return .unverified
    }

    public func identity(for profile: String, region: String, force: Bool = false) async throws -> VerifiedIdentity {
        if !force, let v = verified[profile] { return v }
        if let task = inflight[profile] { return try await task.value }
        let probe = self.probe
        let task = Task { try await probe(profile, region) }
        inflight[profile] = task
        defer { inflight[profile] = nil }
        let v = try await task.value
        verified[profile] = v
        return v
    }

    /// Call after an auth failure or an SSO login: the next use re-verifies.
    public func invalidate(_ profile: String) { verified[profile] = nil }
}
