import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// The controller running a scheduled full charge with the simulated
/// backend, on an injected clock whose wall time can also jump on its own.
@Suite("Scheduled full charge: controller")
struct FullChargeScheduleControllerTests {
    let clock = TestClock()
    let storage = InMemoryStorage()

    private func makeController(
        percent: Int = 70,
        backend: any ChargingBackend = MockChargingBackend(),
        settings: ChargingSettings = .default
    ) -> (ChargeController, StubTelemetry) {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: percent), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: backend,
            settings: settings,
            scheduleStore: FullChargeScheduleStore(defaults: storage),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        return (controller, telemetry)
    }

    /// A schedule starting `lead` from now on the test clock.
    private func schedule(startingIn lead: TimeInterval = hour, window: TimeInterval = 12 * hour) -> FullChargeSchedule {
        let start = clock.now.addingTimeInterval(lead)
        return FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(window))
    }

    private var stored: FullChargeScheduleLoad {
        FullChargeScheduleStore(defaults: storage).loadSchedule()
    }

    // MARK: - Starting

    @Test("It starts a temporary full charge at the first evaluation in its window, removed from the store first, with its deadline at the end")
    func startsInWindow() async throws {
        let (controller, _) = makeController()
        await controller.evaluate(.launch)
        let armed = schedule()
        let set = try await controller.setFullChargeSchedule(armed)
        #expect(set.fullChargeSchedule == armed)
        #expect(stored == .schedule(armed))

        clock.advance(by: hour - 60)
        let before = await controller.evaluate(.periodic)
        #expect(before.activeOverride == nil)
        #expect(before.fullChargeScheduleWait == nil)

        clock.advance(by: 90)
        let started = await controller.evaluate(.periodic)
        let override = try #require(started.activeOverride)
        #expect(override.kind == .fullCharge)
        #expect(override.source == .schedule)
        #expect(override.expiresAtUptime == clock.uptime + armed.endsAt.timeIntervalSince(clock.now))
        #expect(override.expiresAt == armed.endsAt)
        #expect(started.decision?.state == .fullChargeOverride)
        #expect(started.fullChargeSchedule == nil)
        #expect(started.fullChargeScheduleOutcome == .started(armed))
        #expect(stored == .none)
        #expect(started.events.contains { $0.kind == .override && $0.message.contains("Scheduled full charge started") })
    }

    @Test("Started late, its deadline is the time left to the end at that moment: no one-hour minimum")
    func lateStartEndsAtEnd() async throws {
        let (controller, _) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        // Asleep, or not running, until ten minutes before the end.
        clock.advance(by: armed.endsAt.timeIntervalSince(clock.now) - 600)
        let started = await controller.evaluate(.didWake)
        let override = try #require(started.activeOverride)
        #expect(override.expiresAtUptime == clock.uptime + 600)

        clock.advance(by: 600)
        let ended = await controller.evaluate(.periodic)
        #expect(ended.activeOverride == nil)
        #expect(ended.decision?.overrideEnded == .expired)
        #expect(ended.events.contains { $0.message == "Scheduled full charge expired." })
    }

    /// How late after the start the first evaluation runs: on time, and ten
    /// minutes before the end.
    static let lateness: [TimeInterval] = [0, 42_600]

    @Test("Slow backend reads do not shorten the scheduled full charge: its deadline is the time left to the end when the wall clock was read, also when it starts late", arguments: lateness)
    func slowBackendReads(lateness: TimeInterval) async throws {
        // Each capability and mode read takes 30 s, between the policy's
        // monotonic reading and its wall-clock reading.
        let backend = SlowReadingBackend(clock: clock, delay: 30)
        let (controller, _) = makeController(backend: backend)
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        clock.advance(by: armed.startsAt.timeIntervalSince(clock.now) + lateness)
        let started = await controller.evaluate(.periodic)
        let override = try #require(started.activeOverride)
        #expect(override.source == .schedule)
        #expect(override.expiresAtUptime - clock.uptime == armed.endsAt.timeIntervalSince(clock.now))
        #expect(override.expiresAt == armed.endsAt)
        #expect(override.expiresAtUptime - clock.uptime < 12 * hour - lateness)
    }

    /// Begins an evaluation 30 s before `override`'s deadline, with the
    /// capability and mode reads taking 30 s each, so the evaluation
    /// straddles the deadline.
    private func evaluateStraddling(_ override: ChargeOverride, controller: ChargeController, backend: SlowReadingBackend) async -> ControllerStatus {
        clock.advance(by: override.expiresAtUptime - clock.uptime - 30)
        await backend.setDelay(30)
        return await controller.evaluate(.periodic)
    }

    @Test("An evaluation that straddles a manual full charge's deadline because the backend's reads are slow ends it")
    func manualExpiresDuringSlowReads() async throws {
        let backend = SlowReadingBackend(clock: clock, delay: 0)
        let (controller, _) = makeController(backend: backend)
        let manual = try #require(await controller.startFullCharge().activeOverride)
        let status = await evaluateStraddling(manual, controller: controller, backend: backend)
        #expect(clock.uptime > manual.expiresAtUptime)
        #expect(status.decision?.overrideEnded == .expired)
        #expect(status.activeOverride == nil)
    }

    @Test("An evaluation that straddles a scheduled full charge's deadline because the backend's reads are slow ends it")
    func scheduledExpiresDuringSlowReads() async throws {
        let backend = SlowReadingBackend(clock: clock, delay: 0)
        let (controller, _) = makeController(backend: backend)
        try await controller.setFullChargeSchedule(schedule(window: 2 * hour))
        clock.advance(by: hour)
        let started = try #require(await controller.evaluate(.periodic).activeOverride)
        #expect(started.source == .schedule)
        let status = await evaluateStraddling(started, controller: controller, backend: backend)
        #expect(status.decision?.overrideEnded == .expired)
        #expect(status.activeOverride == nil)
    }

    @Test("An evaluation that straddles a discharge session's deadline because the backend's reads are slow ends it, and no longer asks to discharge")
    func dischargeExpiresDuringSlowReads() async throws {
        let backend = SlowReadingBackend(clock: clock, delay: 0)
        let (controller, _) = makeController(percent: 90, backend: backend)
        await controller.evaluate(.launch)
        let session = try #require(await controller.startDischargeToLimit().activeOverride)
        #expect(await controller.status.decision?.desiredMode == .forceDischarge)
        let status = await evaluateStraddling(session, controller: controller, backend: backend)
        #expect(status.decision?.overrideEnded == .expired)
        #expect(status.activeOverride == nil)
        #expect(status.decision?.desiredMode != .forceDischarge)
    }

    /// Wall-clock changes made while an override runs.
    static let wallJumpsAfterStart: [TimeInterval] = [36_000, -36_000]

    @Test("After a clock change, a running manual full charge shows the deadline its monotonic deadline gives", arguments: wallJumpsAfterStart)
    func manualDisplayFollowsDeadline(jump: TimeInterval) async throws {
        let (controller, _) = makeController()
        let manual = try #require(await controller.startFullCharge().activeOverride)
        clock.shiftWall(by: jump)
        clock.advance(by: 60)
        let running = try #require(await controller.evaluate(.clockChanged).activeOverride)
        #expect(running.expiresAtUptime == manual.expiresAtUptime)
        #expect(running.expiresAt == clock.now.addingTimeInterval(manual.expiresAtUptime - clock.uptime))
        #expect(running.expiresAt == manual.expiresAt.addingTimeInterval(jump))
    }

    @Test("After a clock change, a running scheduled full charge shows the deadline its monotonic deadline gives, which the window's end does not bound", arguments: wallJumpsAfterStart)
    func scheduledDisplayFollowsDeadline(jump: TimeInterval) async throws {
        let (controller, _) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        clock.advance(by: hour)
        let started = try #require(await controller.evaluate(.periodic).activeOverride)
        #expect(started.expiresAt == armed.endsAt)
        clock.shiftWall(by: jump)
        clock.advance(by: 60)
        let running = try #require(await controller.evaluate(.clockChanged).activeOverride)
        #expect(running.expiresAtUptime == started.expiresAtUptime)
        #expect(running.expiresAt == armed.endsAt.addingTimeInterval(jump))
    }

    @Test("After a clock change, a running discharge session shows the deadline its monotonic deadline gives", arguments: wallJumpsAfterStart)
    func dischargeDisplayFollowsDeadline(jump: TimeInterval) async throws {
        let (controller, _) = makeController(percent: 90)
        await controller.evaluate(.launch)
        let session = try #require(await controller.startDischargeToLimit().activeOverride)
        clock.shiftWall(by: jump)
        clock.advance(by: 60)
        let running = try #require(await controller.evaluate(.clockChanged).activeOverride)
        #expect(running.kind == .dischargeToLimit)
        #expect(running.expiresAtUptime == session.expiresAtUptime)
        #expect(running.expiresAt == session.expiresAt.addingTimeInterval(jump))
    }

    @Test("Nothing ends at the deadline while no evaluation runs; the next one ends it")
    func sleepAcrossDeadline() async throws {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        await controller.evaluate(.launch)
        let armed = schedule(window: 2 * hour)
        try await controller.setFullChargeSchedule(armed)
        clock.advance(by: hour)
        let started = await controller.evaluate(.periodic)
        #expect(started.decision?.state == .fullChargeOverride)
        #expect(started.currentMode == .normal)

        // Asleep for three hours, past the deadline: no evaluation, no request.
        clock.advance(by: 3 * hour)
        #expect(await controller.status.activeOverride != nil)
        #expect(await backend.requestedModes.isEmpty)

        let woke = await controller.evaluate(.didWake)
        #expect(woke.decision?.overrideEnded == .expired)
        #expect(woke.activeOverride == nil)
        // The limit was confirmed by readings during the full charge, so it
        // holds at once.
        #expect(woke.decision?.state == .holding)
        #expect(await backend.requestedModes == [.inhibitCharging])
    }

    // MARK: - Never twice

    @Test("No second start: within a run, after a backward clock change, or after a relaunch that follows the removal")
    func neverTwice() async throws {
        let (controller, _) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        clock.advance(by: hour)
        let started = await controller.evaluate(.periodic)
        #expect(started.activeOverride?.source == .schedule)

        let cancelled = await controller.cancelOverride()
        #expect(cancelled.activeOverride == nil)
        clock.advance(by: 60)
        #expect(await controller.evaluate(.periodic).activeOverride == nil)

        // The wall clock goes back before the start.
        clock.shiftWall(by: -2 * hour)
        let rewound = await controller.evaluate(.clockChanged)
        #expect(rewound.activeOverride == nil)
        clock.advance(by: hour + 60)
        #expect(await controller.evaluate(.periodic).activeOverride == nil)

        // A relaunch on the same storage finds nothing.
        let (relaunched, _) = makeController()
        let launched = await relaunched.evaluate(.launch)
        #expect(launched.activeOverride == nil)
        #expect(launched.fullChargeSchedule == nil)
        #expect(launched.fullChargeScheduleOutcome == nil)
    }

    // MARK: - Window passed

    @Test("A forward clock jump past the end: the window passed, reported without a cause CellKeeper cannot know")
    func forwardJumpPastEnd() async throws {
        let (controller, _) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        clock.shiftWall(by: 14 * hour)
        clock.advance(by: 60)
        let status = await controller.evaluate(.clockChanged)
        #expect(status.activeOverride == nil)
        #expect(status.fullChargeSchedule == nil)
        #expect(status.fullChargeScheduleOutcome == .windowPassed(armed, lastWait: nil))
        #expect(stored == .none)
        let event = try #require(status.events.last { $0.kind == .override })
        #expect(event.message.contains("the scheduled window passed before the full charge could start"))
        #expect(!event.message.contains("Last checked"))
        #expect(!event.message.contains("asleep"))
        #expect(!event.message.contains("not running"))
    }

    @Test("On battery at the start it waits; connecting power inside the window starts it")
    func waitsForPower() async throws {
        let (controller, telemetry) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        await telemetry.set(snapshot(percent: 70, source: .battery))
        clock.advance(by: hour)
        let waiting = await controller.evaluate(.periodic)
        #expect(waiting.activeOverride == nil)
        #expect(waiting.fullChargeScheduleWait == .onBattery)
        #expect(waiting.fullChargeSchedule == armed)
        #expect(stored == .schedule(armed))

        await telemetry.set(snapshot(percent: 70))
        clock.advance(by: 2 * hour)
        let started = await controller.evaluate(.powerSourceChanged)
        #expect(started.activeOverride?.source == .schedule)
        #expect(started.fullChargeScheduleWait == nil)
        #expect(started.fullChargeScheduleOutcome == .started(armed))
    }

    @Test("Never plugged in: the window passed, with the last reason it waited in this run")
    func passedWhileWaiting() async throws {
        let (controller, telemetry) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        await telemetry.set(snapshot(percent: 70, source: .battery))
        clock.advance(by: hour)
        await controller.evaluate(.periodic)
        clock.advance(by: 12 * hour)
        let passed = await controller.evaluate(.periodic)
        #expect(passed.activeOverride == nil)
        #expect(passed.fullChargeScheduleOutcome == .windowPassed(armed, lastWait: .onBattery))
        #expect(passed.events.contains { $0.message.contains("Last checked: the Mac is on battery.") })
    }

    @Test("A clock set back before the start stops showing the wait, but the reason seen in this run is still given when the window passes")
    func waitAcrossBackwardJump() async throws {
        let (controller, telemetry) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        await telemetry.set(snapshot(percent: 70, source: .battery))
        clock.advance(by: hour)
        #expect(await controller.evaluate(.periodic).fullChargeScheduleWait == .onBattery)

        clock.shiftWall(by: -2 * hour)
        let rewound = await controller.evaluate(.clockChanged)
        #expect(rewound.fullChargeScheduleWait == nil)
        #expect(rewound.fullChargeSchedule == armed)

        clock.shiftWall(by: 20 * hour)
        let passed = await controller.evaluate(.clockChanged)
        #expect(passed.fullChargeScheduleOutcome == .windowPassed(armed, lastWait: .onBattery))
    }

    @Test("After a relaunch, a window that passed is reported without a wait reason from the earlier run")
    func relaunchAfterWaiting() async throws {
        let (controller, telemetry) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        await telemetry.set(snapshot(percent: 70, source: .battery))
        clock.advance(by: hour)
        #expect(await controller.evaluate(.periodic).fullChargeScheduleWait == .onBattery)

        clock.advance(by: 12 * hour)
        let (relaunched, _) = makeController()
        let launched = await relaunched.evaluate(.launch)
        #expect(launched.fullChargeScheduleOutcome == .windowPassed(armed, lastWait: nil))
        #expect(stored == .none)
    }

    // MARK: - Management and settings

    @Test("With management off it waits, is kept, and starts once management is turned on")
    func managementOff() async throws {
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        let (controller, _) = makeController(settings: off)
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        clock.advance(by: hour)
        let waiting = await controller.evaluate(.periodic)
        #expect(waiting.fullChargeScheduleWait == .managementOff)
        #expect(waiting.activeOverride == nil)

        let on = try await controller.apply(settings: .default)
        #expect(on.activeOverride?.source == .schedule)
        #expect(on.decision?.state == .fullChargeOverride)
    }

    @Test("Turning management off keeps an armed schedule")
    func managementOffKeepsSchedule() async throws {
        let (controller, _) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        let status = try await controller.apply(settings: off)
        #expect(status.fullChargeSchedule == armed)
        #expect(stored == .schedule(armed))
    }

    @Test("Already full at the start: started and completed in one evaluation")
    func alreadyFull() async throws {
        let (controller, telemetry) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        await telemetry.set(snapshot(percent: 100, fullyCharged: true))
        clock.advance(by: hour)
        let status = await controller.evaluate(.periodic)
        #expect(status.activeOverride == nil)
        #expect(status.decision?.overrideEnded == .completed)
        #expect(status.fullChargeScheduleOutcome == .alreadyFull(armed))
        #expect(stored == .none)
    }

    @Test("At a 100% limit it still starts")
    func startsAtFullLimit() async throws {
        let (controller, _) = makeController(settings: ChargingSettings.default.withChargeLimit(100))
        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour)
        let status = await controller.evaluate(.periodic)
        #expect(status.activeOverride?.source == .schedule)
        #expect(status.decision?.state == .fullChargeOverride)
    }

    @Test("A temperature pause still wins over the scheduled full charge")
    func temperatureStillWins() async throws {
        let backend = MockChargingBackend()
        let (controller, telemetry) = makeController(backend: backend)
        try await controller.setFullChargeSchedule(schedule())
        await telemetry.set(snapshot(percent: 70, temperature: 45))
        clock.advance(by: hour)
        let status = await controller.evaluate(.periodic)
        #expect(status.activeOverride?.source == .schedule)
        #expect(status.decision?.state == .temperaturePause)
        #expect(status.decision?.notes.contains(.fullChargeSuppressed(by: .temperaturePause)) == true)
        #expect(await backend.requestedModes == [.inhibitCharging])
    }

    @Test("A faulted backend: the scheduled full charge starts, and only normal charging is requested")
    func faultedBackend() async throws {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        await controller.evaluate(.periodic)
        #expect(await backend.requestedModes == [.inhibitCharging])
        await backend.simulateExternalChange(to: .forceDischarge)
        clock.advance(by: 60)
        let faulted = await controller.evaluate(.periodic)
        #expect(faulted.isBackendFaulted)
        #expect(await backend.requestedModes == [.inhibitCharging, .normal])

        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour)
        let status = await controller.evaluate(.periodic)
        #expect(status.activeOverride?.source == .schedule)
        #expect(status.decision?.state == .fullChargeOverride)
        #expect(status.decision?.action == .noAction)
        #expect(await backend.requestedModes == [.inhibitCharging, .normal])
    }

    // MARK: - Running overrides

    /// (wall-clock jump before the schedule is set, its window, whether the
    /// schedule's deadline is the later one).
    static let wallJumps: [(TimeInterval, TimeInterval, Bool)] = [
        (36_000, 7_200, false),
        (-36_000, 50_400, true),
    ]

    @Test("A live full charge is kept with the later deadline, compared on the monotonic clock, whichever way the wall clock jumped", arguments: wallJumps)
    func runningFullCharge(jump: TimeInterval, window: TimeInterval, extends: Bool) async throws {
        let (controller, _) = makeController()
        let manual = await controller.startFullCharge()
        let original = try #require(manual.activeOverride)
        // Forward: the manual charge's wall estimate looks earlier than the
        // schedule's end, though it has more time left. Backward: it looks
        // later, though it has less.
        clock.shiftWall(by: jump)
        let armed = schedule(window: window)
        try await controller.setFullChargeSchedule(armed)
        clock.advance(by: hour)
        let status = await controller.evaluate(.periodic)
        let running = try #require(status.activeOverride)
        #expect(running.startedAt == original.startedAt)
        if extends {
            #expect(running.expiresAtUptime == clock.uptime + window)
            #expect(running.source == .schedule)
            #expect(running.expiresAt == armed.endsAt)
            #expect(status.fullChargeScheduleOutcome == .extendedRunning(armed))
        } else {
            #expect(running.expiresAtUptime == original.expiresAtUptime)
            #expect(running.source == .user)
            // Shown from the monotonic deadline, beyond the schedule's end.
            let deadline = clock.now.addingTimeInterval(original.expiresAtUptime - clock.uptime)
            #expect(running.expiresAt == deadline)
            #expect(deadline > armed.endsAt)
            #expect(status.fullChargeScheduleOutcome == .keptRunning(armed, deadline: .later))
        }
        #expect(stored == .none)
    }

    @Test("A full charge whose monotonic deadline has passed is replaced, however late its wall estimate looks")
    func expiredFullChargeReplaced() async throws {
        let (controller, _) = makeController()
        let manual = try #require(await controller.startFullCharge().activeOverride)
        clock.shiftWall(by: -20 * hour)
        let armed = schedule(startingIn: 12.5 * hour, window: 2 * hour)
        try await controller.setFullChargeSchedule(armed)
        // The manual charge's wall estimate is later than the schedule's end.
        #expect(manual.expiresAt > armed.endsAt)
        clock.advance(by: 12.5 * hour)
        let status = await controller.evaluate(.periodic)
        let running = try #require(status.activeOverride)
        #expect(running.source == .schedule)
        #expect(running.expiresAtUptime == clock.uptime + 2 * hour)
        #expect(status.fullChargeScheduleOutcome == .started(armed))
        #expect(status.events.contains { $0.message == "Temporary full charge expired." })
    }

    @Test("A discharge session running at the start is replaced, and that is logged")
    func dischargeReplaced() async throws {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 90, backend: backend)
        await controller.evaluate(.launch)
        let discharging = await controller.startDischargeToLimit()
        #expect(discharging.decision?.state == .discharging)
        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour)
        let status = await controller.evaluate(.periodic)
        #expect(status.activeOverride?.kind == .fullCharge)
        #expect(status.decision?.state == .fullChargeOverride)
        #expect(status.events.contains { $0.message == "Discharge to limit ended: the scheduled full charge started." })
        #expect(await backend.requestedModes.last == .normal)
    }

    // MARK: - Commands and storage

    @Test("A schedule that is not valid when set is rejected and nothing is stored")
    func rejected() async {
        let (controller, _) = makeController()
        let past = schedule(startingIn: -60)
        await #expect(throws: FullChargeScheduleError(issues: [.startNotInFuture])) {
            try await controller.setFullChargeSchedule(past)
        }
        #expect(stored == .none)
        #expect(await controller.status.fullChargeSchedule == nil)
    }

    @Test("Cancelling removes an armed schedule; a full charge it started is not affected")
    func cancelling() async throws {
        let (controller, _) = makeController()
        try await controller.setFullChargeSchedule(schedule())
        let cancelled = await controller.cancelFullChargeSchedule()
        #expect(cancelled.fullChargeSchedule == nil)
        #expect(stored == .none)

        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour)
        await controller.evaluate(.periodic)
        let after = await controller.cancelFullChargeSchedule()
        #expect(after.activeOverride?.source == .schedule)
    }

    @Test("An outcome stays until dismissed or a new schedule is set")
    func outcomeDismissed() async throws {
        let (controller, _) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        clock.advance(by: hour)
        #expect(await controller.evaluate(.periodic).fullChargeScheduleOutcome == .started(armed))
        #expect(await controller.evaluate(.periodic).fullChargeScheduleOutcome == .started(armed))
        #expect(await controller.dismissFullChargeScheduleOutcome().fullChargeScheduleOutcome == nil)
    }

    @Test("A stored record that cannot be used is removed with a notice; the settings are untouched")
    func unusableAtLaunch() async {
        storage.set(Data(#"{"startsAt":1800003600,"endsAt":1800003610}"#.utf8), forKey: FullChargeScheduleStore.key)
        let settings = ChargingSettings.default.withChargeLimit(85)
        let (controller, _) = makeController(settings: settings)
        let status = await controller.evaluate(.launch)
        #expect(status.fullChargeScheduleOutcome == .discarded(reason: FullChargeScheduleIssue.windowTooShort.description))
        #expect(status.fullChargeSchedule == nil)
        #expect(storage.data(forKey: FullChargeScheduleStore.key) == nil)
        #expect(status.settings == settings)
        #expect(status.decision?.state == .charging)
    }

    @Test("A value under the schedule's key that is not a record is removed with a notice, and the saved charging settings stay as they were")
    func notARecord() async throws {
        let values: [any Sendable] = ["not a record", 42, true, ["startsAt": 1_800_003_600.0]]
        for value in values {
            let storage = InMemoryStorage()
            let settingsStore = SettingsStore(defaults: storage)
            let saved = ChargingSettings.default.withChargeLimit(85)
            try settingsStore.save(saved)
            let savedData = storage.data(forKey: SettingsStore.chargingSettingsKey)
            storage.set(value, forKey: FullChargeScheduleStore.key)
            let loaded = settingsStore.loadChargingSettings()
            let clock = clock
            let controller = ChargeController(
                telemetry: StubTelemetry(snapshot(percent: 70), clock: clock),
                backend: MockChargingBackend(),
                settings: loaded.settings,
                scheduleStore: FullChargeScheduleStore(defaults: storage),
                now: { clock.now },
                uptime: { clock.uptime }
            )
            let status = await controller.evaluate(.launch)
            #expect(status.fullChargeScheduleOutcome == .discarded(reason: "it is not a schedule record"))
            #expect(storage.object(forKey: FullChargeScheduleStore.key) == nil)
            #expect(status.settings == saved)
            let after = settingsStore.loadChargingSettings()
            #expect(after.settings == saved)
            #expect(after.recoveryReason == nil)
            #expect(storage.data(forKey: SettingsStore.chargingSettingsKey) == savedData)
        }
    }

    @Test("A stored schedule whose window passed while CellKeeper was not running is reported at launch")
    func passedAtLaunch() async throws {
        let armed = FullChargeSchedule(startsAt: clock.now.addingTimeInterval(-20 * hour), endsAt: clock.now.addingTimeInterval(-8 * hour))
        try FullChargeScheduleStore(defaults: storage).saveSchedule(armed)
        let (controller, _) = makeController()
        let status = await controller.evaluate(.launch)
        #expect(status.fullChargeScheduleOutcome == .windowPassed(armed, lastWait: nil))
        #expect(status.activeOverride == nil)
        #expect(stored == .none)
    }

    @Test("A stored schedule is loaded at launch and starts in its window")
    func loadedAtLaunch() async throws {
        let armed = schedule()
        try FullChargeScheduleStore(defaults: storage).saveSchedule(armed)
        let (controller, _) = makeController()
        let launched = await controller.evaluate(.launch)
        #expect(launched.fullChargeSchedule == armed)
        clock.advance(by: hour)
        #expect(await controller.evaluate(.periodic).activeOverride?.source == .schedule)
    }

    @Test("After shutdown, setting and cancelling change nothing, and the store keeps the armed schedule")
    func inertAfterShutdown() async throws {
        let (controller, _) = makeController()
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        await controller.shutdown(reason: "quit")
        let other = schedule(startingIn: 2 * hour)
        let set = try await controller.setFullChargeSchedule(other)
        #expect(set.fullChargeSchedule == armed)
        let cancelled = await controller.cancelFullChargeSchedule()
        #expect(cancelled.fullChargeSchedule == armed)
        #expect(stored == .schedule(armed))
    }

    @Test("Without a store, nothing is armed")
    func noStore() async throws {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: 70), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = try await controller.setFullChargeSchedule(schedule())
        #expect(status.fullChargeSchedule == nil)
    }

    @Test("A clock change is an automatic evaluation; setting a schedule is not")
    func triggers() {
        #expect(EvaluationTrigger.clockChanged.isAutomatic)
        #expect(!EvaluationTrigger.scheduleChanged.isAutomatic)
    }
}

