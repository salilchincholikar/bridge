import BridgeUI
import AppKit
import BridgeCore

/// W5: CloudWatch Logs search. Pick a log group, filter by pattern within the tab's time range.
@MainActor
final class LogsViewController: SectionViewController, NSSearchFieldDelegate, NSTextFieldDelegate {
    override var preferredSearchField: NSSearchField? { pattern }
    private let groupFilter = NSSearchField()
    let groups = DataTable(columns: [ColumnSpec("name", "Log group", width: 300), ColumnSpec("ret", "Retention", width: 80), ColumnSpec("size", "Stored", width: 80, rightAligned: true)])
    private let pattern = NSSearchField()
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    let summary = label("", size: 11)
    let events = DataTable(columns: [ColumnSpec("time", "Time", width: 110), ColumnSpec("level", "Level", width: 60), ColumnSpec("msg", "Message", width: 900)])
    let message = TextPane()

    private let followButton = NSButton(title: "Follow", target: nil, action: nil)
    private var followTask: Task<Void, Never>?
    private var followID = UUID()
    private var searchID = UUID()
    private var buffer = LogFollowBuffer()
    var isFollowing: Bool { followTask != nil }

    private var groupNames: [String] = []
    private var selectedGroup: String?
    private var pendingGroup: String?

    override func build() {
        groupFilter.placeholderString = "Filter log groups"; groupFilter.delegate = self
        groupFilter.widthAnchor.constraint(equalToConstant: 220).isActive = true
        pattern.placeholderString = "Filter pattern"; pattern.toolTip = "CloudWatch filter pattern, for example ERROR or \"timed out\""; pattern.delegate = self
        pattern.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        for b in [searchButton, followButton] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self }
        searchButton.action = #selector(searchClicked); followButton.action = #selector(toggleFollow)
        followButton.toolTip = "Poll for new events every 5 seconds. Stops when you leave Logs."
        groups.setColumns([ColumnSpec("name", "Log group", width: 280)])
        events.table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        events.emptyMessage = "Choose a log group"; groups.emptyMessage = "Loading…"
        let groupList = WorkspacePane("Log groups", body: groups.view); WorkspaceLayout.listWidth(groupList)
        let eventList = WorkspacePane("Events", body: events.view)
        let fullMessage = WorkspacePane("Selected message", body: message.scroll)
        fullMessage.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let detailSplit = WorkspaceLayout.split(columns: false, [eventList, fullMessage])
        let right = NSView()
        for v in [summary, detailSplit] as [NSView] { right.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: right.topAnchor), summary.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 8), summary.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -8), summary.heightAnchor.constraint(equalToConstant: 18),
            detailSplit.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6), detailSplit.leadingAnchor.constraint(equalTo: right.leadingAnchor), detailSplit.trailingAnchor.constraint(equalTo: right.trailingAnchor), detailSplit.bottomAnchor.constraint(equalTo: right.bottomAnchor),
        ])
        WorkspaceLayout.fill(WorkspaceLayout.split(columns: true, [groupList, right]), in: content,
            toolbar: WorkspaceLayout.toolbar([groupFilter, NSView(), pattern, searchButton, followButton]))
        groups.onSelect = { [weak self] row in
            guard let name = row?.id else { return }
            self?.stopFollowing(); self?.selectedGroup = name; self?.search(refresh: false)
        }
        events.onSelect = { [weak self] row in self?.message.setText((row?.payload as? LogEvent)?.message ?? "Select an event to read its full message.") }
        message.setText("Select an event to read its full message.")
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === groupFilter { groups.filter = groupFilter.stringValue }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === pattern, commandSelector == #selector(NSResponder.insertNewline(_:)) { search(refresh: true); return true }
        return false
    }
    @objc private func searchClicked() { search(refresh: true) }

    override func handle(_ navigation: Navigation) {
        guard case .logGroup(let name) = navigation else { return }
        if groupNames.contains(name) { selectGroup(name) } else { pendingGroup = name }
    }

    private func selectGroup(_ name: String) {
        if let idx = groups.rows.firstIndex(where: { $0.id == name }) {
            groups.table.selectRowIndexes([idx], byExtendingSelection: false)
            groups.table.scrollRowToVisible(idx)
        } else {
            // Not in the loaded list (more than 500 groups, or a custom name): search it directly.
            selectedGroup = name
            search(refresh: false)
        }
    }

    override var selectionDescription: String? { selectedGroup.map { "log group \($0)" + (pattern.stringValue.isEmpty ? "" : ", filter pattern \(pattern.stringValue)") } }

    override func reload(refresh: Bool) {
        stopFollowing()
        clearError()
        run { [weak self] in
            guard let self else { return }
            guard let pages = try await self.tab.fetchPages(LogsWorkflow.describeGroups(profile: self.tab.profile, region: self.tab.region, maxItems: 500), refresh: refresh, maxPages: 2) else { return }
            let list = pages.flatMap { LogsWorkflow.parseGroups($0.result.json) }.sorted { $0.name < $1.name }
            self.groupNames = list.map(\.name)
            self.groups.emptyMessage = "No log groups in \(self.tab.region)"
            self.groups.setRows(list.map { g in
                TableRow(id: g.name, cells: [Cell(g.name), Cell(g.retentionDays.map { "\($0) d" } ?? "never"), Cell(g.storedBytes.map { Format.bytes(Int64($0)) } ?? "")], payload: g)
            })

            if let g = self.pendingGroup { self.pendingGroup = nil; self.selectGroup(g) }
            else if case .logGroup(let g)? = self.tab.pendingNavigation { self.tab.pendingNavigation = nil; self.selectGroup(g) }
            else if let g = self.selectedGroup { self.search(refresh: refresh); _ = g }
        }
    }

    /// Search the selected group in the tab's time range. Results from an older context are dropped.
    private func search(refresh: Bool) {
        stopFollowing()
        let searchToken = UUID(); searchID = searchToken
        guard let group = selectedGroup else { return }
        clearError()
        summary.stringValue = "Searching \(group)…"
        events.emptyMessage = "Searching…"
        events.setRows([])
        message.setText("Select an event to read its full message.")
        let pat = pattern.stringValue
        run { [weak self] in
            guard let self else { return }
            let req = LogsWorkflow.filterEvents(profile: self.tab.profile, region: self.tab.region, group: group, pattern: pat, window: self.tab.window)
            guard let fetched = try await self.tab.fetch(req, usesWindow: true, refresh: refresh), self.selectedGroup == group, self.searchID == searchToken else { return }
            let list = LogsWorkflow.parseEvents(fetched.result.json)
            self.events.emptyMessage = pat.isEmpty ? "No events in this time range" : "No events matching “\(pat)” in this time range"
            self.buffer = LogFollowBuffer(); self.buffer.append(list)
            self.render(list)
            let from = Format.dateTime.string(from: self.tab.window.start), to = Format.dateTime.string(from: self.tab.window.end)
            self.summary.stringValue = "\(list.count) event\(list.count == 1 ? "" : "s") in \(group) · \(from) to \(to)" + (fetched.result.nextToken != nil ? " · more available (narrow the range or pattern)" : "")

        }
    }
    private func render(_ list: [LogEvent]) {
        events.setRows(list.enumerated().map { i, e in
            TableRow(id: e.eventId ?? "\(e.timestamp.timeIntervalSince1970)-\(i)", cells: [Cell(Format.time.string(from: e.timestamp), mono: true), Cell(e.level == .unknown ? "" : e.level.rawValue, color: Theme.levelColor(e.level)),
                Cell(String(e.message.prefix(400)).replacingOccurrences(of: "\n", with: " ⏎ "), color: Theme.levelColor(e.level), mono: true)], payload: e)
        })
    }
    override func deactivate() { stopFollowing() }
    override func contextWillChange() {
        super.contextWillChange(); searchID = UUID()
        groupNames = []; selectedGroup = nil; pendingGroup = nil; buffer = LogFollowBuffer()
        groups.setRows([]); events.setRows([]); message.setText(""); summary.stringValue = ""
    }
    private func stopFollowing() {
        followID = UUID(); followTask?.cancel(); followTask = nil
        followButton.title = "Follow"
    }
    @objc func toggleFollow() {
        if isFollowing { stopFollowing(); summary.stringValue += " · paused"; return }
        guard let group = selectedGroup else { banner.show("Choose a log group before following events.", style: .info); return }
        searchID = UUID() // A previous one-off search must not overwrite this stream.
        let id = UUID(); followID = id
        let pat = pattern.stringValue
        followButton.title = "Stop following"; clearError()
        followTask = tab.track { [weak self] in
            guard let self else { return }
            var since = Date().addingTimeInterval(-60)
            do {
                while !Task.isCancelled && self.followID == id {
                    let end = Date()
                    var req = LogsWorkflow.filterEvents(profile: self.tab.profile, region: self.tab.region, group: group, pattern: pat, window: TimeWindow(start: since, end: end))
                    req.maxItems = 1000
                    guard let pages = try await self.tab.fetchPages(req, refresh: true, maxPages: 10), self.followID == id else { return }
                    self.buffer.append(pages.flatMap { LogsWorkflow.parseEvents($0.result.json) })
                    self.render(self.buffer.events)
                    let capped = pages.last?.result.nextToken != nil
                    self.summary.stringValue = "Following \(group) · every 5 s · \(self.buffer.events.count) buffered events" + (capped ? " · volume limit reached; narrow the filter" : "")

                    // Retain overlap for ingestion delays. A capped poll never advances past unseen events.
                    since = capped ? since : end.addingTimeInterval(-60)
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            } catch is CancellationError {} catch {
                if self.followID == id { self.present(error) }
            }
            if self.followID == id { self.stopFollowing() }
        }
    }

}
