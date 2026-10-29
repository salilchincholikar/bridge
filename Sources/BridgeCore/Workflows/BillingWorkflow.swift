import Foundation

public struct BillingPeriod: Sendable {
    public let start: String
    public let end: String
    public let today: String
    public let nextMonth: String
    public let previousStart: String
    public let previousEnd: String
    public init(now: Date = Date()) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = cal.startOfDay(for: now)
        let month = cal.date(from: cal.dateComponents([.year, .month], from: day))!
        let previous = cal.date(byAdding: .month, value: -1, to: month)!
        let f = DateFormatter(); f.calendar = cal; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        start = f.string(from: month); today = f.string(from: day)
        end = f.string(from: cal.date(byAdding: .day, value: 1, to: day)!)
        nextMonth = f.string(from: cal.date(byAdding: .month, value: 1, to: month)!)
        previousStart = f.string(from: previous)
        // Compare the same number of calendar days, capped to the previous month's length.
        previousEnd = f.string(from: min(month, cal.date(byAdding: .day, value: cal.component(.day, from: day), to: previous)!))
    }
}

public struct BillingAmount: Equatable, Sendable {
    public let amount: Decimal
    public let unit: String
    public init?(json: JSONValue?) {
        guard let s = json?.string("Amount"), let n = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")),
              let unit = json?.string("Unit"), !unit.isEmpty else { return nil }
        amount = n; self.unit = unit
    }
}

public struct BillingDay: Sendable { public let date: String; public let cost: BillingAmount; public let estimated: Bool }
public struct BillingService: Sendable { public let name: String; public let cost: BillingAmount }

public enum BillingWorkflow {
    public static func usage(profile: String, account: String, start: String, end: String, grouped: Bool = false, token: String? = nil) -> ExecRequest {
        var p: [String: JSONValue] = ["TimePeriod": .object(["Start": .string(start), "End": .string(end)]),
            "Granularity": .string("DAILY"), "Metrics": .array([.string("UnblendedCost")]),
            "Filter": .object(["Dimensions": .object(["Key": .string("LINKED_ACCOUNT"), "Values": .array([.string(account)])])])]
        if grouped { p["GroupBy"] = .array([.object(["Type": .string("DIMENSION"), "Key": .string("SERVICE")])]) }
        if let token { p["NextPageToken"] = .string(token) }
        return ExecRequest(profile: profile, region: "us-east-1", service: "ce", operation: "get-cost-and-usage", params: .object(p))
    }
    public static func forecast(profile: String, account: String, period: BillingPeriod) -> ExecRequest {
        ExecRequest(profile: profile, region: "us-east-1", service: "ce", operation: "get-cost-forecast", params: .object([
            "TimePeriod": .object(["Start": .string(period.today), "End": .string(period.nextMonth)]),
            "Metric": .string("UNBLENDED_COST"), "Granularity": .string("MONTHLY"),
            "Filter": .object(["Dimensions": .object(["Key": .string("LINKED_ACCOUNT"), "Values": .array([.string(account)])])])]))
    }
    public static func days(_ json: JSONValue?) -> [BillingDay] {
        (json?.array("ResultsByTime") ?? []).compactMap { d in
            guard let date = d.string("TimePeriod.Start"), let cost = BillingAmount(json: d.value(at: "Total.UnblendedCost")) else { return nil }
            return BillingDay(date: date, cost: cost, estimated: d["Estimated"]?.boolValue ?? false)
        }.sorted { $0.date < $1.date }
    }
    public static func services(_ pages: [JSONValue]) -> [BillingService] {
        var sums: [String: Decimal] = [:]
        for page in pages { for day in page.array("ResultsByTime") { for g in day.array("Groups") {
            guard let name = g.strings("Keys").first, let cost = BillingAmount(json: g.value(at: "Metrics.UnblendedCost")) else { continue }
            sums[name + "\u{1f}" + cost.unit, default: 0] += cost.amount
        } } }
        return sums.map { key, value in
            let parts = key.components(separatedBy: "\u{1f}")
            return BillingService(name: parts[0], cost: BillingAmount(json: .object(["Amount": .string(NSDecimalNumber(decimal: value).stringValue), "Unit": .string(parts[1])]))!)
        }.sorted { $0.cost.amount > $1.cost.amount }
    }
}
