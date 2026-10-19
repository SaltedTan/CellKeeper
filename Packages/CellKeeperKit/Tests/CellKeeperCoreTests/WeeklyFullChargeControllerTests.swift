import CellKeeperCore
import Foundation
import Testing

// Expected instants are computed by hand and written in UTC. London is on
// BST (+1) until 2026-10-25 01:00Z, then GMT; New York on EDT (-4) until
// 2026-11-01 06:00Z; Tokyo +9; Honolulu -10.

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400
private let london = TimeZone(identifier: "Europe/London")!
private let newYork = TimeZone(identifier: "America/New_York")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
private let monday = 2, wednesday = 4, friday = 6

private func utc(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

private func localDay(_ year: Int, _ month: Int, _ day: Int) -> LocalDay {
    LocalDay(year: year, month: month, day: day)!
}

/// Fridays at 07:00 for 12 hours.
private let fridays = WeeklyFullChargePattern(weekdays: [friday], hour: 7, minute: 0, durationHours: 12)

/// The time zone a test's controller reads at each evaluation.
private final class ZoneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var zone: TimeZone

    init(_ zone: TimeZone) { self.zone = zone }

    var current: TimeZone {
        get { lock.withLock { zone } }
        set { lock.withLock { zone = newValue } }
    }
}

/// A controller with the simulated backend, a weekly store over `storage`,
/// and the clock and zone a test moves.
private struct Rig {
    let clock: TestClock
    let zone: ZoneBox
    let storage: any KeyValueStorage & Sendable
    let telemetry: StubTelemetry
    let controller: ChargeController

    init(at start: Date, in timeZone: TimeZone = london, storage: (any KeyValueStorage & Sendable)? = nil, reading: BatterySnapshot = snapshot(percent: 70), scheduleStore: Bool = false, settings: ChargingSettings = .default) {
        let clock = TestClock(start)
        let zone = ZoneBox(timeZone)
        let storage = storage ?? InMemoryStorage()
        let telemetry = StubTelemetry(reading, clock: clock)
        self.clock = clock
        self.zone = zone
        self.storage = storage
        self.telemetry = telemetry
        controller = ChargeController(
            telemetry: telemetry,
            backend: MockChargingBackend(),
            settings: settings,
            scheduleStore: scheduleStore ? FullChargeScheduleStore(defaults: InMemoryStorage()) : nil,
            weeklyStore: WeeklyFullChargeStore(defaults: storage),
            now: { clock.now },
            timeZone: { zone.current },
            uptime: { clock.uptime }
        )
    }

    /// The same storage, read by a new controller: a relaunch.
    func relaunched(in timeZone: TimeZone? = nil) -> Rig {
        Rig(at: clock.now, in: timeZone ?? zone.current, storage: storage)
    }

    /// Lets time pass, as it does while awake or asleep: wall and monotonic
    /// clocks together.
    func move(to date: Date) {
        clock.advance(by: date.timeIntervalSince(clock.now))
    }

    var stored: WeeklyFullChargeLoad {
        WeeklyFullChargeStore(defaults: storage).loadWeeklyFullCharge()
    }
}

/// Expects that the one-shot rules would start a full charge for
/// `occurrence` on what `status` shows: inside its window, with valid
/// settings, management on, and a usable reading on external power. A test
/// that expects no start checks this first, so it cannot pass because a
/// start condition was missing.
private func expectStartConditionsMet(_ status: ControllerStatus, for occurrence: WeeklyFullChargeOccurrence, at now: Date, sourceLocation: SourceLocation = #_sourceLocation) {
    let check = FullChargeSchedule.check(occurrence.window, input: input(status.snapshot, settings: status.settings, now: now))
    guard case .start = check else {
        Issue.record("The start conditions are not met: \(check)", sourceLocation: sourceLocation)
        return
    }
}

@Suite("Weekly full charge: controller")
struct WeeklyFullChargeControllerTests {
    /// Thursday 2026-10-22 12:00Z; Friday's occurrence is 06:00Z–18:00Z.
    let thursday = utc("2026-10-22T12:00:00Z")
    var friday23: WeeklyFullChargeOccurrence { fridays.occurrence(on: localDay(2026, 10, 23), in: london)! }

