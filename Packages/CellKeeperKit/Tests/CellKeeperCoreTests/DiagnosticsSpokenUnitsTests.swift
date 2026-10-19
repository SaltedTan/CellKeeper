import CellKeeperCore
import Foundation
import Testing

/// What VoiceOver reads for the values of Settings › Diagnostics: units in
/// words where the report and the view write symbols, which speech reads
/// letter by letter. The report's text is unchanged (the golden tests).
@Suite("Diagnostics values, spoken")
struct DiagnosticsSpokenUnitsTests {
    /// Numbers follow the locale; these use a fixed one.
    let english = Locale(identifier: "en_US")
    let environment = DiagnosticsFixture.environment

    private func spoken(_ value: DiagnosticsValue, locale: Locale? = nil) -> String? {
        value.spokenText(formattingTime: DiagnosticsSectionsTests.offset, locale: locale ?? english)
    }

    private func plain(_ value: DiagnosticsValue) -> String {
        value.plainText(formattingTime: DiagnosticsSectionsTests.offset)
    }

    /// True if `text` writes a unit's symbol after a number ("12427 mV",
    /// "41.5°C").
    private static func writesSymbol(_ text: String) throws -> Bool {
        for unit in QuantityUnit.allCases {
            let pattern = try Regex(#"\d\s?"# + NSRegularExpression.escapedPattern(for: unit.symbol) + #"(?!\p{L})"#)
            if text.contains(pattern) { return true }
        }
        return false
    }

    @Test("Every unit is written with its symbol, as before, and read in words", arguments: QuantityUnit.allCases)
    func unit(_ unit: QuantityUnit) {
        let value: DiagnosticsValue = "\(6131, unit: unit)"
        #expect(value.reportText == "6131 \(unit.symbol)")
        #expect(plain(value) == "6131 \(unit.symbol)")
        let words = switch unit {
        case .volts: "6,131 volts"
        case .millivolts: "6,131 millivolts"
        case .milliamps: "6,131 milliamps"
        case .milliampHours: "6,131 milliamp-hours"
        case .watts: "6,131 watts"
        case .degreesCelsius: "6,131 degrees Celsius"
        }
        #expect(spoken(value) == words)
    }

    @Test("One of a unit is singular, also negative; zero, fractions and more are plural", arguments: QuantityUnit.allCases)
    func singularAndPlural(_ unit: QuantityUnit) {
        let one = switch unit {
        case .volts: "volt"
        case .millivolts: "millivolt"
        case .milliamps: "milliamp"
        case .milliampHours: "milliamp-hour"
        case .watts: "watt"
        case .degreesCelsius: "degree Celsius"
        }
        let many = unit.name(singular: false)
        #expect(unit.name(singular: true) == one)
        #expect(many != one)
        #expect(spoken("\(1, unit: unit)") == "1 \(one)")
        #expect(spoken("\(-1, unit: unit)") == "-1 \(one)")
        #expect(spoken("\(0, unit: unit)") == "0 \(many)")
        #expect(spoken("\(-12, unit: unit)") == "-12 \(many)")
        #expect(spoken("\(1.0, unit: unit)") == "1 \(one)")
        #expect(spoken("\(-1.0, unit: unit)") == "-1 \(one)")
        #expect(spoken("\(1.5, unit: unit)") == "1.5 \(many)")
        // Decided by the value as shown, with at most six decimals.
        #expect(spoken("\(1.000_000_1, unit: unit)") == "1 \(one)")
        #expect(spoken("\(1.000_001, unit: unit)") == "1.000001 \(many)")
    }

    @Test("Whole numbers stay exact, beyond 2^53 and at the ends of Int")
    func exactWholeNumbers() {
        let large: DiagnosticsValue = "\(9_007_199_254_740_993, unit: .milliampHours)"
        #expect(large.reportText == "9007199254740993 mAh")
        #expect(spoken(large) == "9,007,199,254,740,993 milliamp-hours")
        #expect(spoken("\(Int.max, unit: .milliampHours)") == "9,223,372,036,854,775,807 milliamp-hours")
        let smallest: DiagnosticsValue = "\(Int.min, unit: .milliamps)"
        #expect(smallest.reportText == "-9223372036854775808 mA")
        #expect(spoken(smallest) == "-9,223,372,036,854,775,808 milliamps")
    }

    /// Locales whose numbers are written with other digits or with a
    /// directional mark before the minus sign.
    static let locales = ["en_US", "de_DE", "ar_EG", "fa_IR", "he_IL"]

    @Test("Singular or plural follows the number, in any locale's digits and signs", arguments: DiagnosticsSpokenUnitsTests.locales)
    func localizedNumbers(_ identifier: String) {
        let locale = Locale(identifier: identifier)
        func shown(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
        func shown(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...6)).locale(locale)) }
        #expect(spoken("\(1, unit: .milliamps)", locale: locale) == "\(shown(1)) milliamp")
        #expect(spoken("\(-1, unit: .milliamps)", locale: locale) == "\(shown(-1)) milliamp")
        #expect(spoken("\(2, unit: .milliamps)", locale: locale) == "\(shown(2)) milliamps")
        #expect(spoken("\(-845, unit: .milliamps)", locale: locale) == "\(shown(-845)) milliamps")
        #expect(spoken("\(1.0, unit: .degreesCelsius)", locale: locale) == "\(shown(1.0)) degree Celsius")
        #expect(spoken("\(-1.0, unit: .degreesCelsius)", locale: locale) == "\(shown(-1.0)) degree Celsius")
        #expect(spoken("\(1.5, unit: .degreesCelsius)", locale: locale) == "\(shown(1.5)) degrees Celsius")
        // Not vacuous: these locales write their own digits, or a mark
        // before the minus sign.
        switch identifier {
        case "ar_EG": #expect(shown(1) == "١")
        case "fa_IR": #expect(shown(1) == "۱" && shown(-1).unicodeScalars.first == "\u{200E}")
        case "he_IL": #expect(shown(-1) == "\u{200E}-1")
        default: break
        }
    }

    @Test("Whether a decimal is one agrees with the number the formatter shows, also halfway", arguments: 0...6)
    func isOneAsShown(_ fractionDigits: Int) throws {
        let posix = Locale(identifier: "en_US_POSIX")
        let step = 1 / pow(10, Double(fractionDigits))
        var values: [Double] = [.infinity, -.infinity, .nan, 0, 2, -2]
        for k in -200...200 {
            // Around 1 and -1, at and between the halfway points of the
            // last decimal shown.
            for offset in [Double(k) * step / 10, (Double(k) + 0.5) * step] {
                values.append(1 + offset)
                values.append(-1 - offset)
            }
        }
        var ones = 0
        for value in values {
            let shown = value.formatted(.number.precision(.fractionLength(0...fractionDigits)).grouping(.never).locale(posix))
            let isShownOne = Double(shown).map { abs($0) == 1 } ?? false
            #expect(QuantityUnit.isOne(value, roundedTo: fractionDigits) == isShownOne, "\(value) shown as \(shown)")
            ones += isShownOne ? 1 : 0
        }
        #expect(ones > 4)
    }

    @Test("A decimal is read with as many decimals as the report writes in the current locale")
    func decimalsAsWritten() {
        for value in [31.25, 41.5, 1.123_456_789, 1.000_000_1, 1_234_567.891, 0.1, -3.5] {
            let written = value.formatted()
            let words = spoken("\(value, unit: .degreesCelsius)", locale: .current)
            #expect(words?.hasPrefix("\(written) degree") == true, "\(value): \(words ?? "nil")")
        }
    }

    @Test("A discharging current is read with its minus sign, as the menu reads it")
    func negativeCurrent() {
        let value: DiagnosticsValue = "\(-845, unit: .milliamps)"
        #expect(value.reportText == "-845 mA")
        #expect(spoken(value) == "-845 milliamps")
        #expect(spoken("\(-1_845, unit: .milliamps)") == "-1,845 milliamps")
    }

    @Test("Spoken numbers follow the locale; the report's whole numbers do not")
    func locale() {
        let german = Locale(identifier: "de_DE")
        let voltage: DiagnosticsValue = "\(12_427, unit: .millivolts)"
        #expect(voltage.reportText == "12427 mV")
        #expect(spoken(voltage, locale: german) == "12.427 millivolts")
        #expect(spoken("\(31.25, unit: .degreesCelsius)", locale: german) == "31,25 degrees Celsius")
    }

    @Test("Temperatures are written in the current locale's format, as the report always wrote them")
    func temperatureWritten() {
        let value: DiagnosticsValue = "\(31.25, unit: .degreesCelsius)"
        #expect(value.reportText == "\((31.25).formatted()) °C")
        #expect(spoken(value) == "31.25 degrees Celsius")
    }

    @Test("A value that names no unit has no spoken form, so the view leaves it as it is")
    func noUnit() {
        #expect(spoken("on") == nil)
        #expect(spoken("81%") == nil)
        #expect(spoken("\(54)") == nil)
        #expect(spoken("\("holding at the limit", identifier: "holding")") == nil)
        #expect(spoken("\(time: referenceDate)") == nil)
        // Letters that are not a unit after a number.
        #expect(spoken("Version 27.0.1 (Build 26A434)") == nil)
    }

    @Test("The rest of a value is read as the view shows it: words without identifiers, moments as the caller formats them")
    func restAsShown() {
        let value: DiagnosticsValue = "\("a charging pause", identifier: "inhibitCharging"), \(312, unit: .milliamps) at \(time: referenceDate.addingTimeInterval(60))"
        #expect(spoken(value) == "a charging pause, 312 milliamps at <60s>")
    }

    @Test("Temperatures in the policy's and the settings check's sentences are read in words")
    func temperaturesInSentences() {
        // The policy writes its numbers in the current locale.
        let reason = DecisionReason.temperatureHigh(celsius: 41.5, pauseAt: 40).description
        #expect(reason.contains("°C"))
        #expect(spoken("\(reason)", locale: .current) == reason.replacingOccurrences(of: "°C", with: " degrees Celsius"))
        #expect(spoken("Battery at 41.5°C (pause at 40°C); charging paused.") == "Battery at 41.5 degrees Celsius (pause at 40 degrees Celsius); charging paused.")
        #expect(spoken("Temperature pause threshold 70°C is outside 30–60°C.") == "Temperature pause threshold 70 degrees Celsius is outside 30–60 degrees Celsius.")
        #expect(spoken("Battery at 41,5°C.") == "Battery at 41,5 degrees Celsius.")
        #expect(spoken("Battery at 1°C, then -1 °C.") == "Battery at 1 degree Celsius, then -1 degree Celsius.")
        // Only after a number.
        #expect(spoken("°C") == nil)
        // A number and its "°C" in different parts of a value.
        #expect(spoken("Battery at \("1,000")°C.") == "Battery at 1,000 degrees Celsius.")
    }

    @Test("A temperature in a sentence is singular when its number, as shown, is one, in any locale's digits")
    func sentenceNumbers() {
        #expect(spoken("Battery at 1.0°C.") == "Battery at 1.0 degree Celsius.")
        #expect(spoken("Battery at 1.1°C.") == "Battery at 1.1 degrees Celsius.")
        #expect(spoken("Battery at 11°C.") == "Battery at 11 degrees Celsius.")
        #expect(spoken("Battery at 10°C.") == "Battery at 10 degrees Celsius.")
        #expect(spoken("Battery at 0.1°C.") == "Battery at 0.1 degrees Celsius.")
        // Digits after a separator that is not the locale's are not one.
        #expect(spoken("Battery at 01°C.") == "Battery at 01 degrees Celsius.")
        #expect(spoken("Battery at 1 001°C.") == "Battery at 1 001 degrees Celsius.")
        // Arabic-Indic and Persian digits, the Arabic decimal separator, and
        // a directional mark before the minus sign.
        let arabic = Locale(identifier: "ar_EG")
        #expect(spoken("Battery at ١°C.", locale: arabic) == "Battery at ١ degree Celsius.")
        #expect(spoken("Battery at ١٫٠°C.", locale: arabic) == "Battery at ١٫٠ degree Celsius.")
        #expect(spoken("Battery at ٤١٫٥°C.", locale: arabic) == "Battery at ٤١٫٥ degrees Celsius.")
        #expect(spoken("Battery at \u{200E}−۱°C.", locale: Locale(identifier: "fa_IR")) == "Battery at \u{200E}−۱ degree Celsius.")
        #expect(spoken("Battery at \u{200E}-1°C.", locale: Locale(identifier: "he_IL")) == "Battery at \u{200E}-1 degree Celsius.")
        // The policy's own sentence, in the current locale's format.
        let reason = DecisionReason.temperatureHigh(celsius: 1, pauseAt: 1).description
        #expect(spoken("\(reason)", locale: .current) == reason.replacingOccurrences(of: "°C", with: " degree Celsius"))
    }

    @Test("A grouped temperature in a sentence is read whole, with the locale's separators", arguments: ["en_US", "de_DE", "fr_FR", "ar_EG"])
    func groupedSentenceNumbers(_ identifier: String) {
        let locale = Locale(identifier: identifier)
        func sentence(_ value: Double, _ digits: ClosedRange<Int>) -> DiagnosticsValue {
            "Battery at \(value.formatted(.number.precision(.fractionLength(digits)).locale(locale)))°C."
        }
        func read(_ value: Double, _ digits: ClosedRange<Int>, _ name: String) -> String {
            "Battery at \(value.formatted(.number.precision(.fractionLength(digits)).locale(locale))) \(name)."
        }
        for (value, digits) in [(1_000.0, 0...0), (1_001.0, 0...0), (1_000.0, 1...1), (1_001.5, 1...1), (-1_000.0, 0...0), (10_001.0, 0...0)] {
            #expect(spoken(sentence(value, digits), locale: locale) == read(value, digits, "degrees Celsius"), "\(value)")
        }
        for (value, digits) in [(1.0, 0...0), (1.0, 1...1), (-1.0, 1...1), (1.04, 0...1)] {
            #expect(spoken(sentence(value, digits), locale: locale) == read(value, digits, "degree Celsius"), "\(value)")
        }
        // Not vacuous: each locale groups thousands with its own separator.
        let grouped = (1_000).formatted(.number.locale(locale))
        switch identifier {
        case "en_US": #expect(grouped == "1,000")
        case "de_DE": #expect(grouped == "1.000")
        case "fr_FR": #expect(grouped == "1\u{202F}000")
        case "ar_EG": #expect(grouped == "١٬٠٠٠")
        default: break
        }
    }

    @Test("A space-like grouping separator is read in any of its forms")
    func spaceGrouping() {
        let french = Locale(identifier: "fr_FR")
        for space in [" ", "\u{00A0}", "\u{202F}"] {
            #expect(spoken("Battery at 1\(space)001°C.", locale: french) == "Battery at 1\(space)001 degrees Celsius.")
            #expect(spoken("Battery at 1\(space)000,0°C.", locale: french) == "Battery at 1\(space)000,0 degrees Celsius.")
        }
        #expect(spoken("Battery at 1,0°C.", locale: french) == "Battery at 1,0 degree Celsius.")
        // English groups with a comma: "1,000" is a thousand.
        #expect(spoken("Battery at 1,000°C and 1°C.") == "Battery at 1,000 degrees Celsius and 1 degree Celsius.")
    }

    @Test("The Simulated fixture's rows with units are read in words; the others have no spoken form")
    func simulatedRows() async {
        let status = await DiagnosticsFixture.simulated()
        let sections = DiagnosticsReport.sections(status: status, environment: environment)
        var spokenRows: [String: String] = [:]
        for row in sections.flatMap(\.rows) {
            if let words = spoken(row.value) { spokenRows[row.label] = words }
        }
        #expect(spokenRows == [
            "Temperature protection": "on (pause 40 degrees Celsius, resume 35 degrees Celsius)",
            "Temperature": "31 degrees Celsius",
            "Voltage": "12,427 millivolts",
            "Current": "-12 milliamps",
            "Adapter": "70 watts",
            "Full-charge capacity": "6,131 milliamp-hours",
            "Design capacity": "6,249 milliamp-hours",
        ])
    }

    @Test("A temperature pause's reason is read with its temperatures in words")
    func temperaturePauseReason() async throws {
        let status = await DiagnosticsFixture.temperaturePause()
        let sections = DiagnosticsReport.sections(status: status, environment: environment)
        let reason = try #require(sections.first { $0.title == "Decision" }?.rows.first { $0.label == "Reason" }?.value)
        #expect(plain(reason).contains("°C"))
        let words = try #require(spoken(reason))
        #expect(words.contains("degrees Celsius"))
        #expect(try !Self.writesSymbol(words))
    }

    @Test("In every fixture, every row whose value writes a unit's symbol has a spoken form without one")
    func everyUnitIsSpoken() async throws {
        let fixtures = try await DiagnosticsFixture.all()
        var rowsWithUnits = 0
        var rowsWithoutUnits = 0
        for (name, status) in fixtures {
            for section in DiagnosticsReport.sections(status: status, environment: environment) {
                for row in section.rows {
                    let place = "\(name), \(section.title ?? "top"): \(row.label)"
                    let shown = plain(row.value)
                    let words = spoken(row.value)
                    if try Self.writesSymbol(shown) {
                        rowsWithUnits += 1
                        #expect(words != nil, "\(place): \(shown)")
                    } else {
                        rowsWithoutUnits += 1
                    }
                    if let words {
                        #expect(try !Self.writesSymbol(words), "\(place): \(words)")
                    }
                }
            }
        }
        // Not vacuous: every fixture shows the temperature protection's
        // thresholds, and most also battery readings.
        #expect(rowsWithUnits > fixtures.count)
        #expect(rowsWithoutUnits > rowsWithUnits)
    }
}
