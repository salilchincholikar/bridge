import BridgeUI
import AppKit
import BridgeCore
import BridgeAgents

/// The assistant panel: consent first, then a chat with a read-only, policy-enforced AWS assistant (docs/technical.md section 6).
/// Nothing is started, spawned or sent anywhere until the user accepts the disclosure for the chosen provider.
@MainActor
final class AgentPanelViewController: NSViewController, NSTextFieldDelegate {
    let tab: TabModel
    private let consentView = NSView()
    private let chatView = NSView()
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let status = label("", size: 11)
    private let scopeLabel = label("", size: 11)
    let transcript = TextPane(monospaced: false)
    let trace = DataTable(columns: [ColumnSpec("when", "Time", width: 62), ColumnSpec("call", "What it read", width: 190), ColumnSpec("result", "Result", width: 80)])
    private let input = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let newChatButton = NSButton(title: "New chat", target: nil, action: nil)
    private let banner = Banner()
    private var bannerHeight: NSLayoutConstraint?
    private var consentTitle = label("", size: 15, color: .labelColor)
    private let consentBody = TextPane(monospaced: false)

    private(set) var provider: AgentProvider
    private var session: AgentConversation?
    private var server: AgentIPCServer?
    private var running: Task<Void, Never>?
    private let storage = NSMutableAttributedString()
    private var streamStart: Int?
    private var streamedText = ""
    private(set) var bytesRead = 0
    /// For Codex: false until the tool-list self-check passed. Sending is blocked until then.
    private(set) var lockdownOK = true

    var isShowingConsent: Bool { !consentView.isHidden }
    var hasSession: Bool { session != nil }
    var isRunning: Bool { running != nil }
    var transcriptText: String { storage.string }
    private static let providerKey = "bridge.agent.provider"

