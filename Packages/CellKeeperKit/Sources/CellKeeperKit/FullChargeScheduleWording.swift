import CellKeeperCore
import Foundation

/// What the menu and Settings say about a scheduled full charge. It says
/// only what CellKeeper does: it *requests* a full charge at the start and
/// requests its limit again at a check after the full charge ends, so it
/// never promises a charge "ready by" a time, a guaranteed 100%, or a return
/// to the limit at a given time. The schedule's end is only the duration
/// the full charge gets when it starts. Simulated and unavailable backends
/// are said to change nothing.
public enum FullChargeScheduleWording {
    /// A date as the menu and Settings show it: weekday, day, month and time,
    /// with the year when it is not the year of `now` (the time the caller's
    /// status describes) in `timeZone`, and with the time zone when the
    /// local time occurs twice (the hour a daylight-saving change repeats),
    /// so the instant is never ambiguous.
    public static func format(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String {
        format(date, timeZone: timeZone, locale: locale, now: now, withZone: isInRepeatedHour(date, timeZone: timeZone))
    }

    static func format(_ date: Date, timeZone: TimeZone, locale: Locale, now: Date, withZone: Bool) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        if !isInSameYear(date, as: now, timeZone: timeZone, locale: locale) {
            style = style.year()
        }
        if withZone {
            style = style.timeZone(.specificName(.short))
        }
        style.timeZone = timeZone
        return date.formatted(style.locale(locale))
    }

    /// True if `date` and `now` fall in the same year of `locale`'s calendar
    /// in `timeZone`, the calendar the date is shown in.
    static func isInSameYear(_ date: Date, as now: Date, timeZone: TimeZone, locale: Locale) -> Bool {
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        return calendar.component(.year, from: date) == calendar.component(.year, from: now)
            && calendar.component(.era, from: date) == calendar.component(.era, from: now)
    }