    // MARK: - Starting

    @Test("It starts a temporary full charge at the first evaluation in an occurrence's window, records it, and shows the next")
    func startsInWindow() async throws {
        let rig = Rig(at: thursday)
        await rig.controller.evaluate(.launch)
        let saved = try await rig.controller.setWeeklyFullCharge(fridays)
        #expect(saved.weeklyFullCharge?.handled.day == localDay(2026, 10, 16))
        #expect(saved.weeklyFullCharge?.handled.result == .beforeSave)
        #expect(saved.weeklyFullChargeNext == friday23)
        #expect(saved.weeklyFullChargeStoreProblem == nil)

        rig.move(to: utc("2026-10-23T05:59:00Z"))
        let before = await rig.controller.evaluate(.periodic)
        #expect(before.activeOverride == nil)
        #expect(before.weeklyFullChargeDue == nil)

        rig.move(to: utc("2026-10-23T06:00:30Z"))
        let started = await rig.controller.evaluate(.periodic)
        let override = try #require(started.activeOverride)
        #expect(override.kind == .fullCharge)
        #expect(override.source == .schedule)
        #expect(override.expiresAtUptime == rig.clock.uptime + 12 * hour - 30)
        #expect(started.decision?.state == .fullChargeOverride)
        #expect(started.weeklyFullChargeOutcome == .started(friday23))
        #expect(started.weeklyFullCharge?.handled == WeeklyFullChargeRecord(friday23, result: .started))
        #expect(started.weeklyFullChargeNext?.startsAt == utc("2026-10-30T07:00:00Z"))
        #expect(rig.stored == .schedule(WeeklyFullChargeSchedule(pattern: fridays, handled: WeeklyFullChargeRecord(friday23, result: .started))))
        #expect(started.events.contains { $0.kind == .override && $0.message.hasPrefix("Weekly full charge started") })
    }

    @Test("Not twice in a run: the clock set back into the window, back before it, three weeks back, or another time zone on the same Friday")
    func notTwiceInRun() async throws {
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(fridays)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        #expect(await rig.controller.evaluate(.periodic).activeOverride != nil)
        await rig.controller.cancelOverride()

        // Still inside the window.
        rig.move(to: utc("2026-10-23T07:00:00Z"))
        let inside = await rig.controller.evaluate(.periodic)
        expectStartConditionsMet(inside, for: friday23, at: rig.clock.now)
        #expect(inside.activeOverride == nil)

        // Set back before the start, then forward into the window again.
        rig.clock.shiftWall(by: -2 * hour)
        let rewound = await rig.controller.evaluate(.clockChanged)
        #expect(rewound.weeklyFullChargeNext?.day == localDay(2026, 10, 30))
        rig.clock.shiftWall(by: 2 * hour)
        let again = await rig.controller.evaluate(.clockChanged)
        expectStartConditionsMet(again, for: friday23, at: rig.clock.now)
        #expect(again.activeOverride == nil)

        // Three weeks back: nothing on or before the recorded Friday starts.
        rig.clock.shiftWall(by: -21 * day)
        let weeksBack = await rig.controller.evaluate(.clockChanged)
        #expect(weeksBack.activeOverride == nil)
        #expect(weeksBack.weeklyFullChargeNext?.day == localDay(2026, 10, 30))
        rig.clock.shiftWall(by: 21 * day)

        // New York at 09:00Z is 05:00 EDT on the same Friday; its 07:00 comes
        // at 11:00Z, and Friday is already handled.
        rig.zone.current = newYork
        let travelled = await rig.controller.evaluate(.clockChanged)
        #expect(travelled.weeklyFullChargeNext?.startsAt == utc("2026-10-30T11:00:00Z"))
        rig.move(to: utc("2026-10-23T11:00:30Z"))
        let newYorkStart = await rig.controller.evaluate(.periodic)
        expectStartConditionsMet(newYorkStart, for: fridays.occurrence(on: localDay(2026, 10, 23), in: newYork)!, at: rig.clock.now)
        #expect(newYorkStart.activeOverride == nil)
        #expect(newYorkStart.weeklyFullChargeDue == nil)
    }

