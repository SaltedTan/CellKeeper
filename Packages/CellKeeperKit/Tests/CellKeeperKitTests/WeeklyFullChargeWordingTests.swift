import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

private let utcZone = TimeZone(identifier: "UTC")!
private let newYork = TimeZone(identifier: "America/New_York")!
private let london = TimeZone(identifier: "Europe/London")!
private let posix = Locale(identifier: "en_US_POSIX")
private let british = Locale(identifier: "en_GB")

/// A Gregorian calendar in `locale`, pinned so that no test depends on the
/// system's calendar.
private func gregorian(in locale: Locale) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    return calendar
}

private let posixGregorian = gregorian(in: posix)

private func utc(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

/// ICU puts a narrow no-break space before AM/PM.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
}

private let fridays = WeeklyFullChargePattern(weekdays: [6], hour: 7, minute: 0, durationHours: 12)
/// Friday 2026-10-23 07:00 BST to 19:00 BST.
private let friday23 = fridays.occurrence(on: LocalDay(year: 2026, month: 10, day: 23)!, in: london)!
/// A time in 2026, the year of every occurrence here.
private let now = utc("2026-10-22T12:00:00Z")

@Suite("Weekly full charge wording")
struct WeeklyFullChargeWordingTests {
    @Test("Days are in the calendar's order, its first weekday first, and named in its locale's words")
    func days() {
        #expect(WeeklyFullChargeWording.weekdayOrder(calendar: posixGregorian) == [1, 2, 3, 4, 5, 6, 7])
        #expect(WeeklyFullChargeWording.weekdayOrder(calendar: gregorian(in: british)) == [2, 3, 4, 5, 6, 7, 1])
        var saturdayFirst = posixGregorian
        saturdayFirst.firstWeekday = 7
        #expect(WeeklyFullChargeWording.weekdayOrder(calendar: saturdayFirst) == [7, 1, 2, 3, 4, 5, 6])
        #expect(WeeklyFullChargeWording.shortName(of: 6, calendar: posixGregorian) == "Fri")
    }

    @Test("The summary names one day in full, several in short, and every day as such")
    func summary() {
        #expect(plain(WeeklyFullChargeWording.summary(fridays, locale: posix, calendar: posixGregorian)) == "Every Friday at 7:00 AM, for 12 hours")
        #expect(WeeklyFullChargeWording.summary(fridays, locale: british, calendar: gregorian(in: british)) == "Every Friday at 07:00, for 12 hours")
        let three = WeeklyFullChargePattern(weekdays: [2, 4, 6], hour: 18, minute: 30, durationHours: 1)
        #expect(plain(WeeklyFullChargeWording.summary(three, locale: posix, calendar: posixGregorian)) == "Every Mon, Wed, and Fri at 6:30 PM, for 1 hour")
        let everyDay = WeeklyFullChargePattern(weekdays: Set(1...7), hour: 7, minute: 0, durationHours: 48)
        #expect(plain(WeeklyFullChargeWording.summary(everyDay, locale: posix, calendar: posixGregorian)) == "Every day at 7:00 AM, for 48 hours")
    }

    @Test("The next start, in Settings and in the menu, is the occurrence's window")
    func next() {
        let window = FullChargeScheduleWording.window(friday23.window, timeZone: london, locale: posix, calendar: posixGregorian, now: now)
        #expect(plain(window) == "Fri, Oct 23 at 7:00 AM – Fri, Oct 23 at 7:00 PM")
        #expect(WeeklyFullChargeWording.nextLine(friday23, timeZone: london, locale: posix, calendar: posixGregorian, now: now) == "Next: \(window)")
        #expect(WeeklyFullChargeWording.menuLine(friday23, timeZone: london, locale: posix, calendar: posixGregorian, now: now) == "Weekly full charge: next \(window)")
    }

    @Test("A start moved by skipped time says what it starts at instead; one not moved says nothing")
    func skipNote() throws {
        let sundays = WeeklyFullChargePattern(weekdays: [1], hour: 2, minute: 30, durationHours: 12)
        let moved = try #require(sundays.occurrence(on: LocalDay(year: 2026, month: 3, day: 8)!, in: newYork))
        let note = WeeklyFullChargeWording.skipNote(moved, pattern: sundays, timeZone: newYork, locale: posix, calendar: posixGregorian, now: utc("2026-03-01T12:00:00Z"))
        #expect(note.map(plain) == "2:30 AM does not occur on Sun, Mar 8 (the clocks go forward), so it starts at Sun, Mar 8 at 3:30 AM.")
        #expect(WeeklyFullChargeWording.skipNote(friday23, pattern: fridays, timeZone: london, locale: posix, calendar: posixGregorian, now: now) == nil)
    }

    @Test("A due occurrence says why it cannot start and until when it can")
    func due() {
        let line = WeeklyFullChargeWording.dueLine(WeeklyFullChargeDue(occurrence: friday23, wait: .onBattery), timeZone: london, locale: posix, calendar: posixGregorian, now: now)
        #expect(plain(line) == "Weekly full charge is due but cannot start yet: the Mac is on battery; connect power. It can still start until Fri, Oct 23 at 7:00 PM.")
    }

