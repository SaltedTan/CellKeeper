import Foundation

/// What a ``FullChargeScheduleStoring`` found.
public enum FullChargeScheduleLoad: Sendable, Equatable {
    /// Nothing is stored.
    case none
    /// A readable schedule with a valid window.
    case schedule(FullChargeSchedule)
    /// Something is stored but it cannot be used; `reason` says why.
    case unusable(reason: String)
}

/// Where the scheduled full charge is kept, apart from ``ChargingSettings``,
/// so that a schedule that cannot be read never affects the settings or
/// Manage charging.
public protocol FullChargeScheduleStoring: Sendable {
    func loadSchedule() -> FullChargeScheduleLoad
    /// Stores a schedule whose window is valid; throws otherwise.
    func saveSchedule(_ schedule: FullChargeSchedule) throws
    func removeSchedule()
}

/// Keeps the scheduled full charge as JSON under its own key in a
/// ``KeyValueStorage`` (`UserDefaults` in the app).
///
/// - The key, `fullChargeSchedule.v1`, is the schema version: a later format
///   is stored under a new key, which this version never reads or removes.
/// - Both endpoints are required (seconds since 1970); unknown keys are
///   ignored. A record without both, or whose window is not finite or not
///   1–48 h, is unusable.
/// - `UserDefaults` persists asynchronously: a removal right before a crash
///   or power loss may not reach the disk, so a schedule that had started
///   may be found again at the next launch.
public final class FullChargeScheduleStore: FullChargeScheduleStoring, @unchecked Sendable {
    public static let key = "fullChargeSchedule.v1"

    private struct Record: Codable {
        var startsAt: Double
        var endsAt: Double
    }

    // `UserDefaults` is thread-safe; the lock serialises access for other
    // storages, such as the tests' in-memory one.
    private let lock = NSLock()
    private let defaults: any KeyValueStorage

    public init(defaults: any KeyValueStorage = UserDefaults.standard) {
        self.defaults = defaults
    }

    public func loadSchedule() -> FullChargeScheduleLoad {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.key) else {
                return .none
            }
            let record: Record
            do {
                record = try JSONDecoder().decode(Record.self, from: data)
            } catch {
                return .unusable(reason: "it could not be read")
            }
            let schedule = FullChargeSchedule(
                startsAt: Date(timeIntervalSince1970: record.startsAt),
                endsAt: Date(timeIntervalSince1970: record.endsAt)
            )
            if let issue = schedule.windowIssues.first {
                return .unusable(reason: issue.description)
            }
            return .schedule(schedule)
        }
    }

    public func saveSchedule(_ schedule: FullChargeSchedule) throws {
        let issues = schedule.windowIssues
        guard issues.isEmpty else { throw FullChargeScheduleError(issues: issues) }
        let data = try JSONEncoder().encode(Record(startsAt: schedule.startsAt.timeIntervalSince1970, endsAt: schedule.endsAt.timeIntervalSince1970))
        lock.withLock {
            defaults.set(data, forKey: Self.key)
        }
    }

    public func removeSchedule() {
        lock.withLock {
            defaults.set(nil, forKey: Self.key)
        }
    }
}
