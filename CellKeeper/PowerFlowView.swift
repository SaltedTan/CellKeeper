import AppKit
import CellKeeperCore
import Charts
import SwiftUI

/// The menu's "Power flow" section (D114): where the Mac's power comes from
/// and goes, as a diagram of the adapter, the battery and the Mac, and a
/// chart of the last hour. Display only: it changes nothing, and the policy
/// and the controller never see what it shows. While the menu is open and
/// the section expanded, its source is read every few seconds; the wording
/// is `PowerFlowWording`'s.
struct PowerFlowSection: View {
    let model: AppModel

    var body: some View {
        DisclosureGroup("Power flow", isExpanded: Binding(
            get: { model.isPowerFlowExpanded },
            set: { model.setPowerFlowExpanded($0) }
        )) {
            PowerFlowContent(state: model.powerFlow, footnote: model.powerFlowFootnote, lineBreakGap: model.powerFlowLineBreakGap)
                .padding(.top, 4)
        }
        // Reads while the menu is open and the section expanded. SwiftUI
        // cancels the task when the menu closes, and starts it again when
        // the section is expanded or collapsed; collapsed, it reads nothing
        // and ends at once.
        .task(id: model.isPowerFlowExpanded) {
            await model.refreshPowerFlowWhileShown()
        }
    }
}

private struct PowerFlowContent: View {
    let state: PowerFlowState
    let footnote: String
    let lineBreakGap: TimeInterval

