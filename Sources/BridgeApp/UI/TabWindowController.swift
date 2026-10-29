import AppKit
import BridgeCore

private final class SidebarItem: NSObject {
    let title: String
    let section: AppSection?
    init(title: String, section: AppSection?) { self.title = title; self.section = section }
    var isHeader: Bool { section == nil }
}

private extension NSToolbarItem.Identifier {
    static let context = NSToolbarItem.Identifier("bridge.context")
    static let profile = NSToolbarItem.Identifier("bridge.profile")
    static let region = NSToolbarItem.Identifier("bridge.region")
    static let range = NSToolbarItem.Identifier("bridge.range")
    static let freshness = NSToolbarItem.Identifier("bridge.freshness")
    static let refresh = NSToolbarItem.Identifier("bridge.refresh")
    static let jump = NSToolbarItem.Identifier("bridge.jump")
    static let awsCommand = NSToolbarItem.Identifier("bridge.command")
    static let assistant = NSToolbarItem.Identifier("bridge.assistant")
}

/// One window = one tab: its own profile, region, time range and selection. Native window tabs (Cmd-T).
@MainActor
final class TabWindowController: NSWindowController, NSToolbarDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate, NSSearchFieldDelegate {
    let app: AppModel
    let tab: TabModel

    private let sidebar = NSOutlineView()
    private let serviceSearch = NSSearchField()
    private var allItems: [SidebarItem] = []
    private var restoreSidebarAfterAssistant = false
    private var assistantItem: NSSplitViewItem?
    private var rootSplit: NSSplitViewController!
    private(set) var settingsWindow: NSWindowController?
    private let accountButton = NSButton(title: "Account", target: nil, action: nil)
    private let accountPopover = NSPopover()
    private(set) var accountDetails: AccountPopoverViewController?
    var accountDetailsShown: Bool { accountPopover.isShown }
    var accountSummary: String { accountDetails?.summaryText ?? "" }
    private let contentHost = NSView()
    private(set) var commandDrawer: AWSCommandDrawer!
    private var splitView: NSSplitView!
    private(set) var agentPanel: AgentPanelViewController?
    private var items: [SidebarItem] = []
    private(set) var sectionControllers: [AppSection: SectionViewController] = [:]
    private var staleSections = Set<AppSection>()
    private let sectionTitle = label("", size: 23, color: .labelColor)
    private let sectionDetail = label("", size: 12)
    private var palette: CommandPalette?
    private var current: SectionViewController?

    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let regionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let freshness = NSTextField(labelWithString: "")
    private var timer: Timer?

