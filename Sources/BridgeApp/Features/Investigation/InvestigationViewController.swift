import BridgeUI
import AppKit
import SwiftUI
import BridgeCore

/// The investigation view: one anchor (for example "example-workload") and the tab's time range, showing every related
/// Lambda function, queue, ECS service, log group and alarm with its status, and charting the selected resource.
@MainActor
final class InvestigationViewController: SectionViewController, NSSearchFieldDelegate {
    private let anchorField = NSSearchField()
    private let investigateButton = NSButton(title: "Investigate", target: nil, action: nil)
    private let savedPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let compareButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let summary = label("", size: 11)
    let resources = DataTable(columns: [ColumnSpec("on", "On", width: 36), ColumnSpec("kind", "Kind", width: 110), ColumnSpec("name", "Name", width: 330),
                                        ColumnSpec("status", "Status", width: 380), ColumnSpec("detail", "Detail", width: 300)])
    let charts = ChartHost()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)

    private(set) var investigation: Investigation
    private var saved: [Investigation] = []
    private var matches: [ResourceRef] = []
    private var statusByRef: [ResourceRef: (text: String, color: NSColor?, detail: String)] = [:]
    private var running = false
    private var generation = UUID()

    override init(tab: TabModel) {
        investigation = Investigation(name: "", profile: tab.profile, region: tab.region, anchor: "")
        super.init(tab: tab)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func contextWillChange() {
        super.contextWillChange()
        generation = UUID(); running = false; matches = []; statusByRef = [:]
        resources.setRows([]); summary.stringValue = ""; charts.clear("Select a resource to inspect its metrics")
    }

    override func build() {
        anchorField.placeholderString = "Workload name, e.g. example-workload"; anchorField.delegate = self
        anchorField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        investigateButton.bezelStyle = .rounded; investigateButton.target = self; investigateButton.action = #selector(investigateClicked)
        saveButton.bezelStyle = .rounded; saveButton.controlSize = .small; saveButton.target = self; saveButton.action = #selector(saveClicked)
        openButton.bezelStyle = .rounded; openButton.controlSize = .small; openButton.target = self; openButton.action = #selector(openClicked); openButton.isEnabled = false
        savedPopup.target = self; savedPopup.action = #selector(savedChosen)
        compareButton.controlSize = .small; compareButton.target = self; compareButton.action = #selector(compareChosen)
        resources.setColumns([ColumnSpec("on", "Include", width: 50, checkbox: true), ColumnSpec("kind", "Type", width: 100), ColumnSpec("name", "Resource", width: 280), ColumnSpec("status", "Status", width: 200)])
        resources.table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        resources.emptyMessage = "Enter a workload name and choose Investigate"
        charts.clear("Select a resource to inspect its metrics")
        let resourceList = WorkspacePane("Related resources", body: resources.view, actions: [saveButton, compareButton, openButton])
        let metrics = WorkspacePane("Selected resource metrics", body: charts.view)
        let split = WorkspaceLayout.split(columns: false, [resourceList, metrics])
        let top = NSView(); let searchBar = WorkspaceLayout.toolbar([anchorField, investigateButton, NSView(), savedPopup])
        for v in [searchBar, summary] as [NSView] { top.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            top.heightAnchor.constraint(equalToConstant: 54), searchBar.topAnchor.constraint(equalTo: top.topAnchor), searchBar.leadingAnchor.constraint(equalTo: top.leadingAnchor), searchBar.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            summary.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 6), summary.leadingAnchor.constraint(equalTo: top.leadingAnchor), summary.trailingAnchor.constraint(equalTo: top.trailingAnchor), summary.heightAnchor.constraint(equalToConstant: 18),
        ])
        WorkspaceLayout.fill(split, in: content, toolbar: top)
        resources.onSelect = { [weak self] row in self?.resourceSelected(row?.payload as? ResourceRef) }
        resources.onToggle = { [weak self] row in self?.toggle(row) }
        resources.onDoubleClick = { [weak self] row in self?.toggle(row) }
        refreshSavedMenus(); loadSaved()
    }

    // MARK: Saved investigations and comparison

    private func loadSaved() { saved = InvestigationStore.load().items; refreshSavedMenus() }

    private func refreshSavedMenus() {
        savedPopup.removeAllItems()
        savedPopup.addItem(withTitle: "Saved")
        for s in saved { savedPopup.addItem(withTitle: "\(s.name.isEmpty ? s.anchor : s.name)  ·  \(s.profile)") }
        if saved.isEmpty { savedPopup.addItem(withTitle: "(none yet)"); savedPopup.lastItem?.isEnabled = false }
        compareButton.removeAllItems()
        compareButton.addItem(withTitle: "Open in profile")
        for n in tab.app.runtime.config.profileNames where n != tab.profile { compareButton.addItem(withTitle: n) }
    }

    @objc private func savedChosen() {
        let i = savedPopup.indexOfSelectedItem - 1
        guard i >= 0, i < saved.count else { return }
        apply(saved[i])
        investigate(refresh: false)
    }

    @objc private func saveClicked() {
        guard !anchorField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        investigation.anchor = anchorField.stringValue
        investigation.profile = tab.profile
        investigation.region = tab.region
        investigation.windowSeconds = tab.windowSeconds
        if investigation.name.isEmpty { investigation.name = investigation.anchor }
        saved.removeAll { $0.id == investigation.id }
        saved.append(investigation)
        do { try InvestigationStore.save(saved); refreshSavedMenus(); summary.stringValue = "Saved “\(investigation.name)”. The file contains the anchor and choices only, no AWS data." }
        catch { present(error) }
    }

    /// Open this investigation in a new tab pointed at another profile (UAT versus production, side by side).
    @objc private func compareChosen() {
        let i = compareButton.indexOfSelectedItem
        guard i > 0, let name = compareButton.titleOfSelectedItem else { return }
        investigation.anchor = anchorField.stringValue
        let other = investigation.retargeted(profile: name, region: tab.app.runtime.region(for: name))
        guard let host = tab.app.windows.first(where: { $0.tab === tab }) else { return }
        let c = tab.app.newTab(joining: host, profile: name)
        c.tab.pendingInvestigation = other
        c.select(.investigation)
    }

    private func apply(_ inv: Investigation) {
        investigation = inv
        anchorField.stringValue = inv.anchor
        if inv.windowSeconds != tab.windowSeconds { tab.setWindowSeconds(inv.windowSeconds) }
    }

    // MARK: Running

    func controlTextDidEndEditing(_ obj: Notification) {
        if let ev = NSApp.currentEvent, ev.type == .keyDown, ev.keyCode == 36 { investigateClicked() }
    }
    @objc private func investigateClicked() { investigate(refresh: true) }

    /// Start an investigation programmatically (used by "Open in profile" and by tests).
    func start(anchor: String) { anchorField.stringValue = anchor; investigate(refresh: true) }

    override var selectionDescription: String? { investigation.anchor.isEmpty ? nil : "investigation anchor \"\(investigation.anchor)\"" }

    override func reload(refresh: Bool) {
        if let p = tab.pendingInvestigation { tab.pendingInvestigation = nil; apply(p) }
        if !anchorField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { investigate(refresh: refresh) }
    }

    func investigate(refresh: Bool) {
        let anchor = anchorField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !anchor.isEmpty, !running else { return }
        investigation.anchor = anchor
        clearError()
        resources.emptyMessage = "Searching…"
        resources.setRows([])
        charts.clear("Select a Lambda function or queue to see its metrics")
        summary.stringValue = "Looking for “\(anchor)” in \(tab.profile) · \(tab.region)…"
        running = true
        let runID = UUID(); generation = runID
        run { [weak self] in
            guard let self else { return }
            defer { if self.generation == runID { self.running = false } }
            var notes: [String] = []
            let p = self.tab.profile, r = self.tab.region

            /// A failure in one service must not hide the others, except a lost session, which applies to all.
            func optional<T>(_ what: String, _ block: () async throws -> T?) async throws -> T? {
                do { return try await block() }
                catch let e as CancellationError { throw e }
                catch ExecError.authExpired { throw ExecError.authExpired(stderr: "") }
                catch { notes.append("\(what): \(ErrorText.describe(error).message)"); return nil }
            }

            var cand = DiscoveryCandidates()
            if let pages = try await optional("Lambda", { try await self.tab.fetchPages(LambdaWorkflow.listFunctions(profile: p, region: r), refresh: refresh) }) {
                cand.lambdas = pages.flatMap { LambdaWorkflow.parseFunctions($0.result.json) }.map(\.name)
            }
            if let pages = try await optional("SQS", { try await self.tab.fetchPages(SqsWorkflow.listQueues(profile: p, region: r), refresh: refresh) }) {
                cand.queues = pages.flatMap { SqsWorkflow.parseQueues($0.result.json) }
            }
            if let pages = try await optional("CloudWatch Logs", { try await self.tab.fetchPages(LogsWorkflow.describeGroups(profile: p, region: r, maxItems: 500), refresh: refresh, maxPages: 2) }) {
                cand.logGroups = pages.flatMap { LogsWorkflow.parseGroups($0.result.json) }.map(\.name)
            }
            var alarms: [AlarmSummary] = []
            if let pages = try await optional("Alarms", { try await self.tab.fetchPages(MetricsWorkflow.alarmsInAlarm(profile: p, region: r), refresh: refresh) }) {
                alarms = pages.flatMap { MetricsWorkflow.parseAlarms($0.result.json) }
                cand.alarms = alarms.map(\.name)
            }
            var ecsServices: [String: EcsService] = [:]  // "cluster/service"
            if let clusterPages = try await optional("ECS", { try await self.tab.fetchPages(EcsWorkflow.listClusters(profile: p, region: r), refresh: refresh) }) {
                // Explicit types: `flatMap{...}.compactMap{ $0.split(...) }` type-checks even when `$0` is an array.
                let clusterArns: [String] = clusterPages.flatMap { EcsWorkflow.arns($0.result.json, key: "clusterArns") }
                let clusterNames: [String] = clusterArns.compactMap { (arn: String) -> String? in arn.split(separator: "/").last.map(String.init) }
                for cluster in clusterNames.prefix(10) {
                    guard let sp = try await optional("ECS \(cluster)", { try await self.tab.fetchPages(EcsWorkflow.listServices(profile: p, region: r, cluster: cluster), refresh: refresh) }) else { continue }
                    let serviceArns: [String] = sp.flatMap { EcsWorkflow.arns($0.result.json, key: "serviceArns") }
                    for arn in serviceArns {
                        if let name = arn.split(separator: "/").last.map(String.init) { cand.ecsServices.append(EcsServiceName(cluster: cluster, name: name)) }
                    }
                }
            }

            self.investigation.profile = p; self.investigation.region = r
            guard self.generation == runID, !Task.isCancelled else { return }
            self.matches = InvestigationDiscovery.matches(anchor: anchor, in: cand)
            let resolved = InvestigationDiscovery.resolve(self.investigation, matches: self.matches)
            self.statusByRef = [:]
            let alarmByName = Dictionary(uniqueKeysWithValues: alarms.map { ($0.name, $0) })
            for a in resolved where a.kind == .alarm {
                if let al = alarmByName[a.name] { self.statusByRef[a] = ("IN ALARM", .systemRed, al.reason ?? "") }
            }
            guard self.generation == runID, !Task.isCancelled else { return }
            self.render(resolved)

            // Status for ECS services: one describe per cluster.
            let byCluster = Dictionary(grouping: resolved.filter { $0.kind == .ecsService }, by: { $0.detail ?? "" })
            for (cluster, refs) in byCluster {
                for req in EcsWorkflow.describeServices(profile: p, region: r, cluster: cluster, services: refs.map(\.name)) {
                    if let f = try await optional("ECS \(cluster)", { try await self.tab.fetch(req, refresh: refresh) }) {
                        for s in EcsWorkflow.parseServices(f.result.json) {
                            ecsServices["\(cluster)/\(s.name)"] = s
                            let ref = ResourceRef(kind: .ecsService, name: s.name, detail: cluster)
                            let bad = s.deployments.contains { $0.rolloutState == "FAILED" } || s.running == 0
                            self.statusByRef[ref] = (s.isHealthy ? "healthy" : "attention", s.isHealthy ? .systemGreen : (bad ? .systemRed : .systemOrange),
                                                     "\(s.running)/\(s.desired) running" + (s.pending > 0 ? ", \(s.pending) pending" : ""))
                        }
                    }
                }
            }
            guard self.generation == runID, !Task.isCancelled else { return }
            self.render(resolved)

            // Status for queues: attributes.
            for ref in resolved.filter({ $0.kind == .sqsQueue }).prefix(15) {
                guard let url = ref.detail, let f = try await optional("SQS", { try await self.tab.fetch(SqsWorkflow.getAttributes(profile: p, region: r, queueUrl: url), refresh: refresh) }),
                      let a = SqsWorkflow.parseAttributes(f.result.json) else { continue }
                let backlog = a.visible ?? 0
                self.statusByRef[ref] = ("\(backlog) waiting", backlog > 1000 ? .systemOrange : nil, "\(a.inFlight ?? 0) in flight" + (a.deadLetterQueueName.map { " · DLQ \($0)" } ?? ""))
            }
            guard self.generation == runID, !Task.isCancelled else { return }
            self.render(resolved)

            // Status for Lambda functions: errors and invocations over the window, in one metrics call.
            let fns = resolved.filter { $0.kind == .lambdaFunction }.prefix(100)
            if !fns.isEmpty {
                var specs: [MetricSpec] = []
                for f in fns { specs += [MetricSpec(namespace: "AWS/Lambda", name: "Errors", dimensions: [("FunctionName", f.name)], stat: "Sum"),
                                         MetricSpec(namespace: "AWS/Lambda", name: "Invocations", dimensions: [("FunctionName", f.name)], stat: "Sum")] }
                let req = MetricsWorkflow.query(profile: p, region: r, window: self.tab.window, specs: specs)
                if let mf = try await optional("Lambda metrics", { try await self.tab.fetch(req, usesWindow: true, refresh: refresh) }) {
                    let series = MetricsWorkflow.parseSeries(mf.result.json)
                    for (i, f) in fns.enumerated() {
                        let errs = series.first { $0.id == "m\(i * 2)" }?.points.reduce(0) { $0 + $1.value } ?? 0
                        let inv = series.first { $0.id == "m\(i * 2 + 1)" }?.points.reduce(0) { $0 + $1.value } ?? 0
                        self.statusByRef[f] = (errs > 0 ? "\(Int(errs)) errors" : "no errors", errs > 0 ? .systemRed : .systemGreen, "\(Int(inv)) invocations in range")
                    }
                }
            }
            guard self.generation == runID, !Task.isCancelled else { return }
            self.render(resolved)
            self.summary.stringValue = "\(resolved.count) resource\(resolved.count == 1 ? "" : "s") match “\(anchor)” · \(Format.dateTime.string(from: self.tab.window.start)) to \(Format.dateTime.string(from: self.tab.window.end))"
                + (notes.isEmpty ? "" : " · some sources unavailable: " + notes.joined(separator: "; "))

        }
    }

    private func render(_ resolved: [ResourceRef]) {
        let excluded = Set(investigation.excluded)
        let all = resolved + matches.filter { excluded.contains($0) }
        resources.emptyMessage = "Nothing matches “\(investigation.anchor)” in \(tab.profile) · \(tab.region)"
        func order(_ k: ResourceKind) -> Int { [ResourceKind.alarm, .ecsService, .lambdaFunction, .sqsQueue, .logGroup].firstIndex(of: k) ?? 9 }
        resources.setRows(all.sorted { (order($0.kind), $0.name) < (order($1.kind), $1.name) }.map { ref in
            let st = statusByRef[ref]
            let off = excluded.contains(ref)
            return TableRow(id: "\(ref.kind.rawValue):\(ref.detail ?? ""):\(ref.name)",
                            cells: [Cell(off ? "☐" : "☑"), Cell(Self.kindTitle(ref.kind), color: .secondaryLabelColor), Cell(ref.name, color: off ? .tertiaryLabelColor : nil, bold: !off),
                                    Cell(st?.text ?? (off ? "excluded" : ""), color: st?.color), Cell(ref.kind == .ecsService ? "\(ref.detail ?? "")  \(st?.detail ?? "")" : (st?.detail ?? ""), color: .secondaryLabelColor)],
                            payload: ref)
        })
    }

    static func kindTitle(_ k: ResourceKind) -> String {
        switch k { case .lambdaFunction: return "Lambda"; case .ecsService: return "ECS service"; case .sqsQueue: return "SQS queue"; case .logGroup: return "Log group"; case .alarm: return "Alarm" }
    }

    private func toggle(_ row: TableRow) {
        guard let ref = row.payload as? ResourceRef else { return }
        if let i = investigation.excluded.firstIndex(of: ref) { investigation.excluded.remove(at: i) } else { investigation.excluded.append(ref) }
        render(InvestigationDiscovery.resolve(investigation, matches: matches))
    }

    private func resourceSelected(_ ref: ResourceRef?) {
        openButton.isEnabled = ref != nil
        guard let ref else { charts.clear("Select a Lambda function or queue to see its metrics"); return }
        switch ref.kind {
        case .lambdaFunction:
            charts.clear("Loading metrics…")
            run { [weak self] in
                guard let self else { return }
                let req = MetricsWorkflow.query(profile: self.tab.profile, region: self.tab.region, window: self.tab.window, specs: MetricsWorkflow.lambdaSpecs(function: ref.name))
                guard let f = try await self.tab.fetch(req, usesWindow: true), (self.resources.selectedRow?.payload as? ResourceRef) == ref else { return }
                self.charts.show(series: MetricsWorkflow.parseSeries(f.result.json),
                                 specs: [("m0", "Invocations", .blue, true), ("m1", "Errors", .red, true), ("m2", "Throttles", .orange, true), ("m3", "Duration, average (ms)", .purple, false)], window: self.tab.window)
            }
        case .sqsQueue:
            charts.clear("Loading metrics…")
            run { [weak self] in
                guard let self else { return }
                let req = MetricsWorkflow.query(profile: self.tab.profile, region: self.tab.region, window: self.tab.window, specs: MetricsWorkflow.sqsSpecs(queueName: ref.name))
                guard let f = try await self.tab.fetch(req, usesWindow: true), (self.resources.selectedRow?.payload as? ResourceRef) == ref else { return }
                self.charts.show(series: MetricsWorkflow.parseSeries(f.result.json),
                                 specs: [("m0", "Visible messages", .blue, false), ("m1", "Oldest message age (seconds)", .orange, false)], window: self.tab.window)
            }
        default:
            charts.clear("No metrics for this kind of resource. Use Open to see its details.")
        }
    }

    @objc private func openClicked() {
        guard let ref = resources.selectedRow?.payload as? ResourceRef else { return }
        switch ref.kind {
        case .lambdaFunction: tab.navigate(.lambda(ref.name))
        case .logGroup: tab.navigate(.logGroup(ref.name))
        case .sqsQueue: tab.navigate(.sqsQueue(ref.name))
        case .ecsService: tab.app.windows.first { $0.tab === tab }?.select(.ecs)
        case .alarm: tab.app.windows.first { $0.tab === tab }?.select(.alarms)
        }
    }
}
