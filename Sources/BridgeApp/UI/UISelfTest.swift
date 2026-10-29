#if BRIDGE_UI_TESTS
import BridgeUI
import AppKit
import BridgeCore
import BridgeAgents

/// Headless check of the REAL UI against the fake `aws` (never real AWS):
///   make ui-test
/// It builds a tab window, drives it the way a user would, and renders it to a bitmap.
@MainActor
enum UISelfTest {
    static var failures = 0
    static var checks = 0
    static func check(_ cond: Bool, _ message: String) {
        checks += 1
        print("\(cond ? "ok  " : "FAIL") \(message)")
        if !cond { failures += 1 }
    }

    /// Spin the main run loop until `condition` holds or `timeout` passes.
    static func waitFor(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func run() -> Int32 {
        checks = 0; failures = 0
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        print("# Bridge UI self-test (fake aws)\n")
        var runtime = BridgeRuntime.load()
        guard let aws = runtime.awsPath, aws.contains("fake-aws") else {
            print("refusing to run: BRIDGE_AWS_PATH must point at the fake aws (Fixtures/fake-aws/aws), never real AWS")
            return 2
        }
        var data: DataService?
        var ready = false
        Task { @MainActor in runtime = await runtime.discoveringProfiles(); data = await runtime.makeDataService(); ready = true }
        _ = waitFor { ready }
        check(runtime.config.profileNames.contains("credentials-only"), "profile discovery includes credentials-only profiles")
        AppModel.shared = AppModel(runtime: runtime, data: data)
        let c = TabWindowController(app: AppModel.shared, profile: "example-dev", region: nil)
        let win = c.window!
        win.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
        win.contentView?.layoutSubtreeIfNeeded()

        func capture(_ name: String, window: NSWindow? = nil) {
            guard let dir = ProcessInfo.processInfo.environment["BRIDGE_UI_SNAPSHOT_DIR"], let view = (window ?? win).contentView else { return }
            (window ?? win).makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.18))
            check(view.bounds.width > 100 && view.bounds.height > 200, "\(name): content has a usable viewport")
            func panes(_ v: NSView) -> [WorkspacePane] { (v as? WorkspacePane).map { [$0] } ?? v.subviews.flatMap(panes) }
            let clipped = panes(view).contains { pane in
                let rect = pane.convert(pane.bounds, to: view)
                return rect.width < 120 || rect.height < 90 || rect.minX < -1 || rect.maxX > view.bounds.width + 1
            }
            check(!clipped, "\(name): resource panes remain visible and within the window")
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/screen-" + name + ".png"))
            }
        }

        c.select(.lambda)

        // 1. Identity and the Lambda list.
        check(waitFor { c.tab.identity != nil }, "identity verified for example-dev")
        check(c.tab.identity?.account == "111111111111", "account 111111111111, got \(c.tab.identity?.account ?? "nil")")
        check(c.accountSummary.contains("111111111111"), "account details show the account: \(c.accountSummary)")
        guard let lambda = c.sectionControllers[.lambda] as? LambdaViewController else { check(false, "lambda controller exists"); return 1 }
        check(waitFor { lambda.table.rows.count == 2 }, "lambda table loaded 2 functions (two pages followed), got \(lambda.table.rows.count)")
        check(lambda.table.rows.map(\.id).sorted() == ["a", "example-workload-orders-handler"], "function names: \(lambda.table.rows.map(\.id))")
        check(c.tab.commandActivity.entries.contains { $0.command.hasPrefix("aws lambda list-functions --profile example-dev --region eu-west-1") }, "request history shows the real Lambda command")
        check(lambda.banner.isHidden, "no error banner")

        // 2. Select a function: detail loads, environment masked by default.
        if let idx = lambda.table.rows.firstIndex(where: { $0.id == "example-workload-orders-handler" }) { lambda.table.table.selectRowIndexes([idx], byExtendingSelection: false) }
        check(waitFor { lambda.detail.textView.string.contains("TABLE_NAME") }, "detail shows environment names")
        let text = lambda.detail.textView.string
        check(text.contains("nodejs20.x") && text.contains("512 MB"), "detail shows runtime and memory")
        check(!text.contains("fake-token-not-a-real-secret"), "environment VALUES are masked by default")
        check(!c.tab.commandActivity.entries.contains { $0.output.contains("fake-token-not-a-real-secret") }, "command history never reveals masked Lambda environment values")
        check(text.contains("••••"), "mask characters present")
        check(waitFor { lambda.table.table.frame.width <= lambda.table.view.bounds.width + 1 }, "Lambda table fits its list viewport")
        capture("lambda")

        // 3. Follow the link to the log group.
        c.tab.navigate(.logGroup("/aws/lambda/example-workload-orders-handler"))
        check(c.tab.section == .logs, "navigation switched to the Logs section")
        guard let logs = c.sectionControllers[.logs] as? LogsViewController else { check(false, "logs controller exists"); return 1 }
        check(waitFor { logs.groups.rows.count == 4 }, "log groups loaded (4), got \(logs.groups.rows.count)")
        check(waitFor { logs.events.rows.count == 5 }, "events for the linked group loaded (5), got \(logs.events.rows.count)")
        check(logs.events.rows.contains { $0.cells[1].text == "error" }, "an error-level event is marked")
        check(c.tab.commandActivity.entries.contains { $0.command.contains("filter-log-events") }, "history includes log event commands")
        check(logs.events.table.frame.width <= logs.events.view.bounds.width + 1, "Log events fit their current viewport (table \(logs.events.table.frame.width), viewport \(logs.events.view.bounds.width), columns \(logs.events.table.tableColumns.map { $0.width }))")
        win.makeKeyAndOrderFront(nil)
        c.focusSearch(nil)
        check(logs.preferredSearchField?.currentEditor() != nil, "Find focuses the current log search")
        capture("logs")
        check(logs.summary.stringValue.contains("5 events"), "summary: \(logs.summary.stringValue)")

        win.makeKeyAndOrderFront(nil)
        c.showAccount(nil)
        check(c.accountDetailsShown, "account button opens a native popover")
        check(c.accountSummary.contains(c.tab.identity?.arn ?? "missing"), "account popover includes the full verified principal")
        func hasNestedScroll(_ view: NSView) -> Bool { view is NSScrollView || view.subviews.contains(where: hasNestedScroll) }
        check(c.accountDetails.map { !hasNestedScroll($0.view) } == true, "account popover has no inner scrolling area")

        // 4. Switch profile: context changes, identity re-verified for the OTHER account, data reloaded.
        c.tab.setProfile("example-prod")
        check(!c.tab.commandActivity.entries.contains { $0.command.contains("--profile example-dev ") }, "profile changes immediately clear old command history")
        check(!c.accountDetailsShown, "changing profile closes the account popover")
        check(!c.accountSummary.contains("111111111111"), "changing profile immediately clears the previous identity from the popover")
        check(!lambda.detail.textView.string.contains("TABLE_NAME"), "switching profile immediately clears old function details")
        check(waitFor { c.tab.identity?.account == "222222222222" }, "after switching, the identity is example-prod's account")
        check(waitFor { c.accountSummary.contains("222222222222") }, "account details follow")
        guard let lambda2 = c.sectionControllers[.logs] else { return 1 }
        _ = lambda2
        check(waitFor { (c.sectionControllers[.logs] as? LogsViewController)?.groups.rows.count == 4 }, "logs reloaded under the new profile")

        // 5. Stale results are dropped: start a request, switch context, and make sure it never renders.
        c.select(.lambda)
        c.tab.setProfile("example-dev")
        c.tab.setRegion("us-east-1")
        check(waitFor { c.tab.region == "us-east-1" && lambda.table.rows.count == 2 }, "context switches re-load the Lambda list")
        check(c.tab.commandActivity.entries.contains { $0.command.contains("--region us-east-1") }, "command history reflects the new region")

        // 5b. ECS: health, stopped-task reasons, links.
        c.tab.setProfile("example-dev"); c.tab.setRegion("eu-west-1")
        c.select(.ecs)
        let ecs = c.sectionControllers[.ecs] as! EcsViewController
        check(waitFor { ecs.services.rows.count == 2 }, "ecs: two services loaded, got \(ecs.services.rows.count)")
        check(ecs.services.rows.first { $0.id == "example-workload" }?.cells[1].text.contains("attention") == true, "ecs: the rolling, under-count service is flagged")
        check(ecs.services.rows.first { $0.id == "example-dev-api" }?.cells[1].text.contains("healthy") == true, "ecs: the steady service is healthy")
        if let i = ecs.services.rows.firstIndex(where: { $0.id == "example-workload" }) { ecs.services.table.selectRowIndexes([i], byExtendingSelection: false) }
        check(waitFor { ecs.tasks.rows.count == 2 }, "ecs: stopped tasks listed, got \(ecs.tasks.rows.count)")
        check(ecs.tasks.rows.contains { $0.cells[3].text.contains("exit 137") }, "ecs: exit code shown with the stop reason")
        check(ecs.tasks.rows.contains { $0.cells[3].text.contains("CannotPullContainerError") }, "ecs: image pull failure reason shown")
        check(waitFor { ecs.detail.textView.string.contains("/ecs/example-workload") }, "ecs: detail shows the container log group from the task definition")
        check(ecs.detail.textView.string.contains("IN_PROGRESS") || ecs.detail.textView.string.contains("health check failed"), "ecs: deployments and events shown")

        check(ecs.services.table.frame.width <= ecs.services.view.bounds.width + 1, "ECS table fits its current viewport (table \(ecs.services.table.frame.width), viewport \(ecs.services.view.bounds.width), columns \(ecs.services.table.tableColumns.map { $0.width }))")
        capture("ecs")

        // 5c. SQS: attributes, DLQ, consumers, charts. No message access.
        c.select(.sqs)
        let sqs = c.sectionControllers[.sqs] as! SqsViewController
        check(waitFor { sqs.queues.rows.count == 3 }, "sqs: three queues, got \(sqs.queues.rows.count)")
        if let i = sqs.queues.rows.firstIndex(where: { $0.id == "example-workload-orders-in" }) { sqs.queues.table.selectRowIndexes([i], byExtendingSelection: false) }
        check(waitFor { sqs.attributes?.visible == 1523 }, "sqs: attributes loaded (1523 visible)")
        check(waitFor { sqs.detail.textView.string.contains("example-workload-orders-dlq") }, "sqs: dead-letter queue shown")
        check(waitFor { sqs.detail.textView.string.contains("example-workload-orders-handler") }, "sqs: consuming Lambda found")
        check(sqs.detail.textView.string.contains("reading messages would hide them"), "sqs: states why messages are not shown")
        check(waitFor { sqs.charts.model.panels.count == 2 }, "sqs: two metric charts loaded, got \(sqs.charts.model.panels.count)")

        capture("sqs")

        // 5d. IAM: jump to a role, read documents.
        c.tab.navigate(.iamRole("example-workload-orders-handler-role"))
        let iam = c.sectionControllers[.iam] as! IamViewController
        check(c.tab.section == .iam, "iam: navigation switched to IAM")
        check(waitFor { iam.roles.rows.count == 3 }, "iam: roles loaded (3), got \(iam.roles.rows.count)")
        check(waitFor { iam.policyChoices.count == 4 }, "iam: trust + 2 attached + 1 inline = 4 rows, got \(iam.policyChoices.count)")
        check(waitFor { iam.document.textView.string.contains("lambda.amazonaws.com") }, "iam: trust policy shown first")
        if let i = iam.policyChoices.firstIndex(where: { $0.id.hasPrefix("att:") && $0.title == "orders-sqs-access" }) { iam.selectPolicy(at: i) }
        check(waitFor { iam.document.textView.string.contains("sqs:ReceiveMessage") }, "iam: URL-encoded policy document decoded and shown")

        capture("iam")

        // 5e. S3: browse, details, and a real download through the policy.
        c.select(.s3)
        let s3 = c.sectionControllers[.s3] as! S3ViewController
        check(waitFor { s3.buckets.rows.count == 2 }, "s3: two buckets, got \(s3.buckets.rows.count)")
        if let i = s3.buckets.rows.firstIndex(where: { $0.id == "example-dev-exports" }) { s3.buckets.table.selectRowIndexes([i], byExtendingSelection: false) }
        check(waitFor { s3.objects.rows.count == 4 }, "s3: 2 folders + 2 objects, got \(s3.objects.rows.count)")
        if let i = s3.objects.rows.firstIndex(where: { $0.id == "o:reports/summary.csv" }) { s3.objects.table.selectRowIndexes([i], byExtendingSelection: false) }
        check(waitFor { s3.detail.textView.string.contains("text/csv") }, "s3: object details loaded from head-object")
        capture("s3")
        let dl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-ui-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dl) }
        if let o = s3.selectedObject, let b = s3.bucket { s3.startDownload(bucket: b, object: o, folder: dl, overwrite: false, aws: runtime.awsPath!) }
        check(waitFor { s3.status.stringValue.hasPrefix("Saved") }, "s3: download finished: \(s3.status.stringValue.prefix(60))")
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: dl.path)) ?? []
        check(saved == ["summary.csv"], "s3: exactly the file, no .bridge-part left: \(saved)")
        check(((try? FileManager.default.attributesOfItem(atPath: dl.appendingPathComponent("summary.csv").path))?[.size] as? NSNumber)?.intValue == 2_097_152, "s3: all 2,097,152 bytes written")

        check(S3DownloadName.suggested(key: "folder/content", contentType: "image/png") == "content.png", "extensionless PNG objects get a useful suggested name")
        check(S3DownloadName.suggested(key: "report.csv", contentType: "image/png") == "report.csv", "explicit object extensions are preserved")
        check(S3DownloadName.suggested(key: "content", contentType: "application/json; charset=utf-8") == "content.json", "MIME parameters are handled in filename suggestions")
        check(S3DownloadName.suggested(key: "content", contentType: "application/octet-stream") == "content", "generic binary metadata does not invent a file type")
        check(S3DownloadName.suggested(key: ".env", contentType: "text/plain") == ".env", "intentional dotfile names are preserved")
        let extensionless = S3Object(key: "content", size: 2_097_152)
        s3.startDownload(bucket: "fake-bucket", object: extensionless, folder: dl, overwrite: false, aws: runtime.awsPath!, fileName: "content.png")
        check(waitFor { s3.status.stringValue.contains("content.png") && FileManager.default.fileExists(atPath: dl.appendingPathComponent("content.png").path) }, "download uses the chosen local filename for an extensionless key")
        check(s3.status.stringValue.contains("content.png"), "saved status identifies the actual chosen filename")
        var rejectedFilename = false
        var filenameCheckDone = false
        if case .allow(let authorized, _) = c.tab.authorize(S3Workflow.download(profile: c.tab.profile, region: c.tab.region, bucket: "fake-bucket", key: "content")) {
            Task { @MainActor in
                do { _ = try await S3Downloader(awsPath: runtime.awsPath!).download(authorized, to: dl, fileName: "../escape.png") }
                catch TransferError.path { rejectedFilename = true }
                catch {}
                filenameCheckDone = true
            }
        }
        check(waitFor { filenameCheckDone } && rejectedFilename, "custom download filenames cannot escape the chosen folder")

        // 5f. Alarms.
        c.select(.alarms)
        let alarms = c.sectionControllers[.alarms] as! AlarmsViewController
        check(waitFor { alarms.table.rows.count == 1 }, "alarms: one alarm in ALARM")
        check(alarms.table.rows.first?.cells[1].text == "ALARM", "alarms: state shown")

        if !alarms.table.rows.isEmpty { alarms.table.table.selectRowIndexes([0], byExtendingSelection: false) }
        capture("alarms")

        // 5g. Investigation.
        c.select(.investigation)
        let inv = c.sectionControllers[.investigation] as! InvestigationViewController
        inv.start(anchor: "example-workload")
        check(waitFor(15) { inv.resources.rows.count == 9 }, "investigation: 9 related resources found (1 lambda, 2 queues, 3 log groups, 1 alarm, 2 ecs), got \(inv.resources.rows.count)")
        let kinds = Dictionary(grouping: inv.resources.rows, by: { $0.cells[1].text }).mapValues(\.count)
        check(kinds["Lambda"] == 1 && kinds["SQS queue"] == 2 && kinds["Log group"] == 3 && kinds["Alarm"] == 1 && kinds["ECS service"] == 2, "investigation: counts by kind \(kinds)")
        let ecsRows = inv.resources.rows.filter { $0.cells[1].text == "ECS service" }
        check(Set(ecsRows.compactMap { ($0.payload as? ResourceRef)?.detail }) == ["example-dev", "batch"], "investigation: ECS services carry real cluster NAMES (not ARNs or lists): \(ecsRows.compactMap { ($0.payload as? ResourceRef)?.detail })")
        check(waitFor(15) { inv.resources.rows.contains { $0.cells[3].text.contains("errors") || $0.cells[3].text == "no errors" } }, "investigation: Lambda status from metrics")
        check(waitFor(15) { inv.resources.rows.contains { $0.cells[1].text == "SQS queue" && $0.cells[3].text.contains("waiting") } }, "investigation: queue status from attributes")
        check(waitFor(15) { inv.resources.rows.contains { $0.cells[1].text == "ECS service" && $0.cells[3].text.contains("attention") } }, "investigation: ECS status from describe-services")
        check(inv.resources.rows.contains { $0.cells[1].text == "Alarm" && $0.cells[3].text == "IN ALARM" }, "investigation: alarm shown as IN ALARM")
        if let i = inv.resources.rows.firstIndex(where: { $0.cells[1].text == "Lambda" }) { inv.resources.table.selectRowIndexes([i], byExtendingSelection: false) }
        check(waitFor { inv.charts.model.panels.count == 4 }, "investigation: selecting the Lambda charts its 4 metrics, got \(inv.charts.model.panels.count)")
        capture("investigation")
        if let row = inv.resources.rows.first(where: { $0.cells[1].text == "Log group" }) { inv.resources.onDoubleClick?(row) }
        check(inv.resources.rows.filter { $0.cells[0].text == "\u{2610}" }.count == 1, "investigation: double-click excludes a resource (unticked box)")
        check(inv.banner.isHidden, "investigation: no error banner")
        if let row = inv.resources.rows.first(where: { $0.cells[0].text == "☐" }) {
            inv.resources.onToggle?(row)
            check(!inv.resources.rows.contains { $0.cells[0].text == "☐" }, "investigation: native include checkbox restores a resource")
        }

        // Navigation, global billing and the generated runner.
        c.select(.home)
        check(c.sectionControllers[.home] is HomeViewController, "overview is a service launcher")
        capture("overview")
        c.select(.billing)
        let billing = c.sectionControllers[.billing] as! BillingViewController
        check(billing.services.rows.isEmpty && billing.dashboard.totalText == "—", "billing makes no paid query on navigation")
        billing.loadCosts()
        check(waitFor { billing.services.rows.count == 3 }, "billing groups costs into three services")
        check(billing.dashboard.totalText.contains("109.80"), "billing exact total: \(billing.dashboard.totalText)")
        check(waitFor { billing.dashboard.forecastText.contains("312.45") }, "billing forecast loaded despite tab region being eu-west-1")
        check(!c.commandDrawer.isExpanded, "AWS command stays collapsed by default")
        win.contentView?.layoutSubtreeIfNeeded()
        let collapsedHeight = billing.content.bounds.height
        c.toggleAWSCommand(nil)
        win.contentView?.layoutSubtreeIfNeeded()
        check(c.commandDrawer.isExpanded && c.commandDrawer.commandPane.textView.string == c.tab.commandActivity.selected.map { "$ " + $0.command }, "shared drawer shows the actual selected command")
        check(billing.content.bounds.height < collapsedHeight - 100, "opening command drawer resizes the page above it")
        c.toggleAWSCommand(nil)
        win.contentView?.layoutSubtreeIfNeeded()
        check(abs(billing.content.bounds.height - collapsedHeight) < 1, "closing command drawer restores page height")
        check(win.title == "Bridge", "window title identifies the app instead of repeating the page")
        check(c.tab.commandActivity.entries.contains { $0.title == "ce get-cost-and-usage" } && c.tab.commandActivity.entries.contains { $0.title == "ce get-cost-forecast" }, "history records each real billing query")
        let trace = CommandActivity()
        let traceRequest = ExecRequest(profile: "test", region: "eu-west-1", service: "lambda", operation: "get-function-configuration")
        let traceID = trace.begin(traceRequest)
        var traceResult = ExecResult(request: traceRequest, commandDisplay: "test", json: .object(["SecretString": .string("do-not-retain")]), nextToken: nil, stderr: "", durationMs: 12, fetchedAt: Date(), sensitive: true)
        trace.finish(traceID, result: traceResult)
        check(trace.selected?.output.contains("do-not-retain") == false && trace.selected?.output.contains("omitted") == true, "sensitive responses are excluded from command history")
        check(trace.selected?.status == "Exit 0 · 12 ms", "command status uses actual execution duration")
        trace.select(traceID)
        let pending = trace.begin(traceRequest)
        trace.cancelRunning()
        trace.finish(pending, result: traceResult)
        check(trace.entries.first { $0.id == pending }?.status == "Cancelled", "late success cannot overwrite a cancelled request")
        trace.clear(); trace.finish(pending, result: traceResult)
        check(trace.entries.isEmpty, "late responses cannot repopulate cleared history")
        for _ in 0..<25 { _ = trace.begin(traceRequest) }
        check(trace.entries.count == 20, "in-memory command history is bounded")
        trace.clear()
        traceResult.sensitive = false
        traceResult.json = .object(["Configuration": .object(["Environment": .object(["Variables": .object(["PLAIN_NAME": .string("hidden-value")])])])])
        let maskedID = trace.begin(traceRequest); trace.finish(maskedID, result: traceResult)
        check(trace.selected?.output.contains("hidden-value") == false, "configuration environment values are masked even when their names do not look secret")
        let cachedID = trace.begin(traceRequest); trace.finish(cachedID, result: traceResult, cached: true)
        check(trace.selected?.status == "Cached", "cached results do not claim a new CLI execution")
        let failedID = trace.begin(traceRequest)
        trace.fail(failedID, error: ExecError.commandFailed(status: 7, stderr: "failed"))
        check(trace.selected?.status == "Exit 7", "failed requests preserve the actual exit code")
        traceResult.json = .object(["data": .string(String(repeating: "x", count: 40_000))])
        let boundedID = trace.begin(traceRequest); trace.finish(boundedID, result: traceResult)
        check((trace.selected?.output.count ?? 0) < 33_000 && trace.selected?.output.contains("Preview truncated") == true, "response previews have a clear bounded size")
        check(billing.services.rows.contains { $0.cells[1].text == "60.0%" }, "billing service table shows spend share")
        check(billing.dashboard.previousText.contains("109.80"), "billing comparison is a separate summary")
        check(billing.dashboard.points.count == 7, "billing has seven daily bars")
        check(billing.dashboard.comparisonChange == 0, "equal current and previous costs produce a neutral comparison")
        let chartModel = BillingDashboardModel()
        let chartStart = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        chartModel.points = (0..<14).map { MetricPoint(time: chartStart.addingTimeInterval(Double($0) * 86400), value: Double($0 + 1)) }
        chartModel.chartRange = .latestWeek
        check(chartModel.visiblePoints.count == 7 && chartModel.visiblePoints.first?.value == 8, "latest-week chart shows seven calendar days ending on the latest report")
        chartModel.moveSelection(1); chartModel.moveSelection(1)
        check(chartModel.selectedPoint?.value == 9, "keyboard chart inspection moves to the next visible day")
        chartModel.chartRange = .month
        check(chartModel.visiblePoints.count == 14 && chartModel.selectedPoint == nil, "switching chart range clears inspection and restores all days")
        check(chartModel.points.count == 14, "chart range never changes the underlying month data")
        let costSort = DataTable(columns: [ColumnSpec("cost", "Cost", width: 120, numeric: true)])
        costSort.setRows([("large", "$1,200.00", "1200"), ("nine", "$9.00", "9"), ("credit", "-$2.00", "-2"), ("ten", "$10.00", "10"), ("cent10", "$0.10", "0.10"), ("cent9", "$0.09", "0.09")].map {
            TableRow(id: $0.0, cells: [Cell($0.1, sortValue: Decimal(string: $0.2))])
        })
        costSort.table.sortDescriptors = [NSSortDescriptor(key: "cost", ascending: true)]
        costSort.tableView(costSort.table, sortDescriptorsDidChange: [])
        check(costSort.rows.map(\.id) == ["credit", "cent9", "cent10", "nine", "ten", "large"], "cost sorting uses amounts, including credits, fractions and thousands separators")
        costSort.table.sortDescriptors = [NSSortDescriptor(key: "cost", ascending: false)]
        costSort.tableView(costSort.table, sortDescriptorsDidChange: [])
        check(costSort.rows.first?.id == "large" && costSort.rows.last?.id == "credit", "descending cost sorting puts the largest spend first")
        check(billing.dashboard.note.contains("111111111111") && billing.dashboard.note.contains("all regions"), "billing scope is explicit")
        // The utility drawer must never remember a shallow intermediate height as expanded.
        var stableDrawer = true
        var visibleDrawer = true
        for size in [NSSize(width: 960, height: 640), NSSize(width: 1440, height: 900), NSSize(width: 1000, height: 680), NSSize(width: 1280, height: 800)] {
            win.setFrame(NSRect(origin: .zero, size: size), display: true)
            win.contentView?.layoutSubtreeIfNeeded()
            for _ in 0..<4 {
                c.commandDrawer.setExpanded(false)
                win.contentView?.layoutSubtreeIfNeeded()
                stableDrawer = stableDrawer && !c.commandDrawer.isExpanded && abs(c.commandDrawer.drawerHeight - 36) < 1
                c.toggleAWSCommand(nil)
                win.contentView?.layoutSubtreeIfNeeded()
                visibleDrawer = visibleDrawer && c.commandDrawer.isExpanded && c.commandDrawer.drawerHeight >= 180 && c.commandDrawer.previewHeight >= 100
            }
        }
        check(stableDrawer, "drawer closes to exactly its header after repeated resizing and toggles")
        check(visibleDrawer, "expanded drawer always has usable preview space at supported window sizes")
        c.commandDrawer.view.display()
        check(c.commandDrawer.dividerIsAtDrawerEdge, "native divider draws at the drawer edge instead of crossing the output")
        let openHeight = c.commandDrawer.drawerHeight
        c.select(.home); win.contentView?.layoutSubtreeIfNeeded()
        check(c.commandDrawer.isExpanded && abs(c.commandDrawer.drawerHeight - openHeight) < 1, "page changes preserve the expanded drawer height")
        c.select(.billing); win.contentView?.layoutSubtreeIfNeeded()
        c.tab.commandActivity.clear()
        check(c.commandDrawer.previewHeight >= 100 && c.commandDrawer.commandPane.textView.string.contains("Commands used by this tab"), "clearing history leaves a fully visible empty-state preview")
        c.commandDrawer.setExpanded(false)
        win.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
        win.contentView?.layoutSubtreeIfNeeded()

        // The dashboard must scroll within smaller windows, never enlarge the window to fit its content.
        for (size, appearance) in [(NSSize(width: 960, height: 640), NSAppearance.Name.aqua),
                                   (NSSize(width: 960, height: 640), NSAppearance.Name.darkAqua),
                                   (NSSize(width: 1180, height: 780), NSAppearance.Name.aqua),
                                   (NSSize(width: 1440, height: 900), NSAppearance.Name.darkAqua)] {
            win.appearance = NSAppearance(named: appearance)
            win.setFrame(NSRect(origin: .zero, size: size), display: false)
            win.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            check(abs(win.frame.width - size.width) < 1 && abs(win.frame.height - size.height) < 1, "billing respects window size \(Int(size.width))×\(Int(size.height))")
            let tableFrame = billing.services.view.convert(billing.services.view.bounds, to: billing.view)
            check(tableFrame.width <= billing.view.bounds.width + 1, "billing service table has no horizontal overflow at \(Int(size.width)) pt")
            if let dir = ProcessInfo.processInfo.environment["BRIDGE_UI_SNAPSHOT_DIR"], let view = win.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir + "/billing-\(Int(size.width))x\(Int(size.height))-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
        }
        win.appearance = nil
        win.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
        c.tab.setProfile("example-prod")
        check(billing.services.rows.isEmpty && billing.dashboard.totalText == "—", "billing clears data immediately on profile switch")
        c.tab.setProfile("example-dev"); c.tab.setRegion("eu-west-1")
        c.select(.runner)
        let runner = c.sectionControllers[.runner] as! RunnerViewController
        check(!runner.operations.rows.contains { $0.id.contains("delete-") || $0.id.contains("get-function-configuration") }, "runner hides mutations and sensitive reads")
        if let i = runner.operations.rows.firstIndex(where: { $0.id == "lambda list-functions" }) {
            runner.operations.table.selectRowIndexes([i], byExtendingSelection: false)
            runner.execute()
            check(waitFor { runner.output.textView.string.contains("Functions") }, "generated runner executes through DataService")
        } else { check(false, "installed catalog contains Lambda list-functions") }
        capture("runner")
        c.select(.settings)
        check(c.settingsWindow?.window?.contentViewController is SettingsViewController, "settings opens a dedicated native window")
        capture("settings", window: c.settingsWindow?.window)
        c.settingsWindow?.close()
        c.select(.logs)
        c.tab.navigate(.logGroup("/aws/lambda/example-workload-orders-handler"))
        _ = waitFor { logs.events.rows.count == 5 }
        logs.toggleFollow()
        check(logs.isFollowing, "log follow starts")
        c.select(.ecs)
        check(!logs.isFollowing, "leaving logs stops polling")

        // 5h. Assistant panel: consent first, then the whole chain through the fake claude. Nothing leaves the machine.
        let consentDir = NSTemporaryDirectory() + "bridge-ui-consent-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: consentDir) }
        setenv("BRIDGE_AGENT_CONSENT", consentDir + "/agent-consent.json", 1)
        setenv("BRIDGE_CLAUDE_PATH", aws.replacingOccurrences(of: "fake-aws/aws", with: "fake-claude/claude"), 1)
        c.tab.setProfile("example-dev"); c.tab.setRegion("eu-west-1")
        c.toggleAssistant(nil)
        guard let panel = c.agentPanel else { check(false, "assistant: panel created"); return 1 }
        check(panel.isShowingConsent, "assistant: the consent screen is shown before anything else")
        capture("assistant-consent")
        panel.send(#"CALL aws_read {"profile":"example-dev","service":"lambda","operation":"list-functions"}"#)
        check(!panel.hasSession && !panel.isRunning && panel.traceCount == 0, "assistant: nothing is started or sent without consent")
        try? AgentConsentStore.grant(.claudeCode)
        panel.refreshState()
        check(!panel.isShowingConsent, "assistant: the chat appears after consent")
        panel.send(#"CALL aws_read {"profile":"example-dev","service":"lambda","operation":"list-functions","region":"eu-west-1"}"#)
        check(waitFor(20) { !panel.isRunning && panel.transcriptText.contains("tools=get_ui_context") }, "assistant: a turn completed through fake claude -> bridge mcp -> socket -> policy -> aws")
        check(panel.transcriptText.contains("FunctionName") && panel.transcriptText.contains("isError=False"), "assistant: the answer contains the data the tool returned")
        check(waitFor { panel.traceCount == 1 }, "assistant: the trace lists what it read, got \(panel.traceCount)")
        check(panel.traceStatuses.first?.hasSuffix(" B") == true, "assistant: the trace shows how many bytes were returned: \(panel.traceStatuses)")
        capture("assistant-chat")
        panel.send(#"CALL aws_read {"profile":"example-prod","service":"lambda","operation":"list-functions"}"#)
        check(waitFor(20) { !panel.isRunning && panel.transcriptText.contains("not available to the assistant") }, "assistant: a profile outside its scope is refused")
        check(waitFor { panel.traceStatuses.last == "denied" }, "assistant: the refusal appears in the trace as denied: \(panel.traceStatuses)")
        check(panel.bytesRead > 0, "assistant: the total bytes returned to the assistant are tracked (\(panel.bytesRead))")
        c.tab.setProfile("example-prod")
        check(!panel.hasSession && panel.transcriptText.contains("new conversation scoped to example-prod"), "assistant: switching profile ends the conversation and its permissions")
        c.tab.setProfile("example-dev")

        // 5i. The same panel with Codex: its own consent, a tool-list check before use, then the whole chain.
        let savedProvider = UserDefaults.standard.string(forKey: "bridge.agent.provider")
        defer { if let p = savedProvider { UserDefaults.standard.set(p, forKey: "bridge.agent.provider") } else { UserDefaults.standard.removeObject(forKey: "bridge.agent.provider") } }
        let fakeCodexPath = aws.replacingOccurrences(of: "fake-aws/aws", with: "fake-codex/codex")
        setenv("BRIDGE_CODEX_PATH", fakeCodexPath, 1)
        panel.setProvider(.codex)
        check(panel.provider == .codex && panel.isShowingConsent, "assistant (Codex): switching provider asks for that provider's own consent")
        panel.send(#"CALL aws_read {"profile":"example-dev","service":"lambda","operation":"list-functions"}"#)
        check(!panel.hasSession && panel.traceCount == 0, "assistant (Codex): nothing is sent without Codex consent")
        try? AgentConsentStore.grant(.codex)
        panel.refreshState()
        check(waitFor(20) { panel.lockdownOK && panel.status.stringValue.contains("tool list verified") }, "assistant (Codex): the tool list was checked and passed: \(panel.status.stringValue)")
        panel.send(#"CALL aws_read {"profile":"example-dev","service":"lambda","operation":"list-functions","region":"eu-west-1"}"#)
        check(waitFor(25) { !panel.isRunning && panel.transcriptText.contains("tools=get_ui_context") }, "assistant (Codex): a turn completed through fake codex -> bridge mcp -> socket -> policy -> aws")
        check(panel.transcriptText.contains("FunctionName") && waitFor { panel.traceCount == 1 }, "assistant (Codex): data came back and the trace lists the read")
        panel.send(#"CALL aws_read {"profile":"example-prod","service":"lambda","operation":"list-functions"}"#)
        check(waitFor(25) { !panel.isRunning && panel.transcriptText.contains("not available to the assistant") }, "assistant (Codex): a profile outside its scope is refused")
        panel.send("FORBIDDEN please")
        check(waitFor(25) { !panel.isRunning && panel.transcriptText.lowercased().contains("stopped") }, "assistant (Codex): an attempted shell command stops the run")

        // An unlocked Codex (shell and web exposed) must be refused outright.
        panel.setProvider(.claudeCode)
        setenv("BRIDGE_CODEX_PATH", aws.replacingOccurrences(of: "fake-aws/aws", with: "fake-codex/codex-unsafe"), 1)
        panel.setProvider(.codex)
        check(waitFor(20) { !panel.lockdownOK && !panel.status.stringValue.contains("tool list verified") }, "assistant (Codex): an unlocked tool list is detected")
        let before = panel.transcriptText
        panel.send("hello")
        check(!panel.hasSession && panel.transcriptText == before, "assistant (Codex): nothing is sent while the tool list is unsafe")
        panel.setProvider(.claudeCode)
        c.toggleAssistant(nil)

        // 6. Render the window and check it is not blank.
        c.select(.logs)
        _ = waitFor { logs.events.rows.count == 5 }
        win.contentView?.layoutSubtreeIfNeeded()
        if let v = win.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            var counts: [UInt32: Int] = [:]
            var total = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) { for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(col.redComponent * 255) << 16 | UInt32(col.greenComponent * 255) << 8 | UInt32(col.blueComponent * 255)
                counts[key, default: 0] += 1; total += 1
            } }
            let top = counts.values.max() ?? 0
            check(total > 0 && Double(total - top) / Double(total) > 0.02, String(format: "window renders content (%.1f%% of sampled pixels differ from the dominant colour)", 100 * Double(total - top) / Double(max(total, 1))))
        } else { check(false, "could render the window") }

        // 7. A tab is its own context: a second tab keeps its own profile.
        let c2 = AppModel.shared.newTab(joining: c, profile: "example-prod")
        check(c2.tab.profile == "example-prod" && c.tab.profile == "example-dev", "second tab has independent context (\(c.tab.profile) vs \(c2.tab.profile))")
        c.tab.cancelAll(); c2.tab.cancelAll()

        print("\n\(checks) UI checks, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}

#endif
