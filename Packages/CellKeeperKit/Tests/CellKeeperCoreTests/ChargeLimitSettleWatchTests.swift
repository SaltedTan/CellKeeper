import CellKeeperCore
import Foundation
import Testing

/// The app's checks while App Nap delays its periodic check, as `AppModel`
/// runs them (D118): every status goes to the watch, and the follow-up
/// check it asks for runs at its time, before the next periodic one.
private struct NappedApp {
    var watch = ChargeLimitSettleWatch()
    private(set) var followUps = 0
    /// Every moment the watch held the activity at a status.
    private(set) var heldAt: [TimeInterval] = []

    /// `rounds` periodic checks `interval` apart on `clock`, each by
    /// `check`, with every follow-up check the watch asks for in between.
    /// Periodic checks stay `interval` apart while the activity is held
    /// too: the follow-up alone must end the wait.
    mutating func run(
        _ rounds: Int,
        every interval: TimeInterval,
        clock: TestClock,
        controller: ChargeController,
        check: () async -> ControllerStatus
    ) async -> ControllerStatus {
        var status = await controller.status
        take(status, controller)
        for _ in 0..<rounds {
            let nextPeriodic = clock.uptime + interval
            var deadlines = 0
            while let deadline = watch.nextDeadline, deadline < nextPeriodic {
                deadlines += 1
                guard deadlines < 10 else {
                    Issue.record("the watch keeps asking for a deadline")
                    return status
                }
                clock.advance(by: deadline - clock.uptime)
                if watch.deadlineReached(at: controller.monotonicNow) {
                    followUps += 1
                    status = await check()
                    take(status, controller)
                }
            }
            clock.advance(by: nextPeriodic - clock.uptime)
            status = await check()
            take(status, controller)
        }
        return status
    }

    private mutating func take(_ status: ControllerStatus, _ controller: ChargeController) {
        watch.observe(judgmentDue: status.chargeLimitJudgmentDue, at: controller.monotonicNow)
        if watch.isHoldingActivity {
            heldAt.append(controller.monotonicNow)
        }
    }
}