    static let regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1",
                          "eu-north-1", "eu-south-1", "ap-south-1", "ap-southeast-1", "ap-southeast-2", "ap-northeast-1",
                          "ap-northeast-2", "ap-northeast-3", "ca-central-1", "sa-east-1", "me-south-1", "af-south-1"]
    static let ranges: [(String, TimeInterval)] = [("Last 5 minutes", 300), ("Last 15 minutes", 900), ("Last hour", 3600),
                                                   ("Last 3 hours", 10_800), ("Last 24 hours", 86_400)]

    init(app: AppModel, profile: String, region: String?) {
        self.app = app
        self.tab = TabModel(app: app, profile: profile, region: region)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.tabbingMode = .preferred
        win.tabbingIdentifier = "bridge.tab"
        win.minSize = NSSize(width: 960, height: 640)
        super.init(window: win)
        win.delegate = self
        buildInterface()
        wireTab()
        win.center()
        select(.home)
        refreshContextUI()
        verifyInBackground()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateFreshness() } }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Interface

    private func buildInterface() {
        guard let win = window else { return }

        items = AppSection.sidebarGroupNames.flatMap { group in
            [SidebarItem(title: group, section: nil)] + AppSection.destinations.filter { $0.sidebarGroup == group }.map { SidebarItem(title: $0.title, section: $0) }
        }

        allItems = items

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")); col.width = 180
        sidebar.addTableColumn(col)
        sidebar.outlineTableColumn = col
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.floatsGroupRows = false
        sidebar.indentationPerLevel = 0
        sidebar.rowSizeStyle = .medium
        sidebar.rowHeight = 28
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true
        sideScroll.drawsBackground = false

        let sideHost = NSView()
        serviceSearch.placeholderString = "Find a service"
        serviceSearch.delegate = self
        serviceSearch.target = self; serviceSearch.action = #selector(chooseSearchResult)
        serviceSearch.controlSize = .regular
        serviceSearch.setAccessibilityLabel("Find a service")
        for v in [serviceSearch, sideScroll] as [NSView] { sideHost.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            serviceSearch.topAnchor.constraint(equalTo: sideHost.topAnchor, constant: 12),
            serviceSearch.leadingAnchor.constraint(equalTo: sideHost.leadingAnchor, constant: 12), serviceSearch.trailingAnchor.constraint(equalTo: sideHost.trailingAnchor, constant: -12),
            sideScroll.topAnchor.constraint(equalTo: serviceSearch.bottomAnchor, constant: 12), sideScroll.leadingAnchor.constraint(equalTo: sideHost.leadingAnchor), sideScroll.trailingAnchor.constraint(equalTo: sideHost.trailingAnchor), sideScroll.bottomAnchor.constraint(equalTo: sideHost.bottomAnchor),
        ])
        sectionTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        let spacer = NSView()

        let heading = NSStackView(views: [sectionTitle, spacer, freshness]); heading.orientation = .horizontal; heading.alignment = .centerY; heading.spacing = 12
        let right = NSView()
        commandDrawer = AWSCommandDrawer(activity: tab.commandActivity, page: contentHost)
        commandDrawer.onStop = { [weak self] in self?.tab.cancelAll(); self?.tab.commandActivity.cancelRunning() }
        commandDrawer.onOpenRunner = { [weak self] in self?.select(.runner) }
        let workspace = commandDrawer.view
        for v in [heading, workspace] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.heightAnchor.constraint(equalToConstant: 28),
            heading.topAnchor.constraint(equalTo: right.topAnchor, constant: 18), heading.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24), heading.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -24),
            workspace.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14), workspace.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            workspace.leadingAnchor.constraint(equalTo: right.leadingAnchor), workspace.trailingAnchor.constraint(equalTo: right.trailingAnchor),
        ])

        let sideVC = NSViewController(); sideVC.view = sideHost
        let detailVC = NSViewController(); detailVC.view = right; detailVC.addChild(commandDrawer)
        rootSplit = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sideVC)
        sideItem.minimumThickness = 190; sideItem.maximumThickness = 250; sideItem.canCollapse = true
        rootSplit.addSplitViewItem(sideItem)
        rootSplit.addSplitViewItem(NSSplitViewItem(viewController: detailVC))
        win.contentViewController = rootSplit
        splitView = rootSplit.splitView
        splitView.setPosition(215, ofDividerAt: 0)

        let toolbar = NSToolbar(identifier: "bridge.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        win.toolbar = toolbar
        win.toolbarStyle = .unifiedCompact
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        profilePopup.isBordered = true; regionPopup.isBordered = false; rangePopup.isBordered = false
        profilePopup.font = .systemFont(ofSize: 13, weight: .medium)
        regionPopup.font = .systemFont(ofSize: 12)
        rangePopup.font = .systemFont(ofSize: 12)
        profilePopup.setAccessibilityLabel("AWS profile"); regionPopup.setAccessibilityLabel("AWS region"); rangePopup.setAccessibilityLabel("Time range")

        accountButton.bezelStyle = .texturedRounded
        accountButton.imagePosition = .imageLeading
        accountButton.target = self; accountButton.action = #selector(showAccount)
        let details = AccountPopoverViewController(profilePicker: profilePopup)
        details.onVerify = { [weak self] in self?.verifyInBackground(force: true) }
        details.onSettings = { [weak self] in self?.accountPopover.close(); self?.showSettings(nil) }
        accountDetails = details
        accountPopover.behavior = .transient; accountPopover.animates = false
        accountPopover.contentViewController = details
        profilePopup.target = self; profilePopup.action = #selector(profileChanged)
        regionPopup.target = self; regionPopup.action = #selector(regionChanged)
        rangePopup.target = self; rangePopup.action = #selector(rangeChanged)
        freshness.font = .systemFont(ofSize: 11)
        freshness.textColor = .secondaryLabelColor
        sidebar.reloadData()
        sidebar.expandItem(nil, expandChildren: true)
    }

    private func wireTab() {
        tab.onContextChanged = { [weak self] in self?.contextChanged() }
        tab.onIdentityChanged = { [weak self] in guard let self else { return }; self.updateAccount() }
        tab.onRefreshed = { [weak self] in self?.updateFreshness() }
        tab.onNavigate = { [weak self] n in self?.navigate(n) }
        tab.selectionProvider = { [weak self] in self?.current?.selectionDescription }
    }

    private func refreshContextUI() {
        // Profiles
        profilePopup.removeAllItems()
        let names = app.runtime.config.profileNames
        for n in names {
            let protected = app.runtime.settings.policy(for: n).protected
            profilePopup.addItem(withTitle: (protected ? "● " : "") + (app.runtime.settings.profiles[n]?.label ?? n))
            profilePopup.lastItem?.representedObject = n
        }
        if names.isEmpty { profilePopup.addItem(withTitle: "no profiles found"); profilePopup.isEnabled = false }
        if let i = names.firstIndex(of: tab.profile) { profilePopup.selectItem(at: i) }
        // Regions
        regionPopup.removeAllItems()
        var regs = Self.regions
        if !regs.contains(tab.region) { regs.insert(tab.region, at: 0) }
        regionPopup.addItems(withTitles: regs)
        regionPopup.selectItem(withTitle: tab.region)
        // Range
        rangePopup.removeAllItems()
        rangePopup.addItems(withTitles: Self.ranges.map(\.0))
        if let i = Self.ranges.firstIndex(where: { $0.1 == tab.windowSeconds }) { rangePopup.selectItem(at: i) }
        updateAccount()
        window?.title = "Bridge"
        window?.subtitle = Bundle.main.object(forInfoDictionaryKey: "BridgeDemo") as? Bool == true ? "Demo · Sample data" : ""
        regionPopup.isEnabled = !tab.section.accountGlobal
        regionPopup.toolTip = tab.section.accountGlobal ? "Billing includes all AWS regions" : "AWS region"
        if tab.section.accountGlobal { regionPopup.removeAllItems(); regionPopup.addItem(withTitle: "All regions") }
        rangePopup.isEnabled = tab.section.supportsTimeRange
        rangePopup.isHidden = !rangePopup.isEnabled
        updateFreshness()
    }

    private func updateFreshness() {
        if tab.section == .home { freshness.stringValue = ""; return }
        if let t = tab.lastRefresh { freshness.stringValue = "updated " + Format.age(Date().timeIntervalSince(t)) } else { freshness.stringValue = "not loaded" }
    }

    // MARK: Sections

    func select(_ section: AppSection) {
        if section == .settings { showSettings(nil); return }
        if !items.contains(where: { $0.section == section }) {
            serviceSearch.stringValue = ""; items = allItems; sidebar.reloadData()
        }
        if tab.section != section { current?.deactivate() }
        tab.section = section
        sectionTitle.stringValue = section.title
        sectionTitle.toolTip = section.detail
        refreshContextUI()
        if let i = items.firstIndex(where: { $0.section == section }) { sidebar.selectRowIndexes([sidebar.row(forItem: items[i])], byExtendingSelection: false) }
        let vc = sectionControllers[section] ?? makeController(for: section)
        sectionControllers[section] = vc
        if current !== vc {
            current?.view.removeFromSuperview()
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(vc.view)
            vc.view.pin(to: contentHost)
            current = vc
        }
        if staleSections.contains(section) || !vc.isViewLoaded || vcNeverLoaded(vc) {
            staleSections.remove(section)
            vc.reload(refresh: false)
            loaded.insert(section)
        }
    }

    private var loaded = Set<AppSection>()
    private func vcNeverLoaded(_ vc: SectionViewController) -> Bool {
        guard let s = sectionControllers.first(where: { $0.value === vc })?.key else { return false }
        return !loaded.contains(s)
    }

    private func makeController(for section: AppSection) -> SectionViewController {
        section.makeController(tab: tab) { [weak self] in self?.select($0) }
    }

    private func navigate(_ n: Navigation) {
        let target: AppSection
        switch n {
        case .logGroup: target = .logs
        case .iamRole: target = .iam
        case .lambda: target = .lambda
        case .sqsQueue: target = .sqs
        case .s3Bucket: target = .s3
        }
        select(target)
        sectionControllers[target]?.handle(n)
    }

    func settingsChanged() {
        tab.reloadSettings()
    }

    private func contextChanged() {
        accountPopover.close()
        tab.commandActivity.clear()
        sectionControllers.values.forEach { $0.contextWillChange() }
        refreshContextUI()
        agentPanel?.profileChanged()
        staleSections = Set(AppSection.allCases)
        loaded.removeAll()
        if let section = current.flatMap({ c in sectionControllers.first { $0.value === c }?.key }) { select(section) }
        verifyInBackground()
    }

    private func verifyInBackground(force: Bool = false) {
        tab.track { [weak self] in
            guard let self else { return }
            do { try await self.tab.verifyIdentity(force: force) } catch is CancellationError {} catch { self.updateAccount() }
        }
    }

    private func updateAccount() {
        accountDetails?.update(for: tab)
        let production = tab.isProtected || tab.suggestsProtection
        let symbol = tab.isProtected ? "checkmark.shield" : (tab.suggestsProtection ? "exclamationmark.shield" : (tab.identity == nil ? "exclamationmark.circle" : "person.crop.circle"))
        accountButton.title = tab.label
        accountButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        accountButton.contentTintColor = production ? .systemOrange : (tab.identity == nil ? .systemOrange : nil)
        accountButton.toolTip = "Account details · " + tab.profile + " · " + (tab.identity?.account ?? "not verified")
        accountButton.setAccessibilityLabel("Account details for " + tab.label)
    }

    @objc func showAccount(_ sender: Any?) {
        if accountPopover.isShown { accountPopover.close(); return }
        updateAccount()
        accountPopover.show(relativeTo: accountButton.bounds, of: accountButton, preferredEdge: .minY)
    }
    func closeAccount() { accountPopover.close() }

    // MARK: Actions

    @objc func profileChanged() {
        if let name = profilePopup.selectedItem?.representedObject as? String { tab.setProfile(name) }
    }
    @objc func regionChanged() { if let r = regionPopup.titleOfSelectedItem { tab.setRegion(r) } }
    @objc func rangeChanged() {
        let i = rangePopup.indexOfSelectedItem
        if i >= 0 && i < Self.ranges.count { tab.setWindowSeconds(Self.ranges[i].1) }
    }
    @objc func toggleAWSCommand(_ sender: Any?) { commandDrawer.toggle() }
    @objc func focusSearch(_ sender: Any?) {
        let search = current?.preferredSearchField ?? serviceSearch
        if search === serviceSearch { rootSplit.splitViewItems.first?.isCollapsed = false }
        window?.makeFirstResponder(search); search.selectText(nil)
    }
    @objc func refresh(_ sender: Any?) {
        tab.refreshWindow()
        current?.reload(refresh: true)
    }
    override func newWindowForTab(_ sender: Any?) { app.newTab(joining: self) }

    /// Show or hide the assistant panel. The panel does nothing until the user accepts its disclosure.
    @objc func toggleAssistant(_ sender: Any?) {
        if agentPanel == nil {
            let panel = AgentPanelViewController(tab: tab)
            agentPanel = panel
            let item = NSSplitViewItem(viewController: panel)
            item.minimumThickness = 300; item.maximumThickness = 420; item.canCollapse = true
            rootSplit.addSplitViewItem(item)
            item.isCollapsed = true; assistantItem = item
        }
        guard let item = assistantItem else { return }
        item.isCollapsed.toggle()
        if !item.isCollapsed {
            if (window?.frame.width ?? 1180) < 1180, let sidebar = rootSplit.splitViewItems.first, !sidebar.isCollapsed {
                restoreSidebarAfterAssistant = true; sidebar.isCollapsed = true
            }
            agentPanel?.refreshState()
        } else if restoreSidebarAfterAssistant {
            rootSplit.splitViewItems.first?.isCollapsed = false; restoreSidebarAfterAssistant = false
        }
    }
    @objc func selectSectionFromMenu(_ sender: NSMenuItem) {
        let all = AppSection.allCases
        if sender.tag >= 0 && sender.tag < all.count { select(all[sender.tag]) }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        if palette == nil {
            palette = CommandPalette()
            palette?.onSelect = { [weak self] in self?.select($0) }
        }
        palette?.present(relativeTo: window)
    }
    @objc func showSettings(_ sender: Any?) {
        // A settings window owns a fixed profile context even if the main window changes behind it.
        let model = TabModel(app: app, profile: tab.profile, region: tab.region)
        let editor = SettingsViewController(tab: model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Profile Settings"; w.subtitle = tab.label; w.tabbingMode = .disallowed
        editor.view.frame = NSRect(x: 0, y: 0, width: 600, height: 530)
        w.contentViewController = editor
        w.setContentSize(NSSize(width: 600, height: 530))
        editor.reload(refresh: false)
        settingsWindow?.close(); settingsWindow = NSWindowController(window: w)
        w.center(); settingsWindow?.showWindow(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = serviceSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        items = query.isEmpty ? allItems : allItems.filter { !$0.isHeader && $0.title.localizedCaseInsensitiveContains(query) }
        sidebar.reloadData()
        if let item = items.first(where: { $0.section == tab.section }) {
            sidebar.selectRowIndexes([sidebar.row(forItem: item)], byExtendingSelection: false)
        }
    }
    @objc private func chooseSearchResult() {
        if let section = items.first(where: { !$0.isHeader })?.section { select(section) }
    }
    @objc func toggleSidebar(_ sender: Any?) { rootSplit.toggleSidebar(sender) }

    func windowWillClose(_ notification: Notification) {
        accountPopover.close()
        sectionControllers.values.forEach { $0.deactivate() }
        settingsWindow?.close()
        palette?.close()
        timer?.invalidate()
        agentPanel?.shutdown()
        tab.cancelAll()
        app.closed(self)
    }

    // MARK: NSToolbarDelegate

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .context, .space, .range, .refresh, .awsCommand, .assistant]
    }
    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .context, .range, .flexibleSpace, .space, .awsCommand, .assistant, .refresh]
    }
    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            if id == .sidebarTrackingSeparator { return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 0) }
            let item = NSToolbarItem(itemIdentifier: id)
            switch id {
            case .context:
                func chevron() -> NSImageView {
                    let image = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                    image.contentTintColor = .tertiaryLabelColor
                    image.widthAnchor.constraint(equalToConstant: 10).isActive = true
                    return image
                }
                let path = NSStackView(views: [accountButton, chevron(), regionPopup])
                path.spacing = 6; path.alignment = .centerY
                accountButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
                item.view = path; item.label = "Account and region"; item.toolTip = "AWS account and region"
            case .profile: item.view = profilePopup; item.label = "Profile"; item.toolTip = "AWS profile"
            case .region: item.view = regionPopup; item.label = "Region"; item.toolTip = "AWS region"
            case .range: item.view = rangePopup; item.label = "Time range"
            case .freshness: item.view = freshness; item.label = "Updated"
            case .awsCommand:
                let button = NSButton(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: "AWS Command") ?? NSImage(), target: self, action: #selector(toggleAWSCommand(_:)))
                button.bezelStyle = .texturedRounded
                item.view = button; item.label = "AWS Command"; item.toolTip = "Show or hide AWS Command (⌘J)"
            case .assistant:
                let b = NSButton(title: "Assistant", image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Assistant") ?? NSImage(), target: self, action: #selector(toggleAssistant(_:)))
                b.bezelStyle = .texturedRounded
                item.view = b; item.label = "Assistant"; item.toolTip = "Assistant (Cmd-Shift-A)"
            case .refresh:
                let b = NSButton(title: "Refresh", image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") ?? NSImage(), target: self, action: #selector(refresh(_:)))
                b.bezelStyle = .texturedRounded
                item.view = b; item.label = "Refresh"; item.toolTip = "Refresh (Cmd-R)"
            default: return nil
            }
            return item
        }
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? items.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarItem)?.isHeader ?? false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? SidebarItem)?.isHeader ?? true) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let it = item as? SidebarItem else { return nil }
        let id = NSUserInterfaceItemIdentifier(it.isHeader ? "header" : "item")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView(); c.identifier = id
            let t = NSTextField(labelWithString: ""); t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t); c.textField = t
            NSLayoutConstraint.activate([t.centerYAnchor.constraint(equalTo: c.centerYAnchor), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4)])
            if !it.isHeader {
                let img = NSImageView(); img.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(img); c.imageView = img
                NSLayoutConstraint.activate([img.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4), img.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                                             img.widthAnchor.constraint(equalToConstant: 16), t.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6)])
            } else {
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4).isActive = true
            }
            return c
        }()
        cell.textField?.stringValue = it.title
        if it.isHeader { cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold); cell.textField?.textColor = .secondaryLabelColor }
        else {
            cell.textField?.font = .systemFont(ofSize: 13); cell.textField?.textColor = .labelColor
            cell.imageView?.image = it.section.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) }
            cell.imageView?.contentTintColor = .secondaryLabelColor
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        if row >= 0, let it = sidebar.item(atRow: row) as? SidebarItem, let s = it.section, s != tab.section { select(s) }
    }
}
