import CellKeeperCore
import Foundation

/// What Settings' weekly full charge editor holds: the days, the start as an
/// hour and a minute, and the duration.
///
/// The start stays an hour and a minute. It is never turned into a moment in
/// the Mac's time zone, where a skipped hour (02:30 on New York's
/// 2026-03-08) or a time zone change would move it, so saving with the time
/// unchanged writes the same hour and minute. A time picker sees it as that
/// hour and minute on a fixed day in GMT (``pickerTime``), shown in
/// ``pickerTimeZone`` with ``pickerCalendar``, both ways.
public struct WeeklyFullChargeDraft: Sendable, Equatable {
    public var weekdays: Set<Int>
    public var hour: Int
    public var minute: Int
    public var durationHours: Int

    public init(weekdays: Set<Int> = [], hour: Int = 7, minute: Int = 0, durationHours: Int = WeeklyFullChargePattern.defaultDurationHours) {
        self.weekdays = weekdays
        self.hour = hour
        self.minute = minute
        self.durationHours = durationHours
    }

    public init(_ pattern: WeeklyFullChargePattern) {
        self.init(weekdays: pattern.weekdays, hour: pattern.hour, minute: pattern.minute, durationHours: pattern.durationHours)
    }

    public var pattern: WeeklyFullChargePattern {
        WeeklyFullChargePattern(weekdays: weekdays, hour: hour, minute: minute, durationHours: durationHours)
    }

    /// GMT, which never changes its offset: the time zone a picker for the
    /// start is shown in.
    public static let pickerTimeZone = TimeZone(secondsFromGMT: 0)!

    /// A Gregorian calendar in ``pickerTimeZone``, for the picker and for
    /// reading its value.
    public static let pickerCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pickerTimeZone
        return calendar
    }()

    /// 2001-01-01 00:00 GMT, a day on which nothing changes the offset.
    static let pickerDay = Date(timeIntervalSinceReferenceDate: 0)

    /// The start as a time picker's value: the hour and minute on 2001-01-01
    /// in GMT. Setting it keeps only the hour and minute it shows there.
    public var pickerTime: Date {
        get {
            Self.pickerDay.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        }
        set {
            let parts = Self.pickerCalendar.dateComponents([.hour, .minute], from: newValue)
            guard let newHour = parts.hour, let newMinute = parts.minute else { return }
            hour = newHour
            minute = newMinute
        }
    }
}