    @Test("Tokyo to Honolulu repeats Friday: started in Tokyo, it does not start in Honolulu")
    func repeatedFriday() async throws {
        let rig = Rig(at: utc("2026-10-22T12:00:00Z"), in: tokyo)
        try await rig.controller.setWeeklyFullCharge(fridays)
        // Friday 07:00 JST.
        rig.move(to: utc("2026-10-22T22:00:30Z"))
        #expect(await rig.controller.evaluate(.periodic).weeklyFullChargeOutcome == .started(fridays.occurrence(on: localDay(2026, 10, 23), in: tokyo)!))
        await rig.controller.cancelOverride()
        rig.zone.current = honolulu
        // Friday 07:00:30 HST.
        rig.move(to: utc("2026-10-23T17:00:30Z"))
        let honoluluFriday = await rig.controller.evaluate(.periodic)
        expectStartConditionsMet(honoluluFriday, for: fridays.occurrence(on: localDay(2026, 10, 23), in: honolulu)!, at: rig.clock.now)
        #expect(honoluluFriday.activeOverride == nil)
        #expect(honoluluFriday.weeklyFullChargeNext?.startsAt == utc("2026-10-30T17:00:00Z"))
    }

    @Test("A relaunch inside a started window does not start it again; inside one not yet started, it starts")
    func relaunch() async throws {
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(fridays)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        #expect(await rig.controller.evaluate(.periodic).activeOverride != nil)
        rig.move(to: utc("2026-10-23T08:00:00Z"))
        let afterStart = rig.relaunched()
        let relaunched = await afterStart.controller.evaluate(.launch)
        expectStartConditionsMet(relaunched, for: friday23, at: afterStart.clock.now)
        #expect(relaunched.activeOverride == nil)
        #expect(relaunched.weeklyFullCharge?.handled.day == localDay(2026, 10, 23))

        // Saved on Thursday, not running at 07:00: a launch at 08:00 starts it,
        // for the time left.
        let notStarted = Rig(at: thursday)
        try await notStarted.controller.setWeeklyFullCharge(fridays)
        notStarted.move(to: utc("2026-10-23T07:00:00Z"))
        let late = notStarted.relaunched()
        let launched = await late.controller.evaluate(.launch)
        #expect(launched.weeklyFullChargeOutcome == .started(friday23))
        #expect(launched.activeOverride?.expiresAtUptime == late.clock.uptime + 11 * hour)
    }

    // MARK: - Missed occurrences and wait evidence

    @Test("A window that passes while nothing runs is recorded and reported once, without a reason it waited, and not replayed")
    func missed() async throws {
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(fridays)
        rig.move(to: utc("2026-10-23T19:00:00Z"))
        let passed = await rig.controller.evaluate(.didWake)
        #expect(passed.weeklyFullChargeOutcome == .windowPassed(friday23, lastWait: nil))
        #expect(passed.weeklyFullCharge?.handled == WeeklyFullChargeRecord(friday23, result: .passed))
        #expect(passed.activeOverride == nil)
        // Set back into the window: not replayed.
        rig.clock.shiftWall(by: -8 * hour)
        let rewound = await rig.controller.evaluate(.clockChanged)
        expectStartConditionsMet(rewound, for: friday23, at: rig.clock.now)
        #expect(rewound.activeOverride == nil)
        #expect(rewound.events.filter { $0.message.contains("the window passed") }.count == 1)
    }

    @Test("Asleep for nine days with a daily schedule: one outcome, naming the latest occurrence")
    func asleepNineDays() async throws {
        let everyDay = WeeklyFullChargePattern(weekdays: Set(1...7), hour: 7, minute: 0, durationHours: 12)
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(everyDay)
        rig.move(to: utc("2026-10-31T20:00:00Z"))
        let woke = await rig.controller.evaluate(.didWake)
        #expect(woke.weeklyFullChargeOutcome == .windowPassed(everyDay.occurrence(on: localDay(2026, 10, 31), in: london)!, lastWait: nil))
        #expect(woke.events.filter { $0.message.contains("the window passed") }.count == 1)
    }