    /// The schedule's window, start to end. Both times carry the time zone
    /// when either occurs twice or the two would otherwise read the same.
    public static func window(_ schedule: FullChargeSchedule, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String {
        var withZone = isInRepeatedHour(schedule.startsAt, timeZone: timeZone) || isInRepeatedHour(schedule.endsAt, timeZone: timeZone)
        if !withZone, format(schedule.startsAt, timeZone: timeZone, locale: locale, now: now, withZone: false) == format(schedule.endsAt, timeZone: timeZone, locale: locale, now: now, withZone: false) {
            withZone = true
        }
        let start = format(schedule.startsAt, timeZone: timeZone, locale: locale, now: now, withZone: withZone)
        let end = format(schedule.endsAt, timeZone: timeZone, locale: locale, now: now, withZone: withZone)
        return "\(start) – \(end)"
    }

    /// True if `date`'s local time in `timeZone` also names another instant:
    /// it lies in the hour (or other span) a backward daylight-saving change
    /// repeats.
    static func isInRepeatedHour(_ date: Date, timeZone: TimeZone) -> Bool {
        var cursor = date.addingTimeInterval(-2 * 86_400)
        let limit = date.addingTimeInterval(2 * 86_400)
        while let transition = timeZone.nextDaylightSavingTimeTransition(after: cursor), transition <= limit {
            let shift = TimeInterval(timeZone.secondsFromGMT(for: transition.addingTimeInterval(-1)) - timeZone.secondsFromGMT(for: transition))
            if shift > 0, date >= transition.addingTimeInterval(-shift), date < transition.addingTimeInterval(shift) {
                return true
            }
            cursor = transition
        }
        return false
    }

    /// The menu's line for an armed schedule: its window, or, once it is
    /// due, why it cannot start yet.
    public static func armedLine(_ schedule: FullChargeSchedule, wait: FullChargeScheduleWait?, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String {
        guard let wait else {
            return "Full charge scheduled: \(window(schedule, timeZone: timeZone, locale: locale, now: now))"
        }
        let end = format(schedule.endsAt, timeZone: timeZone, locale: locale, now: now)
        return "Scheduled full charge is due but cannot start yet: \(waitText(wait)). It can still start until \(end)."
    }

    /// Why a due schedule cannot start, in the user's terms.
    public static func waitText(_ wait: FullChargeScheduleWait) -> String {
        switch wait {
        case .settingsInvalid: "the settings are not valid"
        case .managementOff: "Manage charging is off"
        case .noUsableReading: "there is no usable battery reading"
        case .onBattery: "the Mac is on battery; connect power"
        }
    }

    /// Why a schedule last waited, once its window has passed.
    static func lastCheckedText(_ wait: FullChargeScheduleWait) -> String {
        switch wait {
        case .settingsInvalid: "the settings were not valid"
        case .managementOff: "Manage charging was off"
        case .noUsableReading: "there was no usable battery reading"
        case .onBattery: "the Mac was on battery"
        }
    }

    /// The menu's line for what became of the latest schedule, or nil where
    /// the running full charge's own line says it.
    public static func outcomeLine(_ outcome: FullChargeScheduleOutcome) -> String? {
        switch outcome {
        case .started, .extendedRunning:
            return nil
        case .alreadyFull:
            return "The scheduled full charge found the battery already full."
        case .keptRunning(_, .later):
            return "A temporary full charge was already running and expires later than the scheduled one would have, so the schedule changed nothing."
        case .keptRunning(_, .same):
            return "A temporary full charge was already running and expires when the scheduled one would have, so the schedule changed nothing."
        case .windowPassed(_, let lastWait):
            let lastChecked = lastWait.map { " Last checked: \(lastCheckedText($0))." } ?? ""
            return "The scheduled window passed before the full charge could start.\(lastChecked)"
        case .discarded(let reason):
            return "A saved full-charge schedule was removed: \(reason)."
        }
    }

    /// What a scheduled full charge does with the backend in charge, for
    /// Settings. `end` is the schedule's end, if one is set.
    public static func explanation(for status: ControllerStatus, end: Date?, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String {
        let capabilities = status.capabilities
        let limit = status.settings.chargeLimit
        let until = end.map { format($0, timeZone: timeZone, locale: locale, now: now) } ?? "the end you choose"
        let duration = "The full charge lasts for the time left until \(until) when it starts (longer only if a full charge that expires later is already running), or less if the battery is full or you unplug first."
        if case .unavailable(let reason) = capabilities.availability {
            return "\(status.backend.displayName) is unavailable (\(reason)), so a scheduled full charge changes nothing; CellKeeper only shows what it would do."
        }
        if capabilities.isEnforcedByMacOS {
            return "At the start, CellKeeper requests a macOS Charge Limit of 100%. \(duration) CellKeeper then requests its \(limit)% limit again at its next check; sleep, or a request that is refused, can delay that. macOS may still hold charging, for battery health or when the battery is warm."
        }
        let deferring = capabilities.macOSChargeLimit?.isLimiting == true
            ? " While macOS's Charge Limit is on, it stays in charge and the full charge has no effect."
            : ""
        if capabilities.availability == .simulated {
            return "Simulated: at the start, CellKeeper records a temporary full charge. Nothing on your Mac changes.\(deferring)"
        }
        return "At the start, CellKeeper requests a temporary full charge: it asks for none of its own restrictions, unless a safety rule such as the temperature pause still pauses charging. \(duration) CellKeeper then requests its \(limit)% limit again at its next check; sleep, or a request that fails or is refused, can delay that.\(deferring)"
    }

    /// Said with every schedule: when it can start, and what happens if it
    /// cannot.
    public static let startConditions = "Your Mac must be awake, with CellKeeper running, for the full charge to start; CellKeeper cannot wake your Mac or open itself after a restart. If the start passes while it cannot start, it starts at CellKeeper's next check before the end; otherwise the menu says the window passed. Unplugging ends it."

    /// For macOS's Charge Limit, how to charge overnight: macOS applies the
    /// limit while the Mac sleeps, but only once CellKeeper's request has
    /// gone through. Nil for other backends, and while the backend accepts
    /// no requests.
    public static func overnightHint(for status: ControllerStatus) -> String? {
        guard status.capabilities.isEnforcedByMacOS, status.capabilities.availability.acceptsRequests else { return nil }
        return "To charge overnight, schedule a start while your Mac is awake and wait until the menu shows macOS enforcing 100%. Returning to your limit can wait until your Mac wakes."
    }
}

/// What the menu says about a running temporary full charge, whether the
/// user or a schedule started it, and about the button that starts one. It
/// says what CellKeeper requested and what a read-back confirmed, never that
/// the battery is charging or that 100% stops applying at a given time: the
/// return to the limit is requested at a check after the full charge ends,
/// which sleep or a refused request can delay. The time shown is the
/// override's monotonic deadline as estimated now.
public enum TemporaryFullChargeWording {
    /// The line for `override`, a running full charge. `lastResult` describes
    /// the last request, for a full charge that is not in effect.
    public static func line(for override: ChargeOverride, status: ControllerStatus, lastResult: String?, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String {
        let name = override.source == .schedule ? "Scheduled full charge" : "Temporary full charge"
        let capabilities = status.capabilities
        if case .unavailable = capabilities.availability {
            return "\(name) requested, but charging control is unavailable."
        }
        // A rule that takes precedence over the full charge is the
        // explanation, not the last request's result. It is named as a
        // precedence, never as something applied: whether charging is paused
        // has its own line, with its own confirmation.
        let precedence = status.decision?.notes.lazy.compactMap { note -> String? in
            if case .fullChargeSuppressed(let state) = note { return PolicyNote.fullChargeSuppression(by: state) }
            return nil
        }.first
        if let precedence {
            return "\(name) requested, not in effect: \(precedence)."
        }
        guard let decision = status.decision, decision.state == .fullChargeOverride, status.currentMode == decision.desiredMode else {
            return "\(name) requested, not in effect" + (lastResult.map { " (\($0))" } ?? "") + "."
        }
        let expiry = FullChargeScheduleWording.format(override.expiresAt, timeZone: timeZone, locale: locale, now: now)
        let endings = "at a check after the battery is full, you unplug, or it expires (about \(expiry))"
        let limit = status.settings.chargeLimit
        if capabilities.isEnforcedByMacOS {
            return "\(name): macOS's Charge Limit is at 100%, confirmed. CellKeeper requests its \(limit)% limit again \(endings); sleep can delay that."
        }
        if capabilities.availability == .simulated {
            return "\(name), simulated: nothing on your Mac changes. It ends \(endings)."
        }
        return "\(name): CellKeeper has lifted its own restrictions, confirmed. It requests its \(limit)% limit again \(endings); sleep can delay that."
    }

    /// The help for "Charge to 100% once" with the backend in charge. A
    /// backend that accepts no requests is said to change nothing.
    public static func buttonHelp(for status: ControllerStatus) -> String {
        let hours = Int(ChargeOverride.defaultFullChargeDuration / 3600)
        let endings = "at a check after the battery is full, you unplug, or \(hours) hours pass"
        if case .unavailable(let reason) = status.capabilities.availability {
            return "\(status.backend.displayName) is unavailable (\(reason)), so a temporary full charge changes nothing; CellKeeper only shows what it would do."
        }
        if status.capabilities.isEnforcedByMacOS {
            return "Requests a macOS Charge Limit of 100% once. CellKeeper requests its limit again \(endings)."
        }
        if status.capabilities.availability == .simulated {
            return "Records a temporary full charge, simulated: nothing on your Mac changes. It ends \(endings)."
        }
        return "Requests a temporary full charge once: CellKeeper asks for none of its own restrictions, unless a safety rule such as the temperature pause still pauses charging. It requests its limit again \(endings)."
    }
}
