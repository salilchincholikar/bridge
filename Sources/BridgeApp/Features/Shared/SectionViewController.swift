import AppKit
import BridgeCore

/// Each service owns its content and errors; the window owns shared navigation and command history.
@MainActor
class SectionViewController: NSViewController {
    let tab: TabModel
    let banner = Banner()
    let content = NSView()
    private var signInText = ""
    private var noticesHeight: NSLayoutConstraint?

    init(tab: TabModel) {
        self.tab = tab
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        for child in [banner, content] as [NSView] { child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child) }
        noticesHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor), banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), noticesHeight!,
            content.topAnchor.constraint(equalTo: banner.bottomAnchor), content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        banner.onVisibilityChanged = { [weak self] in self?.noticesHeight?.constant = self?.banner.isHidden == true ? 0 : 60 }
        view = root
        build()
    }

    /// Cmd-F uses the page's first native search field; logs override this to focus the event pattern.
    var preferredSearchField: NSSearchField? {
        func find(_ node: NSView) -> NSSearchField? {
            if let field = node as? NSSearchField { return field }
            for child in node.subviews { if let field = find(child) { return field } }
            return nil
        }
        return find(content)
    }

    /// Override: create subviews inside `content`.
    func build() {}
    /// Override: load data. `refresh` bypasses the cache.
    func reload(refresh: Bool) {}
    func deactivate() {}
    func contextWillChange() { deactivate(); clearError() }
    /// Override: a short description of what is selected, for the assistant's context.
    var selectionDescription: String? { nil }
    /// Override: react to a link from another view.
    func handle(_ navigation: Navigation) {}

    /// Run a loading job on the tab; errors become the banner. Cancelled work (the tab moved on) is silent.
    func run(_ work: @escaping @MainActor () async throws -> Void) {
        tab.track { [weak self] in
            do { try await work() }
            catch is CancellationError {}
            catch { self?.present(error) }
        }
    }

    func clearError() { banner.hide() }

    func present(_ error: Error) {
        let (message, needsSignIn) = ErrorText.describe(error)
        if needsSignIn {
            banner.show(message, style: .warning, actionTitle: "Sign in") { [weak self] in self?.startSignIn() }
        } else {
            banner.show(message, style: .error, actionTitle: "Retry") { [weak self] in self?.reload(refresh: true) }
        }
    }

    /// Sign in from the banner, showing the device URL and code as soon as the CLI prints them.
    func startSignIn() {
        signInText = ""
        banner.show("Signing in… a browser window should open.", style: .info)
        run { [weak self] in
            guard let self else { return }
            do {
                try await self.tab.signIn { prompt in
                    Task { @MainActor [weak self] in
                        var parts: [String] = []
                        if let c = prompt.userCode { parts.append("enter the code \(c)") }
                        if let u = prompt.url { parts.append("at \(u)") }
                        if !parts.isEmpty { self?.banner.show("Signing in: " + parts.joined(separator: " "), style: .info) }
                    }
                }
                self.banner.hide()
                self.reload(refresh: true)
            } catch is CancellationError {
            } catch {
                self.banner.show("Sign-in failed: \(error)", style: .error, actionTitle: "Try again") { [weak self] in self?.startSignIn() }
            }
        }
    }
}
