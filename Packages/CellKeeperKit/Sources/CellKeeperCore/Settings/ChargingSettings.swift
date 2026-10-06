import Foundation

/// Optional protection that pauses charging while the battery is hot.
///
/// This is in addition to, never instead of, the protections implemented by
/// the battery's own management system and the Mac's firmware.
public struct TemperatureProtection: Sendable, Equatable, Codable {
    public var isEnabled: Bool
    /// Charging pauses when the battery temperature reaches this value.
    public var pauseAtCelsius: Double
    /// After a pause, charging may resume once the temperature has fallen to
    /// this value or below.
    public var resumeAtCelsius: Double

    public init(isEnabled: Bool, pauseAtCelsius: Double, resumeAtCelsius: Double) {
        self.isEnabled = isEnabled
        self.pauseAtCelsius = pauseAtCelsius
        self.resumeAtCelsius = resumeAtCelsius
    }

    public static let `default` = TemperatureProtection(isEnabled: true, pauseAtCelsius: 40, resumeAtCelsius: 35)
}

/// User-configurable charging policy settings.
///
/// Values are validated by ``validationIssues``; invalid settings are never
/// persisted or applied, and the policy fails safe if handed invalid values.
public struct ChargingSettings: Sendable, Equatable, Codable {
    /// When false, CellKeeper does not manage charging and asks the backend
    /// for macOS default behaviour.
    public var isManagementEnabled: Bool
    /// Upper charge limit in percent. 100 means "no limit".
    public var chargeLimit: Int
    /// When the charge falls to this percentage (or below) after reaching the
    /// limit, charging resumes. The gap to ``chargeLimit`` is the hysteresis.
    public var resumeThreshold: Int
    public var temperatureProtection: TemperatureProtection

    public init(
        isManagementEnabled: Bool = true,
        chargeLimit: Int = 80,
        resumeThreshold: Int = 75,
        temperatureProtection: TemperatureProtection = .default
    ) {
        self.isManagementEnabled = isManagementEnabled
        self.chargeLimit = chargeLimit
        self.resumeThreshold = resumeThreshold
        self.temperatureProtection = temperatureProtection
    }

    public static let `default` = ChargingSettings()

    // MARK: - Limits

    /// Allowed charge-limit values, in percent.
    public static let chargeLimitRange = 20...100
    /// Lowest allowed resume threshold, in percent: five points above the
    /// policy's safety floor.
    public static let minimumResumeThreshold = 15
    /// Minimum gap between resume threshold and charge limit, in percentage
    /// points. Prevents rapid toggling of charging around a single value.
    public static let minimumHysteresis = 3
    /// Maximum gap between resume threshold and charge limit, so that a
    /// plugged-in Mac does not sit far below its limit without charging.
    public static let maximumHysteresis = 20
    /// Allowed temperature-protection pause thresholds, in degrees Celsius.
    public static let temperaturePauseRange: ClosedRange<Double> = 35...45
    /// Lowest allowed temperature-protection resume threshold. Kept above
    /// typical room temperature so a paused battery can always cool enough to
    /// resume.
    public static let minimumTemperatureResume: Double = 30
    /// Minimum gap between temperature pause and resume thresholds.
    public static let minimumTemperatureHysteresis: Double = 3

    /// The valid resume-threshold range for a given charge limit.
    public static func resumeThresholdRange(forChargeLimit limit: Int) -> ClosedRange<Int> {
        let clampedLimit = min(max(limit, chargeLimitRange.lowerBound), chargeLimitRange.upperBound)
        let lower = max(minimumResumeThreshold, clampedLimit - maximumHysteresis)
        let upper = max(lower, clampedLimit - minimumHysteresis)
        return lower...upper
    }

    // MARK: - Validation

    /// All problems with these settings. Empty means valid.
    public var validationIssues: [SettingsIssue] {
        var issues: [SettingsIssue] = []
        let isChargeLimitInRange = Self.chargeLimitRange.contains(chargeLimit)
        if !isChargeLimitInRange {
            issues.append(.chargeLimitOutOfRange(chargeLimit, allowed: Self.chargeLimitRange))
        }
        // The gap is only checked once both values are in range, so the
        // subtraction cannot overflow on hostile input.
        if resumeThreshold < Self.minimumResumeThreshold || resumeThreshold > 100 {
            issues.append(.resumeThresholdOutOfRange(resumeThreshold, minimum: Self.minimumResumeThreshold))
        } else if isChargeLimitInRange, chargeLimit - resumeThreshold < Self.minimumHysteresis {
            issues.append(.hysteresisTooSmall(chargeLimit: chargeLimit, resumeThreshold: resumeThreshold, minimum: Self.minimumHysteresis))
        } else if isChargeLimitInRange, chargeLimit - resumeThreshold > Self.maximumHysteresis {
            issues.append(.hysteresisTooLarge(chargeLimit: chargeLimit, resumeThreshold: resumeThreshold, maximum: Self.maximumHysteresis))
        }

        let temperature = temperatureProtection
        if !temperature.pauseAtCelsius.isFinite || !temperature.resumeAtCelsius.isFinite {
            issues.append(.temperatureNotFinite)
        } else {
            if !Self.temperaturePauseRange.contains(temperature.pauseAtCelsius) {
                issues.append(.temperaturePauseOutOfRange(temperature.pauseAtCelsius, allowed: Self.temperaturePauseRange))
            }
            if temperature.resumeAtCelsius < Self.minimumTemperatureResume {
                issues.append(.temperatureResumeTooLow(temperature.resumeAtCelsius, minimum: Self.minimumTemperatureResume))
            } else if temperature.pauseAtCelsius - temperature.resumeAtCelsius < Self.minimumTemperatureHysteresis {
                issues.append(.temperatureHysteresisTooSmall(minimum: Self.minimumTemperatureHysteresis))
            }
        }
        return issues
    }

