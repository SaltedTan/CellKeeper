import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

private let utcZone = TimeZone(identifier: "UTC")!
private let newYork = TimeZone(identifier: "America/New_York")!
private let london = TimeZone(identifier: "Europe/London")!
private let posix = Locale(identifier: "en_US_POSIX")
private let british = Locale(identifier: "en_GB")

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
    @Test("Days are in the locale's order and named in its words")
    func days() {
        #expect(WeeklyFullChargeWording.weekdayOrder(locale: posix) == [1, 2, 3, 4, 5, 6, 7])
        #expect(WeeklyFullChargeWording.weekdayOrder(locale: british) == [2, 3, 4, 5, 6, 7, 1])
        #expect(WeeklyFullChargeWording.shortName(of: 6, locale: posix) == "Fri")
    }

    @Test("The summary names one day in full, several in short, and every day as such")
    func summary() {
        #expect(plain(WeeklyFullChargeWording.summary(fridays, locale: posix)) == "Every Friday at 7:00 AM, for 12 hours")
        #expect(WeeklyFullChargeWording.summary(fridays, locale: british) == "Every Friday at 07:00, for 12 hours")
        let three = WeeklyFullChargePattern(weekdays: [2, 4, 6], hour: 18, minute: 30, durationHours: 1)
        #expect(plain(WeeklyFullChargeWording.summary(three, locale: posix)) == "Every Mon, Wed, and Fri at 6:30 PM, for 1 hour")
        let everyDay = WeeklyFullChargePattern(weekdays: Set(1...7), hour: 7, minute: 0, durationHours: 48)
        #expect(plain(WeeklyFullChargeWording.summary(everyDay, locale: posix)) == "Every day at 7:00 AM, for 48 hours")
    }

    @Test("The next start, in Settings and in the menu, is the occurrence's window")
    func next() {
        let window = FullChargeScheduleWording.window(friday23.window, timeZone: london, locale: posix, now: now)
        #expect(plain(window) == "Fri, Oct 23 at 7:00 AM – Fri, Oct 23 at 7:00 PM")
        #expect(WeeklyFullChargeWording.nextLine(friday23, timeZone: london, locale: posix, now: now) == "Next: \(window)")
        #expect(WeeklyFullChargeWording.menuLine(friday23, timeZone: london, locale: posix, now: now) == "Weekly full charge: next \(window)")
    }

    @Test("A start moved by skipped time says what it starts at instead; one not moved says nothing")
    func skipNote() throws {
        let sundays = WeeklyFullChargePattern(weekdays: [1], hour: 2, minute: 30, durationHours: 12)
        let moved = try #require(sundays.occurrence(on: LocalDay(year: 2026, month: 3, day: 8)!, in: newYork))
        let note = WeeklyFullChargeWording.skipNote(moved, pattern: sundays, timeZone: newYork, locale: posix, now: utc("2026-03-01T12:00:00Z"))
        #expect(note.map(plain) == "2:30 AM does not occur on Sun, Mar 8 (the clocks go forward), so it starts at Sun, Mar 8 at 3:30 AM.")
        #expect(WeeklyFullChargeWording.skipNote(friday23, pattern: fridays, timeZone: london, locale: posix, now: now) == nil)
    }

    @Test("A due occurrence says why it cannot start and until when it can")
    func due() {
        let line = WeeklyFullChargeWording.dueLine(WeeklyFullChargeDue(occurrence: friday23, wait: .onBattery), timeZone: london, locale: posix, now: now)
        #expect(plain(line) == "Weekly full charge is due but cannot start yet: the Mac is on battery; connect power. It can still start until Fri, Oct 23 at 7:00 PM.")
    }

    @Test("The last occurrence is shown when it started or passed, not when it began before the save")
    func last() {
        #expect(WeeklyFullChargeWording.lastLine(WeeklyFullChargeRecord(friday23, result: .started), timeZone: london, locale: posix, now: now).map(plain) == "Last: Fri, Oct 23 at 7:00 AM, started")
        #expect(WeeklyFullChargeWording.lastLine(WeeklyFullChargeRecord(friday23, result: .passed), timeZone: london, locale: posix, now: now).map(plain) == "Last: Fri, Oct 23 at 7:00 AM, passed before it could start")
        #expect(WeeklyFullChargeWording.lastLine(WeeklyFullChargeRecord(friday23, result: .beforeSave), timeZone: london, locale: posix, now: now) == nil)
    }

    @Test("Each outcome has its line; a start or an extension has none, since the running line says it")
    func outcomes() {
        func line(_ outcome: WeeklyFullChargeOutcome) -> String? {
            WeeklyFullChargeWording.outcomeLine(outcome, timeZone: london, locale: posix, now: now).map(plain)
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
        var texts = [WeeklyFullChargeWording.explanation, WeeklyFullChargeWording.record, WeeklyFullChargeWording.saveHelp]
        texts += [WeeklyFullChargeStoreProblem.notSaved, .notRemoved].map(WeeklyFullChargeWording.storeProblemLine)
        let outcomes: [WeeklyFullChargeOutcome] = [.alreadyFull(friday23), .keptRunning(friday23, deadline: .later), .keptRunning(friday23, deadline: .same), .windowPassed(friday23, lastWait: .onBattery), .discarded(reason: "x")]
        texts += outcomes.compactMap { WeeklyFullChargeWording.outcomeLine($0, timeZone: london, locale: posix, now: now) }
        for text in texts {
            let lowered = text.lowercased()
            for claim in ["ready by", "guarantee", "never start", "never twice", "only once", "will be full", "is charging", "wakes your mac", "at exactly"] {
                #expect(!lowered.contains(claim), "\(claim) in: \(text)")
            }
        }
        #expect(WeeklyFullChargeWording.saveHelp.contains("can start once more"))
        #expect(WeeklyFullChargeWording.storeProblemLine(.notSaved).contains("once more"))
        #expect(WeeklyFullChargeWording.record.contains("Removing the schedule clears that record."))
    }
}

