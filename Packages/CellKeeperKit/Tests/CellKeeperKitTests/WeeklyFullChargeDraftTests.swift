import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

private let newYork = TimeZone(identifier: "America/New_York")!
private let london = TimeZone(identifier: "Europe/London")!

private func utc(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

/// Sundays at 02:30 for 12 hours: on 2026-03-08 New York skips 02:00–02:59.
private let sundaysAt0230 = WeeklyFullChargePattern(weekdays: [1], hour: 2, minute: 30, durationHours: 12)

@Suite("Weekly full charge editor's draft")
struct WeeklyFullChargeDraftTests {
    @Test("The hazard is real: through a date in New York on its skipped day, 02:30 does not come back as 02:30")
    func hazard() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let noon = utc("2026-03-08T16:00:00Z")
        let moved = try #require(calendar.date(bySettingHour: 2, minute: 30, second: 0, of: noon))
        let parts = calendar.dateComponents([.hour, .minute], from: moved)
        #expect(!(parts.hour == 2 && parts.minute == 30))
    }

    @Test("Every hour and minute goes through the picker's value and back unchanged")
    func roundTrip() {
        for hour in 0..<24 {
            for minute in 0..<60 {
                var draft = WeeklyFullChargeDraft()
                draft.pickerTime = WeeklyFullChargeDraft(hour: hour, minute: minute).pickerTime
                #expect(draft.hour == hour && draft.minute == minute, "\(hour):\(minute)")
            }
        }
    }

    @Test("The picker's value is that time on 2001-01-01 in GMT, whatever the Mac's time zone")
    func fixedDay() {
        #expect(WeeklyFullChargeDraft(hour: 2, minute: 30).pickerTime == utc("2001-01-01T02:30:00Z"))
        #expect(WeeklyFullChargeDraft(hour: 23, minute: 59).pickerTime == utc("2001-01-01T23:59:00Z"))
        #expect(WeeklyFullChargeDraft.pickerTimeZone.secondsFromGMT(for: utc("2001-01-01T00:00:00Z")) == 0)
        #expect(WeeklyFullChargeDraft.pickerCalendar.timeZone == WeeklyFullChargeDraft.pickerTimeZone)
    }

    @Test("A picked value keeps only the hour and minute it shows in GMT, from any day, with any seconds")
    func pickedValue() {
        var draft = WeeklyFullChargeDraft()
        draft.pickerTime = utc("2026-03-08T02:30:45Z")
        #expect(draft.hour == 2 && draft.minute == 30)
        draft.pickerTime = utc("1999-12-31T23:05:00Z")
        #expect(draft.hour == 23 && draft.minute == 5)
    }

    @Test("A saved 02:30 stays 02:30 when only the duration changes, and an unchanged save writes the same pattern")
    func gapDay() {
        var draft = WeeklyFullChargeDraft(sundaysAt0230)
        #expect(draft.pattern == sundaysAt0230)
        // The picker sets back the value it shows.
        draft.pickerTime = draft.pickerTime
        #expect(draft.pattern == sundaysAt0230)
        draft.durationHours = 6
        #expect(draft.pattern == WeeklyFullChargePattern(weekdays: [1], hour: 2, minute: 30, durationHours: 6))
        for pattern in [WeeklyFullChargePattern(weekdays: [2, 6], hour: 0, minute: 0, durationHours: 1), WeeklyFullChargePattern(weekdays: Set(1...7), hour: 23, minute: 59, durationHours: 48)] {
            #expect(WeeklyFullChargeDraft(pattern).pattern == pattern)
        }
    }

    @Test("The draft carries no time zone: after travel the same pattern is still read as local time where the Mac is")
    func travel() throws {
        let fridays = WeeklyFullChargeDraft(WeeklyFullChargePattern(weekdays: [6], hour: 7, minute: 0, durationHours: 12)).pattern
        let day = try #require(LocalDay(year: 2026, month: 10, day: 23))
        #expect(fridays.occurrence(on: day, in: london)?.startsAt == utc("2026-10-23T06:00:00Z"))
        #expect(fridays.occurrence(on: day, in: newYork)?.startsAt == utc("2026-10-23T11:00:00Z"))
    }
}
