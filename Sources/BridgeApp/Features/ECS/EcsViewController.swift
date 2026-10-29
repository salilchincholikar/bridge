import BridgeUI
import AppKit
import BridgeCore

/// W2: ECS. Cluster, services with health, deployments and events, stopped tasks with their reasons, and a link to the logs.
@MainActor
final class EcsViewController: SectionViewController, NSSearchFieldDelegate {
    private let clusterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let filterField = NSSearchField()
    let services = DataTable(columns: [ColumnSpec("name", "Service", width: 260), ColumnSpec("health", "Health", width: 80),
                                       ColumnSpec("desired", "Desired", width: 70, numeric: true, rightAligned: true), ColumnSpec("running", "Running", width: 70, numeric: true, rightAligned: true),
                                       ColumnSpec("pending", "Pending", width: 70, numeric: true, rightAligned: true), ColumnSpec("td", "Task definition", width: 220), ColumnSpec("rollout", "Rollout", width: 110)])
    let tasks = DataTable(columns: [ColumnSpec("task", "Stopped task", width: 110), ColumnSpec("when", "Stopped at", width: 150), ColumnSpec("code", "Stop code", width: 170), ColumnSpec("reason", "Reason", width: 500)])
    let detail = TextPane(monospaced: false)
    private let openLogs = NSButton(title: "Open log group", target: nil, action: nil)
    private let openRole = NSButton(title: "Open task role", target: nil, action: nil)

    private var clusters: [EcsCluster] = []
    private var currentCluster: String?
    private var selectedService: EcsService?
    private var taskDefinition: EcsTaskDefinition?

    override func contextWillChange() {
        super.contextWillChange()
        clusters = []; currentCluster = nil; selectedService = nil; taskDefinition = nil
        services.setRows([]); tasks.setRows([]); clusterPopup.removeAllItems()
        detail.setText("Select a service to inspect it."); openLogs.isEnabled = false; openRole.isEnabled = false
    }