    @Test("The last occurrence is shown when it started or passed, not when it began before the save")
    func last() {
        #expect(WeeklyFullChargeWording.lastLine(WeeklyFullChargeRecord(friday23, result: .started), timeZone: london, locale: posix, calendar: posixGregorian, now: now).map(plain) == "Last: Fri, Oct 23 at 7:00 AM, started")
        #expect(WeeklyFullChargeWording.lastLine(WeeklyFullChargeRecord(friday23, result: .passed), timeZone: london, locale: posix, calendar: posixGregorian, now: now).map(plain) == "Last: Fri, Oct 23 at 7:00 AM, passed before it could start")
        #expect(WeeklyFullChargeWording.lastLine(WeeklyFullChargeRecord(friday23, result: .beforeSave), timeZone: london, locale: posix, calendar: posixGregorian, now: now) == nil)
    }

    @Test("Each outcome has its line; a start or an extension has none, since the running line says it")
    func outcomes() {
        func line(_ outcome: WeeklyFullChargeOutcome) -> String? {
            WeeklyFullChargeWording.outcomeLine(outcome, timeZone: london, locale: posix, calendar: posixGregorian, now: now).map(plain)
        }
        #expect(line(.started(friday23)) == nil)
        #expect(line(.extendedRunning(friday23)) == nil)
        #expect(line(.alreadyFull(friday23)) == "The weekly full charge of Fri, Oct 23 at 7:00 AM found the battery already full.")
        #expect(line(.keptRunning(friday23, deadline: .later)) == "A temporary full charge was already running and expires later than the weekly one of Fri, Oct 23 at 7:00 AM would have, so it changed nothing.")
        #expect(line(.keptRunning(friday23, deadline: .same)) == "A temporary full charge was already running and expires when the weekly one of Fri, Oct 23 at 7:00 AM would have, so it changed nothing.")
        #expect(line(.windowPassed(friday23, lastWait: nil)) == "The weekly full charge of Fri, Oct 23 at 7:00 AM passed before it could start.")
        #expect(line(.windowPassed(friday23, lastWait: .managementOff)) == "The weekly full charge of Fri, Oct 23 at 7:00 AM passed before it could start. Last checked: Manage charging was off.")
        #expect(line(.discarded(reason: "it could not be read")) == "A saved weekly full charge could not be used and is removed: it could not be read.")
    }

    @Test("Nothing promises a ready time, a charge, or that a full charge never starts twice; the ways the record can be lost are said")
    func noOverclaims() {
        var texts = [WeeklyFullChargeWording.explanation, WeeklyFullChargeWording.record, WeeklyFullChargeWording.saveHelp, WeeklyFullChargeWording.removeHelp]
        texts += [WeeklyFullChargeStoreProblem.notSaved, .notRemoved].map(WeeklyFullChargeWording.storeProblemLine)
        let outcomes: [WeeklyFullChargeOutcome] = [.alreadyFull(friday23), .keptRunning(friday23, deadline: .later), .keptRunning(friday23, deadline: .same), .windowPassed(friday23, lastWait: .onBattery), .discarded(reason: "x")]
        texts += outcomes.compactMap { WeeklyFullChargeWording.outcomeLine($0, timeZone: london, locale: posix, calendar: posixGregorian, now: now) }
        for text in texts {
            let lowered = text.lowercased()
            for claim in ["ready by", "guarantee", "never start", "never twice", "only once", "will be full", "is charging", "wakes your mac", "at exactly"] {
                #expect(!lowered.contains(claim), "\(claim) in: \(text)")
            }
        }
        #expect(WeeklyFullChargeWording.saveHelp.contains("can start once more"))
        #expect(WeeklyFullChargeWording.storeProblemLine(.notSaved).contains("once more"))
        // Remove deletes the saved record, not the days handled in this run.
        #expect(WeeklyFullChargeWording.record.contains("Removing the schedule deletes its saved record, but until CellKeeper quits it still remembers the days it handled"))
        #expect(WeeklyFullChargeWording.removeHelp.contains("Until CellKeeper quits, it still does not start a weekly full charge on a day it already handled."))
        for text in [WeeklyFullChargeWording.record, WeeklyFullChargeWording.removeHelp] {
            #expect(!text.contains("clears"), "\(text)")
        }
    }
}

