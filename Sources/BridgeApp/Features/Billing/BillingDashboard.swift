import AppKit
import SwiftUI
import Charts
import Observation
import BridgeCore

enum BillingChartRange: String, CaseIterable, Identifiable {
    case month = "Month to date"
    case latestWeek = "Latest 7 days"
    var id: String { rawValue }
}

/// The controller owns requests; chart inspection and range changes use only data already loaded.
@Observable
final class BillingDashboardModel {
    var month = ""
    var scope = "Selected account · All regions"
    var totalText = "—"
    var previousText = "—"
    var forecastText = "—"
    var comparisonText = "Same elapsed days last month"
    var previousPeriodLabel = ""
    var comparisonChange: Double?
    var unit = "USD"
    var points: [MetricPoint] = [] { didSet { hover = nil; pinnedDay = nil } }
    var hover: Date?
    var pinnedDay: Date?
    var chartRange: BillingChartRange = .month { didSet { hover = nil; pinnedDay = nil } }
    var loaded = false
    var loading = false
    var serviceCount = 0
    var chromeHeight: CGFloat = 440
    var note = "Costs are estimates and may be delayed."
    var onLoad: (() -> Void)?
    var onInfo: (() -> Void)?

    var visiblePoints: [MetricPoint] {
        guard chartRange == .latestWeek, let last = points.last else { return points }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: last.time))!
        return points.filter { $0.time >= start && $0.time <= last.time }
    }
    var selectedPoint: MetricPoint? {
        guard let selected = hover ?? pinnedDay else { return nil }
        return visiblePoints.min { abs($0.time.timeIntervalSince(selected)) < abs($1.time.timeIntervalSince(selected)) }
    }
    func moveSelection(_ offset: Int) {
        let data = visiblePoints
        guard !data.isEmpty else { return }
        let index = selectedPoint.flatMap { point in data.firstIndex { $0.time == point.time } } ?? (offset > 0 ? -1 : data.count)
        hover = nil; pinnedDay = data[min(max(index + offset, 0), data.count - 1)].time
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "d MMM"
        return formatter
    }()
    static func dayLabel(_ date: Date) -> String { dateFormatter.string(from: date) }
    var chartCaption: String {
        guard let first = visiblePoints.first, let last = visiblePoints.last else { return "Daily costs · UTC" }
        return Self.dayLabel(first.time) + " – " + Self.dayLabel(last.time) + " · UTC"
    }
}

