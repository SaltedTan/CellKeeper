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
        let many = unit.spoken(2, locale: english).replacingOccurrences(of: "2 ", with: "")
        #expect(many != one)
        #expect(spoken("\(1, unit: unit)") == "1 \(one)")
        #expect(spoken("\(-1, unit: unit)") == "-1 \(one)")
        #expect(spoken("\(1.0, unit: unit)") == "1 \(one)")
        #expect(spoken("\(0, unit: unit)") == "0 \(many)")
        #expect(spoken("\(1.5, unit: unit)") == "1.5 \(many)")
        #expect(spoken("\(-12, unit: unit)") == "-12 \(many)")
        // A locale's minus sign counts as one too.
        #expect(unit.words("−1") == "−1 \(one)")
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
        let reason = DecisionReason.temperatureHigh(celsius: 41.5, pauseAt: 40).description
        #expect(reason.contains("°C"))
        #expect(spoken("\(reason)") == reason.replacingOccurrences(of: "°C", with: " degrees Celsius"))
        #expect(spoken("Battery at 41.5°C (pause at 40°C); charging paused.") == "Battery at 41.5 degrees Celsius (pause at 40 degrees Celsius); charging paused.")
        #expect(spoken("Temperature pause threshold 70°C is outside 30–60°C.") == "Temperature pause threshold 70 degrees Celsius is outside 30–60 degrees Celsius.")
        #expect(spoken("Battery at 41,5°C.") == "Battery at 41,5 degrees Celsius.")
        #expect(spoken("Battery at 1°C, then -1 °C.") == "Battery at 1 degree Celsius, then -1 degree Celsius.")
        // Only after a number.
        #expect(spoken("°C") == nil)
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
