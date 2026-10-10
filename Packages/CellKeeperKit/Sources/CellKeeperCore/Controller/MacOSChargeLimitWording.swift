import Foundation

/// Whether a restriction CellKeeper set may still be in effect, as far as
/// read-backs establish, for a backend that switches charging itself.
/// Asking for normal charging does not establish that a restriction ended;
/// only a read-back showing normal charging does.
public enum OwnRestrictionState: Sendable, Equatable {
    /// The last read-back shows normal charging: no restriction is in
    /// effect.
    case noneInEffect
    /// The last read-back shows this restriction, which CellKeeper set.
    case inEffect(ChargeControlMode)
    /// CellKeeper set or asked for this restriction, and the backend's state
    /// could not be read back since, so it may still be in effect.
    case unconfirmed(ChargeControlMode)
    /// The backend's state could not be read back, so CellKeeper cannot
    /// confirm that nothing it set remains.
    case unknown
    /// The backend accepts no requests, and CellKeeper knows of no
    /// restriction it set there.
    case noneKnown
    /// The last read-back shows this restriction, which CellKeeper did not
    /// set.
    case notCellKeepers(ChargeControlMode)

    /// True unless a read-back shows normal charging or CellKeeper knows of
    /// nothing it set on a backend that accepts no requests.
    public var mayBeInEffect: Bool {
        switch self {
        case .noneInEffect, .noneKnown: false
        case .inEffect, .unconfirmed, .unknown, .notCellKeepers: true
        }
    }
}

extension ControllerStatus {
    /// Whether a restriction CellKeeper set may still be in effect, as far
    /// as read-backs establish (backends that switch charging themselves).
    public var ownRestriction: OwnRestrictionState {
        switch currentMode {
        case .normal?:
            return .noneInEffect
        case let mode?:
            return mode == ownRestrictionMode ? .inEffect(mode) : .notCellKeepers(mode)
        case nil:
            if let own = ownRestrictionMode { return .unconfirmed(own) }
            return capabilities.availability.acceptsRequests ? .unknown : .noneKnown
        }
    }
}

/// What CellKeeper says about macOS's own Charge Limit with a backend that
/// switches charging itself: only what macOS's report and CellKeeper's
/// read-backs establish. Shared by the menu, Settings and the diagnostics
/// report.
public enum MacOSChargeLimitWording {
    /// macOS's report in a few words.
    public static func summary(_ status: MacOSChargeLimitStatus) -> String {
        guard let limit = status.reportedLimit else { return "Could not be read" }
        if status.isNoLimitReported { return "No active limit reported" }
        return limit >= 100 ? "A 100% limit reported" : "On at \(limit)%"
    }

    /// Whether CellKeeper's own restriction ended, while it asks for normal
    /// charging.
    public static func releaseState(_ own: OwnRestrictionState) -> String {
        switch own {
        case .noneInEffect:
            "The last read-back shows no restriction in effect."
        case .inEffect(let mode):
            "The last read-back still shows CellKeeper's \(mode). CellKeeper keeps asking for normal charging; the restriction remains until a read-back shows it ended."
        case .unconfirmed(let mode):
            "No read-back has confirmed that CellKeeper's \(mode) ended, so it may remain. CellKeeper keeps asking for normal charging until a read-back shows it ended."
        case .unknown:
            "CellKeeper could not read back the backend's state, so it cannot confirm that nothing it set remains. It keeps asking for normal charging."
        case .noneKnown:
            "The backend accepts no requests, and CellKeeper knows of no restriction it set there."
        case .notCellKeepers(let mode):
            "The backend reports \(mode), which CellKeeper did not set; CellKeeper does not override it."
        }
    }

    /// What CellKeeper does about macOS's limit and what the user can do.
    public static func guidance(_ status: MacOSChargeLimitStatus, ownRestriction: OwnRestrictionState) -> String {
        guard status.isLimiting else {
            let report = status.isNoLimitReported
                ? "macOS reports no active Charge Limit"
                : "macOS reports a Charge Limit of 100%"
            return "\(report), so CellKeeper does not defer to it. That does not establish that the setting is 100% or that macOS holds nothing: a temporary full charge may look the same, and Optimized Battery Charging or battery health management can hold charging without appearing in this report."
        }
        let withholding = "CellKeeper withholds its own restrictions and asks for normal charging, so two limits never compete."
        if let limit = status.reportedLimit {
            return "macOS reports its Charge Limit on at \(limit)%. While it is, \(withholding) \(releaseState(ownRestriction)) To let CellKeeper manage charging, open System Settings › Battery, click ⓘ next to Charging, and set the Charge Limit to 100%. CellKeeper never changes it itself."
        }
        return "CellKeeper could not read macOS's Charge Limit report (\(status.readProblem ?? "no report")), so macOS may be limiting charging. Until the report shows no active limit, \(withholding) \(releaseState(ownRestriction)) Check that the Charge Limit in System Settings › Battery (ⓘ next to Charging) is 100%. CellKeeper never changes it itself."
    }
}
