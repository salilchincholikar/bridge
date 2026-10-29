import AppKit
import BridgeCore

/// Where a link in one view should land in another.
enum Navigation: Equatable {
    case logGroup(String)
    case iamRole(String)
    case lambda(String)
    case sqsQueue(String)
    case s3Bucket(String)
}

@MainActor
final class AppModel {
    static var shared: AppModel!
    private(set) var runtime: BridgeRuntime
    private(set) var data: DataService?
    private(set) var windows: [TabWindowController] = []

    init(runtime: BridgeRuntime, data: DataService?) { self.runtime = runtime; self.data = data }

    @discardableResult
    func newTab(joining existing: TabWindowController? = nil, profile: String? = nil) -> TabWindowController {
        let starting = profile ?? existing?.tab.profile ?? runtime.config.profileNames.first ?? "default"
        let c = TabWindowController(app: self, profile: starting, region: existing?.tab.region)
        windows.append(c)
        if let existing, let host = existing.window, let win = c.window {
            host.addTabbedWindow(win, ordered: .above)
            win.makeKeyAndOrderFront(nil)
        } else {
            c.showWindow(nil)
        }
        return c
    }

    func applySettings(_ settings: BridgeSettings) async throws {
        let loaded = SettingsStore.load(path: runtime.settingsPath)
        guard !loaded.fileWasCorrupt else { throw ExecError.invalidRequest("The settings file could not be read. Repair it before saving.") }
        guard settings.validate().isEmpty else { throw ExecError.invalidRequest(settings.validate().joined(separator: "\n")) }
        try SettingsStore.save(settings, path: runtime.settingsPath)
        for w in windows { w.tab.cancelAll(); w.agentPanel?.shutdown() }
        runtime = await BridgeRuntime.load().discoveringProfiles()
        data = await runtime.makeDataService()
        for w in windows { w.settingsChanged() }
    }

    func closed(_ c: TabWindowController) { windows.removeAll { $0 === c } }
}

/// One tab: its OWN profile, region, time range and selection. Nothing here is shared between tabs, so two
/// accounts can be compared side by side. Switching profile or region cancels the tab's in-flight work, and a
/// result that arrives for an older context is dropped instead of being shown (docs/technical.md 4.8).
@MainActor
final class TabModel {
    let id = UUID()
    unowned let app: AppModel
    private(set) var profile: String
    private(set) var region: String
    private(set) var windowSeconds: TimeInterval = 900
    private(set) var window: TimeWindow
    private(set) var identity: VerifiedIdentity?
    var section: AppSection = .lambda
    private(set) var lastRefresh: Date?
    var pendingNavigation: Navigation?
    var pendingInvestigation: Investigation?
    /// Describes what is selected in the current view (set by the window controller).
    var selectionProvider: (() -> String?)?

    var onContextChanged: (() -> Void)?
    var onIdentityChanged: (() -> Void)?
    var onRefreshed: (() -> Void)?
    var onNavigate: ((Navigation) -> Void)?

    let commandActivity = CommandActivity()

    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(app: AppModel, profile: String, region: String?) {
        self.app = app
        self.profile = profile
        self.region = region ?? app.runtime.region(for: profile) ?? "us-east-1"
        self.window = TimeWindow.last(900)
    }

    // MARK: Settings-derived

    var policy: ProfilePolicy { app.runtime.settings.policy(for: profile) }
    var isProtected: Bool { policy.protected }
    var envColor: NSColor? { Theme.color(named: app.runtime.settings.profiles[profile]?.color) }
    var label: String { app.runtime.settings.profiles[profile]?.label ?? profile }
    var suggestsProtection: Bool { !isProtected && BridgeSettings.looksLikeProduction(profile) }

    // MARK: Context

    /// A plain-text snapshot of what the user is looking at, given to the assistant with each message.
    func contextSnapshot() -> String {
        var lines = ["Profile: \(label) (\(profile)) · region \(region)"]
        if let id = identity { lines[0] += " · account \(id.account) · \(id.arn)" }
        var view = "View: \(section.title)"
        if let sel = selectionProvider?() { view += " · selected: \(sel)" }
        lines.append(view)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append("Time range: last \(Format.duration(Int(windowSeconds))) (\(f.string(from: window.start)) to \(f.string(from: window.end)) local time)")
        return lines.joined(separator: "\n")
    }

