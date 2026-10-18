import Foundation

/// A calendar day with no time zone: a floating Gregorian date, such as the
/// Friday a weekly full charge belongs to. It identifies an occurrence of a
/// ``WeeklyFullChargePattern`` wherever the Mac is.
public struct LocalDay: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Day arithmetic only. A Gregorian calendar in UTC has no gaps or
    /// repeated times; a time zone enters only through its offsets.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Nil unless the three numbers name a real Gregorian date in years
    /// 1–9999.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let midnight = Self.utc.date(from: DateComponents(year: year, month: month, day: day)),
              Self.utc.dateComponents([.year, .month, .day], from: midnight) == DateComponents(year: year, month: month, day: day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `timeZone`. Nil for a non-finite date.
    public init?(containing date: Date, in timeZone: TimeZone) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let local = date.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: date)))
        self.init(utcMidnightOf: local)
    }

    private init?(utcMidnightOf date: Date) {
        let components = Self.utc.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The start of the day as if it were in UTC: the origin from which its
    /// local times are counted before a time zone's offset is applied.
    var utcMidnight: Date {
        // A valid day always has one; see init.
        Self.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The day `count` days later (earlier if negative). Nil outside years
    /// 1–9999.
    public func adding(days count: Int) -> LocalDay? {
        Self.utc.date(byAdding: .day, value: count, to: utcMidnight).flatMap(LocalDay.init(utcMidnightOf:))
    }

    /// The Gregorian weekday, 1 (Sunday) to 7 (Saturday).
    public var weekday: Int {
        Self.utc.component(.weekday, from: utcMidnight)
    }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// For example "2026-10-23".
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The instant at which this day reaches `hour`:`minute` in `timeZone`,
    /// by RFC 5545's rules for local times (§3.3.5):
    /// - A time that does not exist on this day, because a change of offset
    ///   skips it (the hour clocks go forward), is read with the offset in
    ///   force before the change, so it falls later by the length of the
    ///   skip (02:30 → 03:30).
    /// - A time that occurs twice, because a change of offset repeats it
    ///   (the hour clocks go back), is the first of the two.
    ///
    /// Computed from `timeZone`'s offsets alone, not from `Calendar`'s
    /// matching policies, which do not document these cases (and were seen
    /// moving a time in a 30-minute skip to the next day).
    public func instant(hour: Int, minute: Int, in timeZone: TimeZone) -> Date {
        let local = utcMidnight.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        // Every real offset is within ±14 h, so the instant lies within a
        // day of `local`, and no time zone changes its offset twice in two
        // days: these are the offsets before and after any change near it.
        let before = timeZone.secondsFromGMT(for: local.addingTimeInterval(-86_400))
        let after = timeZone.secondsFromGMT(for: local.addingTimeInterval(86_400))
        // An instant reads as `local` if the offset in force at it is the
        // one it was computed with: none in a skip, two in a repeat.
        let readingAsLocal = [before, after].compactMap { offset -> Date? in
            let instant = local.addingTimeInterval(-TimeInterval(offset))
            return timeZone.secondsFromGMT(for: instant) == offset ? instant : nil
        }
        return readingAsLocal.min() ?? local.addingTimeInterval(-TimeInterval(before))
    }
}

/// A weekly temporary full charge: the days of the week it starts on, the
/// local time it starts at, and how long its window lasts.
///
/// Times are floating local times: "Friday 07:00" is 07:00 on a Friday in
/// whatever time zone the Mac is in when it is checked. Each occurrence
/// belongs to one local day (``LocalDay``), and each day has at most one.
/// The duration is elapsed time, so a daylight-saving change inside a window
/// moves the clock time it ends at.
public struct WeeklyFullChargePattern: Sendable, Equatable {
    /// Gregorian weekdays, 1 (Sunday) to 7 (Saturday).
    public var weekdays: Set<Int>
    public var hour: Int
    public var minute: Int
    /// Whole hours, within ``durationHoursRange``.
    public var durationHours: Int

    /// The bounds of a temporary full charge (research rule R23).
    public static let durationHoursRange = Int(ChargeOverride.minimumDuration / 3600)...Int(ChargeOverride.maximumDuration / 3600)
    public static let defaultDurationHours = Int(ChargeOverride.defaultFullChargeDuration / 3600)

    public init(weekdays: Set<Int>, hour: Int, minute: Int, durationHours: Int) {
        self.weekdays = weekdays
        self.hour = hour
        self.minute = minute
        self.durationHours = durationHours
    }

    /// The window's length in seconds.
    public var duration: TimeInterval {
        TimeInterval(durationHours) * 3600
    }

    /// Problems with the pattern: at least one day, every day 1–7, a time
    /// of day, and a duration within ``durationHoursRange``.
    public var issues: [WeeklyFullChargeIssue] {
        var issues: [WeeklyFullChargeIssue] = []
        if weekdays.isEmpty {
            issues.append(.noWeekday)
        } else if !weekdays.allSatisfy((1...7).contains) {
            issues.append(.weekdayOutOfRange)
        }
        if !(0...23).contains(hour) || !(0...59).contains(minute) {
            issues.append(.timeOutOfRange)
        }
        if !Self.durationHoursRange.contains(durationHours) {
            issues.append(.durationOutOfRange)
        }
        return issues
    }

    /// The occurrence on `day` in `timeZone`, or nil if the pattern is not
    /// valid or does not start on that day of the week.
    public func occurrence(on day: LocalDay, in timeZone: TimeZone) -> WeeklyFullChargeOccurrence? {
        guard issues.isEmpty, weekdays.contains(day.weekday) else { return nil }
        let start = day.instant(hour: hour, minute: minute, in: timeZone)
        let offset = timeZone.secondsFromGMT(for: start)
        let asWritten = day.utcMidnight.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        return WeeklyFullChargeOccurrence(
            day: day,
            startsAt: start,
            endsAt: start.addingTimeInterval(duration),
            startUTCOffset: offset,
            startShift: start.addingTimeInterval(TimeInterval(offset)).timeIntervalSince(asWritten)
        )
    }

    /// The latest occurrence whose start is at or before `now` in
    /// `timeZone`, or nil if the pattern is not valid or `now` not finite.
    /// It is the only occurrence that can still start or pass: an earlier
    /// one started earlier and, with the same duration, ends earlier.
    public func latestOccurrence(startingAtOrBefore now: Date, in timeZone: TimeZone) -> WeeklyFullChargeOccurrence? {
        guard let today = LocalDay(containing: now, in: timeZone) else { return nil }
        // A week back always holds every weekday; a day either side covers
        // a start moved across midnight by a change of offset.
        return occurrences(from: today.adding(days: -8), through: today.adding(days: 1), in: timeZone)
            .filter { $0.startsAt <= now }
            .max { ($0.startsAt, $0.day) < ($1.startsAt, $1.day) }
    }

    /// The first occurrence that starts after `now` in `timeZone` on a day
    /// after `handled` (any day if nil), or nil if the pattern is not valid
    /// or `now` not finite.
    public func firstOccurrence(startingAfter now: Date, onDayAfter handled: LocalDay?, in timeZone: TimeZone) -> WeeklyFullChargeOccurrence? {
        guard let today = LocalDay(containing: now, in: timeZone), let yesterday = today.adding(days: -1) else { return nil }
        let first = handled.flatMap { $0.adding(days: 1) }.map { max($0, yesterday) } ?? yesterday
        // Nine days from yesterday always reach every weekday after today.
        return occurrences(from: first, through: first.adding(days: 9), in: timeZone)
            .filter { $0.startsAt > now }
            .min { ($0.startsAt, $0.day) < ($1.startsAt, $1.day) }
    }

    private func occurrences(from first: LocalDay?, through last: LocalDay?, in timeZone: TimeZone) -> [WeeklyFullChargeOccurrence] {
        guard issues.isEmpty, var day = first, let last else { return [] }
        var found: [WeeklyFullChargeOccurrence] = []
        while day <= last {
            if let occurrence = occurrence(on: day, in: timeZone) {
                found.append(occurrence)
            }
            guard let next = day.adding(days: 1) else { break }
            day = next
        }
        return found
    }
}

/// One occurrence of a ``WeeklyFullChargePattern``: its local day and its
/// window, computed in the time zone current when it was checked.
public struct WeeklyFullChargeOccurrence: Sendable, Equatable {
    /// The local day it belongs to, which identifies it.
    public var day: LocalDay
    public var startsAt: Date
    /// ``startsAt`` plus the pattern's duration, in elapsed time.
    public var endsAt: Date
    /// The offset from UTC in force at the start, in seconds.
    public var startUTCOffset: Int
    /// How much later than the pattern's time it starts, because that time
    /// does not exist on its day (clocks went forward over it); zero
    /// otherwise.
    public var startShift: TimeInterval

    public init(day: LocalDay, startsAt: Date, endsAt: Date, startUTCOffset: Int, startShift: TimeInterval) {
        self.day = day
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.startUTCOffset = startUTCOffset
        self.startShift = startShift
    }

    /// Its window as a one-shot schedule, which is checked by the same rules
    /// (``FullChargeSchedule/check(_:input:)``).
    public var window: FullChargeSchedule {
        FullChargeSchedule(startsAt: startsAt, endsAt: endsAt)
    }
}

/// A problem with a ``WeeklyFullChargePattern``.
public enum WeeklyFullChargeIssue: Sendable, Equatable, CustomStringConvertible {
    case noWeekday
    case weekdayOutOfRange
    case timeOutOfRange
    case durationOutOfRange

    public var description: String {
        switch self {
        case .noWeekday:
            "Choose at least one day."
        case .weekdayOutOfRange:
            "The days are not valid."
        case .timeOutOfRange:
            "The start time is not valid."
        case .durationOutOfRange:
            "The duration must be \(WeeklyFullChargePattern.durationHoursRange.lowerBound)–\(WeeklyFullChargePattern.durationHoursRange.upperBound) hours."
        }
    }
}