/// Checks more than ``ChargeLimitReadGate/maximumSpan`` apart start the
/// settle time again (D118); the follow-up check just after it ends keeps a
/// read from waiting for ever (review r2 of #113).
@Suite("The settle minute ends on time, however late the periodic checks come")
struct ChargeLimitSettleLivenessTests {
    @Test("A wait an awake suspension pushed past the cap is still judged later, with checks 121 s apart and no sleep")
    func cappedWaitRecovers() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.system.changeExternally(to: 90)
        rig.clock.advance(by: 121)
        var status = await rig.read(.externalPower)
        #expect(status.chargeLimitJudgmentDue != nil)
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: status.chargeLimitJudgmentDue, at: rig.controller.monotonicNow)
        let heldSince = try #require(watch.heldSince)
        // One awake suspension outlasts the episode: its timer resumes at
        // the cap, which ends the activity.
        rig.clock.advance(by: heldSince + ChargeLimitSettleWatch.cap - rig.clock.uptime)
        let capFollowUp = watch.deadlineReached(at: rig.controller.monotonicNow)
        #expect(!capFollowUp)
        #expect(!watch.isHoldingActivity)
        // The app can be napped again: its checks come 121 s apart, each
        // restarting the settle time. The watch's deadlines still run.
        status = await rig.read(.externalPower)
        watch.observe(judgmentDue: status.chargeLimitJudgmentDue, at: rig.controller.monotonicNow)
        for _ in 0..<10 where status.adoptedChange == nil {
            let nextPeriodic = rig.clock.uptime + 121
            var deadlines = 0
            while let due = watch.nextDeadline, due < nextPeriodic, deadlines < 20 {
                deadlines += 1
                rig.clock.advance(by: max(0, due - rig.clock.uptime))
                if watch.deadlineReached(at: rig.controller.monotonicNow) {
                    status = await rig.read(.externalPower)
                    watch.observe(judgmentDue: status.chargeLimitJudgmentDue, at: rig.controller.monotonicNow)
                }
            }
            #expect(deadlines < 20, "the deadlines advance")
            rig.clock.advance(by: nextPeriodic - rig.clock.uptime)
            status = await rig.read(.externalPower)
            watch.observe(judgmentDue: status.chargeLimitJudgmentDue, at: rig.controller.monotonicNow)
        }
        #expect(status.adoptedChange?.limit == 90, "after the rest a new episode follows up on time, and the owner's change is kept")
    }

    @Test("Checks 121 s apart alone never judge a read: each starts the settle time again, as the bound requires")
    func delayedChecksAloneNeverJudge() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.system.changeExternally(to: 90)
        for _ in 0..<10 {
            rig.clock.advance(by: 121)
            let status = await rig.read(.externalPower)
            #expect(status.nativeLimit?.readDeferral == .settling)
            #expect(status.adoptionCount == 0)
            #expect(status.settings.isManagementEnabled)
        }
    }

    @Test("Checks 121 s apart, with the follow-up check the watch asks for: a change made outside CellKeeper is adopted a minute after the first check, and the activity ends")
    func delayedChecksAdoptOutsideChange() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.system.changeExternally(to: 90)
        rig.clock.advance(by: 121)
        var status = await rig.read(.externalPower)
        #expect(status.nativeLimit?.readDeferral == .settling)
        let settlesAt = try #require(status.chargeLimitSettlesAt)
        #expect(settlesAt == rig.clock.uptime + ChargeController.chargeLimitSettleTime)
        #expect(status.chargeLimitJudgmentDue == settlesAt)

        var app = NappedApp()
        status = await app.run(10, every: 121, clock: rig.clock, controller: rig.controller) {
            await rig.read(.externalPower)
        }
        #expect(status.adoptedChange?.limit == 90)
        #expect(!status.settings.isManagementEnabled)
        #expect(rig.system.runInputs == ["85"], "nothing written over it")
        #expect(app.followUps == 1)
        #expect(!app.watch.isHoldingActivity)
        #expect(app.watch.nextDeadline == nil)
    }

    @Test("Checks 121 s apart, with the follow-up check: the 100% a calibration wrote, its read-back not judged across a sleep, is confirmed")
    func delayedChecksConfirmCalibrationWrite() async {
        let rig = CalibrationRig.settling(system: FakeChargeLimitSystem(reading: .limit(80)))
        _ = await rig.controller.evaluate(.launch)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        _ = await rig.read(calibrationReading(70))
        rig.clock.advance(by: 120)
        let clock = rig.clock
        // The read-back after the write: the Mac sleeps during it.
        rig.system.beforeRead(after: 3) { clock.advanceAsleep(by: 30) }
        var status = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.session?.step == .chargeToFull)
        #expect(!status.calibration.isFullLimitConfirmed)
        #expect(status.nativeLimit?.pendingLimits == [100])
        #expect(status.chargeLimitSettlesAt == nil, "the settle time starts again at the next reading")
        #expect(rig.system.runInputs == ["100"])

        var app = NappedApp()
        status = await app.run(10, every: 121, clock: rig.clock, controller: rig.controller) {
            await rig.read(calibrationReading(70))
        }
        #expect(status.calibration.session?.step == .chargeToFull)
        #expect(status.calibration.isFullLimitConfirmed)
        #expect(status.nativeLimit?.pendingLimits == [])
        #expect(rig.system.runInputs == ["100"], "nothing written again")
        // Once confirmed, the no limit macOS shows for CellKeeper's 100%
        // agrees with the record: no later check waits for anything.
        #expect(app.followUps == 1)
        #expect(app.heldAt.count == 1)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.chargeLimitSettlesAt != nil)
        #expect(status.chargeLimitJudgmentDue == nil)
        #expect(!app.watch.isHoldingActivity)
    }

    @Test("Checks 121 s apart, with the follow-up check: the evidence a calibration kept from a launch, with Manage charging off, is settled by a judged read")
    func delayedChecksSettleRetainedEvidence() async {
        let rig = CalibrationRig.settling()
        _ = await rig.startedSettled()
        _ = await rig.controller.shutdown(reason: "quit")
        rig.system.isActiveLimitCleared = true
        let second = rig.relaunched(reading: calibrationReading(85))
        _ = await second.controller.evaluate(.launch)
        second.clock.advance(by: ChargeController.chargeLimitSettleTime)
        second.system.readFails = true
        var status = await second.controller.evaluate(.periodic)
        #expect(status.calibration.last?.end == .unaccountedLimit(found: nil, expected: 90))
        #expect(status.calibration.isEvidenceRetained)
        #expect(!status.settings.isManagementEnabled)
        // Set while CellKeeper could not read it.
        second.system.readFails = false
        second.system.isActiveLimitCleared = false
        second.system.changeExternally(to: 100)

        var app = NappedApp()
        status = await app.run(5, every: 121, clock: second.clock, controller: second.controller) {
            await second.read(calibrationReading(85))
        }
        #expect(!status.calibration.isEvidenceRetained)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: second.records)?.limit == 100)
        #expect(app.followUps == 1)
        #expect(!app.watch.isHoldingActivity)
    }

    @Test("Checks 121 s apart, with the follow-up check: a restore that waited for a judged read gives the owner's limit back")
    func delayedChecksFinishRestore() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // Too long since the last reading: the restore's own starts the
        // settle time again, and macOS shows no limit (cleared, and not yet
        // created again), which the restore cannot judge.
        rig.clock.advance(by: 601)
        rig.system.isActiveLimitCleared = true
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(status.chargeLimitJudgmentDue != nil, "a restore owed, with Manage charging off")
        rig.system.isActiveLimitCleared = false
        rig.system.changeExternally(to: 90)

        var app = NappedApp()
        status = await app.run(10, every: 121, clock: rig.clock, controller: rig.controller) {
            await rig.read(.externalPower)
        }
        #expect(status.adoptedChange?.limit == 90, "judged: the owner's own change is kept, nothing written over it")
        #expect(rig.system.runInputs == ["85"])
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
        #expect(app.followUps >= 1)
        #expect(!app.watch.isHoldingActivity)
    }

    // MARK: - When the app waits

    @Test("A plug-in where macOS shows CellKeeper's own limit at once waits for nothing: no activity, no follow-up")
    func ordinaryPlugInWaitsForNothing() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        var status = await rig.read(.externalPower, 75, .powerSourceChanged)
        #expect(status.chargeLimitSettlesAt == rig.clock.uptime + ChargeController.chargeLimitSettleTime, "settling")
        #expect(status.nativeLimit?.readDeferral == nil, "CellKeeper's own 85%, active")
        #expect(status.chargeLimitJudgmentDue == nil)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 75)
        #expect(status.chargeLimitSettlesAt == nil, "settled")
    }

    @Test("On battery power, or with the power source unknown, nothing waits for the settle time")
    func nothingWaitsOffPower() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.system.isActiveLimitCleared = true
        var status = await rig.read(.battery, 75, .powerSourceChanged)
        #expect(status.nativeLimit?.readDeferral == .onBattery)
        #expect(status.chargeLimitSettlesAt == nil)
        #expect(status.chargeLimitJudgmentDue == nil)
        await rig.telemetry.set(snapshot(percent: 75, source: .unknown))
        status = await rig.controller.evaluate(.periodic)
        #expect(status.chargeLimitSettlesAt == nil)
        #expect(status.chargeLimitJudgmentDue == nil)
    }

    @Test("A no limit that waits for the settle time waits for something only while Manage charging is on: off, with nothing owed, nothing gains from it", arguments: [true, false])
    func noLimitWaitsOnlyWhenManaged(managed: Bool) async {
        let rig = PowerRig(reading: .noLimit, limit: 85, managed: managed)
        let status = await rig.controller.evaluate(.launch)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.chargeLimitSettlesAt == rig.clock.uptime + ChargeController.chargeLimitSettleTime)
        #expect((status.chargeLimitJudgmentDue != nil) == managed)
    }

    @Test("After a read the gate did not judge, the settle time has no end until the next reading starts it again")
    func noEndAfterGateFailure() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.system.changeExternally(to: 90)
        let clock = rig.clock
        rig.system.beforeRead { clock.advanceAsleep(by: 30) }
        var status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptionCount == 0)
        #expect(status.chargeLimitSettlesAt == nil)
        #expect(status.chargeLimitJudgmentDue == nil)
        rig.clock.advance(by: 10)
        status = await rig.read(.externalPower)
        #expect(status.chargeLimitJudgmentDue == rig.clock.uptime + ChargeController.chargeLimitSettleTime)
    }
}

