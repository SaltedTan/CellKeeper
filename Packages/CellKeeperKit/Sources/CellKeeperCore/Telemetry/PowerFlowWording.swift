import Foundation

/// The words of the menu's power flow (``PowerFlow``): what each node shows,
/// what VoiceOver reads for it, the diagram's spoken summary, and the
/// section's notes. Watts are shown with one decimal ("45.0 W") and read in
/// words with at most one ("45 watts", "14.6 watts"), in the user's number
/// format. Like the rest of the app's text, the words are English.
public enum PowerFlowWording {
    /// The section's note under the diagram and the chart, from its source
    /// (``PowerFlowReading/footnote``): "From macOS's battery data, updated
    /// about once a minute."
    public static func footnote(sourceName: String, updateInterval: Duration) -> String {
        "From \(sourceName), updated \(cadence(updateInterval))."
    }

    /// The section's note for the sample on screen, from its provenance
    /// (research note 13 §6.5); `registrySource` is the registry track's.
    /// From the registry: as ``footnote(sourceName:updateInterval:)``. From
    /// the SMC: "Power in and Mac from the SMC, averaged over 3 seconds;
    /// battery from macOS's battery data, updated about once a minute.", or
    /// "Power in, Mac and battery from the SMC, averaged over 3 seconds."
    /// once the battery's power comes from it too. Off external power there
    /// is no power in, so only the Mac (and the battery) are named.
    public static func footnote(
        _ provenance: PowerFlowProvenance,
        isOnExternalPower: Bool,
        registrySourceName: String,
        registryUpdateInterval: Duration
    ) -> String {
        guard case .smc(let span) = provenance.system else {
            return footnote(sourceName: registrySourceName, updateInterval: registryUpdateInterval)
        }
        let averaged = "averaged over \(seconds(span))"
        switch provenance.battery {
        case .smc:
            return "\(isOnExternalPower ? "Power in, Mac and battery" : "Mac and battery") from the SMC, \(averaged)."
        case .registry:
            return "\(isOnExternalPower ? "Power in and Mac" : "Mac") from the SMC, \(averaged); battery from \(registrySourceName), updated \(cadence(registryUpdateInterval))."
        }
    }

    /// Where the sample on screen came from, for the diagnostics report:
    /// "macOS's battery data", "the SMC, averaged over 3 seconds (power in
    /// and Mac); macOS's battery data (battery)", or "none" without one.
    public static func diagnosticsSource(_ provenance: PowerFlowProvenance?, registrySourceName: String) -> String {
        guard let provenance else { return "none" }
        guard case .smc(let span) = provenance.system else { return registrySourceName }
        switch provenance.battery {
        case .smc: return "the SMC, averaged over \(seconds(span))"
        case .registry: return "the SMC, averaged over \(seconds(span)) (power in and Mac); \(registrySourceName) (battery)"
        }
    }

    /// A span in whole seconds, in words: "1 second", "3 seconds".
    static func seconds(_ span: Duration) -> String {
        let seconds = span.components.seconds
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    /// How often a source updates, to the nearest second: "about every
    /// second", "about every 3 seconds", "about once a minute", "about
    /// every 2 minutes", "about every 90 seconds".
    static func cadence(_ interval: Duration) -> String {
        let parts = interval.components
        let roundsUp = parts.attoseconds >= 500_000_000_000_000_000 && parts.seconds < .max
        let seconds = roundsUp ? parts.seconds + 1 : parts.seconds
        switch seconds {
        case ...1: return "about every second"
        case 60: return "about once a minute"
        case 61... where seconds.isMultiple(of: 60): return "about every \(seconds / 60) minutes"
        default: return "about every \(seconds) seconds"
        }
    }

    /// Shown instead of the diagram when macOS reports no power use for the
    /// Mac.
    public static let unavailable = "Power flow is not available: macOS reports no power use for this Mac."

    /// What the chart's legend calls each series.
    public static func title(of series: PowerFlowHistory.Series) -> String {
        switch series {
        case .macUse: "Mac use"
        case .adapterInput: "Power in"
        case .battery: "Battery"
        }
    }

    /// The chart's accessibility label.
    public static let chartLabel = "Power over the last hour, in watts: the Mac's use, the power coming in, and the battery, positive while charging and negative while supplying the Mac"

    /// Says how to read the battery's line.
    public static let chartBatteryNote = "Battery above 0 W is charging, below is supplying the Mac."

    /// Until the history has a line to draw.
    public static let chartEmpty = "The chart fills in as new values arrive."

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

    /// The "Power in" node's value: the power coming in, or why there is
    /// none.
    public static func adapterValue(_ flow: PowerFlow, locale: Locale = .current) -> String {
        switch flow.powerSource {
        case .externalPower: flow.adapterInputWatts.map { watts($0, locale: locale) } ?? "Not available"
        case .battery: "Not connected"
        case .unknown: "Unknown"
        }
    }

    /// The "Power in" node's subtitle: "Up to 68 W", the power negotiated
    /// with whatever supplies it (a charger, a display or a dock: macOS
    /// reports them alike).
    public static func adapterSubtitle(_ flow: PowerFlow) -> String? {
        flow.adapterRatingWatts.map { "Up to \($0) W" }
    }

    /// What VoiceOver reads for the "Power in" node, after its name.
    public static func adapterSpoken(_ flow: PowerFlow, locale: Locale = .current) -> String {
        let rating = flow.adapterRatingWatts.map { ", up to \(spokenWatts(Double($0), locale: locale))" } ?? ""
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
    /// comes from and where it goes, each value as reported ("External
    /// power supplies 45 watts: the Mac uses 30 watts and 15 watts charges
    /// the battery."), then what is idle or not known.
    public static func summary(_ flow: PowerFlow, locale: Locale = .current) -> String {
        func spoken(_ value: Double) -> String { spokenWatts(value, locale: locale) }
        var sources: [String] = []
        if let input = flow.adapterInputWatts {
            sources.append("external power supplies \(spoken(input))")
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
        case .externalPower where flow.adapterInputWatts == nil: sentences.append("the power coming in is not available")
        case .externalPower: break
        case .battery: sentences.append("no external power is connected")
        case .unknown: sentences.append("the power source is unknown")
        }
        return sentences.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }.joined(separator: " ")
    }
}
