import Foundation
import BridgeCore

private func response(_ name: String) -> JSONValue? {
    let path = root.appendingPathComponent("Fixtures/fake-aws/responses/\(name).json").path
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONValue.parse(d)
}

func runWorkflowTests() {
    section("fixtures: every canned response is valid JSON") {
        let dir = root.appendingPathComponent("Fixtures/fake-aws/responses").path
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }
        expect(files.count >= 20, "fixture set present (\(files.count) files)")
        for f in files { expect(response(String(f.dropLast(5))) != nil, "\(f) parses") }
    }

    section("dates and chunking") {
        expect(AwsDate.parse("2026-10-27T10:11:12.000+0000") != nil, "Lambda-style offset without a colon")
        expect(AwsDate.parse("2026-10-28T09:15:00.000000+00:00") != nil, "ISO with microseconds")
        expect(AwsDate.parse("2026-10-28T09:15:00Z") != nil, "plain ISO")
        expect(AwsDate.parse(.number(1_761_640_800)) == AwsDate.parse(.number(1_761_640_800_000)), "seconds and milliseconds agree")
        expect(AwsDate.parse("not a date") == nil, "garbage is nil")
        expect(Array(1...25).chunked(into: 10).map(\.count) == [10, 10, 5], "25 items in chunks of 10")
        expect([Int]().chunked(into: 10).isEmpty, "empty input, no chunks")
    }

    section("lambda: parsing and requests") {
        let f = LambdaWorkflow.parseFunction(response("lambda_get-function-configuration")!)
        expect(f?.name == "example-workload-orders-handler" && f?.runtime == "nodejs20.x" && f?.memoryMB == 512 && f?.timeoutSeconds == 30, "core fields")
        expect(f?.environmentKeys == ["API_TOKEN", "LOG_LEVEL", "TABLE_NAME"], "environment NAMES sorted")
        expect(f?.environment["LOG_LEVEL"] == "info", "values are in the model for the UI to mask")
        expect(f?.logGroup == "/aws/lambda/example-workload-orders-handler", "log group from LoggingConfig")
        expect(f?.lastModified != nil && f?.layers == ["arn:aws:lambda:eu-west-1:111111111111:layer:shared-utils:7"], "date and layers")
        let noLogging = LambdaWorkflow.parseFunction(.object(["FunctionName": .string("plain")]))
        expect(noLogging?.logGroup == "/aws/lambda/plain" && noLogging?.environment.isEmpty == true, "default log group convention; no environment is fine")
        expect(LambdaWorkflow.parseFunction(.object([:])) == nil && LambdaWorkflow.parseFunctions(nil).isEmpty, "garbage and nil yield nothing, not a crash")
        let src = LambdaWorkflow.parseEventSources(response("lambda_list-event-source-mappings"))
        expect(src.first?.sqsQueueName == "example-workload-orders-in" && src.first?.batchSize == 10, "SQS event source")
        expect(LambdaWorkflow.EventSource(arn: "arn:aws:kinesis:eu-west-1:1:stream/x", state: nil, batchSize: nil).sqsQueueName == nil, "non-SQS source has no queue name")
        let r = LambdaWorkflow.getConfiguration(profile: "example-dev", region: "eu-west-1", function: "f")
        expect(r.service == "lambda" && r.operation == "get-function-configuration" && r.params == .object(["FunctionName": .string("f")]), "request shape")
    }

    section("logs: groups, events, requests") {
        let groups = LogsWorkflow.parseGroups(response("logs_describe-log-groups"))
        expect(groups.count == 4 && groups[1].name == "/aws/lambda/example-workload-orders-handler" && groups[1].retentionDays == 14, "groups parsed")
        expect(groups[2].retentionDays == nil, "no retention means never expire")
        let events = LogsWorkflow.parseEvents(response("logs_filter-log-events"))
        expect(events.count == 5 && events.map(\.timestamp) == events.map(\.timestamp).sorted(), "events parsed and ordered")
        expect(events[2].level == .error && events[3].level == .error && events[1].level == .info && events[0].level == .unknown, "level heuristic")
        expect(!events[0].message.hasSuffix("\n"), "trailing newline stripped")
        let w = TimeWindow(start: Date(timeIntervalSince1970: 1_761_640_000), end: Date(timeIntervalSince1970: 1_761_640_900))
        let req = LogsWorkflow.filterEvents(profile: "example-dev", region: "eu-west-1", group: "/aws/lambda/x", pattern: "ERROR", window: w)
        expect(req.params?["startTime"] == .number(1_761_640_000_000) && req.params?["endTime"] == .number(1_761_640_900_000), "window sent as epoch milliseconds")
        expect(req.params?["filterPattern"] == .string("ERROR") && req.params?["limit"] == .number(500), "pattern and limit")
        expect(LogsWorkflow.filterEvents(profile: "k", region: "r", group: "g", pattern: "", window: w).params?["filterPattern"] == nil, "empty pattern omitted")
        expect(LogsWorkflow.describeGroups(profile: "k", region: "eu-west-1", prefix: "/aws/lambda/", pattern: "x").params?["logGroupNamePattern"] == nil, "prefix and pattern are never combined")
    }

    section("ecs: parsing, health, chunking") {
        let clusters = EcsWorkflow.parseClusters(response("ecs_describe-clusters"))
        expect(clusters.map(\.name) == ["example-dev", "batch"] && clusters[0].runningTasks == 4, "clusters")
        expect(EcsWorkflow.arns(response("ecs_list-services"), key: "serviceArns").count == 2, "service ARNs")
        let services = EcsWorkflow.parseServices(response("ecs_describe-services"))
        expect(services.count == 2, "two services")
        expect(services[0].desired == 3 && services[0].running == 2 && services[0].pending == 1, "counts")
        expect(!services[0].isHealthy && services[1].isHealthy, "health: a rolling deployment with fewer running than desired is unhealthy")
        expect(services[0].deployments.first?.rolloutState == "IN_PROGRESS" && services[0].deployments.first?.failed == 2, "deployment state")
        expect(services[0].events.first?.message.contains("health check failed") == true, "events kept in API order (newest first)")
        let tasks = EcsWorkflow.parseTasks(response("ecs_describe-tasks"))
        expect(tasks.count == 2 && tasks[0].id == "7f3a0001", "task id from ARN")
        expect(tasks[0].containers.first?.exitCode == 137 && tasks[0].stoppedReason?.contains("Essential container") == true, "stopped reason and exit code")
        expect(tasks[1].stopCode == "TaskFailedToStart" && tasks[1].stoppedReason?.contains("CannotPullContainerError") == true, "pull failure reason")
        let td = EcsWorkflow.parseTaskDefinition(response("ecs_describe-task-definition"))
        expect(td?.family == "example-workload" && td?.revision == 42 && td?.taskRoleArn?.hasSuffix("example-workload-task-role") == true, "task definition")
        expect(td.map(InvestigationLinks.ecsLogGroups) == ["/ecs/example-workload"], "log group from the container log configuration")
        expect(EcsWorkflow.describeServices(profile: "k", region: "r", cluster: "c", services: (0..<25).map { "s\($0)" }).count == 3, "25 services need 3 describe calls (max 10 each)")
        expect(EcsWorkflow.describeTasks(profile: "k", region: "r", cluster: "c", tasks: (0..<150).map { "t\($0)" }).count == 2, "150 tasks need 2 describe calls (max 100 each)")
        expect(EcsWorkflow.describeServices(profile: "k", region: "r", cluster: "c", services: []).isEmpty, "nothing to describe means no call")
        let stopped = EcsWorkflow.listTasks(profile: "k", region: "r", cluster: "c", service: "svc", desiredStatus: "STOPPED")
        expect(stopped.params?["serviceName"] == .string("svc") && stopped.params?["desiredStatus"] == .string("STOPPED"), "stopped-task listing request")
    }

    section("sqs: attributes, redrive, requests") {
        let q = SqsWorkflow.parseQueues(response("sqs_list-queues"))
        expect(q.map(\.name) == ["example-workload-orders-in", "example-workload-orders-dlq", "billing-events"], "queue names from URLs")
        let a = SqsWorkflow.parseAttributes(response("sqs_get-queue-attributes"))
        expect(a?.visible == 1523 && a?.inFlight == 10 && a?.delayed == 0 && a?.visibilityTimeoutSeconds == 30, "counts parsed from strings")
        expect(a?.deadLetterQueueName == "example-workload-orders-dlq" && a?.maxReceiveCount == 5, "redrive policy (a JSON string inside JSON) parsed")
        expect(a?.isFifo == false && a?.created != nil, "fifo flag and creation time")
        expect(SqsWorkflow.parseAttributes(.object([:])) == nil && SqsWorkflow.parseAttributes(nil) == nil, "missing Attributes yields nil")
        let r = SqsWorkflow.getAttributes(profile: "k", region: "r", queueUrl: "https://sqs/x/q")
        expect(r.operation == "get-queue-attributes" && r.params?["AttributeNames"] == .array([.string("All")]), "attributes request")
        expect(Set(PolicyTable.standard.entries.keys).contains("sqs get-queue-attributes") && !SqsWorkflow.listQueues(profile: "k", region: "r").operation.contains("receive"), "the SQS workflow never builds a receive-message request")
    }

    section("iam: roles and policy documents") {
        let role = IamWorkflow.parseRole(response("iam_get-role"))
        expect(role?.name == "example-workload-orders-handler-role" && role?.path == "/service-role/", "role")
        expect(role?.trustPolicy?.string("Statement.0") == nil && role?.trustPolicy?.array("Statement").first?.string("Principal.Service") == "lambda.amazonaws.com", "trust policy as an object")
        expect(IamWorkflow.parseAttached(response("iam_list-attached-role-policies")).map(\.name) == ["AWSLambdaBasicExecutionRole", "orders-sqs-access"], "attached policies")
        expect(IamWorkflow.parseInlineNames(response("iam_list-role-policies")) == ["inline-dynamodb-orders"], "inline policy names")
        expect(IamWorkflow.parseInlineDocument(response("iam_get-role-policy"))?.array("Statement").first?.strings("Action") == ["dynamodb:GetItem", "dynamodb:PutItem"], "inline document")
        expect(IamWorkflow.defaultVersionId(response("iam_get-policy")) == "v3", "default version id")
        let doc = IamWorkflow.parseVersionDocument(response("iam_get-policy-version"))
        expect(doc?.array("Statement").first?.strings("Action") == ["sqs:ReceiveMessage", "sqs:DeleteMessage"], "URL-encoded policy document decoded")
        expect(IamWorkflow.policyDocument(.string("not json")) == nil && IamWorkflow.policyDocument(nil) == nil, "garbage yields nil")
        expect(IamWorkflow.roleName(fromArn: "arn:aws:iam::1:role/service-role/Name") == "Name" && InvestigationLinks.roleName(fromArn: nil) == nil, "role name from ARN")
    }

    section("s3: listing, breadcrumbs, requests") {
        expect(S3Workflow.parseBuckets(response("s3api_list-buckets")).map(\.name) == ["example-dev-exports", "example-dev-logs"], "buckets")
        let l = S3Workflow.parseListing(response("s3api_list-objects-v2"))
        expect(l.prefixes == ["reports/archive/", "reports/tmp/"] && l.objects.count == 2, "folders and objects")
        expect(l.objects[0].size == 2_097_152 && l.objects[0].displayName == "summary.csv" && l.objects[0].storageClass == "STANDARD", "object fields")
        expect(S3Workflow.parseListing(nil) == S3Listing(prefixes: [], objects: []), "nil listing is empty")
        expect(S3Workflow.breadcrumbs(prefix: "a/b/c/").map(\.prefix) == ["a/", "a/b/", "a/b/c/"] && S3Workflow.breadcrumbs(prefix: "").isEmpty, "breadcrumbs")
        let r = S3Workflow.listObjects(profile: "k", region: "r", bucket: "b", prefix: "reports/")
        expect(r.params?["Delimiter"] == .string("/") && r.params?["Prefix"] == .string("reports/"), "one level at a time")
        expect(S3Workflow.listObjects(profile: "k", region: "r", bucket: "b").params?["Prefix"] == nil, "no prefix at the top")
        expect(S3Workflow.download(profile: "k", region: "r", bucket: "b", key: "k").operation == "get-object", "download request")
    }

    section("metrics and alarms") {
        let t0 = Date(timeIntervalSince1970: 1_761_600_000)
        func win(_ s: TimeInterval) -> TimeWindow { TimeWindow(start: t0, end: t0.addingTimeInterval(s)) }
        expect(MetricsWorkflow.period(for: win(900)) == 60 && MetricsWorkflow.period(for: win(6 * 3600)) == 300 && MetricsWorkflow.period(for: win(2 * 86400)) == 900 && MetricsWorkflow.period(for: win(7 * 86400)) == 3600, "period grows with the window")
        let req = MetricsWorkflow.query(profile: "k", region: "r", window: win(900), specs: MetricsWorkflow.lambdaSpecs(function: "f"))
        let queries = req.params?.array("MetricDataQueries") ?? []
        expect(queries.count == 4 && queries[0].string("Id") == "m0" && queries[3].string("Id") == "m3", "ids m0...m3")
        expect(queries[1].string("MetricStat.Metric.MetricName") == "Errors" && queries[1].string("MetricStat.Stat") == "Sum" && queries[1].int("MetricStat.Period") == 60, "metric stat")
        expect(queries[1].array("MetricStat.Metric.Dimensions").first?.string("Value") == "f", "dimension")
        expect(req.params?.string("StartTime") == AwsDate.iso(t0) && req.params?.string("ScanBy") == "TimestampAscending", "times as ISO, ascending")
        expect(MetricsWorkflow.sqsSpecs(queueName: "q").map(\.name) == ["ApproximateNumberOfMessagesVisible", "ApproximateAgeOfOldestMessage"], "sqs specs")
        let series = MetricsWorkflow.parseSeries(.object(["MetricDataResults": .array([.object(["Id": .string("m0"), "Label": .string("L"),
            "Timestamps": .array([.string("2026-10-28T09:02:00Z"), .string("2026-10-28T09:01:00Z"), .string("bad")]), "Values": .array([.number(2), .number(1), .number(9)])])])]))
        expect(series.first?.points.map(\.value) == [1, 2], "points sorted by time; unparseable timestamps dropped")
        let alarms = MetricsWorkflow.parseAlarms(response("cloudwatch_describe-alarms"))
        expect(alarms.count == 1 && alarms[0].state == "ALARM" && alarms[0].reason?.contains("Threshold Crossed") == true, "alarms")
    }

    section("investigations: discovery, resolution, links, store") {
        let c = DiscoveryCandidates(
            lambdas: ["example-workload-notifier", "example-workload-orders-handler", "billing-sync"],
            ecsServices: [EcsServiceName(cluster: "example-dev", name: "example-workload"), EcsServiceName(cluster: "example-dev", name: "example-dev-api")],
            queues: SqsWorkflow.parseQueues(response("sqs_list-queues")),
            logGroups: LogsWorkflow.parseGroups(response("logs_describe-log-groups")).map(\.name),
            alarms: ["example-workload-orders-in-age", "other-alarm"])
        let m = InvestigationDiscovery.matches(anchor: "EXAMPLE-Workload", in: c)
        expect(m.filter { $0.kind == .lambdaFunction }.count == 2, "two lambdas match, case-insensitively")
        expect(m.contains(ResourceRef(kind: .ecsService, name: "example-workload", detail: "example-dev")), "ecs service with its cluster")
        expect(m.filter { $0.kind == .sqsQueue }.map(\.name) == ["example-workload-orders-dlq", "example-workload-orders-in"], "queues sorted")
        expect(m.filter { $0.kind == .logGroup }.count == 3 && m.filter { $0.kind == .alarm }.count == 1, "log groups and alarms")
        expect(!m.contains { $0.name == "billing-sync" || $0.name == "example-dev-api" }, "non-matches excluded")
        expect(InvestigationDiscovery.matches(anchor: "  ", in: c).isEmpty && InvestigationDiscovery.matches(anchor: "", in: c).isEmpty, "an empty anchor matches nothing")

        var inv = Investigation(name: "orders", profile: "example-dev", region: "eu-west-1", anchor: "example-workload")
        inv.excluded = [ResourceRef(kind: .lambdaFunction, name: "example-workload-notifier")]
        inv.added = [ResourceRef(kind: .lambdaFunction, name: "billing-sync"), ResourceRef(kind: .lambdaFunction, name: "billing-sync")]
        let resolved = InvestigationDiscovery.resolve(inv, matches: m)
        expect(!resolved.contains(ResourceRef(kind: .lambdaFunction, name: "example-workload-notifier")), "excluded match removed")
        expect(resolved.filter { $0.name == "billing-sync" }.count == 1, "hand-added resource included once")

        let sources = LambdaWorkflow.parseEventSources(response("lambda_list-event-source-mappings"))
        expect(InvestigationLinks.sourceQueues(of: sources, among: c.queues).map(\.name) == ["example-workload-orders-in"], "queue feeding the function")
        expect(InvestigationLinks.consumers(ofQueue: c.queues[0], mappingsByFunction: ["example-workload-orders-handler": sources, "other": []]) == ["example-workload-orders-handler"], "consumers of a queue")
        let prod = inv.retargeted(profile: "example-prod")
        expect(prod.profile == "example-prod" && prod.anchor == inv.anchor && prod.id != inv.id && prod.windowSeconds == inv.windowSeconds, "retargeting keeps the anchor, gets a new id")

        let path = NSTemporaryDirectory() + "bridge-inv-\(UUID().uuidString)/investigations.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try? InvestigationStore.save([inv, prod], path: path)
        let back = InvestigationStore.load(path: path)
        expect(back.items == [inv, prod] && back.warning == nil, "saved investigations round trip")
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        expect(!text.contains("AKIA") && !text.contains("Arn") && !text.contains("arn:"), "no AWS response data or ARNs in the saved file")
        try? Data("garbage".utf8).write(to: URL(fileURLWithPath: path))
        let bad = InvestigationStore.load(path: path)
        expect(bad.items.isEmpty && bad.warning != nil && ((try? String(contentsOfFile: path, encoding: .utf8)) == "garbage"), "corrupt file: empty list, warning, file untouched")
    }

    runDataServiceTests()
}

