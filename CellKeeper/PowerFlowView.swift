import AppKit
import CellKeeperCore
import Charts
import SwiftUI

/// The power flow at the top of the menu (D121, on by default in
/// Settings › General): the diagram alone, under the header, whenever the
/// menu is open. The chart and the source's note are under Details › Power
/// history. Display only (D114). While it is shown, its source is read every
/// few seconds; SwiftUI cancels the task when the menu closes.
struct PowerFlowGlance: View {
    let model: AppModel

    var body: some View {
        Group {
            if let flow = model.powerFlow.flow {
                PowerFlowDiagram(flow: flow)
            } else {
                PowerFlowUnavailable(state: model.powerFlow)
            }
        }
        .task(id: model.showsPowerFlowInMenu) {
            await model.refreshPowerFlowWhileShown()
        }
    }
}

/// Details › Power history, while the diagram is at the top of the menu:
/// the last hour's chart and where the values come from. It reads nothing
/// itself; the diagram's reads fill it.
struct PowerHistorySection: View {
    let model: AppModel

    var body: some View {
        DisclosureGroup("Power history") {
            VStack(alignment: .leading, spacing: 10) {
                if model.powerFlow.flow != nil {
                    PowerFlowChart(history: model.powerFlow.history, lineBreakGap: model.powerFlowLineBreakGap)
                }
                Text(model.powerFlowFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The menu's "Power flow" section under Details (D114), while the diagram
/// is not at the top of the menu: where the Mac's power comes from and
/// goes, as a diagram of the adapter, the Mac and the battery, and a chart
/// of the last hour. Display only: it changes nothing, and the policy and
/// the controller never see what it shows. While the menu is open and the
/// section expanded, its source is read every few seconds; the wording is
/// `PowerFlowWording`'s.
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
            PowerFlowUnavailable(state: state)
        }
    }
}

/// A reading without the Mac's power use, or none at all (the header then
/// says why).
private struct PowerFlowUnavailable: View {
    let state: PowerFlowState

    var body: some View {
        Text(state.hasSample ? PowerFlowWording.unavailable : Format.unavailable)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Diagram

/// The adapter, the Mac and the battery in a row, each a symbol in a soft
/// circle with its name and value beneath, joined by two links: the
/// adapter's input into the Mac, and the battery's power between the Mac
/// and the battery, which runs either way. Each link is one reported value,
/// never a sum or a difference (D114): its width grows with the watts and a
/// blob glides along it towards where the power goes, faster for more. A
/// link with no power, or whose power is not known, is a faint track with
/// no blob, dashed when not known. With Reduce Motion the blob stays still
/// and the link brightens towards where the power goes. One element for
/// VoiceOver, named by the flow's summary, containing the three nodes.
private struct PowerFlowDiagram: View {
    let flow: PowerFlow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            FlowNode(
                symbol: "powerplug",
                title: "Adapter",
                value: PowerFlowWording.adapterValue(flow),
                subtitle: PowerFlowWording.adapterSubtitle(flow),
                isDimmed: flow.powerSource != .externalPower,
                spokenValue: PowerFlowWording.adapterSpoken(flow)
            )
            FlowNode(
                symbol: "laptopcomputer",
                title: "Mac",
                value: PowerFlowWording.macValue(flow),
                spokenValue: PowerFlowWording.macSpoken(flow)
            )
            FlowNode(
                symbol: Self.batterySymbol(flow.chargePercent),
                title: "Battery",
                value: PowerFlowWording.batteryValue(flow),
                subtitle: PowerFlowWording.batterySubtitle(flow),
                spokenValue: PowerFlowWording.batterySpoken(flow)
            )
        }
        .background(alignment: .top) {
            FlowLinks(links: FlowLink.links(of: flow))
                .frame(height: FlowNode.circleSize)
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

/// A node: its symbol in a soft circle, its name, its value and an optional
/// line beneath, centred in a third of the row. One element for VoiceOver:
/// the name, and the value with its units in words.
private struct FlowNode: View {
    let symbol: String
    let title: String
    let value: String
    var subtitle: String?
    /// Shown in the secondary colour: the adapter while not connected.
    var isDimmed = false
    let spokenValue: String

    /// The circles' diameter; the links run between them at mid-height.
    static let circleSize: CGFloat = 36

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: FlowNode.circleSize, height: FlowNode.circleSize)
                .background(Circle().fill(.quaternary))
                .padding(.bottom, 4)
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
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(isDimmed ? .secondary : .primary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        // Otherwise its role is unknown (seen in the accessibility tree).
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue)
    }
}

/// One of the diagram's two links and what it carries
/// (``PowerFlow/adapterLink``, ``PowerFlow/batteryLink``).
private struct FlowLink: Equatable {
    enum Side {
        /// Between the adapter and the Mac.
        case adapter
        /// Between the Mac and the battery.
        case battery
    }

    let side: Side
    let state: PowerFlow.Link

    static func links(of flow: PowerFlow) -> [FlowLink] {
        [FlowLink(side: .adapter, state: flow.adapterLink), FlowLink(side: .battery, state: flow.batteryLink)]
    }

    var color: Color {
        switch side {
        case .adapter: PowerFlowHistory.Series.adapterInput.color
        case .battery: PowerFlowHistory.Series.battery.color
        }
    }

    var isFlowing: Bool {
        if case .flowing = state { return true }
        return false
    }
}

/// The links, drawn behind the nodes. A flowing link's blob moves only
/// while the menu shows it and Reduce Motion is off. Hidden from VoiceOver:
/// the diagram's summary says the same.
private struct FlowLinks: View {
    let links: [FlowLink]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = !reduceMotion && links.contains(where: \.isFlowing)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for link in links {
                    draw(link, in: &context, size: size, time: animates ? time : nil)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The share of the full width and speed that `watts` earns: 0 at
    /// nothing, 1 at 100 W or more.
    private static func strength(_ watts: Double) -> CGFloat {
        CGFloat(min(max(watts, 0), 100) / 100)
    }

    /// `time` is nil when the blob stays still.
    private func draw(_ link: FlowLink, in context: inout GraphicsContext, size: CGSize, time: TimeInterval?) {
        // The nodes are three equal columns; each circle is centred in its
        // own. The link runs between two circles, a little clear of each.
        let column = size.width / 3
        let radius = FlowNode.circleSize / 2
        let gap: CGFloat = 5
        let (left, right): (CGFloat, CGFloat) = switch link.side {
        case .adapter: (column / 2, column * 1.5)
        case .battery: (column * 1.5, column * 2.5)
        }
        let y = size.height / 2
        let start = left + radius + gap
        let end = right - radius - gap
        guard end - start > 8 else { return }
        var track = Path()
        track.move(to: CGPoint(x: start, y: y))
        track.addLine(to: CGPoint(x: end, y: y))

        guard case .flowing(let watts, let isTowardsMac) = link.state else {
            // Idle: a faint line; not known: a faint dashed one.
            let dash: [CGFloat] = link.state == .unknown ? [2, 4] : []
            context.stroke(track, with: .style(.quaternary), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
            return
        }
        let strength = Self.strength(watts)
        let width = 3 + strength * 3
        // Towards the Mac is rightwards on the adapter's side and leftwards
        // on the battery's.
        let isRightwards = (link.side == .adapter) == isTowardsMac
        let from = isRightwards ? start : end
        let to = isRightwards ? end : start

        guard let time else {
            // Still: the track brightens towards where the power goes.
            let gradient = Gradient(colors: [link.color.opacity(0.2), link.color])
            context.stroke(track, with: .linearGradient(gradient, startPoint: CGPoint(x: from, y: y), endPoint: CGPoint(x: to, y: y)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            return
        }
        context.stroke(track, with: .color(link.color.opacity(0.22)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        // The blob: longer and quicker for more power, fading in and out at
        // the ends so it never pops.
        let period = 2.4 - Double(strength) * 1.5
        let phase = CGFloat((time / period).truncatingRemainder(dividingBy: 1))
        let length = 10 + strength * 16
        let centre = from + (to - from) * phase
        let blob = CGRect(x: centre - length / 2, y: y - (width + 3) / 2, width: length, height: width + 3)
        var blobContext = context
        blobContext.opacity = Double(sin(phase * .pi))
        blobContext.clip(to: Path(CGRect(x: start - width, y: 0, width: end - start + 2 * width, height: size.height)))
        blobContext.fill(Path(roundedRect: blob, cornerRadius: blob.height / 2), with: .color(link.color))
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
                        // A time label sits to the right of its tick, so
                        // the last one can reach past the plot. One that
                        // does not fit is left out, its grid line kept,
                        // rather than cut to "6:30…"; the axis measures the
                        // label, so this holds in every locale.
                        AxisValueLabel(format: .dateTime.hour().minute(), collisionResolution: .greedy)
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
    /// minutes. None within 9 minutes of either end, where a grid line
    /// would crowd the edge; whether the last one's label fits is the
    /// axis's decision, from the label's width.
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
