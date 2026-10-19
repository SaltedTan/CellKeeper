import CellKeeperCore
import Foundation

/// What VoiceOver reads for CellKeeper's controls and readings where the
/// text on screen does not say it well: a value with its unit, units in
/// words rather than abbreviations ("V", "mA" and "mAh" are read letter by
/// letter), and the announcements CellKeeper asks for. The units' words are
/// ``QuantityUnit``'s, as in Settings › Diagnostics. Like the rest of the
/// app's text, the words are English; numbers follow the user's format.
public enum AccessibilityWording {
    /// A charge limit, as the menu's slider and Settings' stepper read it:
    /// "80%", or "100% (no limit)".
    public static func chargeLimit(_ limit: Int) -> String {
        NativeLimitWording.limit(limit)
    }

    /// A percentage such as the resume threshold: "75%".
    public static func percent(_ value: Int) -> String {
        "\(value)%"
    }

    /// A temperature in degrees Celsius, as on screen: "40 degrees Celsius",
    /// "35.5 degrees Celsius".
    public static func celsius(_ value: Double, locale: Locale = .current) -> String {
        QuantityUnit.degreesCelsius.spoken(value, fractionDigits: 0...1, locale: locale)
    }

    /// A battery voltage from millivolts, with two decimals as on screen:
    /// "12.43 volts".
    public static func volts(fromMillivolts value: Int, locale: Locale = .current) -> String {
        QuantityUnit.volts.spoken(Double(value) / 1000, fractionDigits: 2...2, locale: locale)
    }

    /// A battery current: "312 milliamps", negative while discharging.
    public static func milliamps(_ value: Int, locale: Locale = .current) -> String {
        QuantityUnit.milliamps.spoken(value, locale: locale)
    }

    /// The adapter's power: "70 watts".
    public static func watts(_ value: Int, locale: Locale = .current) -> String {
        QuantityUnit.watts.spoken(value, locale: locale)
    }

    /// The full-charge capacity, and the design capacity with the ratio
    /// when both are known: "6,131 of 6,249 milliamp-hours (98%)".
    public static func capacity(fullChargeMilliampHours full: Int, designMilliampHours design: Int?, percentOfDesign ratio: Double?, locale: Locale = .current) -> String {
        guard let design, let ratio else {
            return QuantityUnit.milliampHours.spoken(full, locale: locale)
        }
        let percent = ratio.formatted(.number.precision(.fractionLength(0)).locale(locale))
        return "\(full.formatted(.number.locale(locale))) of \(QuantityUnit.milliampHours.spoken(design, locale: locale)) (\(percent)%)"
    }

    /// A duration in whole hours: "1 hour", "12 hours".
    public static func hours(_ value: Int, locale: Locale = .current) -> String {
        "\(value.formatted(.number.locale(locale))) \(value.magnitude == 1 ? "hour" : "hours")"
    }

    /// Announced when Copy Diagnostics has put the report on the clipboard.
    public static let diagnosticsCopied = "Diagnostics report copied."
}

extension BannerChange {
    /// What to announce for this step of an action the user just took (a
    /// settings change in the UI, Schedule Full Charge, saving the weekly
    /// full charge): the problem it shows, every time, even when the same
    /// text is already shown, so a refusal repeated is heard again. A step
    /// that keeps or clears the line announces nothing. Only the UI's
    /// settings changes show a banner (``SettingsReconciliation``), so a
    /// Shortcuts action's change and CellKeeper's own announce nothing.
    public var announcement: String? {
        if case .show(let text) = self { return text }
        return nil
    }
}
