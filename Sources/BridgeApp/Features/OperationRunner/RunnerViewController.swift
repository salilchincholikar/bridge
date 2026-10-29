import BridgeUI
import AppKit
import BridgeCore

@MainActor
final class RunnerViewController: SectionViewController, NSSearchFieldDelegate {
    private let search = NSSearchField()
    let operations = DataTable(columns: [ColumnSpec("operation", "Read operation", width: 300)])
    private let form = TopAlignedStackView()
    private let formScroll = NSScrollView()
    private let runButton = NSButton(title: "Run operation", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next page", target: nil, action: nil)
    let output = TextPane()
    private let resultTable = DataTable(columns: [])
    private let resultMode = NSSegmentedControl(labels: ["JSON", "Table"], trackingMode: .selectOne, target: nil, action: nil)
    private var catalog: [CatalogOperation] = []
    private var selected: CatalogOperation?
    private var choices: [String: NSPopUpButton] = [:]
    private var inputs: [String: NSTextField] = [:]
    private var nextToken: String?
    private var lastRequest: ExecRequest?
    private var revision = UUID()
    private var busy = false

    override func build() {
        search.placeholderString = "Find an operation"; search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 240).isActive = true
        runButton.bezelStyle = .rounded; runButton.controlSize = .small; runButton.target = self; runButton.action = #selector(execute)
        nextButton.bezelStyle = .rounded; nextButton.controlSize = .small; nextButton.target = self; nextButton.action = #selector(nextPage); nextButton.isEnabled = false
        resultMode.controlSize = .small; resultMode.target = self; resultMode.action = #selector(modeChanged); resultMode.selectedSegment = 0
        resultTable.view.isHidden = true
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 9; form.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        formScroll.documentView = form; formScroll.hasVerticalScroller = true; formScroll.autohidesScrollers = true; formScroll.drawsBackground = false
        form.translatesAutoresizingMaskIntoConstraints = false; form.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor).isActive = true
        let resultHost = NSView()
        for v in [output.scroll, resultTable.view] { resultHost.addSubview(v); v.pin(to: resultHost) }
        let parameters = WorkspacePane("Parameters", body: formScroll, actions: [runButton])
        parameters.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        let result = WorkspacePane("Result", body: resultHost, actions: [nextButton, resultMode])
        let right = WorkspaceLayout.split(columns: false, [parameters, result])
        let list = WorkspacePane("Read operations", body: operations.view)
        WorkspaceLayout.listWidth(list, minimum: 230, maximum: 340)
        WorkspaceLayout.fill(WorkspaceLayout.split(columns: true, [list, right]), in: content, toolbar: WorkspaceLayout.toolbar([search, NSView()]))
        operations.onSelect = { [weak self] row in self?.choose(row?.payload as? CatalogOperation) }
        if let path = OperationCatalog.discover() { catalog = OperationCatalog.load(path: path) }
        operations.emptyMessage = "AWS models unavailable. Install AWS CLI or set BRIDGE_MODEL_PATH."
        operations.setRows(catalog.map { TableRow(id: $0.title, cells: [Cell($0.title, mono: true)], payload: $0) })
        choose(nil)
    }
    func controlTextDidChange(_ obj: Notification) { operations.filter = search.stringValue }
    private func choose(_ op: CatalogOperation?) {
        revision = UUID(); busy = false; selected = op; nextToken = nil; lastRequest = nil; nextButton.isEnabled = false
        form.arrangedSubviews.forEach { form.removeArrangedSubview($0); $0.removeFromSuperview() }; inputs.removeAll(); choices.removeAll()
        output.setText(""); resultTable.setRows([]); clearError()
        formScroll.contentView.scroll(to: .zero)
        runButton.isEnabled = op != nil
        guard let op else { form.addArrangedSubview(label("Choose an operation to build its parameter form.", size: 13)); return }
        form.addArrangedSubview(label(op.title, size: 16, color: .labelColor))
        if PolicyTable.standard.entry(service: op.service, operation: op.operation)?.costsMoney == true {
            form.addArrangedSubview(label("AWS may charge for this query. Run only when needed.", size: 12, color: .systemOrange))
        }
        if op.fields.isEmpty { form.addArrangedSubview(label("No parameters required.")) }
        for field in op.fields {
            let title = label(field.name + (field.required ? " *" : "") + " · " + field.type, size: 12, color: .labelColor)
            let options = field.type == "boolean" ? ["true", "false"] : field.choices
            if !options.isEmpty {
                let picker = NSPopUpButton(); picker.addItem(withTitle: field.required ? "Choose…" : "Not set")
                for option in options { picker.addItem(withTitle: option); picker.lastItem?.representedObject = option }
                picker.setAccessibilityLabel(field.name)
                choices[field.name] = picker
                form.addArrangedSubview(title); form.addArrangedSubview(picker)
                picker.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -24).isActive = true
                continue
            }
            let input = NSTextField(); input.placeholderString = !field.choices.isEmpty ? field.choices.joined(separator: " | ") : (["structure", "map"].contains(field.type) ? "JSON object: {…}" : field.type == "list" ? "JSON array: […]" : field.type == "boolean" ? "true or false" : "Optional")
            if field.required && field.choices.isEmpty { input.placeholderString = field.type + " · required" }
            input.font = ["structure", "list", "map"].contains(field.type) ? Theme.mono : .systemFont(ofSize: 13); inputs[field.name] = input
            form.addArrangedSubview(title); form.addArrangedSubview(input)
            input.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28).isActive = true
            if !field.children.isEmpty { form.addArrangedSubview(label("JSON keys: " + field.children.map { $0.name + ($0.required ? "*" : "") }.joined(separator: ", "), size: 11)) }
        }
    }
    override func contextWillChange() { super.contextWillChange(); if isViewLoaded { choose(selected) } }
    override func reload(refresh: Bool) { if isViewLoaded { choose(selected) } }
    @objc func execute() {
        guard let op = selected, !busy else { return }
        do {
            var values = inputs.mapValues(\.stringValue)
            for (name, picker) in choices { if let value = picker.selectedItem?.representedObject as? String { values[name] = value } }
            let params = try op.parameters(values)
            let req = ExecRequest(profile: tab.profile, region: op.service == "ce" ? "us-east-1" : tab.region, service: op.service, operation: op.operation, params: params, maxItems: op.paginated ? 100 : nil)
            lastRequest = req; runRequest(req)
        } catch { present(error) }
    }
    @objc private func nextPage() {
        guard var req = lastRequest, let nextToken, !busy else { return }
        req.startingToken = nextToken; runRequest(req)
    }
    private func runRequest(_ req: ExecRequest) {
        busy = true; runButton.isEnabled = false; nextButton.isEnabled = false; clearError()
        let token = revision
        tab.track { [weak self] in
            guard let self else { return }
            defer { if self.revision == token { self.busy = false; self.runButton.isEnabled = true; self.nextButton.isEnabled = self.nextToken != nil } }
            do {
                guard let fetched = try await self.tab.fetch(req, refresh: true, global: req.service == "ce"), self.revision == token else { return }
                let json = fetched.result.json.map { Redactor.mask($0, paths: fetched.maskPaths) }
                self.output.setJSON(json)
                self.nextToken = fetched.result.nextToken
                let array = self.selected?.collection.flatMap { json?.value(at: $0)?.arrayValue } ?? json?.arrayValue ?? []
                let keys = Array(Set(array.flatMap { Array($0.objectValue?.keys ?? Dictionary<String, JSONValue>().keys) })).sorted().prefix(12)
                let columns = keys.isEmpty ? ["Value"] : Array(keys)
                self.resultTable.setColumns(columns.map { ColumnSpec($0, $0, width: 160) })
                self.resultTable.emptyMessage = "This response has no primary collection. Use JSON to inspect it."
                self.resultTable.setRows(array.enumerated().map { i, item in TableRow(id: "\(i)", cells: columns.map { key in
                    let v = key == "Value" ? item : item[key]
                    return Cell(v?.stringValue ?? v?.compactString() ?? "", mono: true)
                }) })
            } catch is CancellationError {} catch { if self.revision == token { self.nextToken = nil; self.present(error) } }
        }
    }
    @objc private func modeChanged() { output.scroll.isHidden = resultMode.selectedSegment == 1; resultTable.view.isHidden = resultMode.selectedSegment == 0 }
}