    init(tab: TabModel) {
        self.tab = tab
        let saved = UserDefaults.standard.string(forKey: Self.providerKey).flatMap(AgentProvider.init(rawValue:))
        provider = saved ?? (AgentHarness.discoverClaude() != nil ? .claudeCode : (CodexHarness.discover() != nil ? .codex : .claudeCode))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        view = root
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        buildConsent()
        buildChat()
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close assistant") ?? NSImage(), target: self, action: #selector(closePanel))
        close.bezelStyle = .inline; close.isBordered = false
        let heading = label("Assistant", size: 13, color: .labelColor); heading.font = .boldSystemFont(ofSize: 13)
        let header = WorkspaceLayout.toolbar([heading, NSView(), providerPopup, close])
        header.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(header)
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12)])
        for v in [consentView, chatView] {
            v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v)
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8), v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.trailingAnchor.constraint(equalTo: root.trailingAnchor), v.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        }
        refreshState()
    }

    private func harnessPath(_ p: AgentProvider) -> String? { p == .claudeCode ? AgentHarness.discoverClaude() : CodexHarness.discover() }

    // MARK: Consent

    private func buildConsent() {
        consentTitle.font = .boldSystemFont(ofSize: 15)
        consentTitle.lineBreakMode = .byWordWrapping; consentTitle.maximumNumberOfLines = 3
        consentTitle.cell?.wraps = true; consentTitle.cell?.isScrollable = false
        let enable = NSButton(title: "I understand: turn it on", target: self, action: #selector(acceptConsent))
        enable.bezelStyle = .rounded
        enable.keyEquivalent = "\r"
        let notNow = NSButton(title: "Not now", target: self, action: #selector(declineConsent))
        notNow.bezelStyle = .rounded
        let buttons = NSStackView(views: [notNow, enable])
        buttons.spacing = 8
        for v in [consentTitle, consentBody.scroll, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; consentView.addSubview(v) }
        NSLayoutConstraint.activate([
            consentTitle.topAnchor.constraint(equalTo: consentView.topAnchor, constant: 14), consentTitle.leadingAnchor.constraint(equalTo: consentView.leadingAnchor, constant: 14),
            consentTitle.trailingAnchor.constraint(equalTo: consentView.trailingAnchor, constant: -14),
            consentBody.scroll.topAnchor.constraint(equalTo: consentTitle.bottomAnchor, constant: 8), consentBody.scroll.leadingAnchor.constraint(equalTo: consentView.leadingAnchor, constant: 4),
            consentBody.scroll.trailingAnchor.constraint(equalTo: consentView.trailingAnchor, constant: -4), consentBody.scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: consentView.trailingAnchor, constant: -14), buttons.bottomAnchor.constraint(equalTo: consentView.bottomAnchor, constant: -14),
        ])
        fillConsent()
    }

    private func fillConsent() {
        consentTitle.stringValue = AgentDisclosure.title(provider)
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 8
        for p in AgentDisclosure.points(provider) {
            let split = p.firstIndex(of: ".").map { (String(p[..<$0]), String(p[p.index(after: $0)...])) } ?? ("", p)
            out.append(NSAttributedString(string: split.0 + ".", attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
            out.append(NSAttributedString(string: split.1 + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
        }
        consentBody.textView.textStorage?.setAttributedString(out)
    }

    @objc func acceptConsent() {
        do { try AgentConsentStore.grant(provider) } catch { banner.show("Could not save your choice: \(error)", style: .error); return }
        refreshState()
    }
    @objc private func closePanel() { (view.window?.windowController as? TabWindowController)?.toggleAssistant(nil) }
    @objc private func declineConsent() { tab.app.windows.first { $0.tab === tab }?.toggleAssistant(nil) }

    func refreshState() {
        fillConsent()
        let granted = AgentConsentStore.isGranted(provider)
        consentView.isHidden = granted
        chatView.isHidden = !granted
        guard granted else { return }
        updateScope()
        checkHarness()
    }

    // MARK: Provider

    private func rebuildProviderMenu() {
        providerPopup.removeAllItems()
        for p in AgentProvider.allCases {
            providerPopup.addItem(withTitle: p.displayName + (harnessPath(p) == nil ? " (not installed)" : ""))
            providerPopup.lastItem?.representedObject = p.rawValue
            providerPopup.lastItem?.isEnabled = harnessPath(p) != nil
        }
        if let i = AgentProvider.allCases.firstIndex(of: provider) { providerPopup.selectItem(at: i) }
    }

    @objc private func providerChosen() {
        guard let raw = providerPopup.selectedItem?.representedObject as? String, let p = AgentProvider(rawValue: raw), p != provider else { return }
        setProvider(p)
    }

    /// Switching assistant ends the conversation (a different company, a different scope of data).
    func setProvider(_ p: AgentProvider) {
        guard p != provider else { return }
        running?.cancel(); running = nil
        shutdown()
        provider = p
        UserDefaults.standard.set(p.rawValue, forKey: Self.providerKey)
        newChat()
        rebuildProviderMenu()
        refreshState()
    }

    // MARK: Chat UI

    private func buildChat() {
        providerPopup.controlSize = .small
        providerPopup.target = self; providerPopup.action = #selector(providerChosen)
        rebuildProviderMenu()
        newChatButton.bezelStyle = .rounded; newChatButton.controlSize = .small; newChatButton.target = self; newChatButton.action = #selector(newChat)
        stopButton.bezelStyle = .rounded; stopButton.target = self; stopButton.action = #selector(stop); stopButton.isHidden = true
        sendButton.bezelStyle = .rounded; sendButton.target = self; sendButton.action = #selector(sendClicked); sendButton.keyEquivalent = "\r"
        input.placeholderString = "Ask about what you're looking at…"
        input.delegate = self
        input.target = self; input.action = #selector(sendClicked)
        trace.setColumns([ColumnSpec("call", "What it read", width: 190, cellIndex: 1), ColumnSpec("result", "Result", width: 80, cellIndex: 2)])
        trace.emptyMessage = "Nothing read yet"
        trace.table.rowHeight = 26
        banner.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [NSView(), newChatButton])
        header.orientation = .horizontal
        header.spacing = 8
        let inputRow = NSStackView(views: [input, sendButton, stopButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 6
        let activity = WorkspacePane("Read activity", body: trace.view)
        let split = WorkspaceLayout.split(columns: false, [transcript.scroll, activity])
        transcript.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 12)
        bannerHeight?.isActive = true
        banner.onVisibilityChanged = { [weak self] in guard let self else { return }; self.bannerHeight?.constant = self.banner.isHidden ? 12 : 60 }
        for v in [header, scopeLabel, status, banner, split, inputRow] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; chatView.addSubview(v) }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 24), header.topAnchor.constraint(equalTo: chatView.topAnchor, constant: 4), header.leadingAnchor.constraint(equalTo: chatView.leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: chatView.trailingAnchor, constant: -12),
            scopeLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4), scopeLabel.leadingAnchor.constraint(equalTo: chatView.leadingAnchor, constant: 12), scopeLabel.trailingAnchor.constraint(equalTo: chatView.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: scopeLabel.bottomAnchor, constant: 1), status.leadingAnchor.constraint(equalTo: chatView.leadingAnchor, constant: 12), status.trailingAnchor.constraint(equalTo: chatView.trailingAnchor, constant: -12),
            banner.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6), banner.leadingAnchor.constraint(equalTo: chatView.leadingAnchor, constant: 10), banner.trailingAnchor.constraint(equalTo: chatView.trailingAnchor, constant: -10),
            split.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 6), split.leadingAnchor.constraint(equalTo: chatView.leadingAnchor), split.trailingAnchor.constraint(equalTo: chatView.trailingAnchor),
            inputRow.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 8), inputRow.leadingAnchor.constraint(equalTo: chatView.leadingAnchor, constant: 12),
            inputRow.trailingAnchor.constraint(equalTo: chatView.trailingAnchor, constant: -12), inputRow.bottomAnchor.constraint(equalTo: chatView.bottomAnchor, constant: -12),
            trace.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        transcript.textView.textContainerInset = NSSize(width: 12, height: 10)
        append("The assistant can read your AWS accounts (read-only) to answer questions about what you are looking at. It cannot change anything.\n\n", color: .secondaryLabelColor)
    }

    private var scope: Set<String> { Set([tab.profile]).union(tab.app.runtime.settings.agentProfiles) }

    private func updateScope() {
        scopeLabel.stringValue = "Can read: \(scope.sorted().joined(separator: ", ")) · read-only · no credentials"
    }

    private func checkHarness() {
        let p = provider
        guard let path = harnessPath(p) else {
            status.stringValue = "\(p.displayName) was not found. Install it and sign in, then reopen this panel."
            sendButton.isEnabled = false
            return
        }
        status.stringValue = "\(p.displayName): checking…"
        lockdownOK = p == .claudeCode
        sendButton.isEnabled = false
        Task { @MainActor in
            let signedIn: Bool? = p == .claudeCode ? await AgentHarness.isSignedIn(claudePath: path) : await CodexHarness.isSignedIn(codexPath: path)
            guard self.provider == p else { return }
            var text = signedIn == true ? "\(p.displayName): signed in (your own login)" : (signedIn == false ? "\(p.displayName) is not signed in. Sign in from a terminal, then try again." : "\(p.displayName): could not check sign-in state")
            if p == .codex {
                // Codex is only used if its tool list, rendered locally with Bridge's flags, contains no shell, web or unknown tool.
                let report = await CodexLockdown.verify(codexPath: path)
                guard self.provider == p else { return }
                self.lockdownOK = report.ok
                if report.ok { text += " · tool list verified (no shell, no web)" }
                else { self.banner.show("Codex is not being used: \(report.problem ?? "its tool list could not be verified"). Update Bridge or switch to Claude Code.", style: .error) }
            }
            self.status.stringValue = text
            self.sendButton.isEnabled = self.lockdownOK
        }
    }

    // MARK: Session lifecycle

    /// A new profile means a new scope: the old conversation (and its permissions) end.
    func profileChanged() {
        guard hasSession || isRunning else { updateScope(); return }
        newChat()
        append("The profile changed, so this is a new conversation scoped to \(tab.profile).\n\n", color: .systemOrange)
    }

    @objc func newChat() {
        running?.cancel()
        running = nil
        shutdown()
        storage.setAttributedString(NSAttributedString())
        transcript.textView.textStorage?.setAttributedString(storage)
        trace.setRows([])
        traceRows.removeAll()
        bytesRead = 0
        banner.hide()
        updateScope()
        setBusy(false)
    }

    func shutdown() {
        server?.stop(); server = nil
        session?.close(); session = nil
    }

    private func startSession() throws -> AgentConversation {
        if let s = session { return s }
        guard let path = harnessPath(provider) else { throw AgentError.harnessNotFound }
        guard let data = tab.app.data else { throw ExecError.spawnFailed(errno: ENOENT) }
        let ep = try AgentIPCServer.makeEndpoint()
        let traceSink: @Sendable (AgentTraceEntry) -> Void = { [weak self] e in Task { @MainActor in self?.addTrace(e) } }
        let backend = AgentBackend(data: data, config: tab.app.runtime.config, settings: tab.app.runtime.settings,
                                   scope: AgentScope(profiles: scope), tab: tab.id,
                                   uiContext: { [weak self] in await MainActor.run { self?.tab.contextSnapshot() ?? "" } }, trace: traceSink)
        let srv = AgentIPCServer(path: ep.path, token: ep.token, backend: backend)
        try srv.start()
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let launch = AgentLaunch(claudePath: path, mcpExecutable: exe, socketPath: ep.path, token: ep.token)
        let s: AgentConversation = provider == .claudeCode ? try AgentSession(launch: launch) : try CodexSession(launch: launch)
        server = srv
        session = s
        return s
    }

    // MARK: Sending

    func controlTextDidEndEditing(_ obj: Notification) {}
    @objc private func stop() { running?.cancel() }
    @objc private func sendClicked() { send(input.stringValue) }

    /// Send a message (also used by tests). Does nothing until the user has consented for this provider and, for Codex,
    /// until the tool-list check passed.
    func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentConsentStore.isGranted(provider), lockdownOK, !message.isEmpty, running == nil else { return }
        input.stringValue = ""
        banner.hide()
        let s: AgentConversation
        do { s = try startSession() } catch { report(error); return }
        append("You\n", color: .secondaryLabelColor, bold: true)
        append(message + "\n\n")
        append("Assistant\n", color: .secondaryLabelColor, bold: true)
        streamStart = storage.length
        streamedText = ""
        setBusy(true)
        let prompt = "Bridge context (a snapshot taken when this message was sent):\n\(tab.contextSnapshot())\n\nQuestion: \(message)"
        running = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.running = nil; self.setBusy(false) }
            do {
                _ = try await s.send(prompt, environment: ProcessInfo.processInfo.environment) { event in Task { @MainActor [weak self] in self?.handle(event) } }
            } catch is CancellationError {
                self.finishStream(final: nil)
                self.append("\n(stopped)\n\n", color: .secondaryLabelColor)
            } catch {
                self.finishStream(final: nil)
                self.report(error)
            }
        }
    }

    private func handle(_ event: ClaudeEvent) {
        switch event {
        case .textDelta(let t):
            streamedText += t
            replaceStream(with: NSAttributedString(string: streamedText, attributes: bodyAttrs()))
        case .assistantText(let t):
            // Claude streams deltas first (ignore the duplicate); Codex sends whole messages only.
            if streamedText.isEmpty { streamedText = t; replaceStream(with: NSAttributedString(string: t, attributes: bodyAttrs())) }
        case .toolUse(_, let name, let inputJSON):
            let what = (inputJSON.string("service").map { $0 + " " } ?? "") + (inputJSON.string("operation") ?? name.replacingOccurrences(of: "mcp__bridge__", with: ""))
            append("\n▸ \(what)\n", color: .tertiaryLabelColor)
            streamStart = storage.length
            streamedText = ""
        case .toolResult(_, let text, let isError):
            append(isError ? "   ✕ \(String(text.prefix(140)))\n" : "   ✓ \(text.utf8.count) bytes\n", color: isError ? .systemRed : .tertiaryLabelColor)
            streamStart = storage.length
            streamedText = ""
        case .result(let text, let isError, _, _, _):
            if !isError { finishStream(final: text) }
        case .initialized(_, let servers, _):
            if let st = servers["bridge"], st != "connected" { banner.show("The assistant could not reach Bridge's tools (\(st)).", style: .warning) }
        }
    }

    private func finishStream(final: String?) {
        guard let start = streamStart else { return }
        let text = final ?? streamedText
        if text.isEmpty { return }
        let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer.render(text))
        replaceStream(with: rendered, from: start)
        append("\n")
        streamStart = nil
    }

    private func replaceStream(with s: NSAttributedString, from: Int? = nil) {
        guard let start = from ?? streamStart, start <= storage.length else { return }
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: s)
        flush()
    }

    private func bodyAttrs(color: NSColor = .labelColor, bold: Bool = false) -> [NSAttributedString.Key: Any] {
        [.font: bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 13), .foregroundColor: color]
    }

    private func append(_ text: String, color: NSColor = .labelColor, bold: Bool = false) {
        storage.append(NSAttributedString(string: text, attributes: bodyAttrs(color: color, bold: bold)))
        flush()
    }

    private func flush() {
        transcript.textView.textStorage?.setAttributedString(storage)
        transcript.textView.scrollToEndOfDocument(nil)
    }

    private func setBusy(_ busy: Bool) {
        sendButton.isHidden = busy
        stopButton.isHidden = !busy
        input.isEnabled = !busy
    }

    private func report(_ error: Error) {
        let name = provider.displayName
        switch error {
        case AgentError.harnessNotFound: banner.show("\(name) was not found. Install it and sign in.", style: .error)
        case AgentError.notSignedIn: banner.show("\(name) is not signed in. Sign in from a terminal, then send again.", style: .warning)
        case AgentError.timedOut: banner.show("The assistant took too long and was stopped.", style: .error)
        case AgentError.forbiddenTool(let t):
            banner.show("The assistant tried to use something Bridge does not allow (\(t)) and was stopped.", style: .error)
            append("\n(Bridge stopped the assistant: it tried to use \(t), which is not allowed.)\n\n", color: .systemRed)
        case AgentError.failed(_, let m): banner.show("The assistant stopped: \(String(m.prefix(300)))", style: .error)
        default: banner.show("The assistant could not start: \(error)", style: .error)
        }
    }

    // MARK: Trace (what the assistant actually read, from Bridge's own side)

    private var traceRows: [TableRow] = []
    private func addTrace(_ e: AgentTraceEntry) {
        bytesRead += e.bytes
        let color: NSColor? = e.status == .ok ? nil : (e.status == .denied ? .systemOrange : .systemRed)
        let result = e.status == .ok ? "\(e.bytes) B" + (e.redactions > 0 ? " · \(e.redactions) redacted" : "") : e.status.rawValue
        traceRows.append(TableRow(id: e.id.uuidString, cells: [Cell(Format.time.string(from: e.time).prefix(8).description, color: .secondaryLabelColor), Cell("\(e.tool) \(e.summary)".trimmingCharacters(in: .whitespaces)), Cell(result, color: color)]))
        trace.setRows(traceRows)
    }
    var traceCount: Int { traceRows.count }
    var traceStatuses: [String] { traceRows.map { $0.cells[2].text } }
}
