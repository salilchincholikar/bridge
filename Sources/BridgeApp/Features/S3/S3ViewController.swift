import BridgeUI
import AppKit
import BridgeCore

/// W4: S3. Buckets, one level at a time, object metadata, and download through the policy with progress and cancel.
@MainActor
final class S3ViewController: SectionViewController, NSSearchFieldDelegate {
    private let filterField = NSSearchField()
    let buckets = DataTable(columns: [ColumnSpec("name", "Bucket", width: 260), ColumnSpec("created", "Created", width: 140)])
    let objects = DataTable(columns: [ColumnSpec("name", "Name", width: 380), ColumnSpec("size", "Size", width: 90, numeric: true, rightAligned: true),
                                      ColumnSpec("modified", "Modified", width: 150), ColumnSpec("class", "Class", width: 100)])
    private let crumb = label("", size: 12, color: .labelColor)
    let detail = TextPane(monospaced: false)
    private let download = NSButton(title: "Download…", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let reveal = NSButton(title: "Show in Finder", target: nil, action: nil)
    let status = label("", size: 11)

    private(set) var bucket: String?
    private(set) var prefix = ""
    private(set) var selectedObject: S3Object?
    private var selectedContentType: String?
    private var downloadTask: Task<Void, Never>?
    private var transferID = UUID()
    private var lastSaved: String?

    override func contextWillChange() {
        super.contextWillChange()
        transferID = UUID(); downloadTask?.cancel(); downloadTask = nil
        bucket = nil; prefix = ""; selectedObject = nil; selectedContentType = nil; lastSaved = nil
        buckets.setRows([]); objects.setRows([]); crumb.stringValue = ""; status.stringValue = ""
        detail.setText("Select an object to inspect it."); download.isEnabled = false; cancel.isHidden = true; reveal.isHidden = true
    }

    override func build() {
        filterField.placeholderString = "Filter buckets"; filterField.delegate = self
        filterField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        buckets.setColumns([ColumnSpec("name", "Bucket", width: 260)])
        objects.setColumns([ColumnSpec("name", "Object", width: 300), ColumnSpec("size", "Size", width: 90, rightAligned: true), ColumnSpec("modified", "Modified", width: 145)])
        objects.emptyMessage = "Choose a bucket"
        download.bezelStyle = .rounded; download.controlSize = .small; download.target = self; download.action = #selector(downloadClicked); download.isEnabled = false
        cancel.bezelStyle = .rounded; cancel.target = self; cancel.action = #selector(cancelClicked); cancel.isHidden = true
        reveal.bezelStyle = .rounded; reveal.target = self; reveal.action = #selector(revealClicked); reveal.isHidden = true
        let bucketList = WorkspacePane("Buckets", body: buckets.view); WorkspaceLayout.listWidth(bucketList)
        let detailBody = NSView()
        let progress = WorkspaceLayout.toolbar([status, NSView(), cancel, reveal])
        for v in [detail.scroll, progress] as [NSView] { detailBody.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            detail.scroll.topAnchor.constraint(equalTo: detailBody.topAnchor), detail.scroll.leadingAnchor.constraint(equalTo: detailBody.leadingAnchor), detail.scroll.trailingAnchor.constraint(equalTo: detailBody.trailingAnchor),
            progress.topAnchor.constraint(equalTo: detail.scroll.bottomAnchor, constant: 4), progress.leadingAnchor.constraint(equalTo: detailBody.leadingAnchor, constant: 6), progress.trailingAnchor.constraint(equalTo: detailBody.trailingAnchor, constant: -6), progress.bottomAnchor.constraint(equalTo: detailBody.bottomAnchor),
        ])
        let objectList = WorkspacePane("Objects", body: objects.view)
        let metadata = WorkspacePane("Object details", body: detailBody, actions: [download])
        metadata.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let right = WorkspaceLayout.split(columns: false, [objectList, metadata])
        WorkspaceLayout.fill(WorkspaceLayout.split(columns: true, [bucketList, right]), in: content,
            toolbar: WorkspaceLayout.toolbar([filterField, NSView(), crumb]))
        buckets.onSelect = { [weak self] row in if let name = row?.id { self?.open(bucket: name, prefix: "") } }
        objects.onSelect = { [weak self] row in self?.objectSelected(row) }
        objects.onDoubleClick = { [weak self] row in self?.activated(row) }
        detail.setText("Select an object to inspect it. Double-click a folder to browse its contents.")
    }

