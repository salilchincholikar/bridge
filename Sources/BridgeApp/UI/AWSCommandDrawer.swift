import AppKit

/// One utility drawer per window tab. Hosts the page above a native, resizable split divider.
@MainActor
final class AWSCommandDrawer: NSViewController, NSSplitViewDelegate {
    let activity: CommandActivity
    let commandPane = TextPane()
    private let page: NSView
    private let split = CommandSplitView()
    private let panel = NSView()
    private let body = NSView()
    private let disclosure = NSButton(title: "AWS Command", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "No service requests")
    private let history = NSPopUpButton()
    private let mode = NSSegmentedControl(labels: ["Command", "Output"], trackingMode: .selectOne, target: nil, action: nil)
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let copy = NSButton(title: "Copy", target: nil, action: nil)
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    private var lastExpandedHeight: CGFloat = 220
    private var changingSize = false
    private let collapsedHeight: CGFloat = 36
    private let minimumExpandedHeight: CGFloat = 180
    var drawerHeight: CGFloat { panel.frame.height }
    var previewHeight: CGFloat { commandPane.scroll.bounds.height }
    var dividerIsAtDrawerEdge: Bool {
        guard let rect = split.renderedDivider else { return false }
        return abs(rect.minY - (split.isFlipped ? page.frame.maxY : panel.frame.maxY)) < 1
    }
    private(set) var isExpanded = false
    var onStop: (() -> Void)?
    var onOpenRunner: (() -> Void)?

