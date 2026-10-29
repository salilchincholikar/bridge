import Foundation

public enum DataError: Error, Equatable, Sendable {
    case denied(DenyReason)
}

public struct Fetched: Sendable {
    public var result: ExecResult
    /// What this was issued for. Compare with the tab's `ViewContext` before rendering.
    public var context: RequestContext
    public var identity: VerifiedIdentity?
    public var fromCache: Bool
    /// Seconds since the data was fetched (0 for a fresh result).
    public var age: TimeInterval
    public var tier: Tier
    public var maskPaths: [String]
    public var costsMoney: Bool
}

/// The ONE way views get AWS data: verify identity, authorize, consult the cache, execute, store.
/// A view that goes through this cannot skip the policy, show another account's cached data, or cache a secret.
public actor DataService {
    private let executor: any ExecutionBackend
    private let authorizer: Authorizer
    private let identities: IdentityStore
    private let cache: ResultCache
    private let settings: @Sendable () -> BridgeSettings
    private let cliVersion: String

    public init(executor: any ExecutionBackend, authorizer: Authorizer = Authorizer(), identities: IdentityStore? = nil,
                cache: ResultCache = ResultCache(), settings: @escaping @Sendable () -> BridgeSettings = { BridgeSettings() },
                cliVersion: String = "unknown") {
        self.executor = executor
        self.authorizer = authorizer
        self.identities = identities ?? IdentityStore(executor: executor, authorizer: authorizer)
        self.cache = cache
        self.settings = settings
        self.cliVersion = cliVersion
    }

    public func identityStore() -> IdentityStore { identities }

    /// - Parameter confirmed: whether the user already completed the confirmation the policy asks for (tier 3+).
    public func fetch(_ request: ExecRequest, tab: UUID, window: TimeWindow? = nil, caller: Caller = .human,
                      refresh: Bool = false, confirmed: Bool = false) async throws -> Fetched {
        let cfg = settings()
        try executor.checkCredentialTrust(profile: request.profile)
        // Identity first: it is part of the cache key and of tier 3+ authorization. The identity probe is itself
        // a tier-1 call and is exempt from this step (it is how identity gets established).
        let isIdentityProbe = request.service == "sts" && request.operation == "get-caller-identity"
        var identity: VerifiedIdentity?
        if !isIdentityProbe { identity = try await identities.identity(for: request.profile, region: request.region) }

        let state: IdentityState = identity.map { .verified(account: $0.account, arn: $0.arn) } ?? .unverified
        let ctx = AuthContext(caller: caller, profile: cfg.policy(for: request.profile), agentMaxTier: cfg.agentMaxTier, identity: state)
        let authorized: AuthorizedRequest
        switch authorizer.authorize(request, context: ctx, confirmed: confirmed) {
        case .allow(let a, _): authorized = a
        case .deny(let reason): throw DataError.denied(reason)
        }

        let tag = RequestContext(tabId: tab, profile: request.profile, region: request.region, accountId: identity?.account, window: window)

        var key: CacheKey?
        if let identity {
            key = CacheKey(request: request, identity: identity, window: window, cliVersion: cliVersion)
            if !refresh, let key, let hit = await cache.get(key) {
                return Fetched(result: hit.result, context: tag, identity: identity, fromCache: true, age: hit.age,
                               tier: authorized.tier, maskPaths: authorized.maskPaths, costsMoney: authorized.costsMoney)
            }
        }

        var result: ExecResult
        do {
            result = try await executor.run(authorized)
        } catch let e as ExecError {
            if case .authExpired = e { await identities.invalidate(request.profile) } // force re-verification after login
            throw e
        }
        // Sensitivity is policy-owned, even when an injected adapter returns an incorrect flag.
        result.sensitive = result.sensitive || authorized.sensitive
        if let key { await cache.put(key, result) }
        return Fetched(result: result, context: tag, identity: identity, fromCache: false, age: 0,
                       tier: authorized.tier, maskPaths: authorized.maskPaths, costsMoney: authorized.costsMoney)
    }

    /// Follows `NextToken` until the result is complete or `maxPages` is reached.
    public func fetchPages(_ request: ExecRequest, tab: UUID, window: TimeWindow? = nil, caller: Caller = .human,
                           refresh: Bool = false, maxPages: Int = 10) async throws -> [Fetched] {
        var pages: [Fetched] = []
        var req = request
        for _ in 0..<max(1, maxPages) {
            let page = try await fetch(req, tab: tab, window: window, caller: caller, refresh: refresh)
            pages.append(page)
            guard let next = page.result.nextToken, request.maxItems != nil else { break }
            req.startingToken = next
        }
        return pages
    }

    public func invalidateIdentity(_ profile: String) async { await identities.invalidate(profile) }
    public func clearCache() async { await cache.removeAll() }
}

extension CLIExecutor {
    /// `aws --version` parsed to e.g. "2.37.9", or "unknown". No network, no credentials.
    public func version() async -> String {
        guard let out = try? await ProcessRunner.run(executable: awsPath, arguments: ["--version"],
                                                     environment: Self.sanitizedEnvironment(from: environment),
                                                     timeout: 15, stdoutCap: 4096),
              out.status == 0 else { return "unknown" }
        let text = String(decoding: out.stdout + out.stderr, as: UTF8.self) // older CLIs print the version on stderr
        if let r = text.range(of: #"aws-cli/[0-9][0-9.]*"#, options: .regularExpression) { return String(text[r].dropFirst("aws-cli/".count)) }
        return "unknown"
    }
}
