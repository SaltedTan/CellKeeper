import Foundation

/// A unit CellKeeper writes after a number: as its symbol on screen and in
/// the diagnostics report ("12427 mV", "31 °C"), and in words for VoiceOver
/// ("12,427 millivolts", "31 degrees Celsius"), which reads symbols such as
/// "mV", "mA" and "mAh" letter by letter. Like the rest of the app's text,
/// the words are English; numbers follow the user's format.
public enum QuantityUnit: Sendable, Equatable, CaseIterable {
    case volts
    case millivolts
    case milliamps
    case milliampHours
    case watts
    case degreesCelsius

    /// The symbol written after the number and a space: "V", "mV", "mA",
    /// "mAh", "W", "°C".
    public var symbol: String {
        switch self {
        case .volts: "V"
        case .millivolts: "mV"
        case .milliamps: "mA"
        case .milliampHours: "mAh"
        case .watts: "W"
        case .degreesCelsius: "°C"
        }
    }

    /// `number`, as written, followed by the unit's name: singular when the
    /// number is 1 or -1 as written ("1 milliamp", "-1 milliamp"), plural
    /// otherwise ("0 milliamps", "1.5 degrees Celsius", "-845 milliamps").
    public func words(_ number: String) -> String {
        let magnitude = number.drop { $0 == "-" || $0 == "−" }
        return "\(number) \(magnitude == "1" ? singular : plural)"
    }

    /// `value` in `locale`'s number format, with the unit in words:
    /// "12,427 millivolts", "-12 milliamps", "31.25 degrees Celsius".
    public func spoken(_ value: Double, locale: Locale = .current) -> String {
        words(value.formatted(.number.locale(locale)))
    }

    private var singular: String {
        switch self {
        case .volts: "volt"
        case .millivolts: "millivolt"
        case .milliamps: "milliamp"
        case .milliampHours: "milliamp-hour"
        case .watts: "watt"
        case .degreesCelsius: "degree Celsius"
        }
    }

    private var plural: String {
        switch self {
        case .volts: "volts"
        case .millivolts: "millivolts"
        case .milliamps: "milliamps"
        case .milliampHours: "milliamp-hours"
        case .watts: "watts"
        case .degreesCelsius: "degrees Celsius"
        }
    }
}
