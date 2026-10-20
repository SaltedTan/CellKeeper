import Foundation

/// The latest occurrence of a weekly full charge that CellKeeper handled:
/// it started, its window passed, or it began before the schedule was
/// saved. An occurrence can start only if its nominal day is after this
/// one's, so while this record is in force a handled occurrence is not
/// started again, whatever the clock or the time zone does. The controller
/// keeps it in memory for the run; a relaunch reads it from the store,
/// which may not have it (``WeeklyFullChargeStore``).
public struct WeeklyFullChargeRecord: Sendable, Equatable {
    public enum Result: String, Sendable, Equatable, CaseIterable {
        /// It started a full charge (or extended or kept a running one).
        case started
        /// Its window passed before it could start.
        case passed
        /// It began before the schedule was saved, so it was never due.
        case beforeSave
        /// It fell due while a guided calibration was in progress, and was
        /// skipped (note 12 §7.4).
        case skippedForCalibration
    }

    /// The occurrence's nominal day, which identifies it.
    public var day: LocalDay
    /// When it started (or would have), for display.
    public var startsAt: Date
    /// The offset from UTC in force at ``startsAt`` when it was handled.
    public var utcOffset: Int
    public var result: Result

    public init(day: LocalDay, startsAt: Date, utcOffset: Int, result: Result) {
        self.day = day
        self.startsAt = startsAt
        self.utcOffset = utcOffset
        self.result = result
    }

    public init(_ occurrence: WeeklyFullChargeOccurrence, result: Result) {
        self.init(day: occurrence.day, startsAt: occurrence.startsAt, utcOffset: occurrence.startUTCOffset, result: result)
    }
}

/// A weekly full charge (D100): its pattern and the record of the latest
/// occurrence handled.
///
/// Only one occurrence can start or pass at any check: P, the one with the
/// latest start at or before now in the current time zone (see
/// ``WeeklyFullChargePattern/latestOccurrence(startingAtOrBefore:in:)``),
/// and only if its nominal day is after the record's. Its window is then
/// checked by the one-shot schedule's own rules, so a weekly occurrence
/// starts under exactly the same conditions.
public struct WeeklyFullChargeSchedule: Sendable, Equatable {
    public var pattern: WeeklyFullChargePattern
    public var handled: WeeklyFullChargeRecord

    public init(pattern: WeeklyFullChargePattern, handled: WeeklyFullChargeRecord) {
        self.pattern = pattern
        self.handled = handled
    }

    /// `pattern` saved at `now` in `timeZone`, counting from then: the
    /// record is the later of `handledAtLeast` (what was handled before)
    /// and the new pattern's latest occurrence that starts at or before
    /// `now` (as begun before the save). So a save never makes a handled day
    /// eligible again, and an occurrence whose start has passed does not
    /// start. Throws if the pattern is not valid or `now` is not finite.
    public static func saving(_ pattern: WeeklyFullChargePattern, handledAtLeast earlier: WeeklyFullChargeRecord?, now: Date, timeZone: TimeZone) throws -> WeeklyFullChargeSchedule {
        let issues = pattern.issues
        guard issues.isEmpty else { throw WeeklyFullChargeError.invalid(issues) }
        // A valid pattern always has an occurrence within the past week.
        guard let latest = pattern.latestOccurrence(startingAtOrBefore: now, in: timeZone) else {
            throw WeeklyFullChargeError.invalid([.timeOutOfRange])
        }
        if let earlier, earlier.day >= latest.day {
            return WeeklyFullChargeSchedule(pattern: pattern, handled: earlier)
        }
        return WeeklyFullChargeSchedule(pattern: pattern, handled: WeeklyFullChargeRecord(latest, result: .beforeSave))
    }

    /// Whether an occurrence starts now, waits or has passed, judged only
    /// from `input` (the values the same evaluation then gives
    /// ``ChargingPolicy/evaluate(_:)``) and `timeZone`.
    public func check(input: PolicyInput, timeZone: TimeZone) -> WeeklyFullChargeCheck {
        guard let due = pattern.latestOccurrence(startingAtOrBefore: input.now, in: timeZone), due.day > handled.day else {
            return .nothingDue
        }
        switch FullChargeSchedule.check(due.window, input: input) {
        case .notYet:
            // Its start is at or before now; kept for completeness.
            return .nothingDue
        case .start(let remaining):
            return .start(due, remaining: remaining)
        case .waiting(let wait):
            return .waiting(due, wait)
        case .passed:
            return .passed(due)
        }
    }