    func reloadSettings() {
        cancelAll(); identity = nil
        region = app.runtime.region(for: profile) ?? region
        window = TimeWindow.last(windowSeconds)
        onContextChanged?()
    }

    func setProfile(_ p: String) {
        guard p != profile else { return }
        cancelAll()
        profile = p
        region = app.runtime.region(for: p) ?? region
        identity = nil
        window = TimeWindow.last(windowSeconds)
        onContextChanged?()
    }

    func setRegion(_ r: String) {
        guard r != region else { return }
        cancelAll()
        region = r
        identity = nil
        window = TimeWindow.last(windowSeconds)
        onContextChanged?()
    }

    func setWindowSeconds(_ s: TimeInterval) {
        guard s != windowSeconds else { return }
        cancelAll()
        windowSeconds = s
        window = TimeWindow.last(s)
        onContextChanged?()
    }

    /// Called by Refresh: a fresh window (the previous one is dropped as stale if its results arrive late).
    func refreshWindow() { window = TimeWindow.last(windowSeconds) }

    func navigate(_ n: Navigation) { pendingNavigation = n; onNavigate?(n) }

    // MARK: Work

    @discardableResult
    func track(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let key = UUID()
        let task = Task { [weak self] in
            await work()
            self?.tasks[key] = nil
        }
        tasks[key] = task
        return task
    }
    func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }

    private func requestContext(usesWindow: Bool) -> RequestContext {
        RequestContext(tabId: id, profile: profile, region: region, accountId: identity?.account, window: usesWindow ? window : nil)
    }

    @discardableResult
    func verifyIdentity(force: Bool = false) async throws -> VerifiedIdentity {
        guard let data = app.data else { throw ExecError.spawnFailed(errno: ENOENT) }
        let issuedFor = requestContext(usesWindow: false)
        // Approval must happen before STS can resolve credentials. Only human UI paths present this dialog.
        while let approval = try CredentialProcessTrust.requiredApproval(profile: profile, environment: ProcessInfo.processInfo.environment) {
            let alert = NSAlert()
            alert.messageText = "Allow this AWS credential helper?"
            alert.informativeText = "Profile: \(approval.profile)\n\n\(approval.command)\n\nAWS CLI will run this local program to obtain credentials. Approve only a command you recognize. Changing it will require approval again."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Allow Helper")
            guard alert.runModal() == .alertSecondButtonReturn else { throw CancellationError() }
            let loaded = SettingsStore.load(path: app.runtime.settingsPath)
            guard !loaded.fileWasCorrupt else { throw CredentialTrustError.unreadableConfiguration }
            try SettingsStore.save(loaded.settings.confirmingCredentialProcess(profile: approval.profile, command: approval.command), path: app.runtime.settingsPath)
        }
        let id = try await data.identityStore().identity(for: profile, region: region, force: force)
        guard ViewContext(requestContext(usesWindow: false)).accepts(issuedFor) else { throw CancellationError() }
        identity = id
        onIdentityChanged?()
        return id
    }

    /// Fetch through `DataService`. Returns nil if the tab moved on while the request was running.
    func fetch(_ request: ExecRequest, usesWindow: Bool = false, refresh: Bool = false, global: Bool = false) async throws -> Fetched? {
        guard let data = app.data else { throw ExecError.spawnFailed(errno: ENOENT) }
        if identity == nil { try await verifyIdentity() }
        try Task.checkCancellation()
        let issuedFor = requestContext(usesWindow: usesWindow)
        let activityID = commandActivity.begin(request)
        do {
            var fetched = try await data.fetch(request, tab: id, window: usesWindow ? window : nil, refresh: refresh)
            try Task.checkCancellation()
            if global { fetched.context.region = issuedFor.region }
            guard ViewContext(requestContext(usesWindow: usesWindow)).accepts(fetched.context), issuedFor.profile == profile else {
                commandActivity.fail(activityID, error: CancellationError()); return nil
            }
            commandActivity.finish(activityID, result: fetched.result, cached: fetched.fromCache, maskPaths: fetched.maskPaths)
            if !fetched.fromCache { lastRefresh = Date() } else if lastRefresh == nil { lastRefresh = Date().addingTimeInterval(-fetched.age) }
            onRefreshed?()
            return fetched
        } catch {
            commandActivity.fail(activityID, error: error)
            throw error
        }
    }

    func fetchPages(_ request: ExecRequest, usesWindow: Bool = false, refresh: Bool = false, maxPages: Int = 10) async throws -> [Fetched]? {
        var pages: [Fetched] = []
        var request = request
        for _ in 0..<max(1, maxPages) {
            guard let page = try await fetch(request, usesWindow: usesWindow, refresh: refresh) else { return nil }
            pages.append(page)
            guard let next = page.result.nextToken, request.maxItems != nil else { break }
            request.startingToken = next
        }
        return pages
    }

    /// Authorize something the UI runs itself (a download), with this tab's verified identity and the profile's limits.
    func authorize(_ request: ExecRequest, confirmed: Bool = false) -> Authorizer.Outcome {
        let state: IdentityState = identity.map { .verified(account: $0.account, arn: $0.arn) } ?? .unverified
        let ctx = AuthContext(caller: .human, profile: policy, agentMaxTier: app.runtime.settings.agentMaxTier, identity: state)
        return Authorizer().authorize(request, context: ctx, confirmed: confirmed)
    }

    /// `aws sso login` for this tab's profile, streaming the device code. Re-verifies identity on success.
    func signIn(onPrompt: @escaping @Sendable (SsoLoginPrompt) -> Void) async throws {
        guard let aws = app.runtime.awsPath else { throw ExecError.spawnFailed(errno: ENOENT) }
        try await SsoLogin(awsPath: aws).login(profile: profile, onPrompt: onPrompt)
        await app.data?.invalidateIdentity(profile)
        identity = nil
    }
}