    override func build() {
        clusterPopup.target = self; clusterPopup.action = #selector(clusterChanged)
        clusterPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        filterField.placeholderString = "Filter services"; filterField.delegate = self
        filterField.widthAnchor.constraint(equalToConstant: 190).isActive = true
        for b in [openLogs, openRole] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self; b.isEnabled = false }
        openLogs.title = "Logs"; openLogs.toolTip = "Open log group"
        openRole.title = "Role"; openRole.toolTip = "Open task role"
        openLogs.action = #selector(logsClicked); openRole.action = #selector(roleClicked)
        services.setColumns([ColumnSpec("name", "Service", width: 240), ColumnSpec("health", "Health", width: 100), ColumnSpec("desired", "Desired", width: 65, rightAligned: true), ColumnSpec("running", "Running", width: 65, rightAligned: true), ColumnSpec("rollout", "Rollout", width: 130, cellIndex: 6)])
        tasks.table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tasks.setColumns([ColumnSpec("task", "Task", width: 90), ColumnSpec("when", "Stopped", width: 125), ColumnSpec("reason", "Reason", width: 280, cellIndex: 3)])
        tasks.emptyMessage = "Select a service to see its stopped tasks"
        let metadata = WorkspacePane("Service details", body: detail.scroll, actions: [openLogs, openRole])
        metadata.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let stopped = WorkspacePane("Recently stopped tasks", body: tasks.view)
        let bottom = WorkspaceLayout.split(columns: true, [metadata, stopped])
        let servicePane = WorkspacePane("Services", body: services.view)
        let body = WorkspaceLayout.split(columns: false, [servicePane, bottom])
        WorkspaceLayout.fill(body, in: content, toolbar: WorkspaceLayout.toolbar([label("Cluster", color: .labelColor), clusterPopup, NSView(), filterField]))
        services.onSelect = { [weak self] row in self?.serviceSelected(row?.payload as? EcsService) }
        detail.setText("Select a service to inspect its configuration, deployments and recent events.")
    }

    func controlTextDidChange(_ obj: Notification) { services.filter = filterField.stringValue }

    override var selectionDescription: String? { selectedService.map { "ECS service \($0.name) in cluster \(currentCluster ?? "?")" } ?? currentCluster.map { "ECS cluster \($0)" } }

    override func reload(refresh: Bool) {
        clearError()
        services.emptyMessage = "Loading…"
        services.setRows([])
        run { [weak self] in
            guard let self else { return }
            guard let listPages = try await self.tab.fetchPages(EcsWorkflow.listClusters(profile: self.tab.profile, region: self.tab.region), refresh: refresh) else { return }
            let arns = listPages.flatMap { EcsWorkflow.arns($0.result.json, key: "clusterArns") }
            var found: [EcsCluster] = []
            for req in EcsWorkflow.describeClusters(profile: self.tab.profile, region: self.tab.region, arns: arns) {
                guard let f = try await self.tab.fetch(req, refresh: refresh) else { return }
                found += EcsWorkflow.parseClusters(f.result.json)
            }
            self.clusters = found
            self.clusterPopup.removeAllItems()
            self.clusterPopup.addItems(withTitles: found.map { "\($0.name)  (\($0.runningTasks ?? 0) running)" })
            if found.isEmpty { self.services.emptyMessage = "No ECS clusters in \(self.tab.region)"; return }
            let keep = found.firstIndex { $0.name == self.currentCluster } ?? 0
            self.clusterPopup.selectItem(at: keep)
            self.currentCluster = found[keep].name

            try await self.loadServices(refresh: refresh)
        }
    }

    @objc private func clusterChanged() {
        let i = clusterPopup.indexOfSelectedItem
        guard i >= 0, i < clusters.count else { return }
        currentCluster = clusters[i].name
        selectedService = nil
        run { [weak self] in try await self?.loadServices(refresh: false) }
    }

    private func loadServices(refresh: Bool) async throws {
        guard let cluster = currentCluster else { return }
        services.emptyMessage = "Loading…"
        services.setRows([])
        guard let listPages = try await tab.fetchPages(EcsWorkflow.listServices(profile: tab.profile, region: tab.region, cluster: cluster), refresh: refresh),
              cluster == currentCluster else { return }
        let arns = listPages.flatMap { EcsWorkflow.arns($0.result.json, key: "serviceArns") }
        var all: [EcsService] = []
        for req in EcsWorkflow.describeServices(profile: tab.profile, region: tab.region, cluster: cluster, services: arns) {
            guard let f = try await tab.fetch(req, refresh: refresh), cluster == currentCluster else { return }
            all += EcsWorkflow.parseServices(f.result.json)

        }
        services.emptyMessage = "No services in \(cluster)"
        services.setRows(all.sorted { $0.name < $1.name }.map { s in
            let rollout = s.deployments.first { $0.status == "PRIMARY" }?.rolloutState ?? ""
            let healthy = s.isHealthy
            let color: NSColor = healthy ? .systemGreen : (rollout == "FAILED" || s.running == 0 ? .systemRed : .systemOrange)
            return TableRow(id: s.name, cells: [Cell(s.name, bold: true), Cell(healthy ? "● healthy" : "● attention", color: color), Cell("\(s.desired)"), Cell("\(s.running)"),
                                                Cell("\(s.pending)"), Cell(s.taskDefinition.map { String($0.split(separator: "/").last ?? "") } ?? ""), Cell(rollout, color: rollout == "FAILED" ? .systemRed : nil)], payload: s)
        })
    }

    private func serviceSelected(_ s: EcsService?) {
        selectedService = s
        taskDefinition = nil
        openLogs.isEnabled = false
        openRole.isEnabled = false
        tasks.setRows([])
        guard let s else { detail.setText("Select a service."); return }
        showDetail(s, td: nil)
        tasks.emptyMessage = "Loading…"
        run { [weak self] in
            guard let self, let cluster = self.currentCluster else { return }
            // Task definition (log group and roles).
            if let tdArn = s.taskDefinition, let f = try await self.tab.fetch(EcsWorkflow.describeTaskDefinition(profile: self.tab.profile, region: self.tab.region, taskDefinition: tdArn)), self.selectedService?.name == s.name {
                self.taskDefinition = EcsWorkflow.parseTaskDefinition(f.result.json)
                self.showDetail(s, td: self.taskDefinition)
                self.openLogs.isEnabled = !(self.taskDefinition.map(InvestigationLinks.ecsLogGroups)?.isEmpty ?? true)
                self.openRole.isEnabled = self.taskDefinition?.taskRoleArn.flatMap { InvestigationLinks.roleName(fromArn: $0) } != nil
            }
            // Stopped tasks: list ARNs, then describe them.
            guard let listed = try await self.tab.fetch(EcsWorkflow.listTasks(profile: self.tab.profile, region: self.tab.region, cluster: cluster, service: s.name, desiredStatus: "STOPPED")),
                  self.selectedService?.name == s.name else { return }
            let arns = EcsWorkflow.arns(listed.result.json, key: "taskArns")
            var stopped: [EcsTask] = []
            for req in EcsWorkflow.describeTasks(profile: self.tab.profile, region: self.tab.region, cluster: cluster, tasks: arns) {
                guard let f = try await self.tab.fetch(req), self.selectedService?.name == s.name else { return }
                stopped += EcsWorkflow.parseTasks(f.result.json)
            }
            self.tasks.emptyMessage = "No stopped tasks for \(s.name) (stopped tasks stay visible for about an hour)"
            self.tasks.setRows(stopped.sorted { ($0.stoppedAt ?? .distantPast) > ($1.stoppedAt ?? .distantPast) }.map { t in
                let reason = t.stoppedReason ?? t.containers.compactMap { $0.reason }.first ?? ""
                let codes = t.containers.compactMap { $0.exitCode }.map { "exit \($0)" }.joined(separator: ", ")
                return TableRow(id: t.arn, cells: [Cell(t.id, mono: true), Cell(Format.date(t.stoppedAt)), Cell(t.stopCode ?? ""), Cell(codes.isEmpty ? reason : "\(reason)  (\(codes))", color: .systemRed)], payload: t)
            })
        }
    }

    private func showDetail(_ s: EcsService, td: EcsTaskDefinition?) {
        var pairs: [(String, String)] = [("Service", s.name), ("Status", s.status ?? "-"), ("Counts", "desired \(s.desired) · running \(s.running) · pending \(s.pending)"),
                                         ("Launch type", s.launchType ?? "-")]
        if let td {
            pairs.append(("Task definition", "\(td.family):\(td.revision ?? 0)"))
            pairs.append(("Task role", td.taskRoleArn ?? "-"))
            pairs.append(("Execution role", td.executionRoleArn ?? "-"))
            for c in td.containers { pairs.append(("Container \(c.name)", "\(c.image ?? "-")\(c.logGroup.map { "\nlogs: \($0)" } ?? "")")) }
        }
        pairs.append(("Deployments", s.deployments.map { d in
            "\(d.status ?? "?") \(d.rolloutState ?? "") · \(d.running ?? 0)/\(d.desired ?? 0) running" + ((d.failed ?? 0) > 0 ? " · \(d.failed!) failed tasks" : "") + (d.created.map { " · since \(Format.date($0))" } ?? "")
        }.joined(separator: "\n")))
        pairs.append(("Recent events", s.events.prefix(8).map { e in "\(e.created.map(Format.dateTime.string(from:)) ?? "")  \(e.message)" }.joined(separator: "\n")))
        detail.setPairs(pairs)
    }

    @objc private func logsClicked() { if let g = taskDefinition.map(InvestigationLinks.ecsLogGroups)?.first { tab.navigate(.logGroup(g)) } }
    @objc private func roleClicked() { if let n = InvestigationLinks.roleName(fromArn: taskDefinition?.taskRoleArn) { tab.navigate(.iamRole(n)) } }
}
