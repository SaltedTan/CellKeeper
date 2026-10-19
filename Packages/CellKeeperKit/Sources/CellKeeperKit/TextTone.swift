import Foundation

/// A colour in sRGB, with components from 0 to 255, and its contrast with
/// another colour as WCAG 2 defines it.
public struct SRGBColor: Sendable, Equatable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A grey with all three components `level`.
    public init(grey level: Double) {
        self.init(red: level, green: level, blue: level)
    }

    /// WCAG 2's relative luminance, from 0 (black) to 1 (white).
    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            let value = component / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2's contrast ratio, from 1 to 21, whichever colour is lighter.
    public func contrastRatio(with other: SRGBColor) -> Double {
        let (lighter, darker) = (max(relativeLuminance, other.relativeLuminance), min(relativeLuminance, other.relativeLuminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    public var description: String {
        String(format: "sRGB(%.0f, %.0f, %.0f)", red, green, blue)
    }
}

/// The colours of warning and error text in the menu and Settings. The
/// system's orange and red are too light for small text on a light
/// background (2.3:1 and 3.6:1 against white), so light mode uses darker
/// shades with at least 4.5:1 against the light backgrounds CellKeeper's
/// text sits on; dark mode keeps the system colours where they reach 4.5:1
/// and lightens red. With Increase Contrast, macOS asks for the
/// high-contrast variants, with at least 7:1 (WCAG's enhanced level).
public enum TextTone: CaseIterable, Sendable {
    /// Something to be aware of: a setting not applied, macOS's limit
    /// holding, a low limit.
    case warning
    /// Something wrong: a fault, a restore that is not confirmed, a failed
    /// save.
    case critical

    /// The colour for an appearance.
    public func color(isDark: Bool, isIncreasedContrast: Bool) -> SRGBColor {
        switch (self, isDark, isIncreasedContrast) {
        case (.warning, false, false): SRGBColor(red: 160, green: 70, blue: 0)
        case (.warning, false, true): SRGBColor(red: 125, green: 50, blue: 0)
        // The system orange in dark mode.
        case (.warning, true, false): SRGBColor(red: 255, green: 146, blue: 48)
        case (.warning, true, true): SRGBColor(red: 255, green: 180, blue: 110)
        case (.critical, false, false): SRGBColor(red: 190, green: 0, blue: 20)
        case (.critical, false, true): SRGBColor(red: 150, green: 0, blue: 10)
        case (.critical, true, false): SRGBColor(red: 255, green: 140, blue: 135)
        case (.critical, true, true): SRGBColor(red: 255, green: 170, blue: 165)
        }
    }

    /// The backgrounds the tones are checked against: the window and form
    /// backgrounds, and a margin for the menu's material, which takes some
    /// colour from what is behind it.
    public static func backgrounds(isDark: Bool, isIncreasedContrast: Bool) -> [SRGBColor] {
        switch (isDark, isIncreasedContrast) {
        case (false, false): [SRGBColor(grey: 255), SRGBColor(grey: 245), SRGBColor(grey: 236), SRGBColor(grey: 224)]
        case (true, false): [SRGBColor(grey: 30), SRGBColor(grey: 40), SRGBColor(grey: 50), SRGBColor(grey: 60)]
        // Increase Contrast also reduces transparency: plain backgrounds.
        case (false, true): [SRGBColor(grey: 255), SRGBColor(grey: 236)]
        case (true, true): [SRGBColor(grey: 30), SRGBColor(grey: 45)]
        }
    }

    /// The contrast the tones reach on every one of those backgrounds:
    /// WCAG's 4.5:1 for small text, 7:1 with Increase Contrast.
    public static func minimumContrast(isIncreasedContrast: Bool) -> Double {
        isIncreasedContrast ? 7 : 4.5
    }
}