@Suite("Dates and the year")
struct DateYearTests {
    @Test("A date in the year of the status shown has no year; one in another year has it")
    func sameAndOtherYear() {
        let date = utc("2026-10-23T06:00:00Z")
        #expect(plain(FullChargeScheduleWording.format(date, timeZone: london, locale: posix, calendar: posixGregorian, now: utc("2026-01-01T12:00:00Z"))) == "Fri, Oct 23 at 7:00 AM")
        #expect(plain(FullChargeScheduleWording.format(date, timeZone: london, locale: posix, calendar: posixGregorian, now: utc("2025-12-31T12:00:00Z"))) == "Fri, Oct 23, 2026 at 7:00 AM")
        #expect(plain(FullChargeScheduleWording.format(date, timeZone: london, locale: posix, calendar: posixGregorian, now: utc("2027-01-15T08:00:00Z"))) == "Fri, Oct 23, 2026 at 7:00 AM")
    }

    @Test("The year is judged in the time zone shown: at New Year, the same instants are one year in New York and two in UTC")
    func localNewYear() {
        // 23:30 EST on 2026-12-31 is 04:30Z on 2027-01-01.
        let lateEvening = utc("2027-01-01T04:30:00Z")
        let morning = utc("2026-12-31T12:00:00Z")
        #expect(plain(FullChargeScheduleWording.format(lateEvening, timeZone: newYork, locale: posix, calendar: posixGregorian, now: morning)) == "Thu, Dec 31 at 11:30 PM")
        #expect(plain(FullChargeScheduleWording.format(lateEvening, timeZone: utcZone, locale: posix, calendar: posixGregorian, now: morning)) == "Fri, Jan 1, 2027 at 4:30 AM")
        // Half an hour after midnight in New York, the new year shows.
        #expect(plain(FullChargeScheduleWording.format(utc("2027-01-01T05:30:00Z"), timeZone: newYork, locale: posix, calendar: posixGregorian, now: morning)) == "Fri, Jan 1, 2027 at 12:30 AM")
    }

    @Test("The year is compared in the calendar the date is shown in: an Islamic new year inside one Gregorian year shows its year, a Gregorian new year inside one Islamic year does not")
    func islamicCalendar() {
        var islamic = Calendar(identifier: .islamicUmmAlQura)
        islamic.timeZone = utcZone
        var gregorianUTC = posixGregorian
        gregorianUTC.timeZone = utcZone

        let may = utc("2026-05-01T12:00:00Z")
        let august = utc("2026-08-01T06:00:00Z")
        // The fixture: one Gregorian year, two Islamic years.
        #expect(gregorianUTC.component(.year, from: may) == gregorianUTC.component(.year, from: august))
        let augustYear = islamic.component(.year, from: august)
        #expect(islamic.component(.year, from: may) != augustYear)
        let crossing = FullChargeScheduleWording.format(august, timeZone: utcZone, locale: posix, calendar: islamic, now: may)
        #expect(crossing.contains(String(augustYear)), "\(crossing)")
        // Rendered in the Islamic calendar, not the Gregorian one.
        #expect(!crossing.contains("2026") && !crossing.contains("Aug"), "\(crossing)")

        let december = utc("2025-12-20T12:00:00Z")
        let january = utc("2026-01-10T06:00:00Z")
        // The fixture: two Gregorian years, one Islamic year.
        #expect(islamic.component(.year, from: december) == islamic.component(.year, from: january))
        #expect(gregorianUTC.component(.year, from: december) != gregorianUTC.component(.year, from: january))
        let sameYear = FullChargeScheduleWording.format(january, timeZone: utcZone, locale: posix, calendar: islamic, now: december)
        #expect(!sameYear.contains(String(islamic.component(.year, from: january))), "\(sameYear)")
        #expect(!sameYear.contains("2026") && !sameYear.contains("Jan"), "\(sameYear)")
        // The same instants in the Gregorian calendar cross its year.
        #expect(FullChargeScheduleWording.format(january, timeZone: utcZone, locale: posix, calendar: gregorianUTC, now: december).contains("2026"))
    }

    @Test("A skipped day's note shows the nominal day in the calendar given too")
    func nominalDayInCalendar() throws {
        let sundays = WeeklyFullChargePattern(weekdays: [1], hour: 2, minute: 30, durationHours: 12)
        let moved = try #require(sundays.occurrence(on: LocalDay(year: 2026, month: 3, day: 8)!, in: newYork))
        let islamic = Calendar(identifier: .islamicUmmAlQura)
        let note = try #require(WeeklyFullChargeWording.skipNote(moved, pattern: sundays, timeZone: newYork, locale: posix, calendar: islamic, now: utc("2026-03-01T12:00:00Z")))
        #expect(!note.contains("Mar"), "\(note)")
        #expect(note.hasPrefix("2:30"), "\(note)")
    }

    @Test("A window into the next year shows the year on the end that is in it")
    func windowIntoNextYear() {
        let window = FullChargeSchedule(startsAt: utc("2026-12-31T20:00:00Z"), endsAt: utc("2027-01-01T08:00:00Z"))
        #expect(plain(FullChargeScheduleWording.window(window, timeZone: utcZone, locale: posix, calendar: posixGregorian, now: utc("2026-12-31T12:00:00Z"))) == "Thu, Dec 31 at 8:00 PM – Fri, Jan 1, 2027 at 8:00 AM")
    }
}