    func controlTextDidChange(_ obj: Notification) { buckets.filter = filterField.stringValue }

    override var selectionDescription: String? { bucket.map { "S3 bucket \($0), prefix \"\(prefix)\"" + (selectedObject.map { ", object \($0.key)" } ?? "") } }

    override func reload(refresh: Bool) {
        clearError()
        buckets.emptyMessage = "Loading…"
        buckets.setRows([])
        run { [weak self] in
            guard let self else { return }
            guard let f = try await self.tab.fetch(S3Workflow.listBuckets(profile: self.tab.profile, region: self.tab.region), refresh: refresh) else { return }
            let list = S3Workflow.parseBuckets(f.result.json).sorted { $0.name < $1.name }
            self.buckets.emptyMessage = "No buckets"
            self.buckets.setRows(list.map { TableRow(id: $0.name, cells: [Cell($0.name, bold: true), Cell(Format.date($0.created))], payload: $0) })

            if case .s3Bucket(let b)? = self.tab.pendingNavigation { self.tab.pendingNavigation = nil; self.handle(.s3Bucket(b)) }
            else if let b = self.bucket { self.open(bucket: b, prefix: self.prefix, refresh: refresh) }
        }
    }

    override func handle(_ navigation: Navigation) {
        guard case .s3Bucket(let name) = navigation, let idx = buckets.rows.firstIndex(where: { $0.id == name }) else { return }
        buckets.table.selectRowIndexes([idx], byExtendingSelection: false)
    }

    func open(bucket b: String, prefix p: String, refresh: Bool = false) {
        bucket = b
        prefix = p
        selectedObject = nil
        download.isEnabled = false
        detail.setText("Select an object to see its details. Double-click a folder to open it.")
        crumb.stringValue = "\(b)/\(p)"
        objects.emptyMessage = "Loading…"
        objects.setRows([])
        run { [weak self] in
            guard let self else { return }
            guard let f = try await self.tab.fetch(S3Workflow.listObjects(profile: self.tab.profile, region: self.tab.region, bucket: b, prefix: p), refresh: refresh),
                  self.bucket == b, self.prefix == p else { return }
            let listing = S3Workflow.parseListing(f.result.json)
            var rows: [TableRow] = []
            if !p.isEmpty { rows.append(TableRow(id: "..", cells: [Cell("↑  ..", color: .secondaryLabelColor), Cell(""), Cell(""), Cell("")], payload: "up")) }
            for pre in listing.prefixes { rows.append(TableRow(id: "d:" + pre, cells: [Cell("▸  " + String(pre.dropFirst(p.count)), bold: true), Cell(""), Cell(""), Cell("folder", color: .secondaryLabelColor)], payload: pre)) }
            for o in listing.objects where o.key != p {
                rows.append(TableRow(id: "o:" + o.key, cells: [Cell(String(o.key.dropFirst(p.count))), Cell(Format.bytes(o.size)), Cell(Format.date(o.lastModified)), Cell(o.storageClass ?? "")], payload: o))
            }
            self.objects.emptyMessage = "Empty"
            self.objects.setRows(rows)

            self.crumb.stringValue = "\(b)/\(p)" + (f.result.nextToken != nil ? "     (more objects exist; only the first page is shown)" : "")
        }
    }

    private func activated(_ row: TableRow) {
        guard let b = bucket else { return }
        if row.id == ".." {
            let parts = prefix.split(separator: "/")
            open(bucket: b, prefix: parts.dropLast().isEmpty ? "" : parts.dropLast().joined(separator: "/") + "/")
        } else if let pre = row.payload as? String, row.id.hasPrefix("d:") { open(bucket: b, prefix: pre) }
    }