enum ErrorText {
    /// A short message for the banner and whether signing in would help.
    static func describe(_ error: Error) -> (message: String, needsSignIn: Bool) {
        switch error {
        case let error as CredentialTrustError: return (error.localizedDescription, false)
        case ExecError.authExpired: return ("This profile is not signed in, or its session expired.", true)
        case DataError.denied(let r): return (policy(r), false)
        case IdentityError.denied(let r): return (policy(r), false)
        case ExecError.commandFailed(_, let s): return (s.isEmpty ? "The AWS CLI reported an error." : s, false)
        case ExecError.timedOut(let n): return ("Timed out after \(Int(n)) s.", false)
        case ExecError.outputTooLarge: return ("The result was too large to load. Narrow the search or time range.", false)
        case ExecError.spawnFailed: return ("The AWS CLI was not found. Install it, or set aws_path in ~/.config/bridge/config.json.", false)
        case ExecError.invalidJSON: return ("The AWS CLI returned something that was not JSON.", false)
        case IdentityError.malformedResponse: return ("Could not verify the account for this profile.", false)
        case let t as TransferError: return ("Download failed: \(t)", false)
        default: return ("\(error)", false)
        }
    }

    static func policy(_ r: DenyReason) -> String {
        switch r {
        case .unsupported: return "Not allowed: this operation is not in the supported set."
        case .credentialClass: return "Not allowed: credential-producing operations are never available."
        case .aboveCap(let need, let cap): return "Needs tier \(need.rawValue) (\(need)); this profile is limited to tier \(cap.rawValue) (\(cap)). Raise max_tier in ~/.config/bridge/config.json."
        case .identityNotVerified: return "The account could not be verified yet."
        case .identityMismatch(let e, let a): return "Expected account \(e) but this profile resolves to \(a)."
        case .sensitiveHiddenFromAgent: return "Sensitive results are not available to agents."
        case .deniedParameter(let p): return "The parameter \(p) is not allowed."
        case .confirmationRequired: return "This action needs confirmation."
        case .invalidRequest(let m): return "Invalid request: \(m)"
        }
    }
}
