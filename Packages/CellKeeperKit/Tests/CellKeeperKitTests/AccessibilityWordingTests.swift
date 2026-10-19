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

    @Test("Hours are counted in words")
    func hours() {
        #expect(AccessibilityWording.hours(1, locale: english) == "1 hour")
        #expect(AccessibilityWording.hours(12, locale: english) == "12 hours")
    }

    @Test("Only a new problem with the user's own change is announced")
    func announcements() {
        #expect(AccessibilityWording.announcement(forProblem: "Refused", replacing: nil) == "Refused")
        #expect(AccessibilityWording.announcement(forProblem: "Other", replacing: "Refused") == "Other")
        #expect(AccessibilityWording.announcement(forProblem: "Refused", replacing: "Refused") == nil)
        #expect(AccessibilityWording.announcement(forProblem: nil, replacing: "Refused") == nil)
        #expect(AccessibilityWording.announcement(forProblem: nil, replacing: nil) == nil)
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
