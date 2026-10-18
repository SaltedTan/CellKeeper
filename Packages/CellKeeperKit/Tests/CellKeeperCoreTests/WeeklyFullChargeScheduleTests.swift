import CellKeeperCore
import Foundation
import Testing

// Expected instants are computed by hand from the zones' published offsets
// and written in UTC, as in WeeklyFullChargeOccurrenceTests.

private let hour: TimeInterval = 3600
private let london = TimeZone(identifier: "Europe/London")!
private let apia = TimeZone(identifier: "Pacific/Apia")!
private let friday = 6, saturday = 7

private func utc(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> LocalDay {
    LocalDay(year: year, month: month, day: day)!
}

/// Fridays at 07:00 for 12 hours: in London in October 2026 (BST), from
/// 06:00Z to 18:00Z.
private let fridays = WeeklyFullChargePattern(weekdays: [friday], hour: 7, minute: 0, durationHours: 12)

/// A schedule whose record is the occurrence of `handledDay`.
private func schedule(_ pattern: WeeklyFullChargePattern = fridays, handled handledDay: LocalDay, in timeZone: TimeZone = london) -> WeeklyFullChargeSchedule {
    let occurrence = pattern.occurrence(on: handledDay, in: timeZone)!
    return WeeklyFullChargeSchedule(pattern: pattern, handled: WeeklyFullChargeRecord(occurrence, result: .started))
}

/// The policy input at `now` with a reading taken then.
private func inputAt(_ now: Date, source: PowerSource = .externalPower, settings: ChargingSettings = .default) -> PolicyInput {
    input(snapshot(percent: 70, source: source, at: now), settings: settings, now: now)
}

@Suite("Weekly full charge: check")
struct WeeklyFullChargeCheckTests {
    let armed = schedule(handled: day(2026, 10, 16))
    var friday23: WeeklyFullChargeOccurrence { fridays.occurrence(on: day(2026, 10, 23), in: london)! }

    @Test("Before its start nothing is due; from its start it starts, with the time left to its end")
    func window() {
        #expect(armed.check(input: inputAt(utc("2026-10-23T05:59:59Z")), timeZone: london) == .nothingDue)
        #expect(armed.check(input: inputAt(utc("2026-10-23T06:00:00Z")), timeZone: london) == .start(friday23, remaining: 12 * hour))
        #expect(armed.check(input: inputAt(utc("2026-10-23T17:00:00Z")), timeZone: london) == .start(friday23, remaining: hour))
    }

    @Test("At and after its end it has passed, until a later occurrence starts", arguments: ["2026-10-23T18:00:00Z", "2026-10-29T12:00:00Z"])
    func passed(at text: String) {
        #expect(armed.check(input: inputAt(utc(text)), timeZone: london) == .passed(friday23))
    }

    @Test("It waits on the one-shot schedule's own conditions")
    func waits() {
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        let start = utc("2026-10-23T06:00:00Z")
        #expect(armed.check(input: inputAt(start, source: .battery), timeZone: london) == .waiting(friday23, .onBattery))
        #expect(armed.check(input: inputAt(start, settings: off), timeZone: london) == .waiting(friday23, .managementOff))
        #expect(armed.check(input: input(nil, now: start), timeZone: london) == .waiting(friday23, .noUsableReading))
    }

    @Test("An occurrence on or before the recorded day never starts or passes again, whatever the clock shows")
    func handled() {
        let started = schedule(handled: day(2026, 10, 23))
        for text in ["2026-10-23T06:00:00Z", "2026-10-23T12:00:00Z", "2026-10-23T18:00:00Z", "2026-10-16T12:00:00Z", "2026-10-02T06:30:00Z"] {
            #expect(started.check(input: inputAt(utc(text)), timeZone: london) == .nothingDue, "at \(text)")
        }
        // London is on GMT by then: 08:00Z is an hour after the start.
        #expect(started.check(input: inputAt(utc("2026-10-30T08:00:00Z")), timeZone: london) == .start(fridays.occurrence(on: day(2026, 10, 30), in: london)!, remaining: 11 * hour))
    }

    @Test("Only the latest occurrence counts: one superseded by a later start is never due")
    func latestOnly() {
        // Asleep from Thursday to the next Saturday: Friday the 23rd passed and
        // Friday the 30th has started; only the 30th is due.
        let everyDay = WeeklyFullChargePattern(weekdays: Set(1...7), hour: 7, minute: 0, durationHours: 48)
        let armed = schedule(everyDay, handled: day(2026, 10, 21))
        let now = utc("2026-10-31T12:00:00Z")
        let saturday31 = everyDay.occurrence(on: day(2026, 10, 31), in: london)!
        #expect(armed.check(input: inputAt(now), timeZone: london) == .start(saturday31, remaining: saturday31.endsAt.timeIntervalSince(now)))
    }

    @Test("The next occurrence is strictly after now and after the record; a due one is never next")
    func next() {
        #expect(armed.next(after: utc("2026-10-23T05:00:00Z"), in: london)?.day == day(2026, 10, 23))
        #expect(armed.next(after: utc("2026-10-23T06:00:00Z"), in: london)?.day == day(2026, 10, 30))
        #expect(schedule(handled: day(2026, 10, 23)).next(after: utc("2026-10-23T05:00:00Z"), in: london)?.day == day(2026, 10, 30))
    }
}

@Suite("Weekly full charge: saving counts from the save")
struct WeeklyFullChargeSavingTests {
    @Test("Saved before today's start, today's occurrence is the next and can start")
    func beforeStart() throws {
        let now = utc("2026-10-23T05:00:00Z")
        let saved = try WeeklyFullChargeSchedule.saving(fridays, handledAtLeast: nil, now: now, timeZone: london)
        #expect(saved.handled.day == day(2026, 10, 16))
        #expect(saved.handled.result == .beforeSave)
        #expect(saved.handled.startsAt == utc("2026-10-16T06:00:00Z"))
        #expect(saved.handled.utcOffset == 3600)
        #expect(saved.check(input: inputAt(utc("2026-10-23T06:00:00Z")), timeZone: london) == .start(fridays.occurrence(on: day(2026, 10, 23), in: london)!, remaining: 12 * hour))
    }

    @Test("Saved inside today's window, today's occurrence began before the save and never starts")
    func insideWindow() throws {
        let now = utc("2026-10-23T08:00:00Z")
        let saved = try WeeklyFullChargeSchedule.saving(fridays, handledAtLeast: nil, now: now, timeZone: london)
        #expect(saved.handled.day == day(2026, 10, 23))
        #expect(saved.check(input: inputAt(now), timeZone: london) == .nothingDue)
        #expect(saved.next(after: now, in: london)?.day == day(2026, 10, 30))
    }

    @Test("A save never makes a handled day eligible again, also with another time")
    func neverLowers() throws {
        // Friday's 07:00 started; the time is changed to 08:00 at 07:30.
        let started = schedule(handled: day(2026, 10, 23)).handled
        var later = fridays
        later.hour = 8
        let now = utc("2026-10-23T06:30:00Z")
        let saved = try WeeklyFullChargeSchedule.saving(later, handledAtLeast: started, now: now, timeZone: london)
        #expect(saved.handled == started)
        #expect(saved.check(input: inputAt(utc("2026-10-23T07:00:00Z")), timeZone: london) == .nothingDue)
    }

    @Test("A pattern that is not valid is refused")
    func invalid() {
        #expect(throws: WeeklyFullChargeError.invalid([.noWeekday])) {
            try WeeklyFullChargeSchedule.saving(WeeklyFullChargePattern(weekdays: [], hour: 7, minute: 0, durationHours: 12), handledAtLeast: nil, now: utc("2026-10-23T05:00:00Z"), timeZone: london)
        }
    }
}

