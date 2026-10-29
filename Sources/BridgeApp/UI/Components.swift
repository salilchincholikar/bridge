import AppKit
import BridgeCore

// MARK: - Theme

enum Theme {
    static func color(named name: String?) -> NSColor? {
        switch name?.lowercased() {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "gray", "grey": return .systemGray
        default: return nil
        }
    }
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let monoDigits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static func levelColor(_ l: LogEvent.Level) -> NSColor? {
        switch l {
        case .error: return .systemRed
        case .warn: return .systemOrange
        case .debug: return .secondaryLabelColor
        default: return nil
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static let dateTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    static func date(_ d: Date?) -> String { d.map(dateTime.string(from:)) ?? "" }
    static func opt(_ i: Int?) -> String { i.map(String.init) ?? "" }
    static func age(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "just now" }
        if seconds < 90 { return "\(Int(seconds)) s ago" }
        if seconds < 5400 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3600)) h ago"
    }
    static func duration(_ seconds: Int) -> String {
        if seconds < 120 { return "\(seconds) s" }
        if seconds < 7200 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }
}

// MARK: - Table

struct Cell {
    var text: String
    var color: NSColor? = nil
    var bold = false
    var mono = false
    var sortValue: Decimal?
    init(_ text: String, color: NSColor? = nil, bold: Bool = false, mono: Bool = false, sortValue: Decimal? = nil) { self.text = text; self.color = color; self.bold = bold; self.mono = mono; self.sortValue = sortValue }
}

final class TableRow {
    let id: String
    var cells: [Cell]
    var payload: Any?
    init(id: String, cells: [Cell], payload: Any? = nil) { self.id = id; self.cells = cells; self.payload = payload }
}

struct ColumnSpec {
    var id: String
    var title: String
    var width: CGFloat
    var numeric = false
    var rightAligned = false
    var checkbox = false
    var cellIndex: Int?
    init(_ id: String, _ title: String, width: CGFloat, numeric: Bool = false, rightAligned: Bool = false, cellIndex: Int? = nil, checkbox: Bool = false) {
        self.checkbox = checkbox
        self.cellIndex = cellIndex
        self.id = id; self.title = title; self.width = width; self.numeric = numeric; self.rightAligned = rightAligned
    }
}

/// A sortable, filterable table with one selected row. Rows are plain data (`TableRow`) so every view uses it the same way.
final class DataTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    let table = NSTableView()
    private let scroll = ResourceTableScrollView()
    private var resizingColumns = false
    private var fitLastColumn = false
    private let empty = NSTextField(wrappingLabelWithString: "")
    private(set) var columns: [ColumnSpec] = []
    private var allRows: [TableRow] = []
    private(set) var rows: [TableRow] = []
    private var sortKey: String?
    private var sortAscending = true
    var filter: String = "" { didSet { applyFilterAndSort() } }
    var onSelect: ((TableRow?) -> Void)?
    var onDoubleClick: ((TableRow) -> Void)?
    var onToggle: ((TableRow) -> Void)?
    var emptyMessage = "Nothing to show" { didSet { updateEmpty() } }

    init(columns: [ColumnSpec]) {
        super.init()
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 28
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        scroll.documentView = table
        scroll.onLayout = { [weak self] in self?.fitColumns() }
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.maximumNumberOfLines = 3
        empty.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [scroll, empty] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), empty.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        setColumns(columns)
    }

    func setColumns(_ cols: [ColumnSpec]) {
        if table.columnAutoresizingStyle != .noColumnAutoresizing {
            fitLastColumn = table.columnAutoresizingStyle == .lastColumnOnlyAutoresizingStyle
        }
        table.columnAutoresizingStyle = .noColumnAutoresizing
        columns = cols
        for c in table.tableColumns { table.removeTableColumn(c) }
        for spec in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            c.title = spec.title
            c.headerCell.alignment = spec.rightAligned ? .right : .left
            c.width = spec.width
            c.minWidth = 40
            c.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            table.addTableColumn(c)
        }
    }

    private func fitColumns() {
        guard !resizingColumns, scroll.contentSize.width > 0, !table.tableColumns.isEmpty else { return }
        resizingColumns = true
        defer { resizingColumns = false }
        let cols = table.tableColumns
        if table.columnAutoresizingStyle != .noColumnAutoresizing {
            fitLastColumn = table.columnAutoresizingStyle == .lastColumnOnlyAutoresizingStyle
            table.columnAutoresizingStyle = .noColumnAutoresizing
        }
        let flex = fitLastColumn ? cols.count - 1 : 0
        let other = cols.enumerated().filter { $0.offset != flex }.reduce(CGFloat(0)) { $0 + $1.element.width }
        let padding: CGFloat = (table.style == .inset ? 40 : 0) + table.intercellSpacing.width * CGFloat(cols.count)
        let desired = max(cols[flex].minWidth, scroll.contentSize.width - other - padding)
        if abs(cols[flex].width - desired) > 0.5 { cols[flex].width = desired }
        let width = max(scroll.contentSize.width, cols.reduce(CGFloat(0)) { $0 + $1.width } + padding)
        if abs(table.frame.width - width) > 0.5 { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
    }

    func setRows(_ new: [TableRow]) {
        fitColumns()
        let selectedId = selectedRow?.id
        allRows = new
        applyFilterAndSort()
        if let id = selectedId, let idx = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes([idx], byExtendingSelection: false) }
    }

    var selectedRow: TableRow? {
        let i = table.selectedRow
        return i >= 0 && i < rows.count ? rows[i] : nil
    }

    private func applyFilterAndSort() {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        rows = f.isEmpty ? allRows : allRows.filter { r in r.cells.contains { $0.text.lowercased().contains(f) } }
        if let key = sortKey, let ci = columns.firstIndex(where: { $0.id == key }) {
            let numeric = columns[ci].numeric
            let dataIndex = columns[ci].cellIndex ?? ci
            rows.sort { a, b in
                guard dataIndex < a.cells.count, dataIndex < b.cells.count else { return false }
                if numeric, let av = a.cells[dataIndex].sortValue, let bv = b.cells[dataIndex].sortValue, av != bv {
                    return sortAscending ? av < bv : av > bv
                }
                let r = a.cells[dataIndex].text.compare(b.cells[dataIndex].text, options: numeric ? [.numeric] : [.numeric, .caseInsensitive])
                return sortAscending ? r == .orderedAscending : r == .orderedDescending
            }
        }
        table.reloadData()
        updateEmpty()
    }

    private func updateEmpty() {
        empty.stringValue = rows.isEmpty ? (allRows.isEmpty ? emptyMessage : "No rows match the filter") : ""
        empty.isHidden = !rows.isEmpty
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < rows.count else { return }
        onToggle?(rows[sender.tag])
    }

    @objc private func doubleClicked() { if let r = selectedRow { onDoubleClick?(r) } }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let ci = columns.firstIndex(where: { $0.id == col.identifier.rawValue }), row < rows.count else { return nil }
        let dataIndex = columns[ci].cellIndex ?? ci
        guard dataIndex < rows[row].cells.count else { return nil }
        if columns[ci].checkbox {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxClicked(_:)))
            button.state = rows[row].cells[dataIndex].text == "☑" ? .on : .off
            button.tag = row; button.setAccessibilityLabel("Include resource " + rows[row].id)
            return button
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: ""); t.identifier = id; t.lineBreakMode = .byTruncatingTail; return t
        }()
        let cell = rows[row].cells[dataIndex]
        field.stringValue = cell.text
        field.toolTip = cell.text
        field.textColor = cell.color ?? .labelColor
        field.font = cell.mono ? Theme.mono : (cell.bold ? .boldSystemFont(ofSize: 13) : (columns[ci].numeric ? Theme.monoDigits : .systemFont(ofSize: 13)))
        field.alignment = columns[ci].rightAligned ? .right : .left
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSelect?(selectedRow) }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first else { return }
        sortKey = d.key
        sortAscending = d.ascending
        applyFilterAndSort()
    }
}