    private func objectSelected(_ row: TableRow?) {
        selectedContentType = nil
        guard let o = row?.payload as? S3Object, let b = bucket else { selectedObject = nil; download.isEnabled = false; return }
        selectedObject = o
        download.isEnabled = false
        detail.setPairs([("Key", o.key), ("Size", "\(Format.bytes(o.size)) (\(o.size) bytes)"), ("Modified", Format.date(o.lastModified)), ("Storage class", o.storageClass ?? "-"), ("Details", "loading…")])
        run { [weak self] in
            guard let self else { return }
            defer { if self.selectedObject?.key == o.key && self.bucket == b { self.download.isEnabled = true } }
            guard let f = try await self.tab.fetch(S3Workflow.headObject(profile: self.tab.profile, region: self.tab.region, bucket: b, key: o.key)), self.selectedObject?.key == o.key else { return }
            let h = f.result.json
            self.selectedContentType = h?.string("ContentType")
            self.detail.setPairs([("Key", o.key), ("Size", "\(Format.bytes(o.size)) (\(o.size) bytes)"), ("Modified", Format.date(o.lastModified)), ("Storage class", h?.string("StorageClass") ?? o.storageClass ?? "STANDARD"),
                                  ("Content type", h?.string("ContentType") ?? "-"), ("ETag", h?.string("ETag") ?? o.etag ?? "-"), ("Encryption", h?.string("ServerSideEncryption") ?? "none reported")])
        }
    }

    // MARK: Download

    @objc private func downloadClicked() {
        guard let b = bucket, let o = selectedObject, let aws = tab.app.runtime.awsPath else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = S3DownloadName.suggested(key: o.key, contentType: selectedContentType)
        panel.isExtensionHidden = false
        panel.prompt = "Download"
        panel.message = "Save s3://\(b)/\(o.key)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // File existence after a save panel returns is not replacement consent: another process may
        // have just created the file. Use the explicit Replace flow below, with no-clobber by default.
        startDownload(bucket: b, object: o, folder: destination.deletingLastPathComponent(), overwrite: false, aws: aws, fileName: destination.lastPathComponent)
    }

    func startDownload(bucket b: String, object o: S3Object, folder: URL, overwrite: Bool, aws: String, fileName: String? = nil) {
        let request = S3Workflow.download(profile: tab.profile, region: tab.region, bucket: b, key: o.key)
        let authorized: AuthorizedRequest
        switch tab.authorize(request) {
        case .deny(let reason): banner.show(ErrorText.policy(reason), style: .error); return
        case .allow(let a, _): authorized = a
        }
        clearError()
        downloadTask?.cancel()
        let transfer = UUID(); transferID = transfer
        download.isEnabled = false
        cancel.isHidden = false
        reveal.isHidden = true
        status.stringValue = "Starting…"
        downloadTask = tab.track { [weak self] in
            guard let self else { return }
            defer { if self.transferID == transfer { self.cancel.isHidden = true; self.download.isEnabled = self.selectedObject != nil } }
            do {
                let result = try await S3Downloader(awsPath: aws, environment: ProcessInfo.processInfo.environment).download(authorized, to: folder, overwrite: overwrite, fileName: fileName) { bytes in
                    Task { @MainActor [weak self] in
                        guard let self, self.transferID == transfer else { return }
                        let pct = o.size > 0 ? Int(Double(bytes) / Double(o.size) * 100) : 0
                        self.status.stringValue = "\(Format.bytes(bytes)) of \(Format.bytes(o.size))  (\(min(pct, 100))%)"
                    }
                }
                guard self.transferID == transfer else { return }
                self.lastSaved = result.finalPath
                self.status.stringValue = "Saved \(Format.bytes(result.bytes)) to \(result.finalPath)"
                self.reveal.isHidden = false
            } catch is CancellationError {
                if self.transferID == transfer { self.status.stringValue = "Cancelled. No partial file was kept." }
            } catch TransferError.destinationExists(let path) {
                guard self.transferID == transfer else { return }
                self.status.stringValue = ""
                let alert = NSAlert()
                alert.messageText = "A file with this name already exists"
                alert.informativeText = path
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Replace")
                if alert.runModal() == .alertSecondButtonReturn { self.startDownload(bucket: b, object: o, folder: folder, overwrite: true, aws: aws, fileName: fileName) }
            } catch {
                guard self.transferID == transfer else { return }
                self.status.stringValue = ""
                self.present(error)
            }
        }
    }

    @objc private func cancelClicked() { downloadTask?.cancel() }
    @objc private func revealClicked() { if let p = lastSaved { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
}