    public var isValid: Bool { validationIssues.isEmpty }

    /// Returns these settings if valid, otherwise throws the issues found.
    public func validated() throws -> ChargingSettings {
        let issues = validationIssues
        guard issues.isEmpty else { throw SettingsValidationError(issues: issues) }
        return self
    }

    /// Returns a copy with a new charge limit (clamped to the allowed range),
    /// adjusting the resume threshold only as far as needed to stay valid.
    /// Intended for UI controls; the result is still subject to validation.
    public func withChargeLimit(_ newLimit: Int) -> ChargingSettings {
        var copy = self
        copy.chargeLimit = min(max(newLimit, Self.chargeLimitRange.lowerBound), Self.chargeLimitRange.upperBound)
        let range = Self.resumeThresholdRange(forChargeLimit: copy.chargeLimit)
        copy.resumeThreshold = min(max(copy.resumeThreshold, range.lowerBound), range.upperBound)
        return copy
    }

    // MARK: - Codable

    // Decoding tolerates missing and unknown keys (falling back to defaults)
    // so that settings saved by other versions keep working. Decoded values
    // are validated by the caller, never trusted.
    private enum CodingKeys: String, CodingKey {
        case isManagementEnabled, chargeLimit, resumeThreshold, temperatureProtection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ChargingSettings.default
        isManagementEnabled = try container.decodeIfPresent(Bool.self, forKey: .isManagementEnabled) ?? defaults.isManagementEnabled
        chargeLimit = try container.decodeIfPresent(Int.self, forKey: .chargeLimit) ?? defaults.chargeLimit
        resumeThreshold = try container.decodeIfPresent(Int.self, forKey: .resumeThreshold) ?? defaults.resumeThreshold
        temperatureProtection = try container.decodeIfPresent(TemperatureProtection.self, forKey: .temperatureProtection) ?? defaults.temperatureProtection
    }
}

/// A single problem with a ``ChargingSettings`` value.
public enum SettingsIssue: Sendable, Equatable, CustomStringConvertible {
    case chargeLimitOutOfRange(Int, allowed: ClosedRange<Int>)
    case resumeThresholdOutOfRange(Int, minimum: Int)
    case hysteresisTooSmall(chargeLimit: Int, resumeThreshold: Int, minimum: Int)
    case hysteresisTooLarge(chargeLimit: Int, resumeThreshold: Int, maximum: Int)
    case temperatureNotFinite
    case temperaturePauseOutOfRange(Double, allowed: ClosedRange<Double>)
    case temperatureResumeTooLow(Double, minimum: Double)
    case temperatureHysteresisTooSmall(minimum: Double)

    public var description: String {
        switch self {
        case .chargeLimitOutOfRange(let value, let allowed):
            "Charge limit \(value)% is outside \(allowed.lowerBound)–\(allowed.upperBound)%."
        case .resumeThresholdOutOfRange(let value, let minimum):
            "Resume threshold \(value)% must be at least \(minimum)% and at most 100%."
        case .hysteresisTooSmall(let limit, let resume, let minimum):
            "Resume threshold \(resume)% must be at least \(minimum) points below the charge limit \(limit)%."
        case .hysteresisTooLarge(let limit, let resume, let maximum):
            "Resume threshold \(resume)% must be no more than \(maximum) points below the charge limit \(limit)%."
        case .temperatureNotFinite:
            "Temperature thresholds must be finite numbers."
        case .temperaturePauseOutOfRange(let value, let allowed):
            "Temperature pause threshold \(value.formatted())°C is outside \(allowed.lowerBound.formatted())–\(allowed.upperBound.formatted())°C."
        case .temperatureResumeTooLow(let value, let minimum):
            "Temperature resume threshold \(value.formatted())°C must be at least \(minimum.formatted())°C."
        case .temperatureHysteresisTooSmall(let minimum):
            "Temperature resume threshold must be at least \(minimum.formatted())°C below the pause threshold."
        }
    }
}

public struct SettingsValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public var issues: [SettingsIssue]

    public init(issues: [SettingsIssue]) {
        self.issues = issues
    }

    public var description: String {
        issues.map(\.description).joined(separator: " ")
    }
}
