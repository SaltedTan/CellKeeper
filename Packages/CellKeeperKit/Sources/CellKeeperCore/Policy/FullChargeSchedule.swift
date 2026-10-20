import Foundation

/// A one-shot scheduled temporary full charge: an activation window from
/// ``startsAt`` to ``endsAt``, both absolute instants.
///
/// Three things are kept apart:
/// - The **activation window** is wall-clock time, checked level-triggered
///   against ``PolicyInput/now`` at every evaluation (research rule R22). A
///   window that passes before the full charge could start is never
///   replayed.
/// - The **override deadline** is monotonic: when the schedule starts, it
///   becomes a ``ChargeOverride`` whose duration is the time left to
///   `endsAt` at that moment (at most 48 h). The end bounds nothing after
///   that: a running full charge with a later deadline keeps it, a clock
///   change does not move the deadline, and, like every override expiry,
///   it is processed only during an evaluation, so sleep and refused or
///   failed requests can delay what follows it.
/// - A **confirmed setting change** is only what a read-back shows; the
///   request it makes may be rate-limited, refused or fail like any other.
///
/// The schedule only starts the existing temporary full charge. It never
/// changes settings, management or the backend, and never discharges.
public struct FullChargeSchedule: Sendable, Equatable {
    public var startsAt: Date
    public var endsAt: Date

    /// The shortest and longest windows, the bounds of a temporary full
    /// charge (research rule R23).
    public static let minimumWindow: TimeInterval = ChargeOverride.minimumDuration
    public static let maximumWindow: TimeInterval = ChargeOverride.maximumDuration
    /// How far ahead a schedule may start, checked only when it is set.
    public static let maximumLeadTime: TimeInterval = 7 * 24 * 60 * 60
    /// The window a new schedule gets unless the user picks another end.
    public static let defaultWindow: TimeInterval = ChargeOverride.defaultFullChargeDuration

    public init(startsAt: Date, endsAt: Date) {
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    /// The window's length in seconds.
    public var window: TimeInterval {
        endsAt.timeIntervalSince(startsAt)
    }

    /// Problems with the window itself, whenever it is checked: both
    /// endpoints finite, and the end 1–48 h after the start.
    public var windowIssues: [FullChargeScheduleIssue] {
        guard startsAt.timeIntervalSinceReferenceDate.isFinite, endsAt.timeIntervalSinceReferenceDate.isFinite, window.isFinite else {
            return [.notFinite]
        }
        if window < Self.minimumWindow { return [.windowTooShort] }
        if window > Self.maximumWindow { return [.windowTooLong] }
        return []
    }

    /// Problems with setting this schedule at `now`: the window's own, a
    /// start that is not in the future, or one more than
    /// ``maximumLeadTime`` ahead.
    public func issues(settingAt now: Date) -> [FullChargeScheduleIssue] {
        var issues = windowIssues
        guard issues.isEmpty else { return issues }
        let lead = startsAt.timeIntervalSince(now)
        if !(lead > 0) {
            issues.append(.startNotInFuture)
        } else if lead > Self.maximumLeadTime {
            issues.append(.startTooFarAhead)
        }
        return issues
    }

    /// Whether the schedule starts now, waits, or has passed, judged only
    /// from `input`: its wall-clock time, settings and snapshot, the same
    /// values the evaluation then gives ``ChargingPolicy/evaluate(_:)``.
    ///
    /// Within the window it starts once the settings are valid, management
    /// is on, and a usable reading (battery present, not stale, a known
    /// charge and power source) shows external power. Starting otherwise
    /// would only waste it: unplugging ends a full charge at once, and
    /// turning management off cancels one. Unlike the menu's manual button,
    /// it may start when the limit is already 100%. Everything else is left
    /// to the policy, exactly as for a full charge the user starts.
    public static func check(_ schedule: FullChargeSchedule, input: PolicyInput) -> FullChargeScheduleCheck {
        // A window that is not valid cannot start; the controller never
        // holds one (it is validated when set and when loaded).
        guard schedule.windowIssues.isEmpty else { return .passed }
        let now = input.now
        if now < schedule.startsAt { return .notYet }
        let remaining = schedule.endsAt.timeIntervalSince(now)
        guard remaining > 0 else { return .passed }
        guard input.settings.isValid else { return .waiting(.settingsInvalid) }
        guard input.settings.isManagementEnabled else { return .waiting(.managementOff) }
        guard let snapshot = input.snapshot, snapshot.isBatteryPresent,
              ChargingPolicy.staleness(of: snapshot, now: now) == nil,
              let percent = snapshot.chargePercent, (0...100).contains(percent),
              snapshot.powerSource != .unknown
        else { return .waiting(.noUsableReading) }
        guard snapshot.powerSource == .externalPower else { return .waiting(.onBattery) }
        return .start(remaining: remaining)
    }
}

/// A problem with a ``FullChargeSchedule``.
public enum FullChargeScheduleIssue: Sendable, Equatable, CustomStringConvertible {
    case notFinite
    case windowTooShort
    case windowTooLong
    case startNotInFuture
    case startTooFarAhead
    /// A guided calibration is in progress (note 12 §7.4).
    case calibrationInProgress