    @Test("Wait evidence belongs to its occurrence: Monday's reason never reaches Wednesday, and survives a rewind before Monday")
    func waitEvidence() async throws {
        let mondaysAndWednesdays = WeeklyFullChargePattern(weekdays: [monday, wednesday], hour: 7, minute: 0, durationHours: 12)
        let sunday = utc("2026-10-18T12:00:00Z")
        let monday19 = mondaysAndWednesdays.occurrence(on: localDay(2026, 10, 19), in: london)!

        let rig = Rig(at: sunday, reading: snapshot(percent: 70, source: .battery))
        try await rig.controller.setWeeklyFullCharge(mondaysAndWednesdays)
        rig.move(to: utc("2026-10-19T06:30:00Z"))
        #expect(await rig.controller.evaluate(.periodic).weeklyFullChargeDue == WeeklyFullChargeDue(occurrence: monday19, wait: .onBattery))
        rig.move(to: utc("2026-10-21T18:30:00Z"))
        let wednesday = await rig.controller.evaluate(.didWake)
        #expect(wednesday.weeklyFullChargeOutcome == .windowPassed(mondaysAndWednesdays.occurrence(on: localDay(2026, 10, 21), in: london)!, lastWait: nil))

        let rewinding = Rig(at: sunday, reading: snapshot(percent: 70, source: .battery))
        try await rewinding.controller.setWeeklyFullCharge(mondaysAndWednesdays)
        rewinding.move(to: utc("2026-10-19T06:30:00Z"))
        #expect(await rewinding.controller.evaluate(.periodic).weeklyFullChargeDue?.occurrence == monday19)
        rewinding.clock.shiftWall(by: -2 * hour)
        let beforeMonday = await rewinding.controller.evaluate(.clockChanged)
        #expect(beforeMonday.weeklyFullChargeDue == nil)
        rewinding.clock.shiftWall(by: 14 * hour)
        let mondayPassed = await rewinding.controller.evaluate(.clockChanged)
        #expect(mondayPassed.weeklyFullChargeOutcome == .windowPassed(monday19, lastWait: .onBattery))
    }

    @Test("With management off it waits and passes with that reason; turned on within the window, it starts")
    func managementOff() async throws {
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        let rig = Rig(at: thursday, settings: off)
        try await rig.controller.setWeeklyFullCharge(fridays)
        rig.move(to: utc("2026-10-23T06:30:00Z"))
        #expect(await rig.controller.evaluate(.periodic).weeklyFullChargeDue == WeeklyFullChargeDue(occurrence: friday23, wait: .managementOff))
        let on = try await rig.controller.apply(settings: .default)
        #expect(on.weeklyFullChargeOutcome == .started(friday23))

        let staysOff = Rig(at: thursday, settings: off)
        try await staysOff.controller.setWeeklyFullCharge(fridays)
        staysOff.move(to: utc("2026-10-23T06:30:00Z"))
        await staysOff.controller.evaluate(.periodic)
        staysOff.move(to: utc("2026-10-23T18:30:00Z"))
        #expect(await staysOff.controller.evaluate(.periodic).weeklyFullChargeOutcome == .windowPassed(friday23, lastWait: .managementOff))
    }

    // MARK: - Clock jumps

    @Test("Fridays for 48 hours: a jump to Sunday 06:00 starts Friday's for its last hour; at Sunday 07:00 it has passed, and a rewind does not bring it back")
    func forwardJump() async throws {
        let long = WeeklyFullChargePattern(weekdays: [friday], hour: 7, minute: 0, durationHours: 48)
        // Friday 2026-10-09 07:00 BST is 06:00Z; its window ends Sunday 06:00Z.
        let earlyThursday = utc("2026-10-08T12:00:00Z")
        let friday9 = long.occurrence(on: localDay(2026, 10, 9), in: london)!

        let jumping = Rig(at: earlyThursday)
        try await jumping.controller.setWeeklyFullCharge(long)
        jumping.clock.shiftWall(by: utc("2026-10-11T05:00:00Z").timeIntervalSince(jumping.clock.now))
        let lastHour = await jumping.controller.evaluate(.clockChanged)
        #expect(lastHour.weeklyFullChargeOutcome == .started(friday9))
        #expect(lastHour.activeOverride?.expiresAtUptime == jumping.clock.uptime + hour)

        let late = Rig(at: earlyThursday)
        try await late.controller.setWeeklyFullCharge(long)
        late.clock.shiftWall(by: utc("2026-10-11T06:00:00Z").timeIntervalSince(late.clock.now))
        #expect(await late.controller.evaluate(.clockChanged).weeklyFullChargeOutcome == .windowPassed(friday9, lastWait: nil))
        late.clock.shiftWall(by: -18 * hour)
        let rewound = await late.controller.evaluate(.clockChanged)
        expectStartConditionsMet(rewound, for: friday9, at: late.clock.now)
        #expect(rewound.activeOverride == nil)
    }

