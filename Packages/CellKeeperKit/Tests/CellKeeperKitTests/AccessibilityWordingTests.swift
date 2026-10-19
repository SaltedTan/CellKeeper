import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

@Suite("What VoiceOver reads")
struct AccessibilityWordingTests {
    /// Numbers follow the locale; these use a fixed one.
    let english = Locale(identifier: "en_US")

    @Test("A charge limit has its unit, and 100% says that there is no limit")
    func chargeLimit() {
        #expect(AccessibilityWording.chargeLimit(80) == "80%")
        #expect(AccessibilityWording.chargeLimit(20) == "20%")
        #expect(AccessibilityWording.chargeLimit(100) == "100% (no limit)")
        #expect(AccessibilityWording.percent(75) == "75%")
    }

    @Test("Temperatures are in degrees Celsius, as on screen")
    func celsius() {
        #expect(AccessibilityWording.celsius(40, locale: english) == "40 degrees Celsius")
        #expect(AccessibilityWording.celsius(35.5, locale: english) == "35.5 degrees Celsius")
    }

    @Test("Battery readings name their units in words")
    func readings() {
        #expect(AccessibilityWording.volts(fromMillivolts: 12_427, locale: english) == "12.43 volts")
        #expect(AccessibilityWording.milliamps(312, locale: english) == "312 milliamps")
        #expect(AccessibilityWording.milliamps(-1_845, locale: english) == "-1,845 milliamps")
        #expect(AccessibilityWording.milliamps(1, locale: english) == "1 milliamp")
        #expect(AccessibilityWording.watts(70, locale: english) == "70 watts")
    }

    @Test("Numbers follow the locale's format")
    func localeNumbers() {
        let german = Locale(identifier: "de_DE")
        #expect(AccessibilityWording.volts(fromMillivolts: 12_427, locale: german) == "12,43 volts")
        #expect(AccessibilityWording.celsius(35.5, locale: german) == "35,5 degrees Celsius")
    }

    @Test("The capacity names its unit once and keeps the ratio")
    func capacity() {
        #expect(AccessibilityWording.capacity(fullChargeMilliampHours: 6131, designMilliampHours: 6249, percentOfDesign: 98.1, locale: english) == "6,131 of 6,249 milliamp-hours (98%)")
        #expect(AccessibilityWording.capacity(fullChargeMilliampHours: 6131, designMilliampHours: nil, percentOfDesign: nil, locale: english) == "6,131 milliamp-hours")
    }

    @Test("The menu names units with the same words as Settings › Diagnostics, singular for one")
    func sharedUnitWords() {
        #expect(AccessibilityWording.milliamps(-845, locale: english) == QuantityUnit.milliamps.spoken(-845, locale: english))
        #expect(AccessibilityWording.watts(1, locale: english) == "1 watt")
        #expect(AccessibilityWording.watts(70, locale: english) == QuantityUnit.watts.spoken(70, locale: english))
        #expect(AccessibilityWording.celsius(1, locale: english) == "1 degree Celsius")
        #expect(AccessibilityWording.celsius(40, locale: english) == QuantityUnit.degreesCelsius.spoken(40, locale: english))
        #expect(AccessibilityWording.capacity(fullChargeMilliampHours: 1, designMilliampHours: nil, percentOfDesign: nil, locale: english) == "1 milliamp-hour")
    }

    @Test("A decimal is singular when it is one as shown, rounded to the decimals shown")
    func shownDecimals() {
        #expect(AccessibilityWording.volts(fromMillivolts: 1000, locale: english) == "1.00 volt")
        #expect(AccessibilityWording.volts(fromMillivolts: -1000, locale: english) == "-1.00 volt")
        #expect(AccessibilityWording.volts(fromMillivolts: 1004, locale: english) == "1.00 volt")
        #expect(AccessibilityWording.volts(fromMillivolts: 1006, locale: english) == "1.01 volts")
        #expect(AccessibilityWording.celsius(1.04, locale: english) == "1 degree Celsius")
        #expect(AccessibilityWording.celsius(1.06, locale: english) == "1.1 degrees Celsius")
        #expect(AccessibilityWording.celsius(0.96, locale: english) == "1 degree Celsius")
        #expect(AccessibilityWording.celsius(0.94, locale: english) == "0.9 degrees Celsius")
        // Halfway, the formatter rounds to even, and so does the choice.
        #expect(AccessibilityWording.celsius(1.05, locale: english) == "1 degree Celsius")
        #expect(AccessibilityWording.celsius(1.15, locale: english) == "1.2 degrees Celsius")
    }