    var body: some View {
        if let flow = state.flow {
            VStack(alignment: .leading, spacing: 10) {
                PowerFlowDiagram(flow: flow)
                PowerFlowChart(history: state.history, lineBreakGap: lineBreakGap)
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // A reading without the Mac's power use, or none at all (the
            // header then says why).
            Text(state.hasSample ? PowerFlowWording.unavailable : Format.unavailable)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Diagram

private enum FlowNodeID: Hashable {
    case adapter
    case battery
    case mac
}

/// The bounds of the diagram's nodes, for drawing the arrows between them.
private struct FlowNodeBounds: PreferenceKey {
    static var defaultValue: [FlowNodeID: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [FlowNodeID: Anchor<CGRect>], nextValue: () -> [FlowNodeID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The adapter above the battery on the left, the Mac on the right, and an
/// arrow for each active flow. One element for VoiceOver, named by the
/// flow's summary, containing the three nodes.
private struct PowerFlowDiagram: View {
    let flow: PowerFlow

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                FlowNode(
                    symbol: "powerplug",
                    title: "Adapter",
                    value: PowerFlowWording.adapterValue(flow),
                    subtitle: PowerFlowWording.adapterSubtitle(flow),
                    isDimmed: flow.powerSource != .externalPower,
                    spokenValue: PowerFlowWording.adapterSpoken(flow)
                )
                .anchorPreference(key: FlowNodeBounds.self, value: .bounds) { [.adapter: $0] }
                FlowNode(
                    symbol: Self.batterySymbol(flow.chargePercent),
                    title: "Battery",
                    value: PowerFlowWording.batteryValue(flow),
                    subtitle: PowerFlowWording.batterySubtitle(flow),
                    spokenValue: PowerFlowWording.batterySpoken(flow)
                )
                .anchorPreference(key: FlowNodeBounds.self, value: .bounds) { [.battery: $0] }
            }
            Spacer(minLength: 64)
            FlowNode(
                symbol: "laptopcomputer",
                title: "Mac",
                value: PowerFlowWording.macValue(flow),
                spokenValue: PowerFlowWording.macSpoken(flow)
            )
            .anchorPreference(key: FlowNodeBounds.self, value: .bounds) { [.mac: $0] }
        }
        .backgroundPreferenceValue(FlowNodeBounds.self) { anchors in
            GeometryReader { proxy in
                if let adapter = anchors[.adapter], let battery = anchors[.battery], let mac = anchors[.mac] {
                    FlowArrows(flow: flow, adapter: proxy[adapter], battery: proxy[battery], mac: proxy[mac])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PowerFlowWording.summary(flow))
    }

    /// A battery symbol for the charge, in quarters; a plain battery while
    /// the charge is unknown, which an empty one would misstate.
    private static func batterySymbol(_ percent: Int?) -> String {
        guard let percent else { return "batteryblock" }
        return switch percent {
        case 88...: "battery.100percent"
        case 63...: "battery.75percent"
        case 38...: "battery.50percent"
        case 13...: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

/// A node: its symbol, a short label, its value and an optional line
/// beneath. One element for VoiceOver: the label, and the value with its
/// units in words.
private struct FlowNode: View {
    let symbol: String
    let title: String
    let value: String
    var subtitle: String?
    /// Shown in the secondary colour: the adapter while not connected.
    var isDimmed = false
    let spokenValue: String

    /// The symbols' column; the arrow from the adapter to the battery runs
    /// down its middle.
    static let iconWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: symbol)
                .font(.title3)
                // Wide enough for the battery symbol: in a narrower frame
                // macOS drew it white (seen offscreen).
                .frame(width: FlowNode.iconWidth)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .foregroundStyle(isDimmed ? .secondary : .primary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        // Otherwise its role is unknown (seen in the accessibility tree).
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue)
    }
}

/// The arrows of the active flows, each labelled with its watts, thicker
/// for more power up to a cap. Hidden from VoiceOver: the diagram's summary
/// says the same.
private struct FlowArrows: View {
    let flow: PowerFlow
    let adapter: CGRect
    let battery: CGRect
    let mac: CGRect

    private enum Route: Hashable {
        case adapterToMac
        case adapterToBattery
        case batteryToMac
    }

    private struct Arrow: Identifiable {
        let id: Route
        let start: CGPoint
        let end: CGPoint
        let watts: Double
        /// Where its label's centre goes, and whether it starts there
        /// instead (to the right of a vertical arrow).
        let label: CGPoint
        let isLabelLeading: Bool

        var width: CGFloat { 1.5 + CGFloat(min(watts, 100) / 100) * 3 }
    }

    var body: some View {
        let arrows = self.arrows
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for arrow in arrows {
                    draw(arrow, in: context)
                }
            }
            ForEach(arrows) { arrow in
                Text(PowerFlowWording.watts(arrow.watts))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: 70, alignment: arrow.isLabelLeading ? .leading : .center)
                    .position(x: arrow.label.x + (arrow.isLabelLeading ? 35 : 0), y: arrow.label.y)
            }
        }
        .accessibilityHidden(true)
    }

    private var arrows: [Arrow] {
        var arrows: [Arrow] = []
        if PowerFlow.isActive(flow.adapterToMacWatts), let watts = flow.adapterToMacWatts {
            let start = CGPoint(x: adapter.maxX + 6, y: adapter.midY)
            let end = CGPoint(x: mac.minX - 6, y: mac.midY - 5)
            arrows.append(Arrow(id: .adapterToMac, start: start, end: end, watts: watts, label: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 10), isLabelLeading: false))
        }
        if PowerFlow.isActive(flow.adapterToBatteryWatts), let watts = flow.adapterToBatteryWatts {
            let x = adapter.minX + FlowNode.iconWidth / 2
            let start = CGPoint(x: x, y: adapter.maxY + 3)
            let end = CGPoint(x: x, y: battery.minY - 3)
            arrows.append(Arrow(id: .adapterToBattery, start: start, end: end, watts: watts, label: CGPoint(x: x + 8, y: (start.y + end.y) / 2), isLabelLeading: true))
        }
        if PowerFlow.isActive(flow.batteryToMacWatts), let watts = flow.batteryToMacWatts {
            let start = CGPoint(x: battery.maxX + 6, y: battery.midY)
            let end = CGPoint(x: mac.minX - 6, y: mac.midY + 5)
            arrows.append(Arrow(id: .batteryToMac, start: start, end: end, watts: watts, label: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + 10), isLabelLeading: false))
        }
        return arrows
    }

    /// A line and a filled head pointing at `end`.
    private func draw(_ arrow: Arrow, in context: GraphicsContext) {
        let dx = arrow.end.x - arrow.start.x
        let dy = arrow.end.y - arrow.start.y
        let length = max(sqrt(dx * dx + dy * dy), 1)
        let unit = CGPoint(x: dx / length, y: dy / length)
        let headLength = min(5 + arrow.width * 1.5, length / 2)
        let headHalfWidth = 2.5 + arrow.width
        let base = CGPoint(x: arrow.end.x - unit.x * headLength, y: arrow.end.y - unit.y * headLength)
        var line = Path()
        line.move(to: arrow.start)
        line.addLine(to: base)
        context.stroke(line, with: .style(.secondary), style: StrokeStyle(lineWidth: arrow.width, lineCap: .round))
        var head = Path()
        head.move(to: arrow.end)
        head.addLine(to: CGPoint(x: base.x - unit.y * headHalfWidth, y: base.y + unit.x * headHalfWidth))
        head.addLine(to: CGPoint(x: base.x + unit.y * headHalfWidth, y: base.y - unit.x * headHalfWidth))
        head.closeSubpath()
        context.fill(head, with: .style(.secondary))
    }
}

// MARK: - Chart

/// The last hour: the Mac's use, the adapter's input and the battery
/// (charging above 0 W, supplying below), each line in its own colour and
/// dash, named in the legend beneath. Swift Charts' audio graph is kept.
private struct PowerFlowChart: View {
    let history: PowerFlowHistory
    let lineBreakGap: TimeInterval

    private struct Line: Hashable {
        let series: PowerFlowHistory.Series
        let segment: Int
    }

    var body: some View {
        let points = history.chartPoints(maximumGap: lineBreakGap)
        let pointsPerLine = Dictionary(grouping: points) { Line(series: $0.series, segment: $0.segment) }.mapValues(\.count)
        if let newest = history.newestTime, history.points.count >= 2 {
            let domain = newest.addingTimeInterval(-PowerFlowHistory.chartWindow)...newest
            VStack(alignment: .leading, spacing: 4) {
                Chart {
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .accessibilityHidden(true)
                    ForEach(points, id: \.self) { point in
                        let name = Self.lineName(point)
                        if pointsPerLine[Line(series: point.series, segment: point.segment)] == 1 {
                            // A point alone between gaps has its series'
                            // symbol, so that it is not told apart by
                            // colour only.
                            PointMark(x: .value("Time", point.time), y: .value("Watts", point.watts))
                                .foregroundStyle(point.series.color)
                                .symbol(point.series.symbol)
                                .symbolSize(36)
                                .accessibilityLabel(name)
                                .accessibilityValue(Self.spokenValue(point))
                        } else {
                            LineMark(x: .value("Time", point.time), y: .value("Watts", point.watts), series: .value("Line", name))
                                .foregroundStyle(point.series.color)
                                .lineStyle(point.series.stroke)
                                .accessibilityLabel(name)
                                .accessibilityValue(Self.spokenValue(point))
                        }
                    }
                }
                .chartXScale(domain: domain)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: Self.quarterHours(in: domain)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisValueLabel {
                            if let watts = value.as(Double.self) {
                                Text("\(watts.formatted()) W")
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 100)
                .accessibilityLabel(PowerFlowWording.chartLabel)
                PowerFlowLegend()
                Text(PowerFlowWording.chartBatteryNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(PowerFlowWording.chartEmpty)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The quarter hours within `range`, for the time axis: whole local
    /// quarter hours, since every time zone's offset is a multiple of 15
    /// minutes. None within 9 minutes of either end, where its label would
    /// be cut off.
    private static func quarterHours(in range: ClosedRange<Date>) -> [Date] {
        let step: TimeInterval = 15 * 60
        let margin: TimeInterval = 9 * 60
        var time = ((range.lowerBound.timeIntervalSinceReferenceDate + margin) / step).rounded(.up) * step
        var dates: [Date] = []
        while time <= range.upperBound.timeIntervalSinceReferenceDate - margin {
            dates.append(Date(timeIntervalSinceReferenceDate: time))
            time += step
        }
        return dates
    }

    /// The series' name, numbered after a break, for the audio graph.
    private static func lineName(_ point: PowerFlowHistory.ChartPoint) -> String {
        let title = PowerFlowWording.title(of: point.series)
        return point.segment == 0 ? title : "\(title), part \(point.segment + 1)"
    }

    private static func spokenValue(_ point: PowerFlowHistory.ChartPoint) -> String {
        "\(PowerFlowWording.spokenWatts(point.watts)) at \(point.time.formatted(date: .omitted, time: .shortened))"
    }
}

/// Each series' key, its line in its colour and dash with its symbol, and
/// its name.
private struct PowerFlowLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(PowerFlowHistory.Series.allCases, id: \.self) { series in
                HStack(spacing: 4) {
                    ZStack {
                        Canvas { context, size in
                            var line = Path()
                            line.move(to: CGPoint(x: 1, y: size.height / 2))
                            line.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
                            context.stroke(line, with: .color(series.color), style: series.stroke)
                        }
                        series.symbol
                            .fill(series.color)
                            .frame(width: 6, height: 6)
                    }
                    .frame(width: 22, height: 8)
                    .accessibilityHidden(true)
                    Text(PowerFlowWording.title(of: series))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension PowerFlowHistory.Series {
    /// The chart's colours: blue, orange and green, three categorical hues
    /// told apart under colour blindness. Each reaches WCAG's 3:1 graphic
    /// contrast on every menu and Settings background (`TextTone.backgrounds`).
    /// Dark mode uses the system's colours (at least 3.3:1); the system's
    /// orange and green reach only about 2:1 on the light backgrounds, so
    /// light mode uses darker shades of all three (at least 4.1:1, 3.4:1
    /// and 3.7:1). The dashes and symbols tell the series apart without
    /// colour.
    fileprivate var color: Color {
        switch self {
        case .macUse: Self.color(light: 0x0064D7, dark: .systemBlue)
        case .adapterInput: Self.color(light: 0xC4520F, dark: .systemOrange)
        case .battery: Self.color(light: 0x12805C, dark: .systemGreen)
        }
    }

    /// `light`, an sRGB hex, in the light appearances, and `dark` in the
    /// dark ones.
    private static func color(light: UInt32, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            if isDark { return dark }
            return NSColor(srgbRed: CGFloat(light >> 16 & 0xFF) / 255, green: CGFloat(light >> 8 & 0xFF) / 255, blue: CGFloat(light & 0xFF) / 255, alpha: 1)
        })
    }

    /// A circle for the Mac's use, a square for the adapter's input and a
    /// triangle for the battery: an isolated point's mark, and in the legend.
    fileprivate var symbol: BasicChartSymbolShape {
        switch self {
        case .macUse: .circle
        case .adapterInput: .square
        case .battery: .triangle
        }
    }

    /// Solid for the Mac's use, dashed for the adapter's input, dotted for
    /// the battery.
    fileprivate var stroke: StrokeStyle {
        switch self {
        case .macUse: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        case .adapterInput: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 4])
        case .battery: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [0.5, 4])
        }
    }
}
