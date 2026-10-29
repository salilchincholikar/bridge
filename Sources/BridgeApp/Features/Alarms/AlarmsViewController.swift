import BridgeUI
import AppKit
import BridgeCore

/// Alarms currently in the ALARM state.
@MainActor
final class AlarmsViewController: SectionViewController {
    let table = DataTable(columns: [ColumnSpec("name", "Alarm", width: 320), ColumnSpec("state", "State", width: 90),
                                    ColumnSpec("updated", "Since", width: 160), ColumnSpec("reason", "Reason", width: 700)])
    private let detail = TextPane(monospaced: false)

    override func contextWillChange() {
        super.contextWillChange()
        table.setRows([]); detail.setText("Select an alarm to inspect it.")
    }

    override func build() {
        table.setColumns([ColumnSpec("name", "Alarm", width: 260), ColumnSpec("state", "State", width: 90)])
        let list = WorkspacePane("In alarm", body: table.view)
        let metadata = WorkspacePane("Alarm details", body: detail.scroll)
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        metadata.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        WorkspaceLayout.fill(WorkspaceLayout.split(columns: true, [list, metadata]), in: content)
        detail.setText("Select an alarm to read the trigger reason and last state change.")
        table.onSelect = { [weak self] row in
            guard let a = row?.payload as? AlarmSummary else { self?.detail.setText("Select an alarm to inspect it."); return }
            self?.detail.setPairs([("Alarm", a.name), ("State", a.state), ("Since", Format.date(a.updated)), ("Type", a.isComposite ? "composite" : "metric"), ("Reason", a.reason ?? "—")])
        }
    }

    override func reload(refresh: Bool) {
        clearError()
        table.emptyMessage = "Loading…"
        table.setRows([])
        run { [weak self] in
            guard let self else { return }
            guard let pages = try await self.tab.fetchPages(MetricsWorkflow.alarmsInAlarm(profile: self.tab.profile, region: self.tab.region), refresh: refresh) else { return }
            let alarms = pages.flatMap { MetricsWorkflow.parseAlarms($0.result.json) }
            self.table.emptyMessage = "No alarms are in the ALARM state in \(self.tab.region)"
            self.table.setRows(alarms.map { a in
                TableRow(id: a.name, cells: [Cell(a.name, bold: true), Cell(a.state, color: a.state == "ALARM" ? .systemRed : nil), Cell(Format.date(a.updated)), Cell(a.reason ?? "")], payload: a)
            })

        }
    }
}
