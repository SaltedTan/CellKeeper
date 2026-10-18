import CellKeeperCore
import Foundation

/// What the menu and Settings say about a scheduled full charge. It says
/// only what CellKeeper does: it *requests* a full charge at the start and
/// requests its limit again at its next check once the full charge ends, so
/// it never promises a charge "ready by" a time, a guaranteed 100%, or a
/// return to the limit at an exact time. Simulated and unavailable backends
/// are said to change nothing.
public enum FullChargeScheduleWording {
    /// A date as the menu and Settings show it: weekday, day, month and time.
    public static func format(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        style.timeZone = timeZone
        return date.formatted(style.locale(locale))
    }

    /// The schedule's window, start to end.
    public static func window(_ schedule: FullChargeSchedule, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        "\(format(schedule.startsAt, timeZone: timeZone, locale: locale)) – \(format(schedule.endsAt, timeZone: timeZone, locale: locale))"
    }

    /// The menu's line for an armed schedule: its window, or, once it is
    /// due, why it cannot start yet.
    public static func armedLine(_ schedule: FullChargeSchedule, wait: FullChargeScheduleWait?, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        guard let wait else {
            return "Full charge scheduled: \(window(schedule, timeZone: timeZone, locale: locale))"
        }
        let end = format(schedule.endsAt, timeZone: timeZone, locale: locale)
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

    /// The menu's line for what became of the latest schedule, or nil where
    /// the running full charge's own line says it.
    public static func outcomeLine(_ outcome: FullChargeScheduleOutcome, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        switch outcome {
        case .started, .extendedRunning:
            return nil
        case .alreadyFull:
            return "The scheduled full charge found the battery already full."
        case .keptRunning(_, let deadline):
            return "A temporary full charge was already running, until \(format(deadline, timeZone: timeZone, locale: locale)), so the scheduled one changed nothing."
        case .windowPassed(_, let lastWait):
            let lastChecked = lastWait.map { " Last checked: \(waitText($0))." } ?? ""
            return "The scheduled window passed before the full charge could start.\(lastChecked)"
        case .discarded(let reason):
            return "A saved full-charge schedule was removed: \(reason)."
        }
    }

    /// What a scheduled full charge does with the backend in charge, for
    /// Settings. `end` is the schedule's end, if one is set.
    public static func explanation(for status: ControllerStatus, end: Date?, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let capabilities = status.capabilities
        let limit = status.settings.chargeLimit
        let expiry = end.map { "the charge expires (\(format($0, timeZone: timeZone, locale: locale)))" } ?? "the charge expires at the end you choose"
        let endings = "After the battery is full, you unplug, or \(expiry)"
        let sleep = "while your Mac sleeps, that waits until it wakes"
        if case .unavailable(let reason) = capabilities.availability {
            return "\(status.backend.displayName) is unavailable (\(reason)), so a scheduled full charge changes nothing; CellKeeper only shows what it would do."
        }
        if capabilities.isEnforcedByMacOS {
            return "At the start, CellKeeper requests a macOS Charge Limit of 100%. \(endings), it requests its \(limit)% limit again at its next check; \(sleep). macOS may still hold charging, for battery health or when the battery is warm."
        }
        let deferring = capabilities.macOSChargeLimit?.isLimiting == true
            ? " While macOS's Charge Limit is on, it stays in charge and the full charge has no effect."
            : ""
        if capabilities.availability == .simulated {
            return "Simulated: at the start, CellKeeper records a temporary full charge. Nothing on your Mac changes.\(deferring)"
        }
        return "At the start, CellKeeper allows charging to 100%. \(endings), its \(limit)% limit applies again from its next check; \(sleep).\(deferring)"
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
