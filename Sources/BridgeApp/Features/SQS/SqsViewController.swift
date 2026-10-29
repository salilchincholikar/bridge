import BridgeUI
import AppKit
import SwiftUI
import BridgeCore

/// W6: SQS. Attributes, DLQ, consumers and metrics. Never reads messages (receive-message hides them from real consumers).
@MainActor
final class SqsViewController: SectionViewController, NSSearchFieldDelegate {
    private let filterField = NSSearchField()
    let queues = DataTable(columns: [ColumnSpec("name", "Queue", width: 320)])
    let detail = TextPane(monospaced: false)
    let charts = ChartHost()
    private let openConsumer = NSButton(title: "Open consumer", target: nil, action: nil)
    private let openDlq = NSButton(title: "Open dead-letter queue", target: nil, action: nil)

    private var all: [SqsQueue] = []
    private(set) var selected: SqsQueue?
    private(set) var attributes: SqsQueueAttributes?
    private var consumers: [String] = []

    override func contextWillChange() {
        super.contextWillChange()
        all = []; selected = nil; attributes = nil; consumers = []
        queues.setRows([]); detail.setText("Select a queue to inspect it."); charts.clear("Select a queue to see its metrics")
        openConsumer.isEnabled = false; openDlq.isEnabled = false
    }

    override func build() {
        filterField.placeholderString = "Filter queues"; filterField.delegate = self
        filterField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        for b in [openConsumer, openDlq] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self; b.isEnabled = false }
        openConsumer.action = #selector(consumerClicked); openDlq.action = #selector(dlqClicked)
        let queueList = WorkspacePane("Queues", body: queues.view)
        WorkspaceLayout.listWidth(queueList)
        let details = WorkspacePane("Queue attributes", body: detail.scroll)
        let metrics = WorkspacePane("Queue metrics", body: charts.view)
        let right = WorkspaceLayout.split(columns: false, [details, metrics])
        WorkspaceLayout.fill(WorkspaceLayout.split(columns: true, [queueList, right]), in: content,
            toolbar: WorkspaceLayout.toolbar([filterField, NSView(), openConsumer, openDlq]))
        queues.onSelect = { [weak self] row in self?.queueSelected(row?.payload as? SqsQueue) }
        detail.setText("Select a queue to see its attributes and relationships.")
        charts.clear("Select a queue to see its metrics")
    }

    func controlTextDidChange(_ obj: Notification) { queues.filter = filterField.stringValue }

    override var selectionDescription: String? { selected.map { "SQS queue \($0.name)" } }

    override func reload(refresh: Bool) {
        clearError()
        queues.emptyMessage = "Loading…"
        queues.setRows([])
        run { [weak self] in
            guard let self else { return }
            guard let pages = try await self.tab.fetchPages(SqsWorkflow.listQueues(profile: self.tab.profile, region: self.tab.region), refresh: refresh) else { return }
            self.all = pages.flatMap { SqsWorkflow.parseQueues($0.result.json) }.sorted { $0.name < $1.name }
            self.queues.emptyMessage = "No SQS queues in \(self.tab.region)"
            self.queues.setRows(self.all.map { TableRow(id: $0.name, cells: [Cell($0.name, bold: true)], payload: $0) })

            if case .sqsQueue(let n)? = self.tab.pendingNavigation { self.tab.pendingNavigation = nil; self.handle(.sqsQueue(n)) }
            else if let s = self.selected, self.all.contains(where: { $0.name == s.name }) { self.loadQueue(s, refresh: refresh) }
        }
    }

    override func handle(_ navigation: Navigation) {
        guard case .sqsQueue(let name) = navigation, let idx = queues.rows.firstIndex(where: { $0.id == name }) else { return }
        queues.table.selectRowIndexes([idx], byExtendingSelection: false)
        queues.table.scrollRowToVisible(idx)
    }

    private func queueSelected(_ q: SqsQueue?) {
        selected = q
        attributes = nil
        consumers = []
        openConsumer.isEnabled = false
        openDlq.isEnabled = false
        guard let q else { detail.setText("Select a queue."); charts.clear("Select a queue to see its metrics"); return }
        loadQueue(q, refresh: false)
    }

    private func loadQueue(_ q: SqsQueue, refresh: Bool) {
        detail.setText("Loading \(q.name)…")
        charts.clear("Loading metrics…")
        run { [weak self] in
            guard let self else { return }
            guard let f = try await self.tab.fetch(SqsWorkflow.getAttributes(profile: self.tab.profile, region: self.tab.region, queueUrl: q.url), refresh: refresh),
                  self.selected?.name == q.name else { return }
            self.attributes = SqsWorkflow.parseAttributes(f.result.json)

            self.showDetail(q)
            self.openDlq.isEnabled = self.attributes?.deadLetterQueueName != nil
            // Consumers: one filtered call by the queue's ARN.
            if let arn = self.attributes?.arn,
               let m = try await self.tab.fetch(LambdaWorkflow.eventSourceMappings(profile: self.tab.profile, region: self.tab.region, sourceArn: arn), refresh: refresh),
               self.selected?.name == q.name {
                self.consumers = LambdaWorkflow.parseEventSources(m.result.json).compactMap(\.functionName)
                self.showDetail(q)
                self.openConsumer.isEnabled = !self.consumers.isEmpty
            }
            // Metrics over the tab's time window.
            let req = MetricsWorkflow.query(profile: self.tab.profile, region: self.tab.region, window: self.tab.window, specs: MetricsWorkflow.sqsSpecs(queueName: q.name))
            if let mf = try await self.tab.fetch(req, usesWindow: true, refresh: refresh), self.selected?.name == q.name {
                self.charts.show(series: MetricsWorkflow.parseSeries(mf.result.json),
                                 specs: [("m0", "Visible messages", .blue, false), ("m1", "Oldest message age (seconds)", .orange, false)], window: self.tab.window)
            }
        }
    }

    private func showDetail(_ q: SqsQueue) {
        guard let a = attributes else { detail.setText("No attributes returned for \(q.name)."); return }
        var pairs: [(String, String)] = [("Queue", q.name), ("Visible", a.visible.map(String.init) ?? "-"), ("In flight", a.inFlight.map(String.init) ?? "-"),
                                         ("Delayed", a.delayed.map(String.init) ?? "-"), ("Visibility timeout", a.visibilityTimeoutSeconds.map { Format.duration($0) } ?? "-"),
                                         ("Retention", a.retentionSeconds.map { Format.duration($0) } ?? "-"), ("Type", a.isFifo ? "FIFO" : "standard")]
        if let d = a.deadLetterQueueName { pairs.append(("Dead-letter queue", "\(d)  (after \(a.maxReceiveCount.map(String.init) ?? "?") receives)")) }
        pairs.append(("Consumers", consumers.isEmpty ? "none found" : consumers.joined(separator: "\n")))
        pairs.append(("Messages", "Not shown: reading messages would hide them from real consumers."))
        detail.setPairs(pairs)
    }

    @objc private func consumerClicked() { if let c = consumers.first { tab.navigate(.lambda(c)) } }
    @objc private func dlqClicked() { if let d = attributes?.deadLetterQueueName { handle(.sqsQueue(d)) } }
}