    // MARK: - Saving and removing

    @Test("Saved inside today's window it does not start today; the next is next week")
    func savedInsideWindow() async throws {
        let rig = Rig(at: utc("2026-10-23T08:00:00Z"))
        let saved = try await rig.controller.setWeeklyFullCharge(fridays)
        expectStartConditionsMet(saved, for: friday23, at: rig.clock.now)
        #expect(saved.activeOverride == nil)
        #expect(saved.weeklyFullCharge?.handled.day == localDay(2026, 10, 23))
        #expect(saved.weeklyFullChargeNext?.day == localDay(2026, 10, 30))
    }

    @Test("An edit after a start, or removing and saving again in the same run, does not start that day again")
    func editsDoNotRestart() async throws {
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(fridays)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        #expect(await rig.controller.evaluate(.periodic).activeOverride != nil)
        await rig.controller.cancelOverride()
        var at8 = fridays
        at8.hour = 8
        let edited = try await rig.controller.setWeeklyFullCharge(at8)
        #expect(edited.weeklyFullCharge?.handled.day == localDay(2026, 10, 23))
        rig.move(to: utc("2026-10-23T07:00:30Z"))
        let atEight = await rig.controller.evaluate(.periodic)
        expectStartConditionsMet(atEight, for: at8.occurrence(on: localDay(2026, 10, 23), in: london)!, at: rig.clock.now)
        #expect(atEight.activeOverride == nil)

        await rig.controller.removeWeeklyFullCharge()
        var at9 = fridays
        at9.hour = 9
        let again = try await rig.controller.setWeeklyFullCharge(at9)
        #expect(again.weeklyFullCharge?.handled.day == localDay(2026, 10, 23))
        rig.move(to: utc("2026-10-23T08:00:30Z"))
        let atNine = await rig.controller.evaluate(.periodic)
        expectStartConditionsMet(atNine, for: at9.occurrence(on: localDay(2026, 10, 23), in: london)!, at: rig.clock.now)
        #expect(atNine.activeOverride == nil)
    }

    @Test("A save counts from the time and time zone the controller reads when it runs the command")
    func savedWithCommandTime() async throws {
        let rig = Rig(at: utc("2026-10-23T10:00:00Z"))
        // 06:00 in New York: Friday's 07:00 there is still to come.
        rig.zone.current = newYork
        let saved = try await rig.controller.setWeeklyFullCharge(fridays)
        #expect(saved.weeklyFullCharge?.handled.day == localDay(2026, 10, 16))
        #expect(saved.weeklyFullCharge?.handled.utcOffset == -4 * 3600)
        #expect(saved.weeklyFullChargeNext?.startsAt == utc("2026-10-23T11:00:00Z"))
    }

    @Test("Removing stops it: no start in a later window, the store is emptied, and the latest outcome stays")
    func remove() async throws {
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(fridays)
        rig.move(to: utc("2026-10-23T19:00:00Z"))
        await rig.controller.evaluate(.periodic)
        let removed = await rig.controller.removeWeeklyFullCharge()
        #expect(removed.weeklyFullCharge == nil)
        #expect(removed.weeklyFullChargeNext == nil)
        #expect(removed.weeklyFullChargeOutcome == .windowPassed(friday23, lastWait: nil))
        #expect(rig.stored == .none)
        rig.move(to: utc("2026-10-30T08:00:00Z"))
        #expect(await rig.controller.evaluate(.periodic).activeOverride == nil)
    }