    @Test("Whole numbers stay exact and never trap")
    func exactWholeNumbers() {
        #expect(AccessibilityWording.milliamps(9_007_199_254_740_993, locale: english) == "9,007,199,254,740,993 milliamps")
        #expect(AccessibilityWording.milliamps(Int.min, locale: english) == "-9,223,372,036,854,775,808 milliamps")
        #expect(AccessibilityWording.watts(Int.max, locale: english) == "9,223,372,036,854,775,807 watts")
        #expect(AccessibilityWording.hours(Int.min, locale: english) == "-9,223,372,036,854,775,808 hours")
        #expect(AccessibilityWording.capacity(fullChargeMilliampHours: 9_007_199_254_740_993, designMilliampHours: 9_007_199_254_740_995, percentOfDesign: 100, locale: english) == "9,007,199,254,740,993 of 9,007,199,254,740,995 milliamp-hours (100%)")
    }

    @Test("Singular or plural follows the number, in any locale's digits and signs", arguments: ["en_US", "de_DE", "ar_EG", "fa_IR", "he_IL"])
    func localizedNumbers(_ identifier: String) {
        let locale = Locale(identifier: identifier)
        func shown(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
        func shown(_ value: Double, _ digits: ClosedRange<Int>) -> String { value.formatted(.number.precision(.fractionLength(digits)).locale(locale)) }
        #expect(AccessibilityWording.milliamps(1, locale: locale) == "\(shown(1)) milliamp")
        #expect(AccessibilityWording.milliamps(-1, locale: locale) == "\(shown(-1)) milliamp")
        #expect(AccessibilityWording.milliamps(-845, locale: locale) == "\(shown(-845)) milliamps")
        #expect(AccessibilityWording.watts(1, locale: locale) == "\(shown(1)) watt")
        #expect(AccessibilityWording.hours(1, locale: locale) == "\(shown(1)) hour")
        #expect(AccessibilityWording.capacity(fullChargeMilliampHours: 1, designMilliampHours: nil, percentOfDesign: nil, locale: locale) == "\(shown(1)) milliamp-hour")
        #expect(AccessibilityWording.celsius(1, locale: locale) == "\(shown(1, 0...1)) degree Celsius")
        #expect(AccessibilityWording.celsius(1.04, locale: locale) == "\(shown(1.04, 0...1)) degree Celsius")
        #expect(AccessibilityWording.celsius(35.5, locale: locale) == "\(shown(35.5, 0...1)) degrees Celsius")
        #expect(AccessibilityWording.volts(fromMillivolts: -1000, locale: locale) == "\(shown(-1.0, 2...2)) volt")
        #expect(AccessibilityWording.volts(fromMillivolts: 12_427, locale: locale) == "\(shown(12.427, 2...2)) volts")
        // Not vacuous: these locales write their own digits, or a mark
        // before the minus sign.
        switch identifier {
        case "ar_EG": #expect(shown(1) == "١")
        case "fa_IR": #expect(shown(1) == "۱" && shown(-1).unicodeScalars.first == "\u{200E}")
        case "he_IL": #expect(shown(-1) == "\u{200E}-1")
        default: break
        }
    }

    @Test("Hours are counted in words")
    func hours() {
        #expect(AccessibilityWording.hours(1, locale: english) == "1 hour")
        #expect(AccessibilityWording.hours(12, locale: english) == "12 hours")
    }

    @Test("A refused settings change made in the UI is announced, every time, even with the same text")
    func refusedUIChange() {
        let refused = SettingsChangeResult.refused("The resume threshold must be below the limit.")
        let first = SettingsReconciliation.banner(after: refused, source: .ui)
        #expect(first.announcement == "The resume threshold must be below the limit.")
        // The banner already shows it; the same refusal again is heard again.
        let banner = first.applied(to: nil)
        let second = SettingsReconciliation.banner(after: refused, source: .ui)
        #expect(second.applied(to: banner) == banner)
        #expect(second.announcement == "The resume threshold must be below the limit.")
        #expect(SettingsReconciliation.banner(after: .refused(SettingsChangeResult.saveFailed), source: .ui).announcement == SettingsChangeResult.saveFailed)
    }

    @Test("A saved or unchanged change, which clears or keeps the banner, is not announced")
    func keptOrCleared() {
        #expect(SettingsReconciliation.banner(after: .saved(previous: .default), source: .ui).announcement == nil)
        #expect(SettingsReconciliation.banner(after: .unchanged, source: .ui).announcement == nil)
        #expect(BannerChange.keep.announcement == nil)
        #expect(BannerChange.clear.announcement == nil)
    }

    @Test("Changes from Shortcuts actions and CellKeeper's own are not announced", arguments: [SettingsChangeSource.shortcuts, .adoption])
    func otherSources(_ source: SettingsChangeSource) {
        #expect(SettingsReconciliation.banner(after: .refused("Refused"), source: source).announcement == nil)
        var sent = ChargingSettings.default
        sent.isManagementEnabled = true
        let keptOff = SettingsReconciliation.outcome(sent: sent, current: sent, controller: .applied(isManagementEnabled: false, managementRefusal: "Kept off."), source: source)
        #expect(keptOff.banner.announcement == nil)
        let rejected = SettingsReconciliation.outcome(sent: sent, current: sent, controller: .rejected("Invalid."), source: source)
        #expect(rejected.banner.announcement == nil)
    }

    @Test("After the controller applied a change made in the UI, a kept-off Manage charging is announced; an ordinary apply is not")
    func reconciliation() {
        var sent = ChargingSettings.default
        sent.isManagementEnabled = true
        let keptOff = SettingsReconciliation.outcome(sent: sent, current: sent, controller: .applied(isManagementEnabled: false, managementRefusal: "Kept off."), source: .ui)
        #expect(keptOff.banner.announcement == "Kept off.")
        let applied = SettingsReconciliation.outcome(sent: sent, current: sent, controller: .applied(isManagementEnabled: true, managementRefusal: nil), source: .ui)
        #expect(applied.banner.announcement == nil)
    }

    @Test("A scheduled or weekly full charge that was not set is announced every time it is not")
    func scheduleRefusals() {
        let refusal = BannerChange.show("The start must be in the future.")
        #expect(refusal.announcement == "The start must be in the future.")
    }
}

@Suite("Warning and error text colours")
struct TextToneTests {
    @Test("Contrast follows WCAG 2: black on white is 21:1, a colour on itself 1:1")
    func contrastFormula() {
        let white = SRGBColor(grey: 255)
        let black = SRGBColor(grey: 0)
        #expect(abs(white.contrastRatio(with: black) - 21) < 0.001)
        #expect(abs(black.contrastRatio(with: white) - 21) < 0.001)
        #expect(abs(white.contrastRatio(with: white) - 1) < 0.001)
        // The system's light-mode orange, which these tones replace for
        // text: below 4.5:1 against white.
        #expect(SRGBColor(red: 255, green: 141, blue: 40).contrastRatio(with: white) < 2.5)
        // A mid grey, a known value: #777777 on white is about 4.48:1.
        #expect(abs(SRGBColor(grey: 119).contrastRatio(with: white) - 4.48) < 0.01)
    }

