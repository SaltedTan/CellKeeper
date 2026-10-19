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

    /// A whole number in `locale`'s format, with the unit in words, singular
    /// for 1 and -1: "12,427 millivolts", "-845 milliamps", "1 milliamp".
    /// Exact for every `Int`.
    public func spoken(_ value: Int, locale: Locale = .current) -> String {
        "\(value.formatted(.number.locale(locale))) \(name(singular: value.magnitude == 1))"
    }

    /// `value` in `locale`'s format with `fractionDigits` decimals, with the
    /// unit in words: "31.25 degrees Celsius", "12.43 volts". Singular when
    /// the value as shown, rounded to the most decimals shown, is 1 or -1
    /// ("1 degree Celsius", "1.0 degree Celsius" for 1.04 with one decimal),
    /// whatever digits the locale writes it in.
    public func spoken(_ value: Double, fractionDigits: ClosedRange<Int>, locale: Locale = .current) -> String {
        let number = value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
        return "\(number) \(name(singular: Self.isOne(value, roundedTo: fractionDigits.upperBound)))"
    }

    /// The unit's name: "milliamp" or "milliamps".
    public func name(singular: Bool) -> String {
        singular ? self.singular : plural
    }

    /// Whether `value`, rounded to `fractionDigits` decimals as the number
    /// formatter rounds it, is 1 or -1: what decides between "1.0 degree"
    /// and "1.1 degrees". The formatter rounds the shortest decimal form of
    /// the double half to even ("1.05" to "1.0"), and so does this, from
    /// the value, not from the text the formatter writes.
    public static func isOne(_ value: Double, roundedTo fractionDigits: Int) -> Bool {
        guard value.isFinite, var decimal = Decimal(string: value.description, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, fractionDigits, .bankers)
        return rounded.magnitude == 1
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