    @Test("A time zone change that moves the next start is logged once, without a cause")
    func nextMoved() async throws {
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(fridays)
        rig.zone.current = newYork
        let moved = await rig.controller.evaluate(.clockChanged)
        #expect(moved.weeklyFullChargeNext?.startsAt == utc("2026-10-23T11:00:00Z"))
        await rig.controller.evaluate(.periodic)
        let lines = await rig.controller.status.events.filter { $0.message.hasPrefix("Next weekly full charge:") }
        #expect(lines.count == 1)
    }

    @Test("Overlapping windows: every day for 48 hours, the next day's start extends a full charge still running")
    func overlap() async throws {
        let everyDay = WeeklyFullChargePattern(weekdays: Set(1...7), hour: 7, minute: 0, durationHours: 48)
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(everyDay)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        let first = await rig.controller.evaluate(.periodic)
        let firstDeadline = try #require(first.activeOverride?.expiresAtUptime)
        rig.move(to: utc("2026-10-24T06:00:30Z"))
        let second = await rig.controller.evaluate(.periodic)
        #expect(second.weeklyFullChargeOutcome == .extendedRunning(everyDay.occurrence(on: localDay(2026, 10, 24), in: london)!))
        #expect(second.activeOverride?.expiresAtUptime == firstDeadline + day)
    }

    @Test("While a full charge it started is live, a manual start changes nothing (D91)")
    func manualStartIgnored() async throws {
        let rig = Rig(at: thursday)
        try await rig.controller.setWeeklyFullCharge(fridays)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        let started = try #require(await rig.controller.evaluate(.periodic).activeOverride)
        let manual = await rig.controller.startFullCharge()
        #expect(manual.activeOverride == started)
    }

    // MARK: - A store that fails

    @Test("A failed write delays nothing: the schedule is used and starts, the problem is shown, and a later write clears it")
    func droppedWrites() async throws {
        let flaky = FlakyStorage()
        let rig = Rig(at: thursday, storage: flaky)
        flaky.set(mode: .droppingWrites)
        let saved = try await rig.controller.setWeeklyFullCharge(fridays)
        #expect(saved.weeklyFullCharge?.pattern == fridays)
        #expect(saved.weeklyFullChargeStoreProblem == .notSaved)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        let started = await rig.controller.evaluate(.periodic)
        #expect(started.weeklyFullChargeOutcome == .started(friday23))
        #expect(started.weeklyFullChargeStoreProblem == .notSaved)
        #expect(started.events.filter { $0.kind == .failure && $0.message.contains("could not save the weekly full charge") }.count == 1)
        flaky.set(mode: .working)
        let recovered = await rig.controller.evaluate(.periodic)
        #expect(recovered.weeklyFullChargeStoreProblem == nil)
        #expect(rig.stored == .schedule(WeeklyFullChargeSchedule(pattern: fridays, handled: WeeklyFullChargeRecord(friday23, result: .started))))
    }

    @Test("A write that was accepted but not read back is reported, and a relaunch finds what was written")
    func acceptedButNotReadBack() async throws {
        let flaky = FlakyStorage()
        let rig = Rig(at: thursday, storage: flaky)
        flaky.set(mode: .failingReads)
        let saved = try await rig.controller.setWeeklyFullCharge(fridays)
        #expect(saved.weeklyFullChargeStoreProblem == .notSaved)
        flaky.set(mode: .working)
        let relaunched = await rig.relaunched().controller.evaluate(.launch)
        #expect(relaunched.weeklyFullCharge?.pattern == fridays)
    }