/// Apia went from UTC−10 to UTC+14 at 2011-12-30 10:00Z, skipping Friday the
/// 30th; nominal 07:00 on the 30th and the 31st both start at 17:00Z.
@Suite("Weekly full charge: a skipped day, checked")
struct WeeklyFullChargeSkippedDayCheckTests {
    let fridaysAndSaturdays = WeeklyFullChargePattern(weekdays: [friday, saturday], hour: 7, minute: 0, durationHours: 12)
    let apiaFridays = WeeklyFullChargePattern(weekdays: [friday], hour: 7, minute: 0, durationHours: 12)

    @Test("Of the two that start together, Saturday the 31st starts, once, however often it is checked")
    func repeatedChecks() throws {
        var armed = schedule(fridaysAndSaturdays, handled: day(2011, 12, 24), in: apia)
        let start = utc("2011-12-30T17:00:00Z")
        guard case .start(let due, _) = armed.check(input: inputAt(start), timeZone: apia) else {
            Issue.record("Expected a start at the shared start")
            return
        }
        #expect(due.day == day(2011, 12, 31))
        armed.handled = WeeklyFullChargeRecord(due, result: .started)
        for offset in [0.0, 60, hour, 11 * hour, 12 * hour, 20 * hour] {
            #expect(armed.check(input: inputAt(start.addingTimeInterval(offset)), timeZone: apia) == .nothingDue, "at +\(offset) s")
        }
        // The skipped Friday never comes after the 31st.
        #expect(armed.next(after: start, in: apia)?.startsAt == utc("2012-01-05T17:00:00Z"))
    }