struct BillingDashboard: View {
    let model: BillingDashboardModel
    let table: DataTable

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.month).font(.headline)
                                Text("All regions · Unblended cost · " + model.unit).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            if model.loading { ProgressView().controlSize(.small) }
                            Button { model.onInfo?() } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.borderless).help("About Cost Explorer and access requirements")
                                .accessibilityLabel("About billing data")
                            if !model.loaded {
                                Button { model.onLoad?() } label: { Label("Load costs", systemImage: "arrow.clockwise") }
                                    .disabled(model.loading)
                            }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            summary("Month to date", value: model.totalText, detail: "Actual spend · may be estimated")
                            summary("Previous period", value: model.previousText,
                                    detail: model.previousPeriodLabel.isEmpty ? model.comparisonText : model.previousPeriodLabel + (model.comparisonChange == nil ? "\n" + model.comparisonText : ""), change: model.comparisonChange)
                            summary("Remaining forecast", value: model.forecastText, detail: "Today to month end · AWS estimate")
                        }
                        dailySpend
                    }
                    .background(GeometryReader { measured in Color.clear.preference(key: BillingChromeHeight.self, value: measured.size.height) })

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Costs by service").font(.headline)
                            Spacer()
                            Text(model.serviceCount == 1 ? "1 service" : "\(model.serviceCount) services").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        BillingServiceTable(table: table).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: max(220, geometry.size.height - model.chromeHeight - 56))
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "clock").foregroundStyle(.tertiary)
                        Text(model.note).foregroundStyle(.secondary).textSelection(.enabled)
                    }.font(.caption)
                        .background(GeometryReader { measured in Color.clear.preference(key: BillingChromeHeight.self, value: measured.size.height) })
                }
                .onPreferenceChange(BillingChromeHeight.self) { height in
                    if abs(model.chromeHeight - height) > 0.5 { model.chromeHeight = height }
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summary(_ title: String, value: String, detail: String, change: Double? = nil) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                Text(value).font(.system(size: 27, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    if let change {
                        HStack(spacing: 4) {
                            Text("Current month:").foregroundStyle(.secondary)
                            Image(systemName: change > 0 ? "arrow.up.right" : (change < 0 ? "arrow.down.right" : "arrow.right"))
                            Text(String(format: "%+.1f%%", change)).monospacedDigit()
                        }.foregroundStyle(change > 0 ? Color.red : (change < 0 ? Color.green : Color.secondary))
                            .help("Current month-to-date cost compared with the same elapsed period last month.")
                    }
                    Text(detail).foregroundStyle(.secondary).lineLimit(2)
                }.font(.system(size: 11)).frame(height: 32, alignment: .top)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }

    private var dailySpend: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily spend").font(.headline)
                Spacer(minLength: 12)
                Picker("Chart range", selection: Binding(get: { model.chartRange }, set: { model.chartRange = $0 })) {
                    ForEach(BillingChartRange.allCases) { range in Text(range.rawValue).tag(range) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                    .help("Chart only. Latest 7 days ends on the latest reported day; account totals stay month to date.")
            }
            HStack {
                Text(model.chartCaption)
                Spacer()
                Text(model.unit)
            }.font(.caption).foregroundStyle(.secondary)
            if model.visiblePoints.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.loading ? "Loading daily costs…" : "Load costs to see daily spending").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 185)
            } else { spendChart.frame(height: 185) }
        }
    }

    private var spendChart: some View {
        Chart {
            ForEach(Array(model.visiblePoints.enumerated()), id: \.offset) { _, point in
                BarMark(x: .value("Day", BillingDashboardModel.dayLabel(point.time)), y: .value("Cost", point.value), width: .ratio(0.65))
                    .foregroundStyle(Color.accentColor).cornerRadius(2)
                    .accessibilityLabel(BillingDashboardModel.dayLabel(point.time))
                    .accessibilityValue(BillingViewController.money(Decimal(point.value), model.unit))
            }
            if let point = model.selectedPoint {
                RuleMark(x: .value("Day", BillingDashboardModel.dayLabel(point.time))).foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .chartXScale(domain: model.visiblePoints.map { BillingDashboardModel.dayLabel($0.time) })
        .chartXAxis {
            AxisMarks(values: model.visiblePoints.enumerated().filter { $0.offset % max(1, model.visiblePoints.count / 7) == 0 }.map { BillingDashboardModel.dayLabel($0.element.time) }) { _ in
                AxisValueLabel().font(.system(size: 11))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(amount, format: .number.precision(.fractionLength(0))).font(.system(size: 11)).monospacedDigit().frame(minWidth: 28, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let position): model.hover = day(at: position, plot: plot, proxy: proxy)
                            case .ended: model.hover = nil
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { event in
                            if let date = day(at: event.location, plot: plot, proxy: proxy) {
                                model.pinnedDay = model.pinnedDay == date ? nil : date
                            }
                        })
                    if let point = model.selectedPoint, let x = proxy.position(forX: BillingDashboardModel.dayLabel(point.time)), let y = proxy.position(forY: point.value) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(BillingDashboardModel.dayLabel(point.time)).font(.caption).foregroundStyle(.secondary)
                            Text(BillingViewController.money(Decimal(point.value), model.unit)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        .padding(9).frame(width: 138, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .position(x: min(max(plot.minX + x, 78), max(78, geometry.size.width - 78)), y: max(30, plot.minY + y - 34))
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .focusable()
        .onMoveCommand { direction in
            if direction == .left { model.moveSelection(-1) }
            if direction == .right { model.moveSelection(1) }
        }
        .onExitCommand { model.hover = nil; model.pinnedDay = nil }
        .accessibilityAction(named: Text("Next day")) { model.moveSelection(1) }
        .accessibilityAction(named: Text("Previous day")) { model.moveSelection(-1) }
        .help("Hover or click to inspect a day. Use arrow keys to move between days; Escape clears the selection.")
    }

    private func day(at position: CGPoint, plot: CGRect, proxy: ChartProxy) -> Date? {
        guard plot.contains(position), let label = proxy.value(atX: position.x - plot.minX, as: String.self) else { return nil }
        return model.visiblePoints.first { BillingDashboardModel.dayLabel($0.time) == label }?.time
    }
}

private struct BillingServiceTable: NSViewRepresentable {
    let table: DataTable
    func makeNSView(context: Context) -> NSView { table.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct BillingChromeHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
