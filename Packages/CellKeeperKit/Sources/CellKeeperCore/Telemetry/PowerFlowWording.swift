import Foundation

/// The words of the menu's power flow (``PowerFlow``): what each node shows,
/// what VoiceOver reads for it, the diagram's spoken summary, and the
/// section's notes. Watts are shown with one decimal ("45.0 W") and read in
/// words with at most one ("45 watts", "14.6 watts"), in the user's number
/// format. Like the rest of the app's text, the words are English.
public enum PowerFlowWording {
    /// The section's note under the diagram and the chart.
    public static let footnote = "From macOS's battery data, updated about once a minute."

    /// Shown instead of the diagram when macOS reports no power use for the
    /// Mac.
    public static let unavailable = "Power flow is not available: macOS reports no power use for this Mac."

    /// What the chart's legend calls each series.
    public static func title(of series: PowerFlowHistory.Series) -> String {
        switch series {
        case .macUse: "Mac use"
        case .adapterInput: "Adapter input"
        case .battery: "Battery"
        }
    }

    /// The chart's accessibility label.
    public static let chartLabel = "Power over the last hour, in watts: the Mac's use, the adapter's input, and the battery, positive while charging and negative while supplying the Mac"

    /// Says how to read the battery's line.
    public static let chartBatteryNote = "Battery above 0 W is charging, below is supplying the Mac."

    /// Until the history has a line to draw.
    public static let chartEmpty = "The chart fills in as macOS updates its battery data."

    // MARK: - Numbers

    /// "45.0 W", "0.3 W".
    public static func watts(_ value: Double, locale: Locale = .current) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)).locale(locale))) W"
    }

    /// "45 watts", "14.6 watts", "1 watt".
    public static func spokenWatts(_ value: Double, locale: Locale = .current) -> String {
        QuantityUnit.watts.spoken(value, fractionDigits: 0...1, locale: locale)
    }

    // MARK: - Nodes

    /// The adapter node's value: its input, or why there is none.
    public static func adapterValue(_ flow: PowerFlow, locale: Locale = .current) -> String {
        switch flow.powerSource {
        case .externalPower: flow.adapterInputWatts.map { watts($0, locale: locale) } ?? "Not available"
        case .battery: "Not connected"
        case .unknown: "Unknown"
        }
    }

    /// The adapter node's subtitle: "68 W adapter", the negotiated power.
    public static func adapterSubtitle(_ flow: PowerFlow) -> String? {
        flow.adapterRatingWatts.map { "\($0) W adapter" }
    }

    /// What VoiceOver reads for the adapter node, after "Adapter".
    public static func adapterSpoken(_ flow: PowerFlow, locale: Locale = .current) -> String {
        let rating = flow.adapterRatingWatts.map { ", \($0.formatted(.number.locale(locale)))-watt adapter" } ?? ""
        switch flow.powerSource {
        case .externalPower:
            guard let input = flow.adapterInputWatts else { return "Input not available\(rating)" }
            return "\(spokenWatts(input, locale: locale)) in\(rating)"
        case .battery: return "Not connected"
        case .unknown: return "Unknown"
        }
    }

    /// The battery node's value: its charge.
    public static func batteryValue(_ flow: PowerFlow) -> String {
        flow.chargePercent.map { "\($0)%" } ?? "Not available"
    }

    /// The battery node's subtitle: "Charging +15.0 W", "Supplying 12.3 W"
    /// or "Idle".
    public static func batterySubtitle(_ flow: PowerFlow, locale: Locale = .current) -> String {
        switch flow.battery {
        case .charging(let value): "Charging +\(watts(value, locale: locale))"
        case .supplying(let value): "Supplying \(watts(value, locale: locale))"
        case .idle: "Idle"
        case nil: "Power not available"
        }
    }

    /// What VoiceOver reads for the battery node, after "Battery".
    public static func batterySpoken(_ flow: PowerFlow, locale: Locale = .current) -> String {
        let charge = flow.chargePercent.map { "\($0)%" } ?? "Charge not available"
        let power = switch flow.battery {
        case .charging(let value): "charging at \(spokenWatts(value, locale: locale))"
        case .supplying(let value): "supplying \(spokenWatts(value, locale: locale))"
        case .idle: "idle"
        case nil: "power not available"
        }
        return "\(charge), \(power)"
    }

    /// The Mac node's value: what it uses.
    public static func macValue(_ flow: PowerFlow, locale: Locale = .current) -> String {
        watts(flow.macUseWatts, locale: locale)
    }

    /// What VoiceOver reads for the Mac node, after "Mac".
    public static func macSpoken(_ flow: PowerFlow, locale: Locale = .current) -> String {
        "uses \(spokenWatts(flow.macUseWatts, locale: locale))"
    }

    // MARK: - Summary

    /// The diagram as one sentence or a few, for VoiceOver: where the power
    /// comes from and where it goes, each value as reported ("The adapter
    /// supplies 45 watts: the Mac uses 30 watts and 15 watts charges the
    /// battery."), then what is idle or not known.
    public static func summary(_ flow: PowerFlow, locale: Locale = .current) -> String {
        func spoken(_ value: Double) -> String { spokenWatts(value, locale: locale) }
        var sources: [String] = []
        if let input = flow.adapterInputWatts {
            sources.append("the adapter supplies \(spoken(input))")
        }
        if case .supplying(let value) = flow.battery {
            sources.append("the battery supplies \(spoken(value))")
        }
        var use = "the Mac uses \(spoken(flow.macUseWatts))"
        if case .charging(let value) = flow.battery {
            use += " and \(spoken(value)) charges the battery"
        }
        var sentences = [sources.isEmpty ? use : "\(sources.joined(separator: " and ")): \(use)"]
        switch flow.battery {
        case .idle: sentences.append("the battery is idle")
        case nil: sentences.append("the battery's power is not available")
        case .charging, .supplying: break
        }
        switch flow.powerSource {
        case .externalPower where flow.adapterInputWatts == nil: sentences.append("the adapter's input is not available")
        case .externalPower: break
        case .battery: sentences.append("no adapter is connected")
        case .unknown: sentences.append("the power source is unknown")
        }
        return sentences.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }.joined(separator: " ")
    }
}