    @Test("Every tone reaches its contrast on every background of its appearance", arguments: TextTone.allCases)
    func tones(_ tone: TextTone) {
        for isDark in [false, true] {
            for isIncreasedContrast in [false, true] {
                let color = tone.color(isDark: isDark, isIncreasedContrast: isIncreasedContrast)
                let minimum = TextTone.minimumContrast(isIncreasedContrast: isIncreasedContrast)
                for background in TextTone.backgrounds(isDark: isDark, isIncreasedContrast: isIncreasedContrast) {
                    let ratio = color.contrastRatio(with: background)
                    #expect(ratio >= minimum, "\(tone) \(color) on \(background): \(ratio)")
                }
            }
        }
    }

    @Test("Increase Contrast never lowers a tone's contrast", arguments: TextTone.allCases)
    func increasedContrast(_ tone: TextTone) {
        for isDark in [false, true] {
            let background = TextTone.backgrounds(isDark: isDark, isIncreasedContrast: false)[0]
            let standard = tone.color(isDark: isDark, isIncreasedContrast: false).contrastRatio(with: background)
            let increased = tone.color(isDark: isDark, isIncreasedContrast: true).contrastRatio(with: background)
            #expect(increased > standard)
        }
    }

    @Test("Warnings and errors stay apart in every appearance")
    func distinct() {
        for isDark in [false, true] {
            for isIncreasedContrast in [false, true] {
                #expect(TextTone.warning.color(isDark: isDark, isIncreasedContrast: isIncreasedContrast) != TextTone.critical.color(isDark: isDark, isIncreasedContrast: isIncreasedContrast))
            }
        }
    }
}
