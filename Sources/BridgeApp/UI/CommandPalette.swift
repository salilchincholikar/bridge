import AppKit

@MainActor
final class CommandPalette: NSWindowController, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let results = DataTable(columns: [ColumnSpec("title", "Go to", width: 480)])
    var onSelect: ((AppSection) -> Void)?
    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Jump to a service"; panel.isFloatingPanel = true
        super.init(window: panel)
        let root = NSView(); panel.contentView = root
        search.placeholderString = "Search services and tools…"; search.delegate = self
        search.target = self; search.action = #selector(openSelection)
        for v in [search, results.view] as [NSView] { root.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([search.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            results.view.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12), results.view.leadingAnchor.constraint(equalTo: root.leadingAnchor), results.view.trailingAnchor.constraint(equalTo: root.trailingAnchor), results.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        results.onDoubleClick = { [weak self] _ in self?.openSelection() }
        results.setRows(AppSection.allCases.map { TableRow(id: $0.rawValue, cells: [Cell($0.title)], payload: $0) })
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(relativeTo window: NSWindow?) {
        search.stringValue = ""; results.filter = ""; results.table.selectRowIndexes([0], byExtendingSelection: false)
        if let frame = window?.frame { self.window?.setFrameOrigin(NSPoint(x: frame.midX - 280, y: frame.midY - 160)) }
        showWindow(nil); self.window?.makeKeyAndOrderFront(nil); self.window?.makeFirstResponder(search)
    }
    func controlTextDidChange(_ obj: Notification) { results.filter = search.stringValue; results.table.selectRowIndexes([0], byExtendingSelection: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { openSelection(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !results.rows.isEmpty else { return true }
            let next = results.table.selectedRow + (commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
            results.table.selectRowIndexes([max(0, min(results.rows.count - 1, next))], byExtendingSelection: false)
            results.table.scrollRowToVisible(results.table.selectedRow); return true
        }
        return false
    }
    @objc private func openSelection() { if let s = results.selectedRow?.payload as? AppSection { close(); onSelect?(s) } }
}
