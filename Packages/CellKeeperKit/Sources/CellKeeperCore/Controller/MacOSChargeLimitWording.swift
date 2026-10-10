import Foundation

/// Whether a restriction CellKeeper set may still be in effect, as far as
/// read-backs establish, for a backend that switches charging itself.
///
/// Pending requests, cleared ownership bookkeeping and policy intent
/// establish nothing: "none in effect" needs a read taken after the last
/// request that could have activated anything, and "not CellKeeper's" needs
/// the backend's records (for the helper, its change history) showing that
/// nothing in effect is CellKeeper's.
public enum OwnRestrictionState: Sendable, Equatable {
    /// A read taken after CellKeeper's last restricting request shows
    /// normal charging: no restriction is in effect.
    case noneInEffect
    /// The last read shows `mode` in effect, and CellKeeper may have set it:
    /// it asked for `own` and has not seen that end.
    case inEffect(ChargeControlMode, own: ChargeControlMode)
    /// CellKeeper may have put `own` into effect, and no read since shows
    /// what is in effect, so it may remain.
    case unconfirmed(ChargeControlMode)
    /// No read shows what is in effect, so CellKeeper cannot confirm that
    /// nothing it set remains.
    case unknown
    /// The backend accepts no requests, and CellKeeper knows of no request
    /// of its own that could be in effect there.
    case noneKnown
    /// The last read shows `mode` in effect, and the backend's records show
    /// positively that it is not CellKeeper's (for the helper: another
    /// client's activation or a change made outside it, with none of the
    /// helper's writes or restores in doubt).
    case notCellKeepers(ChargeControlMode)
    /// The last read shows `mode` in effect; CellKeeper knows of no request
    /// of its own that set it, but nothing shows who did.
    case unexplained(ChargeControlMode)

    /// True unless a read shows normal charging or CellKeeper knows of
    /// nothing it set on a backend that accepts no requests.
    public var mayBeInEffect: Bool {
        switch self {
        case .noneInEffect, .noneKnown: false
        case .inEffect, .unconfirmed, .unknown, .notCellKeepers, .unexplained: true
        }
    }
}

extension ControllerStatus {
    /// Whether a restriction CellKeeper set may still be in effect, as far
    /// as read-backs establish (backends that switch charging themselves).
    public var ownRestriction: OwnRestrictionState {
        switch currentMode {
        case .normal?:
            // `currentMode` is cleared before every restricting request, so
            // this read was taken after the last one.
            return .noneInEffect
        case let mode?:
            if isReportedModeOwn == false {
                return .notCellKeepers(mode)
            }
            if let own = ownRestrictionMode {
                return .inEffect(mode, own: own)
            }
            if isReportedModeOwn == true {
                return .inEffect(mode, own: mode)
            }
            // Nothing establishes who set it; a reported outside change does
            // not, since the helper reports one also while its own failed
            // restore may have left a control active.
            return .unexplained(mode)
        case nil:
            if let own = ownRestrictionMode { return .unconfirmed(own) }
            return capabilities.availability.acceptsRequests ? .unknown : .noneKnown
        }
    }

    /// True if the backend's controls are simulated, so restrictions on
    /// them do not change the Mac's charging.
    public var isControlSimulated: Bool {
        capabilities.availability == .simulated
    }
}

/// What CellKeeper says about macOS's own Charge Limit with a backend that
/// switches charging itself: only what macOS's report and CellKeeper's
/// read-backs establish. Shared by the menu, Settings and the diagnostics
/// report.
public enum MacOSChargeLimitWording {
    /// Added wherever a restriction is named on simulated controls.
    static let simulatedNote = "These are the simulated helper's controls; your Mac's charging is not changed."

    /// macOS's report in a few words.
    public static func summary(_ status: MacOSChargeLimitStatus) -> String {
        guard let limit = status.reportedLimit else { return "Could not be read" }
        if status.isNoLimitReported { return "No active limit reported" }
        return limit >= 100 ? "A 100% limit reported" : "On at \(limit)%"
    }

    /// Whether CellKeeper's own restriction ended, as far as read-backs
    /// establish. `isSimulated` marks the controls as simulated.
    public static func releaseState(_ own: OwnRestrictionState, isSimulated: Bool) -> String {
        let text: String = switch own {
        case .noneInEffect:
            "The last read-back shows no restriction in effect."
        case .inEffect(let mode, let requested) where mode == requested:
            "The last read-back still shows CellKeeper's \(mode). CellKeeper keeps asking for its release; it remains until a read-back shows it ended."
        case .inEffect(let mode, let requested):
            "The last read-back shows \(mode) in effect, and CellKeeper cannot rule out that it is its own (it asked for \(requested)). CellKeeper keeps asking for normal charging until a read-back shows no restriction."
        case .unconfirmed(let mode):
            "No read-back has confirmed that CellKeeper's \(mode) ended, so it may remain. CellKeeper keeps asking for its release until a read-back shows it ended."
        case .unknown:
            "CellKeeper could not read back the backend's state, so it cannot confirm that nothing it set remains. It keeps asking for normal charging."
        case .noneKnown:
            "The backend accepts no requests, and CellKeeper knows of no request of its own that could be in effect there."
        case .notCellKeepers(let mode):
            "The backend's records show \(mode) in effect, set by something other than CellKeeper; CellKeeper does not override it."
        case .unexplained(let mode):
            "The last read-back shows \(mode) in effect, and CellKeeper knows of no request of its own that set it; it does not override it."
        }
        return isSimulated ? "\(text) \(simulatedNote)" : text
    }

    /// What CellKeeper does about macOS's limit and what the user can do.
    public static func guidance(_ status: MacOSChargeLimitStatus, ownRestriction: OwnRestrictionState, isSimulated: Bool) -> String {
        guard status.isLimiting else {
            let report = status.isNoLimitReported
                ? "macOS reports no active Charge Limit"
                : "macOS reports a Charge Limit of 100%"
            return "\(report), so CellKeeper does not defer to it. That does not establish that the setting is 100% or that macOS holds nothing: a temporary full charge may look the same, and Optimized Battery Charging or battery health management can hold charging without appearing in this report."
        }
        let withholding = "CellKeeper withholds new restrictions and asks for the release of any restriction of its own."
        let release = releaseState(ownRestriction, isSimulated: isSimulated)
        if let limit = status.reportedLimit {
            return "macOS reports its Charge Limit on at \(limit)%. While it is, \(withholding) \(release) To let CellKeeper manage charging, open System Settings › Battery, click ⓘ next to Charging, and set the Charge Limit to 100%. CellKeeper never changes it itself."
        }
        return "CellKeeper could not read macOS's Charge Limit report (\(status.readProblem ?? "no report")), so macOS may be limiting charging. Until the report shows no active limit, \(withholding) \(release) Check that the Charge Limit in System Settings › Battery (ⓘ next to Charging) is 100%. CellKeeper never changes it itself."
    }
}