    @Test("Fridays only: the skipped Friday keeps its nominal day after its shifted start, as the occurrence that starts and the one recorded")
    func fridayOnly() throws {
        var armed = schedule(apiaFridays, handled: day(2011, 12, 23), in: apia)
        // An hour after its start (Saturday 08:00 local).
        let now = utc("2011-12-30T18:00:00Z")
        #expect(apiaFridays.latestOccurrence(startingAtOrBefore: now, in: apia)?.day == day(2011, 12, 30))
        #expect(apiaFridays.firstOccurrence(startingAfter: utc("2011-12-30T09:00:00Z"), onDayAfter: day(2011, 12, 23), in: apia)?.day == day(2011, 12, 30))
        guard case .start(let due, let remaining) = armed.check(input: inputAt(now), timeZone: apia) else {
            Issue.record("Expected the skipped Friday to start")
            return
        }
        #expect(due.day == day(2011, 12, 30))
        #expect(due.startsAt == utc("2011-12-30T17:00:00Z"))
        #expect(remaining == 11 * hour)
        armed.handled = WeeklyFullChargeRecord(due, result: .started)
        #expect(armed.check(input: inputAt(now), timeZone: apia) == .nothingDue)
        #expect(armed.next(after: now, in: apia)?.day == day(2012, 1, 6))
    }

    @Test("Saved just before or just after the shared start, the next is the 31st or the following Friday")
    func savingAroundTheSkip() throws {
        let before = try WeeklyFullChargeSchedule.saving(fridaysAndSaturdays, handledAtLeast: nil, now: utc("2011-12-30T16:00:00Z"), timeZone: apia)
        #expect(before.handled.day == day(2011, 12, 24))
        #expect(before.next(after: utc("2011-12-30T16:00:00Z"), in: apia)?.day == day(2011, 12, 31))
        let after = try WeeklyFullChargeSchedule.saving(fridaysAndSaturdays, handledAtLeast: nil, now: utc("2011-12-30T18:00:00Z"), timeZone: apia)
        #expect(after.handled.day == day(2011, 12, 31))
        #expect(after.check(input: inputAt(utc("2011-12-30T18:00:00Z")), timeZone: apia) == .nothingDue)
        #expect(after.next(after: utc("2011-12-30T18:00:00Z"), in: apia)?.startsAt == utc("2012-01-05T17:00:00Z"))
    }
}

/// A storage whose writes can be dropped, or accepted while their read-back
/// fails, as a failing `UserDefaults` might.
final class FlakyStorage: KeyValueStorage, @unchecked Sendable {
    enum Mode {
        case working
        /// Writes and removals change nothing.
        case droppingWrites
        /// Writes and removals take effect, but reads return nothing.
        case failingReads
    }

    private let lock = NSLock()
    private let base = InMemoryStorage()
    private var mode = Mode.working

