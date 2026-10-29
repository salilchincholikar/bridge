import BridgeUI
import AppKit
import BridgeCore

/// W1: Lambda functions, with configuration, masked environment, and links to the log group and execution role.
@MainActor
final class LambdaViewController: SectionViewController, NSSearchFieldDelegate {
    private let filterField = NSSearchField()
    let table = DataTable(columns: [
        ColumnSpec("name", "Name", width: 300), ColumnSpec("runtime", "Runtime", width: 110),
        ColumnSpec("memory", "Memory (MB)", width: 90, numeric: true, rightAligned: true),
        ColumnSpec("timeout", "Timeout (s)", width: 90, numeric: true, rightAligned: true), ColumnSpec("modified", "Last modified", width: 160),
    ])
    let detail = TextPane(monospaced: false)
    private let openLogs = NSButton(title: "Open log group", target: nil, action: nil)
    private let openRole = NSButton(title: "Open execution role", target: nil, action: nil)
    private let reveal = NSButton(checkboxWithTitle: "Reveal environment values", target: nil, action: nil)

    private var functions: [LambdaFunction] = []
    private var selected: LambdaFunction?
    private var detailFunction: LambdaFunction?

    override func contextWillChange() {
        super.contextWillChange()
        functions = []; selected = nil; detailFunction = nil; reveal.state = .off
        table.setRows([]); showDetail(nil)
    }

    override func build() {
        filterField.placeholderString = "Filter functions"; filterField.delegate = self
        filterField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        table.setColumns([ColumnSpec("name", "Function", width: 260), ColumnSpec("runtime", "Runtime", width: 100)])
        for b in [openLogs, openRole] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self }
        openLogs.action = #selector(logsClicked); openRole.action = #selector(roleClicked)
        reveal.target = self; reveal.action = #selector(revealToggled); reveal.controlSize = .small
        let inspector = NSView()
        let actions = WorkspaceLayout.toolbar([openLogs, openRole, NSView()])
        let privacy = WorkspaceLayout.toolbar([reveal, NSView()])
        for v in [actions, detail.scroll, privacy] as [NSView] { inspector.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: inspector.topAnchor), actions.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 6), actions.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -6),
            detail.scroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 8), detail.scroll.leadingAnchor.constraint(equalTo: inspector.leadingAnchor), detail.scroll.trailingAnchor.constraint(equalTo: inspector.trailingAnchor),
            privacy.topAnchor.constraint(equalTo: detail.scroll.bottomAnchor, constant: 4), privacy.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 6), privacy.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -6), privacy.bottomAnchor.constraint(equalTo: inspector.bottomAnchor),
        ])
        let list = WorkspacePane("Functions", body: table.view)
        let configuration = WorkspacePane("Configuration", body: inspector)
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        configuration.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        WorkspaceLayout.fill(WorkspaceLayout.split(columns: true, [list, configuration]), in: content, toolbar: WorkspaceLayout.toolbar([filterField, NSView()]))
        table.onSelect = { [weak self] row in self?.rowSelected(row) }; showDetail(nil)
    }

    func controlTextDidChange(_ obj: Notification) { table.filter = filterField.stringValue }

    override var selectionDescription: String? { selected.map { "Lambda function \($0.name)" } }

    override func reload(refresh: Bool) {
        clearError()
        table.emptyMessage = "Loading…"
        table.setRows([])
        run { [weak self] in
            guard let self else { return }
            guard let pages = try await self.tab.fetchPages(LambdaWorkflow.listFunctions(profile: self.tab.profile, region: self.tab.region), refresh: refresh) else { return }
            self.functions = pages.flatMap { LambdaWorkflow.parseFunctions($0.result.json) }.sorted { $0.name < $1.name }
            self.table.emptyMessage = "No Lambda functions in \(self.tab.region)"
            self.table.setRows(self.functions.map { f in
                TableRow(id: f.name, cells: [Cell(f.name, bold: true), Cell(f.runtime ?? ""), Cell(Format.opt(f.memoryMB)), Cell(Format.opt(f.timeoutSeconds)), Cell(Format.date(f.lastModified))], payload: f)
            })

            if case .lambda(let name)? = self.tab.pendingNavigation { self.tab.pendingNavigation = nil; self.handle(.lambda(name)) }
            else if let s = self.selected, self.functions.contains(where: { $0.name == s.name }) { self.loadDetail(s, refresh: refresh) }
        }
    }

    override func handle(_ navigation: Navigation) {
        guard case .lambda(let name) = navigation else { return }
        if let idx = table.rows.firstIndex(where: { $0.id == name }) {
            table.table.selectRowIndexes([idx], byExtendingSelection: false)
            table.table.scrollRowToVisible(idx)
        }
    }

    private func rowSelected(_ row: TableRow?) {
        guard let f = row?.payload as? LambdaFunction else { selected = nil; showDetail(nil); return }
        selected = f
        reveal.state = .off
        loadDetail(f, refresh: false)
    }

    private func loadDetail(_ f: LambdaFunction, refresh: Bool) {
        showDetail(f, loading: true)
        run { [weak self] in
            guard let self else { return }
            guard let fetched = try await self.tab.fetch(LambdaWorkflow.getConfiguration(profile: self.tab.profile, region: self.tab.region, function: f.name), refresh: refresh),
                  self.selected?.name == f.name else { return }
            // The configuration is sensitive (environment values): it is never cached, so this is a live call.
            self.detailFunction = LambdaWorkflow.parseFunction(fetched.result.json ?? .null) ?? f
            self.showDetail(self.detailFunction)
        }
    }

    private func showDetail(_ f: LambdaFunction?, loading: Bool = false) {
        openLogs.isEnabled = f != nil
        openRole.isEnabled = f?.roleArn.flatMap { InvestigationLinks.roleName(fromArn: $0) } != nil
        reveal.isEnabled = f != nil && !(f?.environmentKeys.isEmpty ?? true)
        guard let f else { detail.setText("Select a function to see its configuration."); return }
        var pairs: [(String, String)] = [("Name", f.name), ("Runtime", f.runtime ?? "-"), ("Handler", f.handler ?? "-"),
                                         ("Memory", f.memoryMB.map { "\($0) MB" } ?? "-"), ("Timeout", f.timeoutSeconds.map { "\($0) s" } ?? "-"),
                                         ("Last modified", Format.date(f.lastModified)), ("Execution role", f.roleArn ?? "-"), ("Log group", f.logGroup)]
        if let d = f.description { pairs.append(("Description", d)) }
        if !f.layers.isEmpty { pairs.append(("Layers", f.layers.joined(separator: "\n"))) }
        if loading { pairs.append(("Environment", "loading…")) }
        else if f.environmentKeys.isEmpty { pairs.append(("Environment", "none")) }
        else {
            let shown = reveal.state == .on
            pairs.append(("Environment", f.environmentKeys.map { "\($0) = \(shown ? (f.environment[$0] ?? "") : "••••••••")" }.joined(separator: "\n")))
        }
        detail.setPairs(pairs)
    }

    @objc private func revealToggled() { showDetail(detailFunction ?? selected) }
    @objc private func logsClicked() { if let f = detailFunction ?? selected { tab.navigate(.logGroup(f.logGroup)) } }
    @objc private func roleClicked() {
        if let name = InvestigationLinks.roleName(fromArn: (detailFunction ?? selected)?.roleArn) { tab.navigate(.iamRole(name)) }
    }
}
