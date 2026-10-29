import AppKit
import BridgeCore
import SwiftUI

@MainActor
final class BillingViewController: SectionViewController, NSMenuItemValidation {
    let services = DataTable(columns: [ColumnSpec("service", "Service", width: 340), ColumnSpec("share", "% of total", width: 90, numeric: true, rightAligned: true), ColumnSpec("cost", "Cost", width: 130, numeric: true, rightAligned: true)])
    let dashboard = BillingDashboardModel()
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var displayedMonth: String?

    override func build() {
        services.table.rowHeight = 28
        services.table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        services.emptyMessage = "Load costs to see your services"
        let menu = NSMenu(title: "Service costs")
        for (index, title) in ["Copy service name", "Copy cost", "Copy row"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(copyService(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; menu.addItem(item)
        }
        services.table.menu = menu
        let host = NSHostingView(rootView: BillingDashboard(model: dashboard, table: services))
        content.addSubview(host); host.pin(to: content)
        dashboard.onLoad = { [weak self] in self?.loadCosts() }
        dashboard.onInfo = { [weak self] in self?.showBillingInfo() }
    }
    override func contextWillChange() {
        generation = UUID(); job?.cancel(); job = nil
        super.contextWillChange()
        reset()
    }
    override func reload(refresh: Bool) {
        if refresh { loadCosts(); return }
        generation = UUID(); job?.cancel(); job = nil; clearError(); reset()
    }
    private func reset() {
        let f = DateFormatter(); f.locale = .current; f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "LLLL yyyy"
        dashboard.month = f.string(from: Date())
        let period = BillingPeriod()
        displayedMonth = period.start
        dashboard.previousPeriodLabel = Self.periodLabel(period.previousStart, period.previousEnd)
        dashboard.scope = "\(tab.label) · All regions"
        dashboard.totalText = "—"; dashboard.forecastText = "—"; dashboard.previousText = "—"
        dashboard.comparisonText = "Same elapsed days last month"; dashboard.comparisonChange = nil; dashboard.chartRange = .month; dashboard.loading = false; dashboard.loaded = false
        dashboard.points = []; dashboard.hover = nil; dashboard.serviceCount = 0
        dashboard.note = "Cost Explorer data may be delayed. API charges can apply."
        services.setRows([])
    }
    static func money(_ n: Decimal, _ unit: String) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = unit
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: n)) ?? "—"
    }
    static func periodLabel(_ start: String, _ end: String) -> String {
        let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.timeZone = TimeZone(secondsFromGMT: 0); input.dateFormat = "yyyy-MM-dd"
        guard let first = input.date(from: start), let exclusiveEnd = input.date(from: end) else { return "Same elapsed days last month" }
        return BillingDashboardModel.dayLabel(first) + " – " + BillingDashboardModel.dayLabel(exclusiveEnd.addingTimeInterval(-86400))
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let index = services.table.clickedRow >= 0 ? services.table.clickedRow : services.table.selectedRow
        return services.rows.indices.contains(index)
    }
    @objc private func copyService(_ sender: NSMenuItem) {
        let index = services.table.clickedRow >= 0 ? services.table.clickedRow : services.table.selectedRow
        guard services.rows.indices.contains(index) else { return }
        let cells = services.rows[index].cells
        let text = sender.tag == 0 ? cells[0].text : (sender.tag == 1 ? cells[2].text : cells.map(\.text).joined(separator: "\t"))
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    private func showBillingInfo() {
        let alert = NSAlert()
        alert.messageText = "About billing data"
        alert.informativeText = "Costs cover the verified account across all AWS regions, using unblended costs and a UTC calendar month. Costs may be delayed or estimated and are not a final invoice.\n\nCost Explorer must be enabled. The selected profile needs ce:GetCostAndUsage and ce:GetCostForecast. AWS may charge for API requests. Refreshing costs makes several queries.\n\nThe forecast covers today through the end of the month and may be unavailable when AWS has insufficient history."
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    @objc func loadCosts() {
        guard job == nil else { return }
        let period = BillingPeriod()
        if displayedMonth != period.start { reset() }
        let token = UUID(); generation = token
        dashboard.loading = true; dashboard.comparisonChange = nil; clearError(); dashboard.note = "Loading costs…"
        job = tab.track { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.dashboard.loading = false; self.job = nil } }
            do {
                let identity = try await self.tab.verifyIdentity()
                let profile = self.tab.profile
                func request(_ start: String, _ end: String, _ grouped: Bool = false, _ next: String? = nil) -> ExecRequest {
                    BillingWorkflow.usage(profile: profile, account: identity.account, start: start, end: end, grouped: grouped, token: next)
                }
                guard let current = try await self.tab.fetch(request(period.start, period.end), refresh: true, global: true), self.generation == token else { return }
                let days = BillingWorkflow.days(current.result.json)
                guard let unit = days.first?.cost.unit, days.allSatisfy({ $0.cost.unit == unit }) else {
                    self.dashboard.totalText = "—"; self.dashboard.previousText = "—"; self.dashboard.forecastText = "—"
                    self.dashboard.points = []; self.dashboard.loaded = false; self.dashboard.serviceCount = 0
                    self.services.setRows([])
                    self.dashboard.note = "No cost data is available for this month yet."; return
                }
                let total = days.reduce(Decimal(0)) { $0 + $1.cost.amount }
                self.dashboard.totalText = Self.money(total, unit)
                self.dashboard.unit = unit; self.dashboard.loaded = true
                let f = ISO8601DateFormatter()
                let points = days.compactMap { d -> MetricPoint? in
                    guard let date = f.date(from: d.date + "T00:00:00Z") else { return nil }
                    return MetricPoint(time: date, value: NSDecimalNumber(decimal: d.cost.amount).doubleValue)
                }
                if !points.isEmpty {
                    self.dashboard.points = points
                }

                var pages: [JSONValue] = []; var next: String?; var seen = Set<String>()
                repeat {
                    guard let fetched = try await self.tab.fetch(request(period.start, period.end, true, next), refresh: true, global: true), self.generation == token else { return }
                    if let json = fetched.result.json { pages.append(json) }
                    next = fetched.result.json?.string("NextPageToken")
                    if let n = next, !seen.insert(n).inserted { throw ExecError.invalidJSON("Repeated billing page token") }
                } while next != nil && pages.count < 20
                let list = BillingWorkflow.services(pages)
                self.services.emptyMessage = "No service costs reported"
                self.services.setRows(list.map { service in
                    let share = total > 0 && service.cost.unit == unit ? service.cost.amount / total * 100 : nil
                    return TableRow(id: service.name + service.cost.unit, cells: [Cell(service.name), Cell(share.map { String(format: "%.1f%%", NSDecimalNumber(decimal: $0).doubleValue) } ?? "—", sortValue: share), Cell(Self.money(service.cost.amount, service.cost.unit), sortValue: service.cost.amount)])
                })
                self.dashboard.serviceCount = list.count
                self.dashboard.note = "Account \(identity.account) · all regions · \(period.start) through today · \(days.contains(where: \.estimated) ? "estimated" : "reported")" + (next != nil ? " · service list truncated" : "")
                // Comparison and forecast may be unavailable. Keep current costs visible if either fails.
                do {
                    if let previous = try await self.tab.fetch(request(period.previousStart, period.previousEnd), refresh: true, global: true), self.generation == token {
                        let old = BillingWorkflow.days(previous.result.json).filter { $0.cost.unit == unit }
                        if !old.isEmpty {
                            let amount = old.reduce(Decimal(0)) { $0 + $1.cost.amount }
                            self.dashboard.previousText = Self.money(amount, unit)
                            if amount > 0 {
                                let change = NSDecimalNumber(decimal: (total - amount) / amount).doubleValue * 100
                                self.dashboard.comparisonChange = change
                                self.dashboard.comparisonText = "Same elapsed days last month"
                            } else {
                                self.dashboard.comparisonChange = nil
                                self.dashboard.comparisonText = "No prior spend to compare"
                            }
                        } else { self.dashboard.previousText = "Unavailable" }
                    }
                } catch is CancellationError { return } catch { if self.generation == token { self.dashboard.previousText = "Unavailable" } }
                do {
                    if let forecast = try await self.tab.fetch(BillingWorkflow.forecast(profile: profile, account: identity.account, period: period), refresh: true, global: true), self.generation == token {
                        self.dashboard.forecastText = BillingAmount(json: forecast.result.json?["Total"]).map { Self.money($0.amount, $0.unit) } ?? "Unavailable"
                    }
                } catch is CancellationError { return } catch { if self.generation == token { self.dashboard.forecastText = "Unavailable" } }
            } catch is CancellationError {} catch {
                guard self.generation == token else { return }
                self.dashboard.note = "Billing unavailable. Check Cost Explorer activation and permissions."
                self.present(error)
            }
        }
    }
}