    func set(mode newMode: Mode) {
        lock.withLock { mode = newMode }
    }

    private var current: Mode { lock.withLock { mode } }

    func data(forKey key: String) -> Data? { current == .failingReads ? nil : base.data(forKey: key) }
    func string(forKey key: String) -> String? { current == .failingReads ? nil : base.string(forKey: key) }
    func object(forKey key: String) -> Any? { current == .failingReads ? nil : base.object(forKey: key) }

    func set(_ value: Any?, forKey key: String) {
        guard current != .droppingWrites else { return }
        base.set(value, forKey: key)
    }
}

@Suite("Weekly full charge: store")
struct WeeklyFullChargeStoreTests {
    let storage = InMemoryStorage()
    var store: WeeklyFullChargeStore { WeeklyFullChargeStore(defaults: storage) }
    let saved = schedule(handled: day(2026, 10, 16))

    /// A stored record with `changes` (each a JSON literal) made to an
    /// otherwise valid one.
    private func store(_ changes: [String: String]) -> WeeklyFullChargeLoad {
        var handled: [String: Any] = ["year": 2026, "month": 10, "day": 16, "startsAt": 1_792_130_400.0, "utcOffset": 3600, "result": "started"]
        var record: [String: Any] = ["weekdays": [6], "hour": 7, "minute": 0, "durationHours": 12]
        for (key, literal) in changes {
            let value = try! JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)
            if key.hasPrefix("handled.") {
                handled[String(key.dropFirst("handled.".count))] = value
            } else {
                record[key] = value
            }
        }
        record["handled"] = handled
        storage.set(try! JSONSerialization.data(withJSONObject: record), forKey: WeeklyFullChargeStore.key)
        return WeeklyFullChargeStore(defaults: storage).loadWeeklyFullCharge()
    }

    @Test("Its own key, weeklyFullCharge.v1, and nothing stored is none")
    func key() {
        #expect(WeeklyFullChargeStore.key == "weeklyFullCharge.v1")
        #expect(store.loadWeeklyFullCharge() == .none)
    }

    @Test("A saved schedule reads back as saved, under its key only, and removing leaves nothing")
    func roundTrip() throws {
        try store.saveWeeklyFullCharge(saved)
        #expect(store.loadWeeklyFullCharge() == .schedule(saved))
        #expect(storage.object(forKey: FullChargeScheduleStore.key) == nil)
        #expect(storage.object(forKey: SettingsStore.chargingSettingsKey) == nil)
        try store.removeWeeklyFullCharge()
        #expect(store.loadWeeklyFullCharge() == .none)
    }

    @Test("A valid hand-written record loads; unknown keys are ignored")
    func handWritten() {
        #expect(store(["note": "\"ignored\"", "handled.extra": "true"]) == .schedule(saved))
    }

    @Test("Every field is required and checked; a value that is not a record cannot be used", arguments: [
        (["weekdays": "[]"], "Choose at least one day."),
        (["weekdays": "[8]"], "The days are not valid."),
        (["weekdays": "[6, 6]"], "it repeats a day"),
        (["hour": "24"], "The start time is not valid."),
        (["minute": "60"], "The start time is not valid."),
        (["durationHours": "0"], "The duration must be 1–48 hours."),
        (["durationHours": "49"], "The duration must be 1–48 hours."),
        (["hour": "7.5"], "it could not be read"),
        (["handled.month": "2", "handled.day": "30"], "its record of the last weekly full charge is not valid"),
        (["handled.utcOffset": "68400"], "its record of the last weekly full charge is not valid"),
        (["handled.result": "\"skipped\""], "its record of the last weekly full charge is not valid"),
        (["handled.year": "\"2026\""], "it could not be read"),
    ] as [([String: String], String)])
    func invalid(changes: [String: String], reason: String) {
        #expect(store(changes) == .unusable(reason: reason))
    }

    @Test("Extreme numbers in every numeric field are refused, never trapping", arguments: [
        (["handled.utcOffset": "-9223372036854775808"], "its record of the last weekly full charge is not valid"),
        (["handled.utcOffset": "9223372036854775807"], "its record of the last weekly full charge is not valid"),
        (["handled.utcOffset": "64801"], "its record of the last weekly full charge is not valid"),
        (["handled.startsAt": "1e300"], "its record of the last weekly full charge is not valid"),
        (["handled.startsAt": "-1e300"], "its record of the last weekly full charge is not valid"),
        (["handled.year": "-9223372036854775808"], "its record of the last weekly full charge is not valid"),
        (["handled.year": "9223372036854775807"], "its record of the last weekly full charge is not valid"),
        (["handled.month": "-9223372036854775808"], "its record of the last weekly full charge is not valid"),
        (["handled.day": "9223372036854775807"], "its record of the last weekly full charge is not valid"),
        (["hour": "-9223372036854775808"], "The start time is not valid."),
        (["hour": "9223372036854775807"], "The start time is not valid."),
        (["minute": "-9223372036854775808"], "The start time is not valid."),
        (["minute": "9223372036854775807"], "The start time is not valid."),
        (["durationHours": "-9223372036854775808"], "The duration must be 1–48 hours."),
        (["durationHours": "9223372036854775807"], "The duration must be 1–48 hours."),
        (["weekdays": "[-9223372036854775808]"], "The days are not valid."),
        (["weekdays": "[9223372036854775807]"], "The days are not valid."),
    ] as [([String: String], String)])
    func extremes(changes: [String: String], reason: String) {
        #expect(store(changes) == .unusable(reason: reason))
    }

    @Test("The offsets ±18 hours, and starts at the ends of years 1 and 9999, are accepted")
    func bounds() throws {
        for offset in ["-64800", "64800"] {
            guard case .schedule(let loaded) = store(["handled.utcOffset": offset]) else {
                Issue.record("offset \(offset) refused")
                continue
            }
            #expect(loaded.handled.utcOffset == Int(offset))
        }
        #expect(store(["handled.startsAt": "-62135596800"]) != .unusable(reason: "its record of the last weekly full charge is not valid"))
        #expect(store(["handled.startsAt": "253402300799"]) != .unusable(reason: "its record of the last weekly full charge is not valid"))
        #expect(store(["handled.startsAt": "253402300800"]) == .unusable(reason: "its record of the last weekly full charge is not valid"))
    }

    @Test("A missing field, a value that is not JSON, and one of another type cannot be used")
    func unreadable() {
        storage.set(try! JSONSerialization.data(withJSONObject: ["weekdays": [6], "hour": 7, "minute": 0, "durationHours": 12]), forKey: WeeklyFullChargeStore.key)
        #expect(store.loadWeeklyFullCharge() == .unusable(reason: "it could not be read"))
        storage.set(Data("not json".utf8), forKey: WeeklyFullChargeStore.key)
        #expect(store.loadWeeklyFullCharge() == .unusable(reason: "it could not be read"))
        storage.set("a string", forKey: WeeklyFullChargeStore.key)
        #expect(store.loadWeeklyFullCharge() == .unusable(reason: "it is not a weekly schedule record"))
    }

    @Test("A write that is dropped, or whose read-back fails, throws; so does a removal that is dropped")
    func verifiedWrites() throws {
        let flaky = FlakyStorage()
        let store = WeeklyFullChargeStore(defaults: flaky)
        flaky.set(mode: .droppingWrites)
        #expect(throws: WeeklyFullChargeStoreError.notReadBack) { try store.saveWeeklyFullCharge(saved) }
        flaky.set(mode: .failingReads)
        #expect(throws: WeeklyFullChargeStoreError.notReadBack) { try store.saveWeeklyFullCharge(saved) }
        // The write was accepted all the same: it is there once reads work.
        flaky.set(mode: .working)
        #expect(store.loadWeeklyFullCharge() == .schedule(saved))
        flaky.set(mode: .droppingWrites)
        #expect(throws: WeeklyFullChargeStoreError.notRemoved) { try store.removeWeeklyFullCharge() }
        flaky.set(mode: .working)
        #expect(store.loadWeeklyFullCharge() == .schedule(saved))
    }
}