    init(activity: CommandActivity, page: NSView) {
        self.activity = activity; self.page = page
        super.init(nibName: nil, bundle: nil)
        activity.onChange = { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        split.isVertical = false; split.dividerStyle = .thin; split.delegate = self
        page.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        panel.frame = NSRect(x: 0, y: 0, width: 900, height: 36)
        split.frame = NSRect(x: 0, y: 0, width: 900, height: 637)
        split.addArrangedSubview(page); split.addArrangedSubview(panel)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        disclosure.isBordered = false; disclosure.font = .systemFont(ofSize: 12, weight: .medium)
        disclosure.imagePosition = .imageLeading; disclosure.target = self; disclosure.action = #selector(toggle)
        disclosure.toolTip = "Show or hide AWS Command (⌘J)"
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let shortcut = NSTextField(labelWithString: "⌘J"); shortcut.font = .systemFont(ofSize: 11); shortcut.textColor = .tertiaryLabelColor
        stop.bezelStyle = .inline; stop.controlSize = .small; stop.target = self; stop.action = #selector(stopRequests)
        stop.toolTip = "Cancel active work in this tab"
        let bar = NSStackView(views: [disclosure, status, NSView(), stop, shortcut]); bar.spacing = 12
        history.controlSize = .small; history.target = self; history.action = #selector(selectHistory)
        history.setAccessibilityLabel("Command history"); history.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        history.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mode.controlSize = .small; mode.selectedSegment = 0; mode.target = self; mode.action = #selector(showPreviewMode)
        let runner = NSButton(title: "Operation runner…", target: self, action: #selector(openRunner))
        for button in [copy, clear, runner] { button.bezelStyle = .inline; button.controlSize = .small }
        copy.target = self; copy.action = #selector(copyPreview); copy.toolTip = "Copy the displayed, redacted preview"
        clear.target = self; clear.action = #selector(clearHistory)
        let tools = NSStackView(views: [history, mode, NSView(), copy, clear, runner]); tools.spacing = 10
        commandPane.textView.setAccessibilityLabel("AWS command preview")
        panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.layer?.masksToBounds = true
        body.wantsLayer = true; body.layer?.masksToBounds = true
        for child in [bar, body] { child.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(child) }
        for child in [tools, commandPane.scroll] { child.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(child) }
        let bodyBottom = body.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        bodyBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bodyBottom,
            bar.topAnchor.constraint(equalTo: panel.topAnchor), bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20), bar.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20), bar.heightAnchor.constraint(equalToConstant: 36),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor), body.leadingAnchor.constraint(equalTo: panel.leadingAnchor), body.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tools.topAnchor.constraint(equalTo: body.topAnchor), tools.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 20), tools.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -20), tools.heightAnchor.constraint(equalToConstant: 30),
            commandPane.scroll.topAnchor.constraint(equalTo: tools.bottomAnchor), commandPane.scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 10), commandPane.scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -10), commandPane.scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        view = split
        refresh()
    }
    override func viewDidAppear() { super.viewDidAppear(); layoutPanels() }
    @objc func toggle() { setExpanded(!isExpanded) }
    func setExpanded(_ expanded: Bool) {
        _ = view
        isExpanded = expanded
        layoutPanels()
    }

    /// Window resizing must preserve intent, rather than infer intent from intermediate pane frames.
    private func layoutPanels() {
        guard isViewLoaded, !changingSize else { return }
        changingSize = true
        defer { changingSize = false }
        let available = split.bounds.height
        let maximum = max(collapsedHeight, available - 280 - split.dividerThickness)
        let height = isExpanded ? min(max(minimumExpandedHeight, lastExpandedHeight), maximum) : collapsedHeight
        // A transient zero/small parent frame is not a new user preference.
        let panelHeight = min(max(0, available - split.dividerThickness), height)
        let pageHeight = max(0, available - panelHeight - split.dividerThickness)
        // Resize the panes before positioning the divider: during a parent resize,
        // setPosition alone can clamp against the previous arranged-subview extent.
        if split.isFlipped {
            page.frame = NSRect(x: 0, y: 0, width: split.bounds.width, height: pageHeight)
            panel.frame = NSRect(x: 0, y: pageHeight + split.dividerThickness, width: split.bounds.width, height: panelHeight)
        } else {
            panel.frame = NSRect(x: 0, y: 0, width: split.bounds.width, height: panelHeight)
            page.frame = NSRect(x: 0, y: panelHeight + split.dividerThickness, width: split.bounds.width, height: pageHeight)
        }
        split.setPosition(pageHeight, ofDividerAt: 0)
        refresh()
        split.needsDisplay = true
    }
    private func refresh() {
        guard isViewLoaded else { return }
        body.isHidden = !isExpanded
        disclosure.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "terminal", accessibilityDescription: nil)
        disclosure.setAccessibilityExpanded(isExpanded)
        let selected = activity.selected
        let count = activity.runningCount
        status.stringValue = count > 0 ? "\(count) running" : (selected?.status ?? "No service requests")
        stop.isHidden = count == 0
        history.removeAllItems()
        for entry in activity.entries.reversed() {
            history.addItem(withTitle: Format.time.string(from: entry.started) + " · " + entry.title + " · " + entry.status)
            history.lastItem?.representedObject = entry.id
            history.lastItem?.toolTip = entry.command
        }
        if history.numberOfItems == 0 { history.addItem(withTitle: "No command history") }
        if let index = history.itemArray.firstIndex(where: { ($0.representedObject as? UUID) == activity.selectedID }) { history.selectItem(at: index) }
        history.isEnabled = !activity.entries.isEmpty
        clear.isEnabled = !activity.entries.isEmpty && count == 0
        copy.isEnabled = selected != nil
        if mode.selectedSegment == 0 {
            commandPane.setText(selected.map { "$ " + $0.command } ?? "Commands used by this tab appear here. Use Operation runner to run a supported read operation.")
        } else { commandPane.setText(selected?.output ?? "Response previews appear here after a request.") }
    }
    @objc private func selectHistory() { if let id = history.selectedItem?.representedObject as? UUID { activity.select(id) } }
    @objc private func showPreviewMode() { refresh() }
    @objc private func copyPreview() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commandPane.textView.string, forType: .string) }
    @objc private func clearHistory() { activity.clear() }
    @objc private func stopRequests() { onStop?() }
    @objc private func openRunner() { onOpenRunner?() }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanels() }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(280, max(0, splitView.bounds.height - collapsedHeight))
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(0, splitView.bounds.height - collapsedHeight - splitView.dividerThickness)
    }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard !changingSize else { return proposedPosition }
        let height = splitView.bounds.height - proposedPosition - splitView.dividerThickness
        // Dragging has two stable states; never leave only the controls visible without a preview.
        if height < minimumExpandedHeight / 2 {
            isExpanded = false
            refresh()
            return max(0, splitView.bounds.height - collapsedHeight - splitView.dividerThickness)
        }
        isExpanded = true
        let maximum = max(collapsedHeight, splitView.bounds.height - 280 - splitView.dividerThickness)
        lastExpandedHeight = min(max(minimumExpandedHeight, height), maximum)
        refresh()
        return max(0, splitView.bounds.height - lastExpandedHeight - splitView.dividerThickness)
    }
}

/// Track the native divider's draw position so layout regression checks can verify the visible edge.
private final class CommandSplitView: NSSplitView {
    private(set) var renderedDivider: NSRect?
    override func drawDivider(in rect: NSRect) {
        renderedDivider = rect
        super.drawDivider(in: rect)
    }
}