    public var description: String {
        switch self {
        case .notFinite:
            "The schedule's times are not valid."
        case .windowTooShort:
            "The end must be at least \(Int(FullChargeSchedule.minimumWindow / 3600)) hour after the start."
        case .windowTooLong:
            "The end must be at most \(Int(FullChargeSchedule.maximumWindow / 3600)) hours after the start."
        case .startNotInFuture:
            "The start must be in the future."
        case .startTooFarAhead:
            "The start must be at most \(Int(FullChargeSchedule.maximumLeadTime / 86_400)) days ahead."
        case .calibrationInProgress:
            CalibrationWording.inProgress
        }
    }
}

/// Why a schedule that is due cannot start yet.
public enum FullChargeScheduleWait: String, Sendable, Equatable, CustomStringConvertible {
    /// The settings are not valid.
    case settingsInvalid
    /// Manage charging is off.
    case managementOff
    /// No usable battery reading: none, stale, no battery, or an unknown
    /// charge or power source.
    case noUsableReading
    /// The Mac is running on battery.
    case onBattery

    public var description: String {
        switch self {
        case .settingsInvalid: "the settings are not valid"
        case .managementOff: "Manage charging is off"
        case .noUsableReading: "no usable battery reading"
        case .onBattery: "the Mac is on battery"
        }
    }
}

/// What ``FullChargeSchedule/check(_:input:)`` found.
public enum FullChargeScheduleCheck: Sendable, Equatable {
    /// Before the window.
    case notYet
    /// Inside the window and eligible: start a full charge whose duration is
    /// `remaining`, the time left to the window's end now.
    case start(remaining: TimeInterval)
    /// Inside the window, but it cannot start yet.
    case waiting(FullChargeScheduleWait)
    /// The window has passed.
    case passed
}

/// What became of a schedule, for the menu and the activity log.
public enum FullChargeScheduleOutcome: Sendable, Equatable {
    /// It started a temporary full charge.
    case started(FullChargeSchedule)
    /// The full charge it started, extended or kept was complete in the
    /// same evaluation.
    case alreadyFull(FullChargeSchedule)
    /// A full charge was already running; the schedule moved its monotonic
    /// deadline later. The running override shows the deadline in force.
    case extendedRunning(FullChargeSchedule)
    /// A full charge was already running with a monotonic deadline later
    /// than, or the same as, the schedule's; it continues unchanged. The
    /// running override shows the deadline in force.
    case keptRunning(FullChargeSchedule, deadline: RunningDeadline)
    /// The window passed before the full charge could start. `lastWait` is
    /// the reason it last waited in this run, if it was seen waiting.
    case windowPassed(FullChargeSchedule, lastWait: FullChargeScheduleWait?)
    /// A stored schedule could not be read or was not valid, and was
    /// removed.
    case discarded(reason: String)

    /// This outcome once the full charge it started, extended or kept
    /// turned out complete in the same evaluation; other outcomes are
    /// unchanged.
    public var foundAlreadyFull: FullChargeScheduleOutcome {
        switch self {
        case .started(let schedule), .extendedRunning(let schedule), .keptRunning(let schedule, _):
            .alreadyFull(schedule)
        case .alreadyFull, .windowPassed, .discarded:
            self
        }
    }
}

/// How the monotonic deadline of a full charge already running compared
/// with a schedule's, when the schedule kept it unchanged.
public enum RunningDeadline: Sendable, Equatable {
    /// Later than the schedule's.
    case later
    /// The same as the schedule's, as when two schedules whose windows end
    /// together start in one evaluation.
    case same
}

/// A rejected schedule.
public struct FullChargeScheduleError: Error, Sendable, Equatable, CustomStringConvertible {
    public var issues: [FullChargeScheduleIssue]

    public init(issues: [FullChargeScheduleIssue]) {
        self.issues = issues
    }

    public var description: String {
        issues.map(\.description).joined(separator: " ")
    }
}
