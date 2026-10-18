import CellKeeperCore
import Foundation

/// What the menu and Settings say about the weekly full charge. Like
/// ``FullChargeScheduleWording`` it says only what CellKeeper does: it
/// requests a temporary full charge at each start, never a charge "ready
/// by" a time or a return to the limit at a given time, and it never
/// promises that a full charge cannot start twice: it says that CellKeeper
/// records each one it handled, and when that record can be lost. Every
/// date is shown relative to `now`, the time of the status the caller shows
/// (the year appears only when it differs).
public enum WeeklyFullChargeWording {
    /// Gregorian weekdays (1 = Sunday) in `locale`'s order, its first
    /// weekday first.
    public static func weekdayOrder(locale: Locale = .current) -> [Int] {
        let first = calendar(locale).firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// The short name of `weekday` (1 = Sunday) in `locale`.
    public static func shortName(of weekday: Int, locale: Locale = .current) -> String {
        calendar(locale).shortWeekdaySymbols[(weekday - 1) % 7]
    }

    /// For example "Every Friday at 7:00 AM, for 12 hours", "Every Mon, Wed,
    /// and Fri at …", or "Every day at …".
    public static func summary(_ pattern: WeeklyFullChargePattern, locale: Locale = .current) -> String {
        let calendar = calendar(locale)
        let days: String
        if pattern.weekdays.count == 7 {
            days = "day"
        } else if pattern.weekdays.count == 1, let only = pattern.weekdays.first {
            days = calendar.weekdaySymbols[(only - 1) % 7]
        } else {
            let names = weekdayOrder(locale: locale).filter(pattern.weekdays.contains).map { calendar.shortWeekdaySymbols[$0 - 1] }
            days = names.formatted(.list(type: .and).locale(locale))
        }
        let hours = pattern.durationHours == 1 ? "1 hour" : "\(pattern.durationHours) hours"
        return "Every \(days) at \(timeOfDay(hour: pattern.hour, minute: pattern.minute, locale: locale)), for \(hours)"
    }

    /// Settings' line for the next occurrence, which is always in the
    /// future.
    public static func nextLine(_ next: WeeklyFullChargeOccurrence, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String {
        "Next: \(FullChargeScheduleWording.window(next.window, timeZone: timeZone, locale: locale, now: now))"
    }

    /// The menu's line for the next occurrence, shown whenever a weekly full
    /// charge is in use, also while another one is due.
    public static func menuLine(_ next: WeeklyFullChargeOccurrence?, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String {
        guard let next else { return "Weekly full charge: no next start found" }
        return "Weekly full charge: next \(FullChargeScheduleWording.window(next.window, timeZone: timeZone, locale: locale, now: now))"
    }

    /// When a change of offset skipped the start time on the occurrence's
    /// day, so that it starts later: what it starts at instead. Nil
    /// otherwise.
    public static func skipNote(_ occurrence: WeeklyFullChargeOccurrence, pattern: WeeklyFullChargePattern, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String? {
        guard occurrence.startShift > 0 else { return nil }
        let time = timeOfDay(hour: pattern.hour, minute: pattern.minute, locale: locale)
        let day = nominalDay(occurrence.day, locale: locale, now: now, timeZone: timeZone)
        let start = FullChargeScheduleWording.format(occurrence.startsAt, timeZone: timeZone, locale: locale, now: now)
        return "\(time) does not occur on \(day) (the clocks go forward), so it starts at \(start)."
    }

    /// The line for an occurrence that is due but cannot start yet, shown
    /// beneath the next one.
    public static func dueLine(_ due: WeeklyFullChargeDue, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String {
        let end = FullChargeScheduleWording.format(due.occurrence.endsAt, timeZone: timeZone, locale: locale, now: now)
        return "Weekly full charge is due but cannot start yet: \(FullChargeScheduleWording.waitText(due.wait)). It can still start until \(end)."
    }

    /// Settings' line for the latest occurrence that started or passed; nil
    /// for one that began before the schedule was saved.
    public static func lastLine(_ record: WeeklyFullChargeRecord, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String? {
        let start = FullChargeScheduleWording.format(record.startsAt, timeZone: timeZone, locale: locale, now: now)
        switch record.result {
        case .started: return "Last: \(start), started"
        case .passed: return "Last: \(start), passed before it could start"
        case .beforeSave: return nil
        }
    }

    /// What it means that the store is not in line with what is in use.
    public static func storeProblemLine(_ problem: WeeklyFullChargeStoreProblem) -> String {
        switch problem {
        case .notSaved:
            "CellKeeper could not save the weekly full charge. It keeps using it and tries again at its next check. Until then, if CellKeeper opens again, it may use what was saved before, and may start a weekly full charge it already started or found passed once more while its window is open."
        case .notRemoved:
            "CellKeeper could not save that the weekly full charge was removed. It tries again at its next check. Until then, the weekly full charge may come back if CellKeeper opens again."
        }
    }

    /// The menu's line for what became of the latest occurrence, or nil
    /// where the running full charge's own line says it.
    public static func outcomeLine(_ outcome: WeeklyFullChargeOutcome, timeZone: TimeZone = .current, locale: Locale = .current, now: Date) -> String? {
        func start(_ occurrence: WeeklyFullChargeOccurrence) -> String {
            FullChargeScheduleWording.format(occurrence.startsAt, timeZone: timeZone, locale: locale, now: now)
        }
        switch outcome {
        case .started, .extendedRunning:
            return nil
        case .alreadyFull(let occurrence):
            return "The weekly full charge of \(start(occurrence)) found the battery already full."
        case .keptRunning(let occurrence, .later):
            return "A temporary full charge was already running and expires later than the weekly one of \(start(occurrence)) would have, so it changed nothing."
        case .keptRunning(let occurrence, .same):
            return "A temporary full charge was already running and expires when the weekly one of \(start(occurrence)) would have, so it changed nothing."
        case .windowPassed(let occurrence, let lastWait):
            let lastChecked = lastWait.map { " Last checked: \(FullChargeScheduleWording.lastCheckedText($0))." } ?? ""
            return "The weekly full charge of \(start(occurrence)) passed before it could start.\(lastChecked)"
        case .discarded(let reason):
            return "A saved weekly full charge could not be used and is removed: \(reason)."
        }
    }

    /// Said with the weekly full charge in Settings.
    public static let explanation = "Each start requests the same temporary full charge as a scheduled full charge, above, for the time left until the end of its window. Times follow your Mac's time zone wherever it is; the duration is elapsed time, so a daylight-saving change during it moves the clock time it ends at. Your Mac must be awake, with CellKeeper running, for it to start; CellKeeper cannot wake your Mac or open itself after a restart. If a start passes while it cannot start, it starts at CellKeeper's next check before its end; otherwise the menu says it passed, and it is not made up later. Unplugging ends it."

    /// What CellKeeper records, said with the weekly full charge.
    public static let record = "CellKeeper records each weekly full charge that starts or passes, so it does not start that one again, even if the clock or the time zone changes. Removing the schedule clears that record."

    /// The help of the Save button: when the record can be lost.
    public static let saveHelp = "Saves the weekly full charge. It counts from now: one whose start has already passed does not start. If CellKeeper quits unexpectedly or your Mac loses power just after one starts, its record may not have been saved, and it can start once more when CellKeeper opens again, while its window is open."

    // MARK: - Formatting

    /// A Gregorian calendar in `locale`, for weekday names and order.
    private static func calendar(_ locale: Locale) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar
    }

    /// `hour`:`minute` as `locale` writes a time of day.
    static func timeOfDay(hour: Int, minute: Int, locale: Locale) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return Date(timeIntervalSince1970: TimeInterval(hour * 3600 + minute * 60)).formatted(style.locale(locale))
    }

    /// A nominal day as `locale` writes a date (weekday, day and month, with
    /// the year when it is not `now`'s in `timeZone`).
    static func nominalDay(_ day: LocalDay, locale: Locale, now: Date, timeZone: TimeZone) -> String {
        let utc = TimeZone(secondsFromGMT: 0)!
        // Noon UTC on the day reads as that day in UTC.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = utc
        let noon = gregorian.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? now
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        var nowCalendar = locale.calendar
        nowCalendar.timeZone = timeZone
        var dayCalendar = locale.calendar
        dayCalendar.timeZone = utc
        if dayCalendar.component(.year, from: noon) != nowCalendar.component(.year, from: now) {
            style = style.year()
        }
        style.timeZone = utc
        return noon.formatted(style.locale(locale))
    }
}