    @Test("With the store failing, a rewind into the window and a time zone change still start nothing again in this run; after recovery a relaunch finds the record")
    func failureRewindRecovery() async throws {
        let flaky = FlakyStorage()
        let rig = Rig(at: thursday, storage: flaky)
        try await rig.controller.setWeeklyFullCharge(fridays)
        flaky.set(mode: .droppingWrites)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        #expect(await rig.controller.evaluate(.periodic).weeklyFullChargeOutcome == .started(friday23))
        await rig.controller.cancelOverride()
        rig.clock.shiftWall(by: -2 * hour)
        await rig.controller.evaluate(.clockChanged)
        rig.clock.shiftWall(by: 3 * hour)
        let rewound = await rig.controller.evaluate(.clockChanged)
        expectStartConditionsMet(rewound, for: friday23, at: rig.clock.now)
        #expect(rewound.activeOverride == nil)
        rig.zone.current = newYork
        rig.move(to: utc("2026-10-23T11:00:30Z"))
        let travelled = await rig.controller.evaluate(.periodic)
        expectStartConditionsMet(travelled, for: fridays.occurrence(on: localDay(2026, 10, 23), in: newYork)!, at: rig.clock.now)
        #expect(travelled.activeOverride == nil)
        #expect(travelled.weeklyFullChargeStoreProblem == .notSaved)
        flaky.set(mode: .working)
        #expect(await rig.controller.evaluate(.periodic).weeklyFullChargeStoreProblem == nil)
        #expect(await rig.relaunched().controller.evaluate(.launch).weeklyFullCharge?.handled.day == localDay(2026, 10, 23))
    }

    @Test("As stated: if the record was never saved, a relaunch inside the window starts that occurrence once more")
    func lostRecordOnRelaunch() async throws {
        let flaky = FlakyStorage()
        let rig = Rig(at: thursday, storage: flaky)
        try await rig.controller.setWeeklyFullCharge(fridays)
        flaky.set(mode: .droppingWrites)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        #expect(await rig.controller.evaluate(.periodic).weeklyFullChargeOutcome == .started(friday23))
        flaky.set(mode: .working)
        rig.move(to: utc("2026-10-23T08:00:00Z"))
        let relaunched = await rig.relaunched().controller.evaluate(.launch)
        #expect(relaunched.weeklyFullChargeOutcome == .started(friday23))
    }

    @Test("A removal that cannot be saved still stops it in this run, says so, and, as stated, it comes back after a relaunch")
    func removalNotSaved() async throws {
        let flaky = FlakyStorage()
        let rig = Rig(at: thursday, storage: flaky)
        try await rig.controller.setWeeklyFullCharge(fridays)
        flaky.set(mode: .droppingWrites)
        let removed = await rig.controller.removeWeeklyFullCharge()
        #expect(removed.weeklyFullCharge == nil)
        #expect(removed.weeklyFullChargeStoreProblem == .notRemoved)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        #expect(await rig.controller.evaluate(.periodic).activeOverride == nil)
        #expect(await rig.relaunched().controller.evaluate(.launch).weeklyFullCharge?.pattern == fridays)
    }

    @Test("A stored value that cannot be used is removed with a notice; the settings are untouched")
    func discarded() async throws {
        let storage = InMemoryStorage()
        storage.set("not a schedule", forKey: WeeklyFullChargeStore.key)
        let rig = Rig(at: thursday, storage: storage)
        let status = await rig.controller.evaluate(.launch)
        #expect(status.weeklyFullCharge == nil)
        #expect(status.weeklyFullChargeOutcome == .discarded(reason: "it is not a weekly schedule record"))
        #expect(status.settings == .default)
        #expect(rig.stored == .none)

        let flaky = FlakyStorage()
        flaky.set("not a schedule", forKey: WeeklyFullChargeStore.key)
        flaky.set(mode: .droppingWrites)
        let stuck = await Rig(at: thursday, storage: flaky).controller.evaluate(.launch)
        #expect(stuck.weeklyFullCharge == nil)
        #expect(stuck.weeklyFullChargeStoreProblem == .notRemoved)
    }

    // MARK: - With the one-shot schedule

    /// A rig with both schedules, and a one-shot whose window is Friday
    /// 06:00Z to `oneShotEnd`, set on Thursday.
    private func bothDue(oneShotEnd: Date, reading: BatterySnapshot = snapshot(percent: 70), weeklyStorage: (any KeyValueStorage & Sendable)? = nil) async throws -> Rig {
        let rig = Rig(at: thursday, storage: weeklyStorage, reading: reading, scheduleStore: true)
        try await rig.controller.setWeeklyFullCharge(fridays)
        try await rig.controller.setFullChargeSchedule(FullChargeSchedule(startsAt: utc("2026-10-23T06:00:00Z"), endsAt: oneShotEnd))
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        return rig
    }