func runDataServiceTests() {
    let tab = UUID()
    let service = DataService(executor: CLIExecutor(awsPath: fakeAws, environment: testEnvironment), cliVersion: "2.99.9")

    section("data service: identity, authorization, cache, freshness") {
        let first = try? blocking { try await service.fetch(LambdaWorkflow.listFunctions(profile: "example-dev", region: "eu-west-1", maxItems: nil), tab: tab) }.get()
        expect(first?.fromCache == false && first?.identity?.account == "111111111111", "first fetch is live, identity verified")
        expect(first?.context.accountId == "111111111111" && first?.context.tabId == tab && first?.context.profile == "example-dev", "context captured with the verified account")
        expect(first?.tier == .read && LambdaWorkflow.parseFunctions(first?.result.json).count == 2, "tier and parsed data")
        let second = try? blocking { try await service.fetch(LambdaWorkflow.listFunctions(profile: "example-dev", region: "eu-west-1", maxItems: nil), tab: tab) }.get()
        expect(second?.fromCache == true && (second?.age ?? -1) >= 0, "second fetch comes from the cache with its age")
        let refreshed = try? blocking { try await service.fetch(LambdaWorkflow.listFunctions(profile: "example-dev", region: "eu-west-1", maxItems: nil), tab: tab, refresh: true) }.get()
        expect(refreshed?.fromCache == false, "refresh bypasses the cache")
        let prod = try? blocking { try await service.fetch(LambdaWorkflow.listFunctions(profile: "example-prod", region: "eu-west-1", maxItems: nil), tab: tab) }.get()
        expect(prod?.fromCache == false && prod?.identity?.account == "222222222222", "another profile resolves to its OWN account and never sees example-dev's cache")

        let sensitiveReq = LambdaWorkflow.getConfiguration(profile: "example-dev", region: "eu-west-1", function: "example-workload-orders-handler")
        let s1 = try? blocking { try await service.fetch(sensitiveReq, tab: tab) }.get()
        let s2 = try? blocking { try await service.fetch(sensitiveReq, tab: tab) }.get()
        expect(s1?.result.sensitive == true && s1?.maskPaths == ["Environment.Variables"], "sensitive result flagged with mask paths")
        expect(s2?.fromCache == false, "sensitive results are never served from cache")
        let fullRequest = ExecRequest(profile: "example-dev", region: "eu-west-1", service: "lambda", operation: "get-function", params: .object(["FunctionName": .string("f")]))
        let full1 = try? blocking { try await service.fetch(fullRequest, tab: tab) }.get()
        let full2 = try? blocking { try await service.fetch(fullRequest, tab: tab) }.get()
        expect(full1?.result.sensitive == true && full2?.fromCache == false, "full function response never cached")
        expect(full1?.result.json?["Configuration"]?["Environment"]?["Variables"] != nil, "human response retains environment for explicit reveal")
        if let json = full1?.result.json {
            let masked = Redactor.mask(json, paths: full1!.maskPaths)
            expect(masked["Code"]?["Location"] != json["Code"]?["Location"], "presigned code URL masked in safe presentation")
            expect(masked["Configuration"]?["Environment"]?["Variables"] != json["Configuration"]?["Environment"]?["Variables"], "nested environment masked in safe presentation")
        }
    }

    section("data service: denials and failures") {
        func denied(_ req: ExecRequest, caller: Caller = .human) -> DenyReason? {
            if case .failure(let e) = blocking({ try await service.fetch(req, tab: tab, caller: caller) }), case DataError.denied(let r) = e { return r }
            return nil
        }
        expect(denied(ExecRequest(profile: "example-dev", region: "eu-west-1", service: "sqs", operation: "receive-message")) == .aboveCap(required: .reversibleChange, cap: .transfer), "receive-message denied for a human at the default cap")
        expect(denied(ExecRequest(profile: "example-dev", region: "eu-west-1", service: "ec2", operation: "describe-instances")) == .unsupported, "unlisted operation denied")
        expect(denied(ExecRequest(profile: "example-dev", region: "eu-west-1", service: "sts", operation: "get-session-token")) == .credentialClass, "credential operation denied")
        expect(denied(LambdaWorkflow.getConfiguration(profile: "example-dev", region: "eu-west-1", function: "f"), caller: .agent) == .sensitiveHiddenFromAgent, "sensitive hidden from agents")
        expect(denied(S3Workflow.download(profile: "example-dev", region: "eu-west-1", bucket: "b", key: "k"), caller: .agent) == .aboveCap(required: .transfer, cap: .read), "agents cannot download by default")
        if case .failure(let e) = blocking({ try await service.fetch(LambdaWorkflow.listFunctions(profile: "my-expired-profile", region: "eu-west-1", maxItems: nil), tab: tab) }), case ExecError.authExpired = e {} else { expect(false, "an expired SSO session surfaces as authExpired") }
    }

    section("data service: paging and CLI version") {
        let pages = try? blocking { try await service.fetchPages(LambdaWorkflow.listFunctions(profile: "example-dev", region: "eu-west-1", maxItems: 1), tab: tab, refresh: true, maxPages: 3) }.get()
        expect(pages?.count == 3, "follows NextToken up to maxPages, got \(pages?.count ?? -1)")
        let one = try? blocking { try await service.fetchPages(LambdaWorkflow.listFunctions(profile: "example-dev", region: "eu-west-1", maxItems: nil), tab: tab, refresh: true) }.get()
        expect(one?.count == 1, "no maxItems means a single page")
        let v = blocking { await CLIExecutor(awsPath: fakeAws, environment: testEnvironment).version() }.successValue
        expect(v == "2.99.9", "CLI version parsed, got \(v ?? "nil")")
        expect(blocking { await CLIExecutor(awsPath: "/nonexistent", environment: [:]).version() }.successValue == "unknown", "missing CLI gives unknown")
    }

    section("data service: results through the real workflow requests") {
        func run(_ req: ExecRequest) -> JSONValue? { (try? blocking { try await service.fetch(req, tab: tab, refresh: true) }.get())?.result.json }
        expect(EcsWorkflow.parseServices(run(EcsWorkflow.describeServices(profile: "example-dev", region: "eu-west-1", cluster: "example-dev", services: ["example-workload"])[0])).count == 2, "ecs describe-services through the whole stack")
        expect(IamWorkflow.parseRole(run(IamWorkflow.getRole(profile: "example-dev", region: "eu-west-1", role: "r")))?.name == "example-workload-orders-handler-role", "iam get-role")
        expect(S3Workflow.parseListing(run(S3Workflow.listObjects(profile: "example-dev", region: "eu-west-1", bucket: "b"))).objects.count == 2, "s3 listing")
        let win = TimeWindow.last(900)
        let series = MetricsWorkflow.parseSeries(run(MetricsWorkflow.query(profile: "example-dev", region: "eu-west-1", window: win, specs: MetricsWorkflow.sqsSpecs(queueName: "q"))))
        expect(series.count == 4 && series[0].points.count == 90, "metric data parsed (the fake always returns 4 series of 90 points)")
        expect(series[0].points.last.map { abs($0.time.timeIntervalSinceNow) < 120 } == true, "newest point is about now")
        expect(MetricsWorkflow.parseAlarms(run(MetricsWorkflow.alarmsInAlarm(profile: "example-dev", region: "eu-west-1"))).count == 1, "alarms")
        let ev = LogsWorkflow.parseEvents(run(LogsWorkflow.filterEvents(profile: "example-dev", region: "eu-west-1", group: "/aws/lambda/x", pattern: "ERROR", window: win)))
        expect(ev.count == 5, "log events through the whole stack")
    }
}
