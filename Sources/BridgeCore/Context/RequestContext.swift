import Foundation

/// What a request was issued for. Captured when the request is SENT and carried back with its result.
public struct RequestContext: Equatable, Sendable {
    public var tabId: UUID
    public var profile: String
    public var region: String
    /// The verified account at dispatch time; nil if identity was not yet verified.
    public var accountId: String?
    public var window: TimeWindow?

    public init(tabId: UUID, profile: String, region: String, accountId: String? = nil, window: TimeWindow? = nil) {
        self.tabId = tabId
        self.profile = profile
        self.region = region
        self.accountId = accountId
        self.window = window
    }
}

/// The context a tab is showing now. A result is rendered only if it was issued for this exact context;
/// otherwise it is dropped, so nothing is ever shown under a header from a different account, region
/// or time range (docs/technical.md 4.8). Each tab owns one; tabs do not share context.
public struct ViewContext: Equatable, Sendable {
    public var current: RequestContext

    public init(_ current: RequestContext) { self.current = current }

    public func accepts(_ tag: RequestContext) -> Bool {
        guard tag.tabId == current.tabId, tag.profile == current.profile, tag.region == current.region,
              tag.window == current.window else { return false }
        // Both known: they must agree. A result issued before the identity was verified is still the same profile.
        if let a = tag.accountId, let b = current.accountId, a != b { return false }
        return true
    }
}