/// The scheduled full charge with macOS's Charge Limit, against a fake
/// macOS: the start is a restricting change with no exemption, and failures
/// keep the existing recovery of the user's own limit.
@Suite("Scheduled full charge: macOS's Charge Limit")
struct FullChargeScheduleNativeTests {
    let clock = TestClock()
    let storage = InMemoryStorage()
    let system = FakeChargeLimitSystem(reading: .limit(80))
    let store = InMemoryRecordStore()

    private func makeController(limit: Int = 90, percent: Int = 75) -> (ChargeController, StubTelemetry) {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: percent), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(limit),
            adoptionMarkerStore: store,
            scheduleStore: FullChargeScheduleStore(defaults: storage),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        return (controller, telemetry)
    }

    private func schedule(startingIn lead: TimeInterval = hour, window: TimeInterval = 12 * hour) -> FullChargeSchedule {
        let start = clock.now.addingTimeInterval(lead)
        return FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(window))
    }

    @Test("It requests 100%, and its limit again once the battery is full")
    func requestsFullThenLimit() async throws {
        let (controller, telemetry) = makeController()
        await controller.evaluate(.launch)
        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour)
        let started = await controller.evaluate(.periodic)
        #expect(started.decision?.state == .fullChargeOverride)
        #expect(system.reading == .noLimit)
        #expect(started.currentMode == .nativeLimit(percent: 100))

        await telemetry.set(snapshot(percent: 100, charging: false, fullyCharged: true))
        clock.advance(by: 60)
        let finished = await controller.evaluate(.powerSourceChanged)
        #expect(finished.activeOverride == nil)
        #expect(system.reading == .limit(90))
        #expect(system.runInputs == ["90", "100", "90"])
    }

    @Test("Its start is rate-limited like any restricting change, and made at a later evaluation")
    func startRateLimited() async throws {
        let (controller, _) = makeController()
        await controller.evaluate(.launch)
        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour - 30)
        try await controller.apply(settings: ChargingSettings.default.withChargeLimit(95))
        #expect(system.reading == .limit(95))

        clock.advance(by: 30)
        let refused = await controller.evaluate(.periodic)
        #expect(refused.activeOverride?.source == .schedule)
        guard case .refused(.rateLimited)? = refused.lastExecution?.result else {
            Issue.record("expected a rate-limited refusal, got \(String(describing: refused.lastExecution?.result))")
            return
        }
        #expect(system.reading == .limit(95))

        clock.advance(by: 60)
        await controller.evaluate(.periodic)
        #expect(system.reading == .noLimit)
        #expect(system.runInputs == ["90", "95", "100"])
    }

    @Test("While the Mac sleeps past the deadline, macOS keeps 100%; the first evaluation after wake requests the limit")
    func sleepAcrossDeadline() async throws {
        let (controller, _) = makeController()
        await controller.evaluate(.launch)
        try await controller.setFullChargeSchedule(schedule(window: 2 * hour))
        clock.advance(by: hour)
        await controller.evaluate(.periodic)
        #expect(system.reading == .noLimit)

        clock.advance(by: 3 * hour)
        #expect(system.reading == .noLimit)
        #expect(system.runInputs == ["90", "100"])

        let woke = await controller.evaluate(.didWake)
        #expect(woke.decision?.overrideEnded == .expired)
        #expect(system.reading == .limit(90))
        #expect(system.runInputs == ["90", "100", "90"])
    }

    @Test("A return to the limit that is rate-limited leaves 100% until a later evaluation")
    func returnRateLimited() async throws {
        let (controller, telemetry) = makeController()
        await controller.evaluate(.launch)
        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour)
        await controller.evaluate(.periodic)
        #expect(system.reading == .noLimit)

        await telemetry.set(snapshot(percent: 100, charging: false, fullyCharged: true))
        clock.advance(by: 30)
        let completed = await controller.evaluate(.powerSourceChanged)
        #expect(completed.activeOverride == nil)
        guard case .refused(.rateLimited)? = completed.lastExecution?.result else {
            Issue.record("expected a rate-limited refusal, got \(String(describing: completed.lastExecution?.result))")
            return
        }
        #expect(system.reading == .noLimit)

        clock.advance(by: 60)
        await controller.evaluate(.periodic)
        #expect(system.reading == .limit(90))
    }

    @Test("A return to the limit that fails restores the user's own limit, as any failed request does")
    func returnFails() async throws {
        let (controller, telemetry) = makeController()
        await controller.evaluate(.launch)
        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour)
        await controller.evaluate(.periodic)
        await telemetry.set(snapshot(percent: 100, charging: false, fullyCharged: true))
        clock.advance(by: 60)
        system.scheduleRuns([.fails])
        let status = await controller.evaluate(.powerSourceChanged)
        #expect(system.runInputs == ["90", "100", "90", "80"])
        #expect(system.reading == .limit(80))
        #expect(status.currentMode == .normal)
    }

    @Test("A scheduled 100% request that fails restores the user's own limit, which may be below or above CellKeeper's", arguments: [
        (80, 95), (95, 85),
    ])
    func startFails(owner: Int, limit: Int) async throws {
        system.reading = .limit(owner)
        let (controller, _) = makeController(limit: limit)
        await controller.evaluate(.launch)
        #expect(system.reading == .limit(limit))
        try await controller.setFullChargeSchedule(schedule())
        clock.advance(by: hour)
        system.scheduleRuns([.fails])
        let status = await controller.evaluate(.periodic)
        guard case .failed? = status.lastExecution?.result else {
            Issue.record("expected a failure, got \(String(describing: status.lastExecution?.result))")
            return
        }
        #expect(system.runInputs == ["\(limit)", "100", "\(owner)"])
        // No exemption for schedules: with an owner limit below CellKeeper's,
        // this is lower than CellKeeper's limit would have been.
        #expect(system.reading == .limit(owner))
        #expect(status.currentMode == .normal)
        #expect(status.nativeLimit?.ownerLimit == nil)
    }

    @Test("A Charge Limit changed outside CellKeeper in the starting evaluation keeps the schedule from starting")
    func adoptionInSameEvaluation() async throws {
        let (controller, _) = makeController()
        await controller.evaluate(.launch)
        let armed = schedule()
        try await controller.setFullChargeSchedule(armed)
        clock.advance(by: hour)
        system.changeExternally(to: 85)
        let status = await controller.evaluate(.periodic)
        #expect(!status.settings.isManagementEnabled)
        #expect(status.activeOverride == nil)
        #expect(status.fullChargeSchedule == armed)
        #expect(status.fullChargeScheduleWait == .managementOff)
        #expect(system.runInputs == ["90"])
        #expect(system.reading == .limit(85))
    }
}

/// The simulated backend, with capability and mode reads that each take
/// `delay` seconds of the test clock, as a slow backend's would.
actor SlowReadingBackend: ChargingBackend {
    private let inner = MockChargingBackend()
    private let clock: TestClock
    private var delay: TimeInterval

    init(clock: TestClock, delay: TimeInterval) {
        self.clock = clock
        self.delay = delay
    }

    func setDelay(_ newDelay: TimeInterval) {
        delay = newDelay
    }

    nonisolated var descriptor: BackendDescriptor { inner.descriptor }

    func capabilities() async -> ControlCapabilities {
        clock.advance(by: delay)
        return await inner.capabilities()
    }

    func currentMode() async throws -> ChargeControlMode? {
        clock.advance(by: delay)
        return try await inner.currentMode()
    }

    func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome {
        try await inner.setMode(mode)
    }
}
