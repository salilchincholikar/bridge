import Foundation
import BridgeCore

func runBillingCatalogTests() {
    section("billing dates, account scope, decimal costs and partial responses") {
        let iso = ISO8601DateFormatter()
        let p = BillingPeriod(now: iso.date(from: "2024-03-31T22:30:00Z")!)
        expect(p.start == "2024-03-01" && p.end == "2024-04-01" && p.today == "2024-03-31", "UTC period includes today's costs with exclusive end")
        expect(p.previousStart == "2024-02-01" && p.previousEnd == "2024-03-01", "previous comparison clamps to leap-February length")
        let first = BillingPeriod(now: iso.date(from: "2026-01-01T00:00:01Z")!)
        expect(first.previousStart == "2025-12-01" && first.previousEnd == "2025-12-02", "first-day and year boundary comparison")
        let req = BillingWorkflow.usage(profile: "p", account: "123456789012", start: p.start, end: p.end, grouped: true, token: "page2")
        expect(req.region == "us-east-1" && req.params?.strings("Filter.Dimensions.Values") == ["123456789012"], "CE endpoint and selected-account filter")
        expect(req.params?.string("NextPageToken") == "page2" && req.params?.array("GroupBy").first?.string("Key") == "SERVICE", "service grouping and API-native pagination")
        let forecast = BillingWorkflow.forecast(profile: "p", account: "123456789012", period: p)
        expect(forecast.params?.string("TimePeriod.Start") == p.today && forecast.params?.string("TimePeriod.End") == p.nextMonth && forecast.params?.string("Metric") == "UNBLENDED_COST", "forecast covers remaining month, using forecast metric enum")
        let data = #"{"ResultsByTime":[{"TimePeriod":{"Start":"2026-10-01"},"Total":{"UnblendedCost":{"Amount":"0.10","Unit":"USD"}},"Estimated":true,"Groups":[{"Keys":["S3"],"Metrics":{"UnblendedCost":{"Amount":"0.10","Unit":"USD"}}}]},{"TimePeriod":{"Start":"2026-10-02"},"Total":{"UnblendedCost":{"Amount":"0.20","Unit":"USD"}},"Groups":[{"Keys":["S3"],"Metrics":{"UnblendedCost":{"Amount":"0.20","Unit":"USD"}}}]},{}]}"#
        let json = try! JSONValue.parse(Data(data.utf8))
        let days = BillingWorkflow.days(json)
        expect(days.count == 2 && days.first?.estimated == true, "days ignore malformed rows and keep estimated status")
        expect(days.reduce(Decimal(0)) { $0 + $1.cost.amount } == Decimal(string: "0.30"), "money summed exactly as Decimal")
        let services = BillingWorkflow.services([json, json])
        expect(services.count == 1 && services[0].cost.amount == Decimal(string: "0.60"), "service totals aggregate across days and pages")
        expect(BillingWorkflow.days(nil).isEmpty && BillingAmount(json: .object(["Amount": .string("broken"), "Unit": .string("USD")])) == nil, "absent or malformed money is not zero")
        for op in ["get-cost-and-usage", "get-cost-forecast"] {
            let e = PolicyTable.standard.entry(service: "ce", operation: op)
            expect(e?.tier == .read && e?.costsMoney == true, "billing query is a read with a cost notice: \(op)")
        }
        expect(PolicyTable.standard.entry(service: "ce", operation: "delete-cost-category-definition") == nil, "billing mutations stay unsupported")
    }
    section("catalog is metadata, never authorization") {
        expect(OperationCatalog.cliName("ListS3Resources") == "list-s3-resources", "acronym and numeric CLI name conversion")
        let root = NSTemporaryDirectory() + "bridge-catalog-\(UUID().uuidString)"
        let dir = root + "/lambda/2020-01-01"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = #"{"operations":{"ListFunctions":{"input":{"shape":"Input"}},"DeleteFunction":{},"GetFunctionConfiguration":{}},"shapes":{"Input":{"type":"structure","required":["Limit"],"members":{"Limit":{"shape":"Integer"},"Enabled":{"shape":"Bool"},"Nested":{"shape":"Nested"}}},"Nested":{"type":"structure","members":{"Again":{"shape":"Nested"}}},"Integer":{"type":"integer"},"Bool":{"type":"boolean"}}}"#
        try! Data(model.utf8).write(to: URL(fileURLWithPath: dir + "/service-2.json"))
        try! Data(#"{"pagination":{"ListFunctions":{"result_key":["Functions","Other"]}}}"#.utf8).write(to: URL(fileURLWithPath: dir + "/paginators-1.json"))
        let list = OperationCatalog.load(path: root)
        expect(list.count == 1 && list.first?.operation == "list-functions", "unlisted mutations and sensitive reads never appear in runner")
        guard let op = list.first else { return }
        expect(op.collection == "Functions" && op.paginated, "first paginator key is primary collection")
        expect(op.fields.first { $0.name == "Nested" }?.children.count == 1, "recursive shapes stop expanding")
        expect((try? op.parameters([:])) == nil, "missing required field rejected")
        expect((try? op.parameters(["Limit": "1.5"])) == nil, "integer field rejects fractional numbers")
        expect((try? op.parameters(["Limit": "3", "Enabled": "\"true\""])) == nil, "boolean field rejects a string")
        expect((try? op.parameters(["Limit": "3", "Nested": "[]"])) == nil, "nested structure rejects an array")
        let params = try? op.parameters(["Limit": "3", "Enabled": "false", "Nested": "{\"Again\":{}}"])
        expect(params?.int("Limit") == 3 && params?["Enabled"]?.boolValue == false && params?["Nested"]?.objectValue != nil, "form values preserve typed JSON")
    }
    section("log follow overlap, duplicates and capacity") {
        let json = try! JSONValue.parse(Data(#"{"events":[{"eventId":"a","timestamp":1000,"message":"same"},{"eventId":"b","timestamp":1000,"message":"same"},{"eventId":"c","timestamp":2000,"message":"later"}]}"#.utf8))
        let list = LogsWorkflow.parseEvents(json)
        var buffer = LogFollowBuffer(capacity: 2)
        buffer.append(Array(list.prefix(2))); buffer.append(list)
        expect(buffer.events.count == 2 && Set(buffer.events.compactMap(\.eventId)) == ["b", "c"], "ID dedupe retains distinct identical messages and evicts oldest events")
        buffer.append([list[2]])
        expect(buffer.events.count == 2, "overlapping polling windows do not duplicate buffered events")
    }
}