    /// The next occurrence: the first that starts strictly after `now` on a
    /// nominal day after the record's. An occurrence that is due is never
    /// the next one.
    public func next(after now: Date, in timeZone: TimeZone) -> WeeklyFullChargeOccurrence? {
        pattern.firstOccurrence(startingAfter: now, onDayAfter: handled.day, in: timeZone)
    }
}

/// What ``WeeklyFullChargeSchedule/check(input:timeZone:)`` found.
public enum WeeklyFullChargeCheck: Sendable, Equatable {
    /// No occurrence that has started is waiting to be handled.
    case nothingDue
    /// This occurrence starts a full charge whose duration is `remaining`,
    /// the time left to its end.
    case start(WeeklyFullChargeOccurrence, remaining: TimeInterval)
    /// This occurrence is due but cannot start yet.
    case waiting(WeeklyFullChargeOccurrence, FullChargeScheduleWait)
    /// This occurrence's window has passed before it could start.
    case passed(WeeklyFullChargeOccurrence)
}

/// A due occurrence that cannot start yet, and why.
public struct WeeklyFullChargeDue: Sendable, Equatable {
    public var occurrence: WeeklyFullChargeOccurrence
    public var wait: FullChargeScheduleWait

    public init(occurrence: WeeklyFullChargeOccurrence, wait: FullChargeScheduleWait) {
        self.occurrence = occurrence
        self.wait = wait
    }
}

/// What became of the latest weekly occurrence handled, for the menu and
/// the activity log.
public enum WeeklyFullChargeOutcome: Sendable, Equatable {
    /// It started a temporary full charge.
    case started(WeeklyFullChargeOccurrence)
    /// The full charge it started, extended or kept was complete in the same
    /// evaluation.
    case alreadyFull(WeeklyFullChargeOccurrence)
    /// A full charge was already running; this occurrence moved its
    /// monotonic deadline later.
    case extendedRunning(WeeklyFullChargeOccurrence)
    /// A full charge was already running with a monotonic deadline later
    /// than, or the same as, this occurrence's; it continues unchanged.
    case keptRunning(WeeklyFullChargeOccurrence, deadline: RunningDeadline)
    /// Its window passed before it could start. `lastWait` is the reason it
    /// last waited in this run, if it was seen waiting.
    case windowPassed(WeeklyFullChargeOccurrence, lastWait: FullChargeScheduleWait?)
    /// A stored weekly schedule could not be used, and is not.
    case discarded(reason: String)
    /// It fell due while a guided calibration was in progress, and was
    /// skipped.
    case skippedForCalibration(WeeklyFullChargeOccurrence)

    /// This outcome once the full charge it started, extended or kept
    /// turned out complete in the same evaluation; other outcomes are
    /// unchanged.
    public var foundAlreadyFull: WeeklyFullChargeOutcome {
        switch self {
        case .started(let occurrence), .extendedRunning(let occurrence), .keptRunning(let occurrence, _):
            .alreadyFull(occurrence)
        case .alreadyFull, .windowPassed, .discarded, .skippedForCalibration:
            self
        }
    }
}

/// Where the stored weekly full charge differs from the one in use, until
/// a later write is read back as made. The one in memory is what this run
/// uses; only a relaunch reads the store.
public enum WeeklyFullChargeStoreProblem: Sendable, Equatable {
    /// The weekly full charge in use, or its record, could not be saved.
    case notSaved
    /// Its removal could not be saved.
    case notRemoved
}

/// Why a weekly schedule was not saved.
public enum WeeklyFullChargeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid([WeeklyFullChargeIssue])
    /// No store was given to the controller.
    case notAvailable
    /// A guided calibration is in progress (note 12 §7.4).
    case calibrationInProgress

    public var description: String {
        switch self {
        case .invalid(let issues): issues.map(\.description).joined(separator: " ")
        case .notAvailable: "Weekly full charges are not available."
        case .calibrationInProgress: CalibrationWording.inProgress
        }
    }
}

