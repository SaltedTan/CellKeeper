import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// The boot a test's calibration clock reports: an identifier, and a
/// monotonic clock that starts again at each restart.
final class TestBoot: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TestClock
    private var identifier = "boot-1"
    private var base: TimeInterval
    private var started: Date

    init(clock: TestClock) {
        self.clock = clock
        base = clock.uptime - 1_000
        started = clock.now
    }

    var calibrationClock: CalibrationClock {
        CalibrationClock(
            monotonic: { [self] in lock.withLock { clock.uptime - base } },
            bootSession: { [self] in lock.withLock { identifier } },
            bootTime: { [self] in lock.withLock { started } }
        )
    }

    /// The Mac starts again: a new boot, its monotonic clock from 100 s.
    func restart() {
        lock.withLock {
            identifier = "boot-\(UUID().uuidString)"
            base = clock.uptime - 100
            started = clock.now
        }
    }
}

/// A usable reading without a temperature, as on macOS 27.
func calibrationReading(_ percent: Int, _ source: PowerSource = .externalPower, charging: Bool? = nil, full: Bool = false, temperature: Double? = nil) -> BatterySnapshot {
    snapshot(percent: percent, source: source, charging: charging, fullyCharged: full, temperature: temperature)
}

let allConfirmed = CalibrationConfirmations(optimizedCharging: .off, isCoolRoomConfirmed: true, isRecoverySeen: true, isMenuOnlyAcknowledged: true)

/// A controller on macOS's Charge Limit (the owner's own limit 90%,
/// CellKeeper's 80%), with fakes for the shortcut and the read-back, and
/// in-memory stores a second controller can share (a relaunch).
struct CalibrationRig {
    let clock: TestClock
    let boot: TestBoot
    let system: FakeChargeLimitSystem
    let records: InMemoryRecordStore
    let storage: any KeyValueStorage & Sendable
    let telemetry: StubTelemetry
    let controller: ChargeController

    init(
        clock: TestClock = TestClock(),
        boot: TestBoot? = nil,
        system: FakeChargeLimitSystem = FakeChargeLimitSystem(reading: .limit(90)),
        records: InMemoryRecordStore = InMemoryRecordStore(),
        storage: (any KeyValueStorage & Sendable)? = nil,
        reading: BatterySnapshot = calibrationReading(70),
        settings: ChargingSettings = ChargingSettings.default.withChargeLimit(80),
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) {
        self.clock = clock
        self.boot = boot ?? TestBoot(clock: clock)
        self.system = system
        self.records = records
        let storage = storage ?? InMemoryStorage()
        self.storage = storage
        telemetry = StubTelemetry(reading, clock: clock)
        let backend = NativeChargeLimitBackend(runner: system, reader: system, store: records, platformIssue: nil, now: { clock.now }, uptime: { clock.uptime })
        controller = ChargeController(
            telemetry: telemetry,
            backend: backend,
            settings: settings,
            adoptionMarkerStore: records,
            scheduleStore: FullChargeScheduleStore(defaults: storage),
            weeklyStore: WeeklyFullChargeStore(defaults: storage),
            calibrationStore: CalibrationStore(defaults: storage),
            now: { clock.now },
            timeZone: { timeZone },
            uptime: { clock.uptime },
            calibrationClock: self.boot.calibrationClock
        )
    }

    /// A second controller on the same Mac and storage: a relaunch.
    func relaunched(reading: BatterySnapshot, settings: ChargingSettings = ChargingSettings.default.withChargeLimit(80)) -> CalibrationRig {
        CalibrationRig(clock: clock, boot: boot, system: system, records: records, storage: storage, reading: reading, settings: settings)
    }

    var stored: CalibrationLoad { CalibrationStore(defaults: storage).loadCalibration() }

    func read(_ reading: BatterySnapshot, _ trigger: EvaluationTrigger = .periodic) async -> ControllerStatus {
        await telemetry.set(reading)
        return await controller.evaluate(trigger)
    }