// MARK: - Text panes

/// Read-only text with a monospaced or proportional font.
final class TextPane {
    let scroll = NSTextView.scrollableTextView()
    var textView: NSTextView { scroll.documentView as! NSTextView }

    init(monospaced: Bool = true) {
        textView.isEditable = false
        textView.usesFindBar = true
        textView.isRichText = false
        textView.font = monospaced ? Theme.mono : .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.drawsBackground = false
        scroll.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
    }

    func setText(_ s: String) { textView.string = s }
    func setJSON(_ v: JSONValue?) {
        guard let v, let d = try? v.data(pretty: true) else { textView.string = ""; return }
        textView.string = String(decoding: d, as: UTF8.self)
    }

    /// Bold label, then value, one pair per paragraph. Values may be masked by the caller.
    func setPairs(_ pairs: [(String, String)]) {
        let out = NSMutableAttributedString()
        let stacked = scroll.contentSize.width > 0 && scroll.contentSize.width < 420
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 8
        if !stacked { para.headIndent = 130; para.tabStops = [NSTextTab(textAlignment: .left, location: 130)] }
        for (key, value) in pairs {
            if stacked {
                let caption = NSMutableParagraphStyle(); caption.paragraphSpacing = 3
                out.append(NSAttributedString(string: key + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: caption]))
                out.append(NSAttributedString(string: value + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
            } else {
                out.append(NSAttributedString(string: key + "\t", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
                out.append(NSAttributedString(string: value + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
            }
        }
        textView.textStorage?.setAttributedString(out)
    }

}

// MARK: - Banner

final class Banner: NSView {
    enum Style { case info, warning, error }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(clicked)
        for v in [label, button] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ message: String, style: Style = .error, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        label.stringValue = message
        self.action = action
        button.title = actionTitle ?? ""
        button.isHidden = actionTitle == nil
        let base: NSColor = style == .error ? .systemRed : (style == .warning ? .systemOrange : .systemBlue)
        layer?.backgroundColor = base.withAlphaComponent(0.16).cgColor
        isHidden = false
        onVisibilityChanged?()
    }
    func hide() { isHidden = true; action = nil; onVisibilityChanged?() }
    @objc private func clicked() { action?() }
}

// MARK: - Layout helpers

extension NSView {
    func pin(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top), bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left), trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
        ])
    }
}

func label(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor, mono: Bool = false) -> NSTextField {
    let t = NSTextField(labelWithString: text)
    t.font = mono ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    t.textColor = color
    t.lineBreakMode = .byTruncatingMiddle
    return t
}

private final class ResourceTableScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}
