import Foundation

/// What a ``WeeklyFullChargeStoring`` found.
public enum WeeklyFullChargeLoad: Sendable, Equatable {
    /// Nothing is stored.
    case none
    /// A readable, valid weekly schedule with its record.
    case schedule(WeeklyFullChargeSchedule)
    /// Something is stored but it cannot be used; `reason` says why.
    case unusable(reason: String)
}

/// Where the weekly full charge and its record are kept, apart from
/// ``ChargingSettings`` and the one-shot schedule, so that one that cannot
/// be read never affects the settings or Manage charging.
public protocol WeeklyFullChargeStoring: Sendable {
    func loadWeeklyFullCharge() -> WeeklyFullChargeLoad
    /// Stores `schedule` and reads it back; throws unless it reads back as
    /// written.
    func saveWeeklyFullCharge(_ schedule: WeeklyFullChargeSchedule) throws
    /// Removes the stored value and reads back; throws unless nothing is
    /// left.
    func removeWeeklyFullCharge() throws
}

/// A write or removal that did not read back as made.
public enum WeeklyFullChargeStoreError: Error, Sendable, Equatable {
    case notReadBack
    case notRemoved
}

/// Keeps the weekly full charge as JSON under its own key in a
/// ``KeyValueStorage`` (`UserDefaults` in the app).
///
/// - The key, `weeklyFullCharge.v1`, is the schema version: a later format
///   is stored under a new key, which this version never reads or removes.
/// - Every field is required; unknown keys are ignored. A value under the
///   key that is not JSON data, an unreadable record, or one that is not
///   valid (no day or a day outside 1–7, repeated days, a time of day or a
///   duration out of range, a record whose day is not a real date, whose
///   start is not finite, whose offset is beyond ±18 hours, or whose result
///   is unknown) is unusable; only no value at all counts as none.
/// - Writes are read back and compared. That confirms what this process
///   reads, not that `UserDefaults` has reached the disk: after a crash or
///   power loss, the last write may be missing at the next launch.
public final class WeeklyFullChargeStore: WeeklyFullChargeStoring, @unchecked Sendable {
    public static let key = "weeklyFullCharge.v1"
    /// Real offsets are within ±14 hours; anything beyond ±18 is not one.
    static let maximumOffset = 18 * 3600

    private struct Record: Codable {
        struct Handled: Codable {
            var year: Int
            var month: Int
            var day: Int
            /// Seconds since 1970.
            var startsAt: Double
            var utcOffset: Int
            var result: String
        }

        var weekdays: [Int]
        var hour: Int
        var minute: Int
        var durationHours: Int
        var handled: Handled
    }

    // `UserDefaults` is thread-safe; the lock keeps a write and its
    // read-back together, and serialises access for other storages, such as
    // the tests' in-memory one.
    private let lock = NSLock()
    private let defaults: any KeyValueStorage

    public init(defaults: any KeyValueStorage = UserDefaults.standard) {
        self.defaults = defaults
    }

    public func loadWeeklyFullCharge() -> WeeklyFullChargeLoad {
        lock.withLock {
            guard let stored = defaults.object(forKey: Self.key) else {
                return .none
            }
            guard let data = stored as? Data else {
                return .unusable(reason: "it is not a weekly schedule record")
            }
            let record: Record
            do {
                record = try JSONDecoder().decode(Record.self, from: data)
            } catch {
                return .unusable(reason: "it could not be read")
            }
            let weekdays = Set(record.weekdays)
            guard weekdays.count == record.weekdays.count else {
                return .unusable(reason: "it repeats a day")
            }
            let pattern = WeeklyFullChargePattern(weekdays: weekdays, hour: record.hour, minute: record.minute, durationHours: record.durationHours)
            if let issue = pattern.issues.first {
                return .unusable(reason: issue.description)
            }
            let handled = record.handled
            guard let day = LocalDay(year: handled.year, month: handled.month, day: handled.day),
                  handled.startsAt.isFinite,
                  abs(handled.utcOffset) <= Self.maximumOffset,
                  let result = WeeklyFullChargeRecord.Result(rawValue: handled.result)
            else {
                return .unusable(reason: "its record of the last weekly full charge is not valid")
            }
            return .schedule(WeeklyFullChargeSchedule(
                pattern: pattern,
                handled: WeeklyFullChargeRecord(day: day, startsAt: Date(timeIntervalSince1970: handled.startsAt), utcOffset: handled.utcOffset, result: result)
            ))
        }
    }

    public func saveWeeklyFullCharge(_ schedule: WeeklyFullChargeSchedule) throws {
        let issues = schedule.pattern.issues
        guard issues.isEmpty else { throw WeeklyFullChargeError.invalid(issues) }
        let handled = schedule.handled
        let record = Record(
            weekdays: schedule.pattern.weekdays.sorted(),
            hour: schedule.pattern.hour,
            minute: schedule.pattern.minute,
            durationHours: schedule.pattern.durationHours,
            handled: Record.Handled(
                year: handled.day.year,
                month: handled.day.month,
                day: handled.day.day,
                startsAt: handled.startsAt.timeIntervalSince1970,
                utcOffset: handled.utcOffset,
                result: handled.result.rawValue
            )
        )
        let data = try JSONEncoder().encode(record)
        try lock.withLock {
            defaults.set(data, forKey: Self.key)
            guard let readBack = defaults.object(forKey: Self.key) as? Data, readBack == data else {
                throw WeeklyFullChargeStoreError.notReadBack
            }
        }
    }

    public func removeWeeklyFullCharge() throws {
        try lock.withLock {
            defaults.set(nil, forKey: Self.key)
            guard defaults.object(forKey: Self.key) == nil else {
                throw WeeklyFullChargeStoreError.notRemoved
            }
        }
    }
}