@Suite("Dates and the year")
struct DateYearTests {
    @Test("A date in the year of the status shown has no year; one in another year has it")
    func sameAndOtherYear() {
        let date = utc("2026-10-23T06:00:00Z")
        #expect(plain(FullChargeScheduleWording.format(date, timeZone: london, locale: posix, now: utc("2026-01-01T12:00:00Z"))) == "Fri, Oct 23 at 7:00 AM")
        #expect(plain(FullChargeScheduleWording.format(date, timeZone: london, locale: posix, now: utc("2025-12-31T12:00:00Z"))) == "Fri, Oct 23, 2026 at 7:00 AM")
        #expect(plain(FullChargeScheduleWording.format(date, timeZone: london, locale: posix, now: utc("2027-01-15T08:00:00Z"))) == "Fri, Oct 23, 2026 at 7:00 AM")
    }

    @Test("The year is judged in the time zone shown: at New Year, the same instants are one year in New York and two in UTC")
    func localNewYear() {
        // 23:30 EST on 2026-12-31 is 04:30Z on 2027-01-01.
        let lateEvening = utc("2027-01-01T04:30:00Z")
        let morning = utc("2026-12-31T12:00:00Z")
        #expect(plain(FullChargeScheduleWording.format(lateEvening, timeZone: newYork, locale: posix, now: morning)) == "Thu, Dec 31 at 11:30 PM")
        #expect(plain(FullChargeScheduleWording.format(lateEvening, timeZone: utcZone, locale: posix, now: morning)) == "Fri, Jan 1, 2027 at 4:30 AM")
        // Half an hour after midnight in New York, the new year shows.
        #expect(plain(FullChargeScheduleWording.format(utc("2027-01-01T05:30:00Z"), timeZone: newYork, locale: posix, now: morning)) == "Fri, Jan 1, 2027 at 12:30 AM")
    }

    @Test("A window into the next year shows the year on the end that is in it")
    func windowIntoNextYear() {
        let window = FullChargeSchedule(startsAt: utc("2026-12-31T20:00:00Z"), endsAt: utc("2027-01-01T08:00:00Z"))
        #expect(plain(FullChargeScheduleWording.window(window, timeZone: utcZone, locale: posix, now: utc("2026-12-31T12:00:00Z"))) == "Thu, Dec 31 at 8:00 PM – Fri, Jan 1, 2027 at 8:00 AM")
    }
}