    @Test("Both due: the one-shot starts first; the weekly one extends it if it ends later, keeps it if it ends earlier or at the same time")
    func bothDueOrders() async throws {
        let shorter = try await bothDue(oneShotEnd: utc("2026-10-23T12:00:00Z"))
        let extended = await shorter.controller.evaluate(.periodic)
        #expect(extended.fullChargeScheduleOutcome == .started(FullChargeSchedule(startsAt: utc("2026-10-23T06:00:00Z"), endsAt: utc("2026-10-23T12:00:00Z"))))
        #expect(extended.weeklyFullChargeOutcome == .extendedRunning(friday23))
        #expect(extended.activeOverride?.expiresAtUptime == shorter.clock.uptime + 12 * hour - 30)

        let longer = try await bothDue(oneShotEnd: utc("2026-10-23T20:00:00Z"))
        let keptLater = await longer.controller.evaluate(.periodic)
        #expect(keptLater.weeklyFullChargeOutcome == .keptRunning(friday23, deadline: .later))

        let equal = try await bothDue(oneShotEnd: friday23.endsAt)
        let keptSame = await equal.controller.evaluate(.periodic)
        #expect(keptSame.weeklyFullChargeOutcome == .keptRunning(friday23, deadline: .same))
        #expect(keptSame.activeOverride?.expiresAtUptime == equal.clock.uptime + 12 * hour - 30)
    }

    @Test("Both due with the battery already full, and the weekly store failing: both say already full, and the full charge ends once")
    func bothDueAlreadyFull() async throws {
        let flaky = FlakyStorage()
        let full = snapshot(percent: 100, charging: false, fullyCharged: true)
        let rig = try await bothDue(oneShotEnd: utc("2026-10-23T12:00:00Z"), reading: full, weeklyStorage: flaky)
        flaky.set(mode: .droppingWrites)
        let before = await rig.controller.status.overridesEnded
        let status = await rig.controller.evaluate(.periodic)
        #expect(status.fullChargeScheduleOutcome == .alreadyFull(FullChargeSchedule(startsAt: utc("2026-10-23T06:00:00Z"), endsAt: utc("2026-10-23T12:00:00Z"))))
        #expect(status.weeklyFullChargeOutcome == .alreadyFull(friday23))
        #expect(status.weeklyFullChargeStoreProblem == .notSaved)
        #expect(status.activeOverride == nil)
        #expect(status.overridesEnded == before + 1)
        #expect(status.lastEndedOverride?.end == .completed)
    }

    @Test("An expired full charge replaced by the schedules, which then complete at once, makes two endings: the expiry and one completion")
    func expiredPredecessor() async throws {
        let full = snapshot(percent: 100, charging: false, fullyCharged: true)
        let rig = Rig(at: thursday, reading: snapshot(percent: 70), scheduleStore: true)
        try await rig.controller.setWeeklyFullCharge(fridays)
        try await rig.controller.setFullChargeSchedule(FullChargeSchedule(startsAt: utc("2026-10-23T06:00:00Z"), endsAt: utc("2026-10-23T12:00:00Z")))
        rig.move(to: utc("2026-10-23T04:00:00Z"))
        await rig.controller.startFullCharge(duration: hour)
        let before = await rig.controller.status.overridesEnded
        // Asleep past its deadline and into both windows, then full.
        await rig.telemetry.set(full)
        rig.move(to: utc("2026-10-23T06:00:30Z"))
        let status = await rig.controller.evaluate(.didWake)
        #expect(status.overridesEnded == before + 2)
        #expect(status.lastEndedOverride?.end == .completed)
        #expect(status.lastEndedOverride?.override.source == .schedule)
        #expect(status.weeklyFullChargeOutcome == .alreadyFull(friday23))
        #expect(status.events.filter { $0.message.hasSuffix("expired.") }.count == 1)
    }
}
