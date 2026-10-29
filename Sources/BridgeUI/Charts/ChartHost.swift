import AppKit
import SwiftUI
import Charts
import Observation
import BridgeCore

// Time-series charts hosted in AppKit. Command Line Tools ships no SwiftUIMacros plugin, so `@State` does not
// compile (Spikes/ui/RESULTS.md); SwiftUI observes this @Observable model instead. All panels share one time
// axis and one hover position (a rule and a readout on every panel at the same time).

public struct ChartPanel: Identifiable {
    public var id: String
    public var title: String
    public var points: [MetricPoint]
    public var color: Color
    /// Render as bars (counts such as Errors) instead of a line.
    public var bars = false
    public init(id: String, title: String, points: [MetricPoint], color: Color, bars: Bool = false, format: @escaping (Double) -> String = { v in v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }) {
        self.id = id; self.title = title; self.points = points; self.color = color; self.bars = bars; self.format = format
    }
    public var format: (Double) -> String = { v in v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

@Observable
public final class ChartModel {
    public var panels: [ChartPanel] = []
    public var domain: ClosedRange<Date> = Date().addingTimeInterval(-900)...Date()
    public var hover: Date?
    public var message: String = ""
}

private struct ChartsView: View {
    let model: ChartModel

    var body: some View {
        if model.panels.isEmpty {
            Text(model.message.isEmpty ? "No data" : model.message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 14) { ForEach(model.panels) { panel($0) } }.padding(12)
            }
        }
    }

    private func nearest(_ pts: [MetricPoint], _ d: Date) -> MetricPoint? {
        pts.min { abs($0.time.timeIntervalSince(d)) < abs($1.time.timeIntervalSince(d)) }
    }

    private func panel(_ p: ChartPanel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.title).font(.headline)
                Spacer()
                if let h = model.hover, let pt = nearest(p.points, h) {
                    Text("\(pt.time.formatted(date: .omitted, time: .standard))   \(p.format(pt.value))").font(.caption).monospacedDigit()
                }
            }
            Chart {
                ForEach(Array(p.points.enumerated()), id: \.offset) { _, pt in
                    if p.bars { BarMark(x: .value("Time", pt.time), y: .value("Value", pt.value)).foregroundStyle(p.color) }
                    else { LineMark(x: .value("Time", pt.time), y: .value("Value", pt.value)).foregroundStyle(p.color) }
                }
                if let h = model.hover, let pt = nearest(p.points, h) {
                    RuleMark(x: .value("Time", pt.time)).foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: model.domain)
            .chartPlotStyle { plot in plot.clipped() }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                if let frame = proxy.plotFrame { model.hover = proxy.value(atX: loc.x - geo[frame].origin.x, as: Date.self) }
                            case .ended:
                                model.hover = nil
                            }
                        }
                }
            }
            .frame(height: 130)
        }
    }
}

/// An AppKit-embeddable chart area. Update `model`; the view follows.
public final class ChartHost {
    public let model = ChartModel()
    public let view: NSView
    public init() {
        view = NSHostingView(rootView: ChartsView(model: model))
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    }

    /// Replace the panels from metric series keyed by id (`m0`...), for a window.
    public func show(series: [MetricSeries], specs: [(id: String, title: String, color: Color, bars: Bool)], window: TimeWindow) {
        model.domain = window.start...window.end
        model.panels = specs.compactMap { s in
            guard let ser = series.first(where: { $0.id == s.id }) else { return nil }
            return ChartPanel(id: s.id, title: s.title, points: ser.points, color: s.color, bars: s.bars)
        }
        model.message = model.panels.isEmpty ? "No metric data in this time range" : ""
    }

    public func clear(_ message: String) { model.panels = []; model.message = message }
}