/// Tells `watch` its deadline came at `now`, and expects the follow-up
/// check to be due or not.
private func expectDeadline(_ watch: inout ChargeLimitSettleWatch, at now: TimeInterval, isDue: Bool, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    let reached = watch.deadlineReached(at: now)
    #expect(reached == isDue, comment, sourceLocation: sourceLocation)
}

@Suite("Charge Limit settle watch")
struct ChargeLimitSettleWatchTests {
    private let cap = ChargeLimitSettleWatch.cap

    @Test("A wait begins an episode: the activity is held, and one follow-up check is due a second after the settle time ends")
    func beginsOnWait() {
        var watch = ChargeLimitSettleWatch()
        #expect(!watch.isHoldingActivity)
        #expect(watch.nextDeadline == nil)
        watch.observe(judgmentDue: 1_060, at: 1_000)
        #expect(watch.isHoldingActivity)
        #expect(watch.heldSince == 1_000)
        #expect(watch.followUpAt == 1_061)
        #expect(watch.nextDeadline == 1_061)
    }

    @Test("The follow-up check is due at its time and not before, and runs once for each end of the settle time")
    func followUpOnce() {
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: 1_060, at: 1_000)
        expectDeadline(&watch, at: 1_060.5, isDue: false)
        #expect(watch.followUpAt == 1_061)
        expectDeadline(&watch, at: 1_061, isDue: true)
        #expect(watch.followUpAt == nil)
        #expect(watch.isHoldingActivity, "until a status says the wait ended")
        #expect(watch.nextDeadline == 1_000 + cap)
        // A status from before the follow-up check, with the same end.
        watch.observe(judgmentDue: 1_060, at: 1_061)
        #expect(watch.followUpAt == nil, "never twice for the same end")
        // The settle time started again: a new end, a new follow-up.
        watch.observe(judgmentDue: 1_130, at: 1_070)
        #expect(watch.followUpAt == 1_131)
        #expect(watch.heldSince == 1_000, "the same episode")
    }

    @Test("A newer end replaces the pending follow-up check: never more than one")
    func onePending() {
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: 1_060, at: 1_000)
        watch.observe(judgmentDue: 1_100, at: 1_040)
        #expect(watch.followUpAt == 1_101)
        #expect(watch.nextDeadline == 1_101)
        expectDeadline(&watch, at: 1_061, isDue: false, "the replaced one is not due")
        expectDeadline(&watch, at: 1_101, isDue: true)
        #expect(watch.followUpAt == nil)
    }

    @Test("A follow-up check whose time has passed when the status arrives is due at once")
    func lateStatus() {
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: 1_060, at: 1_075)
        #expect(watch.nextDeadline == 1_061)
        expectDeadline(&watch, at: 1_075, isDue: true)
    }

    @Test("A status that waits for nothing ends the episode: a read judged, battery power, the power source unknown, Manage charging off with nothing owed")
    func endsWhenNothingWaits() {
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: 1_060, at: 1_000)
        watch.observe(judgmentDue: nil, at: 1_030)
        #expect(!watch.isHoldingActivity)
        #expect(watch.followUpAt == nil)
        #expect(watch.nextDeadline == nil)
        expectDeadline(&watch, at: 1_061, isDue: false)
        watch.observe(judgmentDue: 1_100, at: 1_040)
        #expect(watch.heldSince == 1_040, "the next wait begins a new episode")
    }

    @Test("The cap ends an episode at its deadline, before a follow-up due later")
    func capAtDeadline() {
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: 1_060, at: 1_000)
        expectDeadline(&watch, at: 1_061, isDue: true)
        watch.observe(judgmentDue: 1_290, at: 1_230)
        #expect(watch.followUpAt == 1_291)
        watch.observe(judgmentDue: 1_330, at: 1_270)
        #expect(watch.nextDeadline == 1_000 + cap, "the cap comes before the follow-up at 1331")
        expectDeadline(&watch, at: 1_000 + cap - 0.5, isDue: false)
        #expect(watch.isHoldingActivity)
        expectDeadline(&watch, at: 1_000 + cap, isDue: false)
        #expect(!watch.isHoldingActivity)
        #expect(watch.followUpAt == nil)
        #expect(watch.nextDeadline == nil)
    }

    @Test("The cap ends an episode at a status too, and none begins again for the rest, unless the wait ends")
    func capAtStatus() {
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: 1_060, at: 1_000)
        watch.observe(judgmentDue: 1_400, at: 1_000 + cap)
        #expect(!watch.isHoldingActivity)
        #expect(watch.nextDeadline == nil)
        watch.observe(judgmentDue: 1_460, at: 1_400)
        #expect(!watch.isHoldingActivity, "the same wait goes on, within the rest")
        #expect(watch.followUpAt == nil)
        watch.observe(judgmentDue: nil, at: 1_470)
        watch.observe(judgmentDue: 1_540, at: 1_480)
        #expect(watch.isHoldingActivity, "a new wait, a new episode")
        #expect(watch.followUpAt == 1_541)
    }

    @Test("After the rest, a wait that goes on begins another episode, so it is still followed up on time")
    func capThenRest() {
        let rest = ChargeLimitSettleWatch.rest
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: 1_060, at: 1_000)
        expectDeadline(&watch, at: 1_000 + cap, isDue: false)
        #expect(!watch.isHoldingActivity)
        watch.observe(judgmentDue: 1_000 + cap + 60, at: 1_000 + cap + rest - 1)
        #expect(!watch.isHoldingActivity, "a second before the rest ends")
        watch.observe(judgmentDue: 1_000 + cap + rest + 60, at: 1_000 + cap + rest)
        #expect(watch.isHoldingActivity, "the rest is over and the wait goes on")
        #expect(watch.heldSince == 1_000 + cap + rest)
        #expect(watch.followUpAt == 1_000 + cap + rest + 61)
    }

    @Test("A wait that never ends, its deadlines handled on time, keeps the activity about half the time")
    func neverEndingWaitHalfTheTime() {
        var watch = ChargeLimitSettleWatch()
        var held: TimeInterval = 0
        var now: TimeInterval = 1_000
        let step: TimeInterval = 10
        // Statuses every 10 s for two hours, each waiting for a settle time
        // that keeps starting again.
        while now < 1_000 + 2 * 60 * 60 {
            watch.observe(judgmentDue: now + 60, at: now)
            if let deadline = watch.nextDeadline, deadline <= now + step {
                _ = watch.deadlineReached(at: deadline)
            }
            if watch.isHoldingActivity { held += step }
            now += step
        }
        #expect(held <= 60 * 60 + cap, "about half of the two hours, give or take one episode")
        #expect(held >= 60 * 60 - cap, "and episodes keep beginning")
    }

    @Test("At sleep and at quit nothing is held and nothing is pending; the next wait begins afresh, after a cap too")
    func stop() {
        var watch = ChargeLimitSettleWatch()
        watch.observe(judgmentDue: 1_060, at: 1_000)
        watch.stop()
        #expect(!watch.isHoldingActivity)
        #expect(watch.followUpAt == nil)
        #expect(watch.nextDeadline == nil)
        expectDeadline(&watch, at: 1_061, isDue: false)

        watch.observe(judgmentDue: 1_400, at: 1_100)
        watch.observe(judgmentDue: 1_400, at: 1_100 + cap)
        #expect(!watch.isHoldingActivity)
        watch.stop()
        watch.observe(judgmentDue: 1_500, at: 1_440)
        #expect(watch.isHoldingActivity, "a wake starts the settle time again")
        #expect(watch.followUpAt == 1_501)
    }

    @Test("The process activity is taken once and ended once, with its own reason")
    func processActivity() {
        let activity = ChargeLimitSettleActivity()
        #expect(!activity.isActive)
        activity.setHolding(true)
        activity.setHolding(true)
        #expect(activity.isActive)
        activity.setHolding(false)
        #expect(!activity.isActive)
        activity.setHolding(false)
        #expect(!activity.isActive)
        #expect(ChargeLimitSettleActivity.reason != ProcessLeaseActivity.reason)
    }
}
