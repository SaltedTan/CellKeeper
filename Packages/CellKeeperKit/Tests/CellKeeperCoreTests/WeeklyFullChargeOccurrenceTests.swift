import CellKeeperCore
import Foundation
import Testing

// Every expected instant below is computed by hand from the zone's
// published offsets and written in UTC, so no test compares the code with
// Foundation's own local-time conversion.

private let hour: TimeInterval = 3600
private let london = TimeZone(identifier: "Europe/London")!
private let newYork = TimeZone(identifier: "America/New_York")!
private let lordHowe = TimeZone(identifier: "Australia/Lord_Howe")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let honolulu = TimeZone(identifier: "Pacific/Honolulu")!

private func utc(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> LocalDay {
    LocalDay(year: year, month: month, day: day)!
}

private let sunday = 1, monday = 2, wednesday = 4, friday = 6, saturday = 7

private func weekly(_ weekdays: Set<Int>, _ hour: Int, _ minute: Int = 0, hours: Int = 12) -> WeeklyFullChargePattern {
    WeeklyFullChargePattern(weekdays: weekdays, hour: hour, minute: minute, durationHours: hours)
}

@Suite("Weekly full charge: local days")
struct LocalDayTests {
    @Test("Only real Gregorian dates in years 1–9999 are days")
    func validation() {
        #expect(LocalDay(year: 2028, month: 2, day: 29) != nil)
        #expect(LocalDay(year: 2026, month: 2, day: 29) == nil)
        #expect(LocalDay(year: 2026, month: 4, day: 31) == nil)
        #expect(LocalDay(year: 2026, month: 13, day: 1) == nil)
        #expect(LocalDay(year: 2026, month: 1, day: 0) == nil)
        #expect(LocalDay(year: 0, month: 1, day: 1) == nil)
        #expect(LocalDay(year: 10_000, month: 1, day: 1) == nil)
    }

    @Test("Weekdays are Gregorian, 1 for Sunday to 7 for Saturday")
    func weekdays() {
        #expect(day(2026, 10, 23).weekday == friday)
        #expect(day(2026, 3, 8).weekday == sunday)
        #expect(day(2028, 2, 29).weekday == 3)
        #expect(day(2026, 12, 31).weekday == 5)
        #expect(day(2027, 1, 1).weekday == friday)
    }

    @Test("Days are added across months, years and leap days")
    func adding() {
        #expect(day(2026, 12, 31).adding(days: 1) == day(2027, 1, 1))
        #expect(day(2028, 2, 28).adding(days: 1) == day(2028, 2, 29))
        #expect(day(2028, 3, 1).adding(days: -1) == day(2028, 2, 29))
        #expect(day(2026, 10, 23).adding(days: 7) == day(2026, 10, 30))
        #expect(day(9999, 12, 31).adding(days: 1) == nil)
    }

    @Test("The day an instant falls on depends on the time zone")
    func containing() {
        let lateEvening = utc("2026-10-23T23:30:00Z")
        #expect(LocalDay(containing: lateEvening, in: london) == day(2026, 10, 24))
        #expect(LocalDay(containing: lateEvening, in: newYork) == day(2026, 10, 23))
        #expect(LocalDay(containing: lateEvening, in: tokyo) == day(2026, 10, 24))
        let morning = utc("2026-10-23T10:00:00Z")
        #expect(LocalDay(containing: morning, in: TimeZone(identifier: "Pacific/Kiritimati")!) == day(2026, 10, 24))
        #expect(LocalDay(containing: morning, in: TimeZone(identifier: "Pacific/Pago_Pago")!) == day(2026, 10, 22))
        // Midnight in New York on the day clocks go forward is still EST.
        #expect(LocalDay(containing: utc("2026-03-08T04:59:59Z"), in: newYork) == day(2026, 3, 7))
        #expect(LocalDay(containing: utc("2026-03-08T05:00:00Z"), in: newYork) == day(2026, 3, 8))
        #expect(LocalDay(containing: Date(timeIntervalSinceReferenceDate: .infinity), in: london) == nil)
    }

    @Test("Days order by date and read as ISO 8601 dates")
    func orderAndDescription() {
        #expect(day(2026, 10, 23) < day(2026, 10, 24))
        #expect(day(2026, 12, 31) < day(2027, 1, 1))
        #expect(day(2026, 9, 30) < day(2026, 10, 1))
        #expect(day(2026, 3, 8).description == "2026-03-08")
    }
}

@Suite("Weekly full charge: local times")
struct LocalTimeTests {
    @Test("The fixtures are real changes of offset: a skipped hour, a repeated hour, and Lord Howe's half hours")
    func fixtures() {
        // New York: EST (-5 h) until 2026-03-08 07:00Z, EDT (-4 h) until 2026-11-01 06:00Z.
        #expect(newYork.secondsFromGMT(for: utc("2026-03-08T06:59:59Z")) == -5 * 3600)
        #expect(newYork.secondsFromGMT(for: utc("2026-03-08T07:00:00Z")) == -4 * 3600)
        #expect(newYork.secondsFromGMT(for: utc("2026-11-01T05:59:59Z")) == -4 * 3600)
        #expect(newYork.secondsFromGMT(for: utc("2026-11-01T06:00:00Z")) == -5 * 3600)
        // London: GMT until 2026-03-29 01:00Z, BST (+1 h) until 2026-10-25 01:00Z.
        #expect(london.secondsFromGMT(for: utc("2026-03-29T00:59:59Z")) == 0)
        #expect(london.secondsFromGMT(for: utc("2026-03-29T01:00:00Z")) == 3600)
        #expect(london.secondsFromGMT(for: utc("2026-10-25T00:59:59Z")) == 3600)
        #expect(london.secondsFromGMT(for: utc("2026-10-25T01:00:00Z")) == 0)
        // Lord Howe: +11 h until 2026-04-04 15:00Z, then +10:30 until 2026-10-03 15:30Z.
        #expect(lordHowe.secondsFromGMT(for: utc("2026-04-04T14:59:59Z")) == 39_600)
        #expect(lordHowe.secondsFromGMT(for: utc("2026-04-04T15:00:00Z")) == 37_800)
        #expect(lordHowe.secondsFromGMT(for: utc("2026-10-03T15:29:59Z")) == 37_800)
        #expect(lordHowe.secondsFromGMT(for: utc("2026-10-03T15:30:00Z")) == 39_600)
    }

    @Test("An ordinary local time is that time in the zone's offset")
    func ordinary() {
        #expect(day(2026, 10, 23).instant(hour: 7, minute: 0, in: london) == utc("2026-10-23T06:00:00Z"))
        #expect(day(2026, 10, 23).instant(hour: 7, minute: 0, in: newYork) == utc("2026-10-23T11:00:00Z"))
        #expect(day(2026, 10, 23).instant(hour: 7, minute: 0, in: tokyo) == utc("2026-10-22T22:00:00Z"))
        #expect(day(2026, 10, 23).instant(hour: 7, minute: 0, in: TimeZone(secondsFromGMT: 19_800)!) == utc("2026-10-23T01:30:00Z"))
        #expect(day(2026, 3, 8).instant(hour: 1, minute: 59, in: newYork) == utc("2026-03-08T06:59:00Z"))
    }

    @Test("A time the clocks skip is read with the offset before the skip, so it falls later by the skip's length")
    func skipped() {
        // 02:00–02:59 do not exist in New York on 2026-03-08.
        #expect(day(2026, 3, 8).instant(hour: 2, minute: 30, in: newYork) == utc("2026-03-08T07:30:00Z"))
        #expect(day(2026, 3, 8).instant(hour: 2, minute: 0, in: newYork) == utc("2026-03-08T07:00:00Z"))
        #expect(day(2026, 3, 8).instant(hour: 3, minute: 0, in: newYork) == utc("2026-03-08T07:00:00Z"))
        // 01:00–01:59 do not exist in London on 2026-03-29.
        #expect(day(2026, 3, 29).instant(hour: 1, minute: 30, in: london) == utc("2026-03-29T01:30:00Z"))
        // 02:00–02:29 do not exist on Lord Howe on 2026-10-04: 02:10 → 02:40 (+11).
        #expect(day(2026, 10, 4).instant(hour: 2, minute: 10, in: lordHowe) == utc("2026-10-03T15:40:00Z"))
    }

    @Test("A time the clocks repeat is the first of the two")
    func repeated() {
        // 01:00–01:59 happen twice in New York on 2026-11-01: EDT, then EST.
        #expect(day(2026, 11, 1).instant(hour: 1, minute: 30, in: newYork) == utc("2026-11-01T05:30:00Z"))
        #expect(day(2026, 11, 1).instant(hour: 1, minute: 0, in: newYork) == utc("2026-11-01T05:00:00Z"))
        #expect(day(2026, 11, 1).instant(hour: 2, minute: 0, in: newYork) == utc("2026-11-01T07:00:00Z"))
        // The second 01:30 exists too, an hour later.
        #expect(newYork.secondsFromGMT(for: utc("2026-11-01T06:30:00Z")) == -5 * 3600)
        // 01:00–01:59 happen twice in London on 2026-10-25: BST, then GMT.
        #expect(day(2026, 10, 25).instant(hour: 1, minute: 30, in: london) == utc("2026-10-25T00:30:00Z"))
        // 01:30–01:59 happen twice on Lord Howe on 2026-04-05: +11, then +10:30.
        #expect(day(2026, 4, 5).instant(hour: 1, minute: 45, in: lordHowe) == utc("2026-04-04T14:45:00Z"))
    }
}

@Suite("Weekly full charge: occurrences")
struct WeeklyOccurrenceTests {
    @Test("An occurrence is its day's window: the start in the zone, the end a duration of elapsed time later")
    func occurrenceOnADay() throws {
        let fridays = weekly([friday], 7)
        let occurrence = try #require(fridays.occurrence(on: day(2026, 10, 23), in: london))
        #expect(occurrence.day == day(2026, 10, 23))
        #expect(occurrence.startsAt == utc("2026-10-23T06:00:00Z"))
        #expect(occurrence.endsAt == utc("2026-10-23T18:00:00Z"))
        #expect(occurrence.startUTCOffset == 3600)
        #expect(occurrence.startShift == 0)
        #expect(occurrence.window == FullChargeSchedule(startsAt: utc("2026-10-23T06:00:00Z"), endsAt: utc("2026-10-23T18:00:00Z")))
        #expect(occurrence.window.windowIssues.isEmpty)
        #expect(fridays.occurrence(on: day(2026, 10, 24), in: london) == nil)
    }

    @Test("A start moved by skipped time says how far; a repeated time is not moved")
    func shifts() throws {
        let skipped = try #require(weekly([sunday], 2, 30).occurrence(on: day(2026, 3, 8), in: newYork))
        #expect(skipped.startsAt == utc("2026-03-08T07:30:00Z"))
        #expect(skipped.startShift == hour)
        #expect(skipped.startUTCOffset == -4 * 3600)
        let halfHour = try #require(weekly([sunday], 2, 10).occurrence(on: day(2026, 10, 4), in: lordHowe))
        #expect(halfHour.startShift == hour / 2)
        #expect(halfHour.startUTCOffset == 39_600)
        let repeated = try #require(weekly([sunday], 1, 30).occurrence(on: day(2026, 11, 1), in: newYork))
        #expect(repeated.startShift == 0)
        #expect(repeated.startUTCOffset == -4 * 3600)
    }

    @Test("The duration is elapsed time: a window across a change of offset ends at a different clock time")
    func elapsedDuration() throws {
        // Saturday 20:00 EDT for 12 hours ends Sunday 07:00 EST, not 08:00.
        let saturdayEvening = try #require(weekly([saturday], 20).occurrence(on: day(2026, 10, 31), in: newYork))
        #expect(saturdayEvening.startsAt == utc("2026-11-01T00:00:00Z"))
        #expect(saturdayEvening.endsAt == utc("2026-11-01T12:00:00Z"))
        #expect(newYork.secondsFromGMT(for: saturdayEvening.endsAt) == -5 * 3600)
        // 48 hours from Saturday 07:00 BST end Monday 06:00 GMT.
        let long = try #require(weekly([saturday], 7, hours: 48).occurrence(on: day(2026, 10, 24), in: london))
        #expect(long.endsAt == utc("2026-10-26T06:00:00Z"))
    }

    @Test("The latest occurrence is the one that started last at or before now, whichever days are chosen")
    func latest() {
        let fridays = weekly([friday], 7)
        #expect(fridays.latestOccurrence(startingAtOrBefore: utc("2026-10-23T05:59:59Z"), in: london)?.day == day(2026, 10, 16))
        #expect(fridays.latestOccurrence(startingAtOrBefore: utc("2026-10-23T06:00:00Z"), in: london)?.day == day(2026, 10, 23))
        #expect(fridays.latestOccurrence(startingAtOrBefore: utc("2026-10-29T12:00:00Z"), in: london)?.day == day(2026, 10, 23))
        #expect(fridays.latestOccurrence(startingAtOrBefore: utc("2026-10-16T05:59:59Z"), in: london)?.startsAt == utc("2026-10-09T06:00:00Z"))
        let threeDays = weekly([monday, wednesday, friday], 7)
        #expect(threeDays.latestOccurrence(startingAtOrBefore: utc("2026-10-20T15:00:00Z"), in: newYork)?.startsAt == utc("2026-10-19T11:00:00Z"))
        let everyDay = weekly(Set(1...7), 7)
        #expect(everyDay.latestOccurrence(startingAtOrBefore: utc("2026-10-23T05:00:00Z"), in: london)?.day == day(2026, 10, 22))
        // Across the year's end, in GMT.
        #expect(fridays.latestOccurrence(startingAtOrBefore: utc("2027-01-01T05:00:00Z"), in: london)?.startsAt == utc("2026-12-25T07:00:00Z"))
    }

    @Test("Around changes of offset, the latest occurrence follows the moved or first start")
    func latestAroundChanges() {
        let skipped = weekly([sunday], 2, 30)
        #expect(skipped.latestOccurrence(startingAtOrBefore: utc("2026-03-08T07:29:59Z"), in: newYork)?.startsAt == utc("2026-03-01T07:30:00Z"))
        #expect(skipped.latestOccurrence(startingAtOrBefore: utc("2026-03-08T07:30:00Z"), in: newYork)?.day == day(2026, 3, 8))
        let repeated = weekly([sunday], 1, 30)
        #expect(repeated.latestOccurrence(startingAtOrBefore: utc("2026-11-01T05:29:59Z"), in: newYork)?.startsAt == utc("2026-10-25T05:30:00Z"))
        // At the second 01:30, the day's occurrence is still the first one.
        #expect(repeated.latestOccurrence(startingAtOrBefore: utc("2026-11-01T06:30:00Z"), in: newYork)?.startsAt == utc("2026-11-01T05:30:00Z"))
    }

    @Test("The first occurrence after now skips the days up to the handled one")
    func next() {
        let fridays = weekly([friday], 7)
        let beforeStart = utc("2026-10-23T05:00:00Z")
        #expect(fridays.firstOccurrence(startingAfter: beforeStart, onDayAfter: nil, in: london)?.day == day(2026, 10, 23))
        #expect(fridays.firstOccurrence(startingAfter: beforeStart, onDayAfter: day(2026, 10, 16), in: london)?.day == day(2026, 10, 23))
        // Friday was handled (the clock went back after it started).
        #expect(fridays.firstOccurrence(startingAfter: beforeStart, onDayAfter: day(2026, 10, 23), in: london)?.day == day(2026, 10, 30))
        // After the start, the next one is a week later, handled or not.
        #expect(fridays.firstOccurrence(startingAfter: utc("2026-10-23T07:00:00Z"), onDayAfter: day(2026, 10, 16), in: london)?.day == day(2026, 10, 30))
        // A record three weeks ahead of the clock.
        #expect(fridays.firstOccurrence(startingAfter: beforeStart, onDayAfter: day(2026, 11, 13), in: london)?.startsAt == utc("2026-11-20T07:00:00Z"))
    }

    @Test("Across time zones the same instant has different occurrences, and the handled day still counts")
    func travel() {
        let fridays = weekly([friday], 7)
        let now = utc("2026-10-23T09:00:00Z")
        #expect(fridays.latestOccurrence(startingAtOrBefore: now, in: london)?.startsAt == utc("2026-10-23T06:00:00Z"))
        #expect(fridays.latestOccurrence(startingAtOrBefore: now, in: newYork)?.startsAt == utc("2026-10-16T11:00:00Z"))
        #expect(fridays.firstOccurrence(startingAfter: now, onDayAfter: nil, in: newYork)?.startsAt == utc("2026-10-23T11:00:00Z"))
        // Started in London on Friday, now in New York before 07:00 the same Friday.
        #expect(fridays.firstOccurrence(startingAfter: now, onDayAfter: day(2026, 10, 23), in: newYork)?.startsAt == utc("2026-10-30T11:00:00Z"))

        // Tokyo to Honolulu repeats Friday: handled in Tokyo, it does not come again.
        let inHonolulu = utc("2026-10-23T15:00:00Z")
        #expect(LocalDay(containing: inHonolulu, in: honolulu) == day(2026, 10, 23))
        #expect(fridays.firstOccurrence(startingAfter: inHonolulu, onDayAfter: nil, in: honolulu)?.startsAt == utc("2026-10-23T17:00:00Z"))
        #expect(fridays.firstOccurrence(startingAfter: inHonolulu, onDayAfter: day(2026, 10, 23), in: honolulu)?.startsAt == utc("2026-10-30T17:00:00Z"))

        // Honolulu to Tokyo: Saturday comes five hours after Friday's start.
        let fridaysAndSaturdays = weekly([friday, saturday], 7)
        let inTokyo = utc("2026-10-23T20:00:00Z")
        #expect(fridaysAndSaturdays.firstOccurrence(startingAfter: inTokyo, onDayAfter: day(2026, 10, 23), in: tokyo)?.startsAt == utc("2026-10-23T22:00:00Z"))
    }

    @Test("A pattern that is not valid, or a time that is not finite, has no occurrences")
    func nothingWhenInvalid() {
        let noDays = weekly([], 7)
        let now = utc("2026-10-23T09:00:00Z")
        #expect(noDays.occurrence(on: day(2026, 10, 23), in: london) == nil)
        #expect(noDays.latestOccurrence(startingAtOrBefore: now, in: london) == nil)
        #expect(noDays.firstOccurrence(startingAfter: now, onDayAfter: nil, in: london) == nil)
        #expect(weekly([friday], 7, hours: 49).occurrence(on: day(2026, 10, 23), in: london) == nil)
        let infinite = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(weekly([friday], 7).latestOccurrence(startingAtOrBefore: infinite, in: london) == nil)
        #expect(weekly([friday], 7).firstOccurrence(startingAfter: infinite, onDayAfter: nil, in: london) == nil)
    }
}

@Suite("Weekly full charge: pattern")
struct WeeklyPatternTests {
    @Test("Durations are whole hours from 1 to 48, 12 by default")
    func durations() {
        #expect(WeeklyFullChargePattern.durationHoursRange == 1...48)
        #expect(WeeklyFullChargePattern.defaultDurationHours == 12)
        #expect(weekly([friday], 7, hours: 1).issues.isEmpty)
        #expect(weekly([friday], 7, hours: 48).issues.isEmpty)
        #expect(weekly([friday], 7, hours: 12).duration == 12 * hour)
    }

    @Test("A pattern needs a day, days 1–7, a time of day, and a duration of 1–48 hours")
    func issues() {
        #expect(weekly(Set(1...7), 23, 59).issues.isEmpty)
        #expect(weekly([], 7).issues == [.noWeekday])
        #expect(weekly([0], 7).issues == [.weekdayOutOfRange])
        #expect(weekly([friday, 8], 7).issues == [.weekdayOutOfRange])
        #expect(weekly([friday], 24).issues == [.timeOutOfRange])
        #expect(weekly([friday], -1).issues == [.timeOutOfRange])
        #expect(weekly([friday], 7, 60).issues == [.timeOutOfRange])
        #expect(weekly([friday], 7, hours: 0).issues == [.durationOutOfRange])
        #expect(weekly([friday], 7, hours: 49).issues == [.durationOutOfRange])
        #expect(weekly([], 24, hours: 0).issues == [.noWeekday, .timeOutOfRange, .durationOutOfRange])
        #expect(WeeklyFullChargeIssue.durationOutOfRange.description == "The duration must be 1–48 hours.")
    }
}