    /// Launches, waits out the rate limit of the first change, and starts a
    /// calibration on power at 70%.
    func started(sourceLocation: SourceLocation = #_sourceLocation) async -> ControllerStatus {
        await controller.evaluate(.launch)
        clock.advance(by: 120)
        let status = await controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.refusal == nil, sourceLocation: sourceLocation)
        #expect(status.calibration.session?.step == .chargeToFull, sourceLocation: sourceLocation)
        return status
    }

    /// Drives a started session to `target` through every step before it.
    @discardableResult
    func drive(to target: CalibrationStep, sourceLocation: SourceLocation = #_sourceLocation) async -> ControllerStatus {
        var status = await started(sourceLocation: sourceLocation)
        func at(_ step: CalibrationStep) -> Bool {
            #expect(status.calibration.session?.step == step, sourceLocation: sourceLocation)
            return step == target
        }
        if at(.chargeToFull) { return status }
        clock.advance(by: hour)
        status = await read(calibrationReading(100, charging: false, full: true))
        if at(.restAtTop) { return status }
        clock.advance(by: 2 * hour)
        status = await read(calibrationReading(100, charging: false, full: true))
        if at(.unplug) { return status }
        clock.advance(by: 600)
        status = await read(calibrationReading(99, .battery), .powerSourceChanged)
        if at(.drain) { return status }
        clock.advance(by: 4 * hour)
        status = await read(calibrationReading(20, .battery))
        if at(.restAtBottom) { return status }
        clock.advance(by: 60)
        status = await read(calibrationReading(18, .battery), .willSleep)
        clock.advance(by: 5.1 * hour)
        status = await read(calibrationReading(17, .battery), .didWake)
        if at(.plugIn) { return status }
        clock.advance(by: 300)
        status = await read(calibrationReading(17), .powerSourceChanged)
        _ = at(.finalCharge)
        return status
    }
}

@Suite("Calibration: controller")
struct CalibrationControllerTests {
    // MARK: - The whole calibration

    @Test("A calibration runs its seven steps, asks for 100% only in steps 1, 2 and 7, confirms each return, and reports")
    func wholeCalibration() async throws {
        let rig = CalibrationRig()
        var status = await rig.started()
        #expect(rig.system.runInputs == ["80", "100"])
        #expect(status.decision?.state == .calibrating)
        #expect(status.currentMode == .nativeLimit(percent: 100))
        #expect(status.calibration.isFullLimitConfirmed)
        #expect(status.nativeLimit?.ownerLimit == 90, "the owner's own limit stays recorded")

        rig.clock.advance(by: hour)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .restAtTop)
        #expect(rig.system.runInputs == ["80", "100"], "full does not end the 100% (unlike a temporary full charge)")

        rig.clock.advance(by: 2 * hour)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .unplug, "the normal limit was confirmed in the same evaluation")
        #expect(rig.system.runInputs == ["80", "100", "80"])
        #expect(rig.system.reading == .limit(80))

        status = await rig.read(calibrationReading(99, .battery), .powerSourceChanged)
        #expect(status.calibration.session?.step == .drain)
        rig.clock.advance(by: 4 * hour)
        status = await rig.read(calibrationReading(20, .battery))
        #expect(status.calibration.session?.step == .restAtBottom)
        let shown = try #require(status.calibration.session?.plugInAfter)
        #expect(shown.timeIntervalSince(rig.clock.now) >= 5 * hour)

        status = await rig.read(calibrationReading(18, .battery), .willSleep)
        rig.clock.advance(by: 5.1 * hour)
        status = await rig.read(calibrationReading(17, .battery), .didWake)
        #expect(status.calibration.session?.step == .plugIn)
        #expect(status.calibration.session?.restResult == .counted(sleptFor: 5.1 * hour, fromPercent: 18, toPercent: 17))
        #expect(rig.system.runInputs == ["80", "100", "80"], "nothing asked for 100% in steps 3-6")

        status = await rig.read(calibrationReading(17), .powerSourceChanged)
        #expect(status.calibration.session?.step == .finalCharge)
        #expect(rig.system.runInputs == ["80", "100", "80", "100"])

        rig.clock.advance(by: 2 * hour)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session == nil)
        #expect(rig.system.runInputs == ["80", "100", "80", "100", "80"])
        let report = try #require(status.calibration.last)
        #expect(report.end == .completed)
        #expect(status.calibration.outcome == report)
        #expect(report.stepsDone == CalibrationStep.allCases)
        #expect(report.restResult?.isCountedSleep == true)
        #expect(report.after != nil)
        #expect(rig.stored == .stored(CalibrationStored(last: report)))
        #expect(status.events.contains { $0.kind == .calibration && $0.message.hasPrefix("Calibration finished") })
        #expect(status.decision?.state == .osEnforcedLimit)
    }

    @Test("The 100% request is rate-limited like any change, and asked for again once the limit allows")
    func fullRateLimited() async {
        let rig = CalibrationRig()
        await rig.controller.evaluate(.launch)
        let status = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.session?.step == .chargeToFull)
        #expect(rig.system.runInputs == ["80"])
        guard case .refuse(.rateLimited)? = status.decision?.action else {
            Issue.record("not rate-limited: \(String(describing: status.decision?.action))")
            return
        }
        #expect(!status.calibration.isFullLimitConfirmed)
        // A "charged" reading under the old limit does not end step 1.
        rig.clock.advance(by: 61)
        let later = await rig.read(calibrationReading(80, charging: false, full: true))
        #expect(later.calibration.session?.step == .chargeToFull)
        #expect(rig.system.runInputs == ["80", "100"])
    }

    // MARK: - Leaving 100%: the confirmed return

    @Test("A return the rate limit defers is shown as returning and made once the limit allows; the next step waits for it")
    func returnRateLimited() async {
        // Already full at the start: step 1 ends 30 s after the 100%
        // request, and an unplug 10 s later asks for the normal limit
        // within a minute of it.
        let rig = CalibrationRig(reading: calibrationReading(100, charging: false, full: true))
        _ = await rig.started()
        rig.clock.advance(by: 30)
        var status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .restAtTop)
        rig.clock.advance(by: 10)
        status = await rig.read(calibrationReading(100, .battery), .powerSourceChanged)
        #expect(status.calibration.session?.step == .drain)
        #expect(status.calibration.isReturning)
        #expect(rig.system.reading == .noLimit)
        guard case .refuse(.rateLimited)? = status.decision?.action else {
            Issue.record("not rate-limited: \(String(describing: status.decision?.action))")
            return
        }
        rig.clock.advance(by: 61)
        status = await rig.read(calibrationReading(99, .battery))
        #expect(!status.calibration.isReturning)
        #expect(rig.system.reading == .limit(80))
        #expect(status.calibration.session?.step == .drain)
    }

    @Test("A return the read-back does not confirm is a failed return: the session ends in step 2, never reaching step 3")
    func unconfirmedReturn() async {
        let rig = CalibrationRig()
        await rig.drive(to: .restAtTop)
        rig.clock.advance(by: 2 * hour)
        // The shortcut runs but macOS still reports 100%.
        rig.system.scheduleRuns([.hasNoEffect])
        let status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session == nil)
        #expect(status.calibration.last?.end == .returnFailed)
        #expect(status.calibration.last?.lastStep == .restAtTop)
        #expect(status.calibration.last?.steps.map(\.step) == [.chargeToFull, .restAtTop])
        #expect(rig.system.reading == .limit(90), "the fallback gave back the owner's own limit")
    }

    @Test("A return that fails ends the session; the existing failure handling gives back the owner's own limit")
    func returnFails() async {
        let rig = CalibrationRig()
        await rig.drive(to: .restAtTop)
        rig.clock.advance(by: 2 * hour)
        rig.system.scheduleRuns([.fails])
        let status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session == nil)
        #expect(status.calibration.last?.end == .returnFailed)
        #expect(rig.system.reading == .limit(90), "the owner's own limit, confirmed")
        #expect(status.consecutiveFailures == 1)
    }

    @Test("Unplugging during the rest at the top moves to the drain and asks for the normal limit at once")
    func earlyUnplug() async {
        let rig = CalibrationRig()
        await rig.drive(to: .restAtTop)
        rig.clock.advance(by: 1800)
        let status = await rig.read(calibrationReading(99, .battery), .powerSourceChanged)
        #expect(status.calibration.session?.step == .drain)
        #expect(status.calibration.session?.shortRests == [.restAtTop])
        #expect(status.calibration.isReturning == false, "confirmed in the same evaluation")
        #expect(rig.system.reading == .limit(80))
    }

    @Test("Sleep in step 2 keeps 100% (macOS keeps a limit through sleep); the rest counts sleep, and the bound applies after waking")
    func sleepAtTop() async {
        let rig = CalibrationRig()
        await rig.drive(to: .restAtTop)
        var status = await rig.read(calibrationReading(100, charging: false, full: true), .willSleep)
        #expect(rig.system.reading == .noLimit)
        #expect(status.calibration.session?.step == .restAtTop)
        rig.clock.advance(by: 3 * hour)
        status = await rig.read(calibrationReading(100, charging: false, full: true), .didWake)
        #expect(status.calibration.session?.step == .unplug)
        #expect(rig.system.reading == .limit(80))
    }

    @Test("Sleep in step 7 keeps 100%; a charged reading after waking returns to the limit and completes the session")
    func sleepInFinalCharge() async {
        let rig = CalibrationRig()
        await rig.drive(to: .finalCharge)
        rig.clock.advance(by: 600)
        var status = await rig.read(calibrationReading(40), .willSleep)
        #expect(rig.system.reading == .noLimit)
        rig.clock.advance(by: 4 * hour)
        status = await rig.read(calibrationReading(100, charging: false, full: true), .didWake)
        #expect(status.calibration.session == nil)
        #expect(status.calibration.last?.end == .completed)
        #expect(rig.system.reading == .limit(80))
    }

    @Test("Step 1's bound ends the session at the first evaluation after waking, and the normal limit is asked for")
    func boundAfterWake() async {
        let rig = CalibrationRig()
        _ = await rig.started()
        _ = await rig.read(calibrationReading(80), .willSleep)
        rig.clock.advance(by: 7 * hour)
        let status = await rig.read(calibrationReading(81), .didWake)
        #expect(status.calibration.last?.end == .stepBound(.chargeToFull))
        #expect(rig.system.reading == .limit(80))
    }

    // MARK: - Exclusion (§7.4)

    @Test("During a session, full charges and their schedules are refused with “a calibration is in progress”")
    func exclusion() async throws {
        let rig = CalibrationRig()
        _ = await rig.started()
        let full = await rig.controller.startFullCharge()
        #expect(full.activeOverride == nil)
        #expect(full.events.contains { $0.message == "Temporary full charge not started: a calibration is in progress." })
        let schedule = FullChargeSchedule(startsAt: rig.clock.now.addingTimeInterval(hour), endsAt: rig.clock.now.addingTimeInterval(3 * hour))
        await #expect(throws: FullChargeScheduleError(issues: [.calibrationInProgress])) {
            try await rig.controller.setFullChargeSchedule(schedule)
        }
        await #expect(throws: WeeklyFullChargeError.calibrationInProgress) {
            try await rig.controller.setWeeklyFullCharge(WeeklyFullChargePattern(weekdays: [2], hour: 7, minute: 0, durationHours: 12))
        }
        let status = await rig.controller.evaluate(.manual)
        #expect(status.fullChargeSchedule == nil)
        #expect(status.weeklyFullCharge == nil)
        // Changing CellKeeper's own limit is allowed.
        let limited = try await rig.controller.apply(settings: ChargingSettings.default.withChargeLimit(90))
        #expect(limited.calibration.session != nil)
        #expect(limited.settings.chargeLimit == 90)
    }

    @Test("A weekly full charge falling due during a session is skipped and recorded as handled with that reason")
    func weeklySkipped() async throws {
        // referenceDate is a Friday at 08:00 UTC.
        let rig = CalibrationRig()
        await rig.controller.evaluate(.launch)
        try await rig.controller.setWeeklyFullCharge(WeeklyFullChargePattern(weekdays: Set(1...7), hour: 9, minute: 0, durationHours: 12))
        rig.clock.advance(by: 120)
        _ = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        rig.clock.advance(by: hour)
        let status = await rig.read(calibrationReading(80))
        #expect(status.activeOverride == nil)
        guard case .skippedForCalibration(let occurrence)? = status.weeklyFullChargeOutcome else {
            Issue.record("not skipped: \(String(describing: status.weeklyFullChargeOutcome))")
            return
        }
        #expect(status.weeklyFullCharge?.handled == WeeklyFullChargeRecord(occurrence, result: .skippedForCalibration))
        #expect(status.calibration.session?.step == .chargeToFull)
        guard case .schedule(let stored) = WeeklyFullChargeStore(defaults: rig.storage).loadWeeklyFullCharge() else {
            Issue.record("not stored")
            return
        }
        #expect(stored.handled.result == .skippedForCalibration)
    }

    @Test("Admission refuses while a temporary full charge runs or a one-shot full charge is scheduled")
    func admissionExcludes() async throws {
        let rig = CalibrationRig()
        await rig.controller.evaluate(.launch)
        rig.clock.advance(by: 120)
        await rig.controller.startFullCharge()
        var status = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.session == nil)
        #expect(status.calibration.refusal == "A temporary full charge is running. Let it end, or cancel it, first.")
        await rig.controller.cancelOverride()
        try await rig.controller.setFullChargeSchedule(FullChargeSchedule(startsAt: rig.clock.now.addingTimeInterval(hour), endsAt: rig.clock.now.addingTimeInterval(3 * hour)))
        status = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.refusal == "A full charge is scheduled. Cancel it first.")
        await rig.controller.cancelFullChargeSchedule()
        status = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.refusal == nil)
        #expect(status.calibration.session != nil)
    }

    @Test("Turning management off, or switching control away from macOS's Charge Limit, ends the session")
    func managementAndSwitch() async throws {
        let rig = CalibrationRig()
        _ = await rig.started()
        var off = ChargingSettings.default.withChargeLimit(80)
        off.isManagementEnabled = false
        let status = try await rig.controller.apply(settings: off)
        #expect(status.calibration.session == nil)
        #expect(status.calibration.last?.end == .managementOff)
        #expect(rig.system.reading == .limit(90))

        let other = CalibrationRig()
        _ = await other.started()
        let switched = await other.controller.switchBackend(to: MockChargingBackend())
        #expect(switched.calibration.last?.end == .controlChanged)
        #expect(other.system.reading == .limit(90))
    }

    @Test("A Charge Limit changed outside CellKeeper during a session is kept, management turned off, and the session ended")
    func outsideChange() async {
        let rig = CalibrationRig()
        _ = await rig.started()
        rig.system.changeExternally(to: 85)
        let status = await rig.read(calibrationReading(80))
        #expect(status.calibration.last?.end == .outsideChange)
        #expect(!status.settings.isManagementEnabled)
        #expect(rig.system.reading == .limit(85))
    }

    @Test("Cancel ends the session at once, writes the ended mark, and the normal limit applies")
    func cancel() async throws {
        let rig = CalibrationRig()
        let started = await rig.started()
        let id = try #require(started.calibration.session?.id)
        rig.clock.advance(by: 61)
        let status = await rig.controller.cancelCalibration()
        #expect(status.calibration.session == nil)
        #expect(status.calibration.last?.end == .cancelled)
        #expect(status.calibration.last?.id == id)
        #expect(rig.system.reading == .limit(80))
        guard case .stored(let stored) = rig.stored else {
            Issue.record("nothing stored")
            return
        }
        #expect(stored.session == nil)
        #expect(stored.last?.id == id)
    }

    // MARK: - Storage

    @Test("A write that fails stops the session at once in memory; its end is saved once storage works again")
    func storageFails() async {
        let flaky = FlakyStorage()
        let rig = CalibrationRig(storage: flaky)
        _ = await rig.started()
        flaky.set(mode: .droppingWrites)
        rig.clock.advance(by: hour)
        var status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session == nil)
        #expect(status.calibration.last?.end == .storageFailed)
        #expect(status.calibration.isEndUnsaved)
        #expect(rig.system.reading == .limit(80), "the normal policy at once")

        flaky.set(mode: .working)
        status = await rig.controller.evaluate(.periodic)
        #expect(!status.calibration.isEndUnsaved)
        #expect(rig.stored == .stored(CalibrationStored(last: status.calibration.last)))
    }

    @Test("A start that cannot be saved does not start")
    func startUnsaved() async {
        let flaky = FlakyStorage()
        let rig = CalibrationRig(storage: flaky)
        await rig.controller.evaluate(.launch)
        rig.clock.advance(by: 120)
        flaky.set(mode: .failingReads)
        let status = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.session == nil)
        #expect(status.calibration.refusal == "CellKeeper could not save the calibration, so it did not start it.")
        #expect(rig.system.runInputs == ["80"])
    }

    // MARK: - Startup (§7.6)

    @Test("After a quit, a session found at launch is paused with the normal policy, asks nothing, and resumes only on continue; step 2's timer restarts")
    func quitAndContinue() async {
        let rig = CalibrationRig()
        await rig.drive(to: .restAtTop)
        await rig.controller.shutdown(reason: "quit")
        #expect(rig.system.reading == .limit(90), "the quit gave back the owner's own limit")
        #expect(rig.records.data == nil)

        rig.clock.advance(by: 600)
        let second = rig.relaunched(reading: calibrationReading(100, charging: false, full: true))
        var status = await second.controller.evaluate(.launch)
        #expect(status.calibration.session?.step == .restAtTop)
        #expect(status.calibration.isPaused)
        #expect(status.decision?.state == .osEnforcedLimit)
        #expect(second.system.reading == .limit(80), "the normal policy, not 100%")
        rig.clock.advance(by: 3 * hour)
        status = await second.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .restAtTop, "no progress while paused")
        #expect(second.system.reading == .limit(80))

        status = await second.controller.continueCalibration()
        #expect(!status.calibration.isPaused)
        #expect(status.calibration.session?.step == .restAtTop)
        #expect(second.system.reading == .noLimit)
        #expect(status.calibration.session?.resumedAt.count == 1)
        rig.clock.advance(by: 2 * hour - 60)
        status = await second.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .restAtTop, "the 2 hours count from the continue")
        rig.clock.advance(by: 120)
        status = await second.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .unplug)
    }

    @Test("After a crash, the backend's recovery gives back the owner's limit first; the session is then paused")
    func crash() async {
        let rig = CalibrationRig()
        _ = await rig.started()
        #expect(rig.records.data != nil)
        rig.clock.advance(by: 600)
        let second = rig.relaunched(reading: calibrationReading(85))
        let status = await second.controller.evaluate(.launch)
        #expect(second.system.runInputs.last == "90", "the recovery restored the owner's own limit")
        #expect(status.calibration.session?.step == .chargeToFull)
        #expect(status.calibration.isPaused)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("finish restoring your own limit of 90%") })
    }

    @Test("After a crash, a limit the owner changed meanwhile is adopted by the recovery, and the session ends")
    func crashThenOutsideChange() async {
        let rig = CalibrationRig()
        _ = await rig.started()
        rig.system.changeExternally(to: 85)
        let second = rig.relaunched(reading: calibrationReading(85))
        let status = await second.controller.evaluate(.launch)
        #expect(status.calibration.session == nil)
        #expect(status.calibration.last?.end == .outsideChange)
        #expect(second.system.reading == .limit(85))
    }

    @Test("After a quit, a limit that is not the owner's own recorded in the session is the owner's change: kept, nothing written, Manage charging off, and the session ends")
    func quitThenOutsideChange() async throws {
        let rig = CalibrationRig()
        _ = await rig.started()
        await rig.controller.shutdown(reason: "quit")
        rig.system.changeExternally(to: 95)
        let inputs = rig.system.runInputs
        let second = rig.relaunched(reading: calibrationReading(85))
        var status = await second.controller.evaluate(.launch)
        #expect(status.calibration.session == nil)
        #expect(status.calibration.last?.end == .unaccountedLimit(found: 95, expected: 90))
        #expect(second.system.runInputs == inputs, "nothing written")
        #expect(!status.settings.isManagementEnabled)
        #expect(status.adoptedChange?.limit == 95)
        #expect(status.adoptionCount == 1)
        #expect(status.decision?.state == .unmanaged)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: second.records)?.limit == 95, "the marker keeps Manage charging off at the next launch")
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("changed outside CellKeeper to 95%") && $0.message.contains("turned off Manage charging") })
        second.clock.advance(by: 120)
        status = await second.controller.evaluate(.periodic)
        #expect(second.system.runInputs == inputs)
        #expect(second.system.reading == .limit(95))
        // Turning Manage charging on again retires the marker, and 95% is
        // then recorded as the owner's own limit before CellKeeper's is set.
        status = try await second.controller.apply(settings: ChargingSettings.default.withChargeLimit(80), adoptionsSeen: status.adoptionCount)
        #expect(status.settings.isManagementEnabled)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: second.records) == nil)
        #expect(second.system.reading == .limit(80))
        #expect(status.nativeLimit?.ownerLimit == 95)
    }

    @Test("If the marker cannot be stored, the session's record is kept as evidence and nothing is written, also at the next launch")
    func markerStoreFails() async throws {
        let rig = CalibrationRig()
        _ = await rig.started()
        await rig.controller.shutdown(reason: "quit")
        rig.system.changeExternally(to: 95)
        rig.records.saveFails = true
        let inputs = rig.system.runInputs
        let second = rig.relaunched(reading: calibrationReading(85))
        var status = await second.controller.evaluate(.launch)
        #expect(rig.system.runInputs == inputs)
        #expect(!status.settings.isManagementEnabled, "off in memory")
        #expect(NativeChargeLimitBackend.pendingAdoption(in: rig.records) == nil)
        guard case .stored(let kept) = rig.stored else {
            Issue.record("nothing stored")
            return
        }
        #expect(kept.session != nil, "the evidence is kept: the session is not replaced by its report before the marker is stored")
        #expect(status.calibration.isEvidenceRetained)
        #expect(status.calibration.session == nil, "ended in memory")
        #expect(status.events.contains { $0.message.hasPrefix("CellKeeper could not store its record of the Charge Limit it kept.") })
        // Management off did not reach the disk either: the next launch
        // starts with it on, and still writes nothing.
        let third = rig.relaunched(reading: calibrationReading(85))
        status = await third.controller.evaluate(.launch)
        #expect(rig.system.runInputs == inputs)
        #expect(!status.settings.isManagementEnabled)
        // Once the marker can be stored, the report replaces the session.
        rig.records.saveFails = false
        rig.clock.advance(by: 61)
        status = await third.controller.evaluate(.periodic)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: rig.records)?.limit == 95)
        guard case .stored(let ended) = rig.stored else {
            Issue.record("nothing stored")
            return
        }
        #expect(ended.session == nil)
        #expect(ended.last?.end == .unaccountedLimit(found: 95, expected: 90))
        #expect(!status.calibration.isEvidenceRetained)
        #expect(rig.system.runInputs == inputs)
        let fourth = rig.relaunched(reading: calibrationReading(85))
        status = await fourth.controller.evaluate(.launch)
        #expect(rig.system.runInputs == inputs, "the marker keeps the next launch from writing")
        #expect(!status.settings.isManagementEnabled)
    }

    @Test("A crash after the marker is stored and before the report replaces the session leaves the next launch writing nothing")
    func crashBetweenWrites() async {
        let flaky = FlakyStorage()
        let rig = CalibrationRig(storage: flaky)
        _ = await rig.started()
        await rig.controller.shutdown(reason: "quit")
        rig.system.changeExternally(to: 95)
        let inputs = rig.system.runInputs
        // The report's write does not reach storage, as after a crash right
        // after the marker was stored.
        flaky.set(mode: .droppingWrites)
        let second = rig.relaunched(reading: calibrationReading(85))
        _ = await second.controller.evaluate(.launch)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: rig.records)?.limit == 95)
        guard case .stored(let kept) = rig.stored else {
            Issue.record("nothing stored")
            return
        }
        #expect(kept.session != nil)
        flaky.set(mode: .working)
        let third = rig.relaunched(reading: calibrationReading(85))
        let status = await third.controller.evaluate(.launch)
        #expect(rig.system.runInputs == inputs)
        #expect(!status.settings.isManagementEnabled)
        #expect(status.calibration.session == nil)
    }

    @Test("After a quit, a limit that cannot be read at launch is not accounted for either: nothing written, Manage charging off")
    func quitThenUnreadable() async throws {
        let rig = CalibrationRig()
        _ = await rig.started()
        await rig.controller.shutdown(reason: "quit")
        rig.system.readFails = true
        let inputs = rig.system.runInputs
        let second = rig.relaunched(reading: calibrationReading(85))
        var status = await second.controller.evaluate(.launch)
        #expect(status.calibration.last?.end == .unaccountedLimit(found: nil, expected: 90))
        #expect(!status.settings.isManagementEnabled)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("could not read macOS's Charge Limit when it started again") })
        // No record is held, but nothing read the limit: not confirmed.
        let report = try #require(status.calibration.outcome)
        let unread = CalibrationWording.outcomeLine(report, status: status)
        #expect(!unread.contains("applies again"))
        #expect(unread.contains("macOS has not confirmed CellKeeper's limit back yet, so its Charge Limit may still be at 100%."))
        #expect(unread.contains("set your own limit, 90%, in System Settings › Battery › Charging"))
        second.system.readFails = false
        second.clock.advance(by: 120)
        status = await second.controller.evaluate(.periodic)
        #expect(second.system.runInputs == inputs, "nothing written, also once the limit can be read")
        #expect(second.system.reading == .limit(90))
        #expect(CalibrationWording.outcomeLine(report, status: status).contains("Your own Charge Limit of 90% applies again, confirmed by macOS."))
    }

    @Test("At launch, a passed cap (by the wall clock across a restart) or bound ends the session")
    func boundsAtLaunch() async {
        let rig = CalibrationRig()
        await rig.drive(to: .unplug)
        await rig.controller.shutdown(reason: "quit")
        rig.clock.advance(by: 73 * hour)
        rig.boot.restart()
        let second = rig.relaunched(reading: calibrationReading(100, charging: false, full: true))
        let status = await second.controller.evaluate(.launch)
        #expect(status.calibration.last?.end == .sessionCap)

        let other = CalibrationRig()
        await other.drive(to: .unplug)
        await other.controller.shutdown(reason: "quit")
        other.clock.advance(by: 5 * hour)
        let relaunched = other.relaunched(reading: calibrationReading(100, charging: false, full: true))
        #expect(await relaunched.controller.evaluate(.launch).calibration.last?.end == .stepBound(.unplug))
    }

    @Test("At launch, a one-shot full charge found scheduled ends the session")
    func scheduleAtLaunch() async throws {
        let rig = CalibrationRig()
        _ = await rig.started()
        await rig.controller.shutdown(reason: "quit")
        try FullChargeScheduleStore(defaults: rig.storage).saveSchedule(FullChargeSchedule(startsAt: rig.clock.now.addingTimeInterval(hour), endsAt: rig.clock.now.addingTimeInterval(3 * hour)))
        let second = rig.relaunched(reading: calibrationReading(80))
        let status = await second.controller.evaluate(.launch)
        #expect(status.calibration.last?.end == .scheduleFound)
    }

    @Test("At launch on battery in step 1, the unplug ends the session")
    func unpluggedAtLaunch() async {
        let rig = CalibrationRig()
        _ = await rig.started()
        await rig.controller.shutdown(reason: "quit")
        let second = rig.relaunched(reading: calibrationReading(80, .battery))
        let status = await second.controller.evaluate(.launch)
        #expect(status.calibration.last?.end == .unplugged(.chargeToFull))
    }

    @Test("After a restart in step 5, once the time shown has come, continue records the owner's account")
    func restartDuringRest() async throws {
        let rig = CalibrationRig()
        let resting = await rig.drive(to: .restAtBottom)
        let shown = try #require(resting.calibration.session?.plugInAfter)
        _ = await rig.read(calibrationReading(18, .battery), .willSleep)
        await rig.controller.shutdown(reason: "shutting down")
        rig.clock.advance(by: 6 * hour)
        rig.boot.restart()
        #expect(rig.clock.now > shown)
        let second = rig.relaunched(reading: calibrationReading(17, .battery))
        var status = await second.controller.evaluate(.launch)
        #expect(status.calibration.isPaused)
        #expect(status.calibration.needsRestAnswer)

        status = await second.controller.continueCalibration()
        #expect(status.calibration.isPaused)
        #expect(status.calibration.refusal == "Answer whether your Mac stayed shut down and unplugged until the time shown.")

        status = await second.controller.continueCalibration(restAnswer: true)
        #expect(!status.calibration.isPaused)
        #expect(status.calibration.session?.step == .plugIn)
        guard case .ownersAccount(let bootTime, let last)? = status.calibration.session?.restResult else {
            Issue.record("not the owner's account")
            return
        }
        #expect(bootTime != nil)
        #expect(last?.percent == 18)
        status = await second.read(calibrationReading(17), .powerSourceChanged)
        #expect(status.calibration.session?.step == .finalCharge)
    }

    // MARK: - Temperature

    @Test("A session started with a temperature reading ends if the reading disappears")
    func temperatureLost() async {
        let rig = CalibrationRig(reading: calibrationReading(70, temperature: 30))
        await rig.controller.evaluate(.launch)
        rig.clock.advance(by: 120)
        var status = await rig.controller.startCalibration(CalibrationConfirmations(optimizedCharging: .off, isRecoverySeen: true, isMenuOnlyAcknowledged: true), isNotifying: false)
        #expect(status.calibration.session?.temperatureCheck == .measured)
        rig.clock.advance(by: 61)
        status = await rig.read(calibrationReading(72))
        #expect(status.calibration.last?.end == .temperatureLost)
        #expect(rig.system.reading == .limit(80))
    }
}

extension CalibrationRestResult {
    var isCountedSleep: Bool {
        if case .counted = self { return true }
        return false
    }
}
