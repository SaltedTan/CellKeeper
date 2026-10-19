import ProbeCore
import Testing

/// Builds synthetic runs on the probe's real schedule: baseline readings at
/// 0, 2, … 20 s, the assertion at 20.5 s, readings every 2 s while it is
/// held, the release, and readings every 2 s after it.
///
/// By default every reading shows a fresh battery update, made at the
/// reading's own time. With `updateInterval` (or explicit `updates`), the
/// battery publishes new values only at those moments, as on the test Mac
/// (about once a minute, research note 10 §9), and every reading repeats
/// the latest update: its state is the one the phase functions give for the
/// update's time.
struct Scenario {
    /// The Unix time of run second 0 (a whole second).
    static let epoch = 1_792_400_000.0
    static let notPrivileged = Int32(bitPattern: 0xE000_02C1)
    static let notFound = Int32(bitPattern: 0xE000_02F0)

    var assertion = AssertionKind.disableInflow
    var creationTime = 20.5
    var hold = 180
    var creationResult: Int32 = 0
    /// The state at `seconds` after creation; default: charging stopped
    /// from 4 s on.
    var held: (Double) -> Sample.Reading = { $0 < 4 ? .charging : .stopped }
    /// The state at `seconds` after the release; default: resumed from 6 s.
    var after: (Double) -> Sample.Reading = { $0 < 6 ? .stopped : .charging }
    var afterDuration = 180.0
    var baselineTimes = Array(stride(from: 0.0, through: 20, by: 2))
    var baseline: (Double) -> Sample.Reading = { _ in .charging }
    var releaseResult: Int32 = 0
    var releaseAttempts = 1
    var stillListed: Bool? = false
    /// Extra readings while held, at seconds after creation.
    var extraHeld: [(Double, Sample.Reading)] = []
    /// If set, exactly these readings after the release, at seconds after it.
    var afterReadings: [(Double, Sample.Reading)]?
    /// Battery updates every this many seconds, one of them at
    /// `updatePhase` (run seconds); nil: every reading is its own update.
    var updateInterval: Double?
    var updatePhase = 6.0
    /// Explicit battery update times (run seconds), instead of an interval.
    var updates: [Double]?
    /// No battery update after this run time.
    var updatesStopAt: Double?
    var sleepNotices: [ProbeRun.SleepNotice] = []

    var releasedAt: Double { creationTime + Double(hold) + 0.5 }

    /// The latest update at or before `time`, or nil if every reading is its
    /// own update.
    func update(atOrBefore time: Double) -> Double? {
        let limit = min(time, updatesStopAt ?? time)
        if let updates {
            return updates.last { $0 <= limit }
        }
        guard let interval = updateInterval else { return updatesStopAt.map { min(time, $0) } }
        return updatePhase + ((limit - updatePhase) / interval).rounded(.down) * interval
    }

    /// The state the battery reports for an update made at `time`.
    func state(atUpdate time: Double) -> Sample.Reading {
        if time < creationTime { return baseline(time) }
        if time < releasedAt { return held(time - creationTime) }
        return after(time - releasedAt)
    }

    func sample(at time: Double, _ phase: Sample.Phase, own: Sample.Reading) -> Sample {
        let made = update(atOrBefore: time)
        var sample = (made.map { state(atUpdate: $0) } ?? own).sample(at: time, phase)
        sample.updateTime = Int((Self.epoch + (made ?? time)).rounded(.down))
        return sample
    }

    var run: ProbeRun {
        var samples = baselineTimes.map { sample(at: $0, .baseline, own: baseline($0)) }
        let creation = ProbeRun.Creation(
            time: creationTime, unixTime: Self.epoch + creationTime, result: creationResult, timeout: hold + 30
        )
        guard creationResult == 0 else {
            return ProbeRun(assertion: assertion, samples: samples, creation: creation, release: nil)
        }
        let heldTimes = stride(from: 2.0, through: Double(hold), by: 2)
        samples += heldTimes.map { sample(at: creationTime + $0, .held, own: held($0)) }
        samples += extraHeld.map { sample(at: creationTime + $0.0, .held, own: $0.1) }
        let afterReadings = afterReadings ?? stride(from: 2.0, through: afterDuration, by: 2).map { ($0, after($0)) }
        samples += afterReadings.map { sample(at: releasedAt + $0.0, .after, own: $0.1) }
        let release = ProbeRun.Release(
            time: releasedAt, unixTime: Self.epoch + releasedAt, result: releaseResult,
            attempts: releaseAttempts, stillListed: stillListed
        )
        return ProbeRun(assertion: assertion, samples: samples, creation: creation, release: release, sleepNotices: sleepNotices)
    }

    var verdict: Verdict { Verdict.evaluate(run) }

    /// The reason of an inconclusive verdict, or nil.
    var inconclusiveReason: String? {
        if case let .inconclusive(reason) = verdict { return reason }
        return nil
    }
}

extension Sample {
    /// Shorthands for the readings a run can see.
    enum Reading {
        case charging
        case stopped
        /// Charging flag still on while the current has already fallen.
        case flagLagging
        /// Charging flag off while current still flows: a flag-only effect.
        case flagOnly
        /// The adapter unplugged: battery power, discharging, and no read
        /// reports an adapter.
        case unplugged
        /// The adapter's power cut while it stays plugged in: battery power,
        /// discharging, the adapter still reported attached, almost no
        /// power input.
        case cut
        /// As `cut`, but IOPowerSources still reports AC power.
        case cutOnAC
        /// Discharging on AC power while the adapter still delivers power
        /// (a weak adapter, or a high load).
        case weakAdapter
        /// Apple's published fallback for DisableInflow: only the
        /// `ExternalConnected` flag changes, and the battery still charges.
        case flagOnlyCut
        case full
        case unreadable

        func sample(at time: Double, _ phase: Sample.Phase) -> Sample {
            var sample = Sample(
                time: time, phase: phase, externalPower: true, batteryPresent: true, percent: 62,
                isCharging: true, isCharged: false, averageCurrent: 1500, instantCurrent: 1480,
                registryIsCharging: true, registryExternalConnected: true, rawExternalConnected: true,
                adapterAttached: true, adapterWatts: 68,
                updateTime: Int((Scenario.epoch + time).rounded(.down)), unixTime: Scenario.epoch + time,
                systemPowerIn: 45000
            )
            switch self {
            case .charging:
                break
            case .stopped:
                sample.isCharging = false
                sample.averageCurrent = 0
                sample.instantCurrent = 0
                sample.systemPowerIn = 10000
            case .flagLagging:
                sample.instantCurrent = 10
            case .flagOnly:
                sample.isCharging = false
            case .unplugged:
                sample.externalPower = false
                sample.isCharging = false
                sample.instantCurrent = -900
                sample.registryExternalConnected = false
                sample.rawExternalConnected = false
                sample.adapterAttached = false
                sample.adapterWatts = nil
                sample.systemPowerIn = 0
            case .cut:
                sample.externalPower = false
                sample.isCharging = false
                sample.instantCurrent = -900
                sample.registryExternalConnected = false
                sample.systemPowerIn = 300
            case .cutOnAC:
                sample.isCharging = false
                sample.instantCurrent = -900
                sample.systemPowerIn = 200
            case .weakAdapter:
                sample.isCharging = false
                sample.instantCurrent = -400
                sample.systemPowerIn = 30000
            case .flagOnlyCut:
                sample.externalPower = false
                sample.registryExternalConnected = false
            case .full:
                sample.percent = 100
                sample.isCharged = true
            case .unreadable:
                sample.instantCurrent = nil
                sample.averageCurrent = nil
            }
            return sample
        }
    }
}

@Suite("The verdict over synthetic runs")
struct VerdictTests {
    // MARK: Charging stopped on adapter power (outcome b)

    @Test("Charging stops after creation and resumes after the release: inhibited")
    func inhibited() {
        let verdict = Scenario().verdict
        #expect(verdict == .inhibited(stoppedAfter: 4, resumedAfter: 6))
        #expect(verdict.title == "inhibited")
        #expect(verdict.exitStatus == 0)
        let explanation = verdict.explanation(assertion: .disableInflow)
        #expect(explanation.contains("DisableInflow"))
        #expect(explanation.contains("thermal management can also stop charging"))
    }

    @Test("ChargeInhibit is judged by the same rules")
    func chargeInhibitSameRules() {
        var scenario = Scenario()
        scenario.assertion = .chargeInhibit
        #expect(scenario.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 6))
        #expect(scenario.verdict.explanation(assertion: .chargeInhibit).contains("the ChargeInhibit assertion"))

        scenario.held = { $0 < 4 ? .charging : .cut }
        scenario.after = { $0 < 6 ? .cut : .charging }
        #expect(scenario.verdict == .adapterCut(cutAfter: 4, powerBackAfter: 6, resumedAfter: 6))
    }

    @Test("Readings that disagree while the current falls, before the stop, are allowed")
    func transitionBeforeStop() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case ..<8: .flagLagging
            default: .stopped
            }
        }
        #expect(scenario.verdict == .inhibited(stoppedAfter: 8, resumedAfter: 6))
    }

    @Test("After the release, readings that disagree while charging ramps up are allowed")
    func transitionAfterRelease() {
        var scenario = Scenario()
        scenario.after = { seconds in
            switch seconds {
            case ..<6: .stopped
            case ..<10: .flagLagging
            default: .charging
            }
        }
        #expect(scenario.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 10))
    }

    @Test("The instant current is used before the average, which lags")
    func instantCurrentFirst() {
        var run = Scenario().run
        // The average still shows charging current while the instant reading
        // is already zero.
        for index in run.samples.indices where run.samples[index].phase == .held && run.samples[index].isCharging == false {
            run.samples[index].averageCurrent = 700
        }
        #expect(Verdict.evaluate(run) == .inhibited(stoppedAfter: 4, resumedAfter: 6))
    }

    @Test("Charging resumes, but later than 120 s after the release: inhibited, resumed late")
    func resumedLate() {
        var scenario = Scenario()
        scenario.after = { $0 < 130 ? .stopped : .charging }
        scenario.afterDuration = 200
        let verdict = scenario.verdict
        #expect(verdict == .inhibitedResumedLate(stoppedAfter: 4, resumedAfter: 130))
        #expect(verdict.title == "inhibited, resumed late")
    }

    @Test("Charging resumes exactly at the end of the 120 s window and stays: still inhibited")
    func resumedAtWindowEdge() {
        var scenario = Scenario()
        scenario.after = { $0 < 120 ? .stopped : .charging }
        scenario.afterDuration = 140
        #expect(scenario.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 120))
    }

    @Test("Charging never resumes: a distinct verdict that sends the owner to the recovery steps")
    func neverResumed() {
        var scenario = Scenario()
        scenario.after = { _ in .stopped }
        scenario.afterDuration = 300
        let verdict = scenario.verdict
        #expect(verdict == .inhibitedDidNotResume(stoppedAfter: 4, watchedFor: 300))
        #expect(verdict.title == "inhibited, did not resume")
        #expect(verdict.exitStatus == 3)
        let explanation = verdict.explanation(assertion: .disableInflow)
        #expect(explanation.contains("recovery steps"))
        #expect(explanation.contains("docs/safety.md"))
        #expect(explanation.contains("pmset -g assertions"))
        #expect(explanation.contains("lists no DisableInflow"))
        #expect(explanation.contains("restart"))
        #expect(explanation.contains("shut it down"))
    }

    // MARK: The adapter's power cut (outcome c)

    @Test("The Mac runs from its battery while held, adapter reported, almost no input: adapter cut")
    func adapterCut() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .cut }
        scenario.after = { $0 < 6 ? .cut : .charging }
        let verdict = scenario.verdict
        #expect(verdict == .adapterCut(cutAfter: 4, powerBackAfter: 6, resumedAfter: 6))
        #expect(verdict.title == "adapter cut")
        #expect(verdict.exitStatus == 0)
        let explanation = verdict.explanation(assertion: .disableInflow)
        #expect(explanation.contains("[INFERRED/UNVERIFIED]"))
        #expect(explanation.contains("1000 mW"))
        #expect(explanation.contains("Confirm that the adapter stayed plugged in"))
    }

    @Test("Discharging while IOPowerSources still reports AC power counts as a cut too")
    func adapterCutOnAC() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .cutOnAC }
        scenario.after = { $0 < 6 ? .cutOnAC : .charging }
        #expect(scenario.verdict == .adapterCut(cutAfter: 4, powerBackAfter: 6, resumedAfter: 6))
    }

    @Test("Adapter power returning is reported apart from charging resuming")
    func powerBackBeforeCharging() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .cut }
        scenario.after = { seconds in
            switch seconds {
            case ..<6: .cut
            case ..<40: .stopped
            default: .charging
            }
        }
        let verdict = scenario.verdict
        #expect(verdict == .adapterCut(cutAfter: 4, powerBackAfter: 6, resumedAfter: 40))
        #expect(verdict.explanation(assertion: .disableInflow).contains("Adapter power was back 6.0 s after the release"))
    }

    @Test("A cut whose charging comes back after the 120 s window: adapter cut, resumed late")
    func adapterCutResumedLate() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .cut }
        scenario.after = { $0 < 130 ? .cut : .charging }
        scenario.afterDuration = 200
        let verdict = scenario.verdict
        #expect(verdict == .adapterCutResumedLate(cutAfter: 4, powerBackAfter: 130, resumedAfter: 130))
        #expect(verdict.title == "adapter cut, resumed late")
        #expect(verdict.exitStatus == 0)
    }

    @Test("A cut that does not end after the release: discharging, did not resume, with the recovery steps")
    func cutDidNotRestore() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .cut }
        scenario.after = { _ in .cut }
        scenario.afterDuration = 300
        let verdict = scenario.verdict
        #expect(verdict == .dischargingDidNotResume(dischargedAfter: 4, powerBackAfter: nil, watchedFor: 300, looksLikeCut: true))
        #expect(verdict.title == "discharging, did not resume")
        #expect(verdict.exitStatus == 3)
        let explanation = verdict.explanation(assertion: .disableInflow)
        #expect(explanation.contains("looked like an adapter cut"))
        #expect(explanation.contains("lists no DisableInflow"))
        #expect(explanation.contains("shut it down, wait about 30 seconds"))
    }

    @Test("Discharging with the adapter still delivering power is not a cut")
    func weakAdapter() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .weakAdapter }
        scenario.after = { $0 < 6 ? .weakAdapter : .charging }
        let verdict = scenario.verdict
        #expect(verdict == .dischargingWithAdapter(dischargedAfter: 4, resumedAfter: 6))
        #expect(verdict.title == "discharging with adapter attached")
        #expect(verdict.exitStatus == 0)
        #expect(verdict.explanation(assertion: .disableInflow).contains("not attributed to a cut"))
    }

    @Test("One reading above the input threshold is enough to withhold the cut verdict")
    func oneHighInput() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case 50: .weakAdapter
            default: .cut
            }
        }
        scenario.after = { $0 < 6 ? .cut : .charging }
        #expect(scenario.verdict == .dischargingWithAdapter(dischargedAfter: 4, resumedAfter: 6))
    }

    @Test("An unreadable power input during the discharge withholds the cut verdict")
    func unknownInput() {
        var run = Scenario(held: { $0 < 4 ? .charging : .cut }, after: { $0 < 6 ? .cut : .charging }).run
        if let index = run.samples.firstIndex(where: { $0.phase == .held && $0.time > Scenario().creationTime + 50 }) {
            run.samples[index].systemPowerIn = nil
        }
        #expect(Verdict.evaluate(run) == .dischargingWithAdapter(dischargedAfter: 4, resumedAfter: 6))
    }

    @Test("Readings that look like an unplugged adapter: inconclusive, with the times, even though charging comes back")
    func unplugLike() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .unplugged }
        scenario.after = { $0 < 6 ? .unplugged : .charging }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("the battery discharged 4.0 s after the assertion was created") == true)
        #expect(reason?.contains("did not report the adapter attached") == true)
        #expect(reason?.contains("unplugged at those moments would look the same") == true)
        #expect(scenario.verdict.exitStatus == 2)
    }

    @Test("A single unplug-like reading during a cut withholds the cut verdict")
    func oneUnplugLikeReading() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case 60: .unplugged
            default: .cut
            }
        }
        scenario.after = { $0 < 6 ? .cut : .charging }
        #expect(scenario.inconclusiveReason?.contains("1 of the") == true)
    }

    @Test("Unplug-like readings that never end still send the owner to the recovery steps")
    func unplugLikeNeverResumed() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .unplugged }
        scenario.after = { _ in .unplugged }
        scenario.afterDuration = 300
        let verdict = scenario.verdict
        #expect(verdict == .dischargingDidNotResume(dischargedAfter: 4, powerBackAfter: nil, watchedFor: 300, looksLikeCut: false))
        #expect(verdict.exitStatus == 3)
        #expect(verdict.explanation(assertion: .disableInflow).contains("did not all look like an adapter cut"))
    }

    @Test("Apple's fallback, which changes only ExternalConnected, never passes as a cut")
    func flagOnlyCut() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .flagOnlyCut }
        scenario.after = { _ in .charging }
        #expect(Verdict.state(of: Sample.Reading.flagOnlyCut.sample(at: 0, .held)) == .mixed)
        #expect(scenario.inconclusiveReason?.contains("disagreed") == true)
    }

    @Test("A cut that ends while the assertion is still held: inconclusive")
    func cutEndsWhileHeld() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case ..<60: .cut
            default: .charging
            }
        }
        scenario.after = { _ in .charging }
        #expect(scenario.inconclusiveReason?.contains("charging started again 60.0 s after it, while it was still held") == true)
    }

    @Test("A stop that turns into a discharge while held: inconclusive")
    func effectChanges() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case ..<50: .stopped
            default: .cut
            }
        }
        #expect(scenario.inconclusiveReason?.contains("readings changed (battery power, not charging, -900 mA)") == true)
    }

    @Test("Battery power after the release is no problem after a cut, but is after a stop")
    func batteryAfterRelease() {
        let after = (2...10).map { Sample.Reading.cut.sample(at: 200 + Double($0) * 2, .after) }
        #expect(Verdict.analyzeResume(after, releasedAt: Scenario.epoch + 200, batteryAllowed: true) == .pending(sawCharging: false))
        guard case let .problem(_, problem) = Verdict.analyzeResume(after, releasedAt: Scenario.epoch + 200, batteryAllowed: false) else {
            Issue.record("expected a problem")
            return
        }
        #expect(problem == .onBattery)
    }

    // MARK: No effect (outcome a)

    @Test("Charging continues while the assertion is held: no effect observed during the measured hold")
    func noEffect() {
        var scenario = Scenario()
        scenario.held = { _ in .charging }
        scenario.after = { _ in .charging }
        let verdict = scenario.verdict
        #expect(verdict == .noEffect(heldFor: 180))
        #expect(verdict.title == "no effect observed")
        #expect(verdict.explanation(assertion: .disableInflow).contains("during the measured hold"))
        #expect(verdict.exitStatus == 0)
    }

    @Test("A creation that does not succeed is refused, whatever follows")
    func refused() {
        var scenario = Scenario()
        scenario.creationResult = Scenario.notPrivileged
        let verdict = scenario.verdict
        #expect(verdict == .refused(result: Scenario.notPrivileged))
        #expect(verdict.title == "refused")
        #expect(verdict.explanation(assertion: .disableInflow).contains("0xe00002c1 (kIOReturnNotPrivileged)"))
    }

    // MARK: Battery updates about once a minute (note 09 §10, note 10 §4)

    /// The test Mac's cadence: one update a minute, one of them 6 s into the
    /// run, so the first update during the hold comes 46 s after creation,
    /// as in note 09's run.
    var minuteUpdates: Scenario {
        var scenario = Scenario()
        scenario.updateInterval = 60
        scenario.updatePhase = 6
        return scenario
    }

    @Test("A stop seen only in readings that repeat one battery update is not sustained")
    func oneUpdateIsNotSustained() {
        var scenario = minuteUpdates
        scenario.hold = 100
        scenario.held = { $0 < 40 ? .charging : .stopped }
        let held = scenario.run.samples.filter { $0.phase == .held && Verdict.state(of: $0) == .stopped }
        #expect(held.count == 28)
        #expect(Set(held.compactMap(\.updateTime)).count == 1)
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("of 1 battery update") == true)
        #expect(reason?.contains("of at least 2 battery updates needed") == true)
    }

    @Test("A stop first seen at the update 46 s after creation is attributed, and confirmed by the next")
    func stopAfter46Seconds() {
        var scenario = minuteUpdates
        scenario.held = { $0 < 40 ? .charging : .stopped }
        scenario.after = { $0 < 30 ? .stopped : .charging }
        #expect(scenario.verdict == .inhibited(stoppedAfter: 46, resumedAfter: 46))
    }

    @Test("No effect needs two battery updates made after the creation; note 09's run had one")
    func noEffectNeedsTwoUpdates() {
        var scenario = minuteUpdates
        scenario.held = { _ in .charging }
        scenario.after = { _ in .charging }
        scenario.hold = 100
        #expect(scenario.inconclusiveReason?.contains("only 1 battery update made after its creation") == true)
        scenario.hold = 180
        #expect(scenario.verdict == .noEffect(heldFor: 180))
    }

    @Test("A resume seen only in readings of one update is not a resume yet")
    func resumeNeedsTwoUpdates() {
        var scenario = minuteUpdates
        scenario.held = { $0 < 40 ? .charging : .stopped }
        // Updates come 45 and 105 s after the release; charging shows from
        // the second.
        scenario.after = { $0 < 70 ? .stopped : .charging }
        scenario.afterDuration = 100
        #expect(scenario.inconclusiveReason?.contains("before the 120.0 s window was over") == true)
        // Readings end before the update after the first charging one.
        scenario.afterDuration = 130
        #expect(scenario.inconclusiveReason?.contains("charged in some readings, but never in 5 readings") == true)
        scenario.afterDuration = 170
        #expect(scenario.verdict == .inhibited(stoppedAfter: 46, resumedAfter: 106))
    }

    @Test("An update in the same second as the creation never counts as the effect's first")
    func ambiguousUpdateSecond() {
        var scenario = Scenario()
        // The baseline's updates at -54 and 6 s; one at 20.9 s, in the
        // creation's second (20.5 s), already shows the stop.
        scenario.updates = [-54, 6, 20.9, 80.9, 140.9, 200.9, 260.9, 320.9]
        scenario.held = { _ in .stopped }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("not clearly made after the creation") == true)
    }

    @Test("Madeafter: only an UpdateTime in a later second than the moment counts")
    func madeAfterRule() {
        var sample = Sample.Reading.charging.sample(at: 0, .held)
        sample.updateTime = 100
        #expect(!Verdict.madeAfter(sample, 100.8))
        #expect(!Verdict.madeAfter(sample, 100.0))
        #expect(Verdict.madeAfter(sample, 99.9))
        sample.updateTime = nil
        #expect(!Verdict.madeAfter(sample, 0))
    }

    @Test("Did not resume needs two updates made after the release; otherwise inconclusive, recovery still printed")
    func didNotResumeNeedsUpdates() {
        var scenario = minuteUpdates
        scenario.held = { $0 < 40 ? .charging : .stopped }
        scenario.after = { _ in .stopped }
        scenario.afterDuration = 300
        // The battery stops publishing just before the release.
        scenario.updatesStopAt = 195
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("only 0 battery updates made after the release") == true)
        let report = Report(
            assertion: .disableInflow, startedAt: "2026-10-20 10:00:00 +11:00",
            machine: .init(model: "Mac16,1", osVersion: "27.0.1", osBuild: "26A434", firmware: "mBoot-20457.1.29"),
            hold: 180, preconditionChecks: [], run: scenario.run, verdict: scenario.verdict
        )
        #expect(report.needsRecovery())
        #expect(report.render().contains("CHECK RECOVERY FIRST"))
    }

    @Test("A battery update older than 150 s while held ends the hold: inconclusive")
    func staleWhileHeld() {
        var scenario = minuteUpdates
        scenario.held = { _ in .charging }
        scenario.updatesStopAt = 30
        #expect(scenario.inconclusiveReason?.contains("had not been updated for more than 150 s") == true)
        var stale = Sample.Reading.charging.sample(at: 200, .held)
        stale.updateTime = Int(Scenario.epoch) + 49
        #expect(Verdict.holdProblem(of: stale) == .staleUpdate(150))
    }

    @Test("A baseline that shows only one battery update creates nothing")
    func baselineOneUpdate() {
        var scenario = minuteUpdates
        scenario.updatePhase = 30
        let baseline = scenario.run.samples.filter { $0.phase == .baseline }
        #expect(Set(baseline.compactMap(\.updateTime)).count == 1)
        #expect(!Verdict.baselineReady(baseline, minimumSpan: 19.5))
        #expect(Verdict.baselineProblem(baseline)?.contains("only 1 battery update") == true)
        #expect(scenario.inconclusiveReason?.contains("only 1 battery update") == true)
        #expect(Verdict.baselineReady(minuteUpdates.run.samples.filter { $0.phase == .baseline }, minimumSpan: 19.5))
    }

    @Test("The baseline's latest update must be at most 70 s old when the assertion is created")
    func baselineUpdateAge() {
        let baseline = [0.0, 2, 4].map { Sample.Reading.charging.sample(at: $0, .baseline) }
        #expect(Verdict.baselineFreshnessProblem(baseline, at: 4.5, unixTime: Scenario.epoch + 4.5) == nil)
        #expect(Verdict.baselineFreshnessProblem(baseline, at: 8, unixTime: Scenario.epoch + 8) == nil)
        let late = Verdict.baselineFreshnessProblem(baseline, at: 10, unixTime: Scenario.epoch + 10)
        #expect(late?.contains("6.0 s old") == true)
        #expect(late?.contains("nothing was created") == true)
        let stale = Verdict.baselineFreshnessProblem(baseline, at: 4.5, unixTime: Scenario.epoch + 75)
        #expect(stale?.contains("latest battery update was 71.0 s old") == true)
        #expect(Verdict.baselineFreshnessProblem([], at: 1, unixTime: Scenario.epoch) != nil)
    }

    @Test("An UpdateTime that goes backward, or lies ahead of the wall clock, is inconclusive")
    func updateTimeOrder() {
        var backward = Scenario().run
        if let index = backward.samples.firstIndex(where: { $0.phase == .held && $0.time > 60 }) {
            backward.samples[index].updateTime! -= 30
        }
        guard case let .inconclusive(reason) = Verdict.evaluate(backward) else {
            Issue.record("expected inconclusive")
            return
        }
        #expect(reason.contains("UpdateTime went backward"))

        var ahead = Scenario().run
        if let index = ahead.samples.lastIndex(where: { $0.phase == .after }) {
            ahead.samples[index].updateTime! += 5
        }
        guard case let .inconclusive(aheadReason) = Verdict.evaluate(ahead) else {
            Issue.record("expected inconclusive")
            return
        }
        #expect(aheadReason.contains("ahead of the reading's wall time"))
    }

    @Test("A wall clock that jumps between readings is inconclusive")
    func wallClockJump() {
        var run = Scenario().run
        for index in run.samples.indices where run.samples[index].time > 100 {
            run.samples[index].unixTime! += 5
            run.samples[index].updateTime! += 5
        }
        guard case let .inconclusive(reason) = Verdict.evaluate(run) else {
            Issue.record("expected inconclusive")
            return
        }
        #expect(reason.contains("wall clock and the run's clock disagreed"))
    }

    // MARK: Sleep and safety

    @Test("A system sleep notification makes the run inconclusive")
    func sleepNotice() {
        var scenario = Scenario()
        scenario.sleepNotices = [.init(time: 90, message: "kIOMessageSystemWillSleep")]
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("kIOMessageSystemWillSleep at +90.0 s") == true)
        scenario.sleepNotices = [.init(time: 90, message: "kIOMessageCanSystemSleep")]
        #expect(scenario.inconclusiveReason?.contains("kIOMessageCanSystemSleep") == true)
    }

    @Test("A charge below 25% while held ends the hold: inconclusive")
    func chargeFloor() {
        var run = Scenario(held: { $0 < 4 ? .charging : .cut }, after: { $0 < 6 ? .cut : .charging }).run
        for index in run.samples.indices where run.samples[index].phase == .held && run.samples[index].time > 100 {
            run.samples[index].percent = 24
        }
        guard case let .inconclusive(reason) = Verdict.evaluate(run) else {
            Issue.record("expected inconclusive")
            return
        }
        #expect(reason.contains("the charge fell below 25%"))
        var low = Sample.Reading.cut.sample(at: 0, .held)
        low.percent = 25
        #expect(Verdict.holdProblem(of: low) == nil)
        low.percent = 24
        #expect(Verdict.holdProblem(of: low) == .belowFloor(25))
        // Battery power alone never ends the hold.
        #expect(Verdict.holdProblem(of: Sample.Reading.cut.sample(at: 0, .held)) == nil)
    }

    // MARK: Sustained runs (finding: a mixed sequence gave a false "inhibited")

    @Test("A flag-only effect with one current dip is not inhibited")
    func flagOnlyWithOneDip() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case 10: .stopped
            default: .flagOnly
            }
        }
        // Charging resumes after the release, as it would with a flag-only effect.
        scenario.after = { _ in .charging }
        #expect(scenario.inconclusiveReason?.contains("disagreed") == true)
    }

    @Test("A flag-only effect with no dip at all is not inhibited either")
    func flagOnly() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .flagOnly }
        #expect(scenario.inconclusiveReason?.contains("never clearly stopped") == true)
    }

    @Test("Current that flows again while the flag stays off, after a real stop, is inconclusive")
    func currentReturnsWhileFlagOff() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case ..<30: .stopped
            default: .flagOnly
            }
        }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("disagreed") == true)
        #expect(reason?.contains("30.0 s after it") == true)
    }

    @Test("A flag that comes back on with no current, after a real stop, is inconclusive")
    func flagReturnsWithoutCurrent() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case 40: .flagLagging
            default: .stopped
            }
        }
        #expect(scenario.inconclusiveReason?.contains("disagreed") == true)
    }

    @Test("A single stopped reading, then charging, then a long stop: inconclusive")
    func dipThenStop() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case 4: .stopped
            case ..<12: .charging
            default: .stopped
            }
        }
        #expect(scenario.inconclusiveReason?.contains("started again") == true)
    }

    @Test("A stop that lasts fewer than 5 readings before the release: inconclusive")
    func stopTooShort() {
        var scenario = Scenario()
        scenario.hold = 96
        scenario.held = { $0 < 90 ? .charging : .stopped }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("only 4 readings") == true)
        #expect(reason?.contains("5 readings at least 1.5 s apart, spanning at least 8.0 s, of at least 2 battery updates needed") == true)
    }

    @Test("Exactly 5 stopped readings, 2 s apart and spanning 8 s, at the end of the 90 s window, are enough")
    func stopExactlySustained() {
        var scenario = Scenario()
        scenario.hold = 98
        scenario.held = { $0 < 90 ? .charging : .stopped }
        let stopped = scenario.run.samples.filter { $0.phase == .held && Verdict.state(of: $0) == .stopped }
        #expect(stopped.map(\.time) == [90, 92, 94, 96, 98].map { Scenario().creationTime + $0 })
        #expect(scenario.verdict == .inhibited(stoppedAfter: 90, resumedAfter: 6))
    }

    // MARK: Clustered readings (finding: clustered samples confirmed a stop or a resume)

    @Test("The reviewer's case: four charging readings within 0.1 s and one more are not a resume")
    func reviewerClusteredResume() {
        var scenario = Scenario()
        let charging: [(Double, Sample.Reading)] = [9.900, 9.901, 9.902, 9.903, 10.000].map { ($0, .charging) }
        let stopped: [(Double, Sample.Reading)] = stride(from: 12.0, through: 180, by: 2).map { ($0, .stopped) }
        scenario.afterReadings = [(2, .stopped), (4, .stopped), (6, .stopped), (8, .stopped)] + charging + stopped
        #expect(scenario.verdict.title == "inconclusive")
        #expect(scenario.inconclusiveReason?.contains("never in 5 readings") == true)
    }

    @Test("Clustered charging readings after the release count as one")
    func clusteredResumeCountsOnce() {
        var scenario = Scenario()
        let cluster: [(Double, Sample.Reading)] = stride(from: 6.0, through: 6.8, by: 0.1).map { ($0, .charging) }
        // One cluster, then two more charging readings 2 s apart: three counted, not five.
        scenario.afterReadings = [(2, .stopped), (4, .stopped)] + cluster + [(8.8, .charging), (10.8, .charging)]
            + stride(from: 12.8, through: 180, by: 2).map { ($0, .stopped) }
        #expect(scenario.inconclusiveReason?.contains("never in 5 readings") == true)
    }

    @Test("Five charging readings 1.5 s apart span only 6 s; the resume counts once the run spans 8 s")
    func resumeNeedsSpan() {
        let fiveOnly: [(Double, Sample.Reading)] = [6, 7.5, 9, 10.5, 12].map { ($0, .charging) }
        var short = Scenario()
        short.afterReadings = [(2, .stopped), (4, .stopped)] + fiveOnly
            + stride(from: 14.0, through: 180, by: 2).map { ($0, .stopped) }
        #expect(short.inconclusiveReason?.contains("never in 5 readings") == true)

        var long = Scenario()
        long.afterReadings = [(2, .stopped), (4, .stopped)] + fiveOnly + [(13.5, .charging), (15, .charging)]
            + stride(from: 17.0, through: 70, by: 2).map { ($0, .charging) }
        #expect(long.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 6))
    }

    @Test("Clustered stopped readings do not make a sustained stop")
    func clusteredStop() {
        var scenario = Scenario()
        scenario.hold = 92
        scenario.held = { $0 < 90 ? .charging : .stopped }
        scenario.extraHeld = [90.4, 90.8, 91.2, 91.6].map { ($0, .stopped) }
        #expect(scenario.inconclusiveReason?.contains("only 2 readings") == true)
    }

    @Test("Five stopped readings 1.5 s apart span only 6 s: not a sustained stop")
    func stopNeedsSpan() {
        var scenario = Scenario()
        scenario.hold = 92
        scenario.held = { $0 < 86 ? .charging : .stopped }
        // Replace the regular stopped readings with ones 1.5 s apart.
        var run = scenario.run
        let creation = scenario.creationTime
        run.samples.removeAll { $0.phase == .held && $0.time >= creation + 86 }
        run.samples += [86, 87.5, 89, 90.5, 92].map { Sample.Reading.stopped.sample(at: creation + $0, .held) }
        guard case let .inconclusive(reason) = Verdict.evaluate(run) else {
            Issue.record("expected inconclusive, got \(Verdict.evaluate(run))")
            return
        }
        #expect(reason.contains("only 5 readings"))
        #expect(reason.contains("spanning 6.0 s"))
    }

    @Test("Extra readings closer than 1.5 s neither count nor break a stop")
    func closeReadingsIgnored() {
        var scenario = Scenario()
        scenario.extraHeld = [4.3, 10.2, 10.9, 31.1].map { ($0, .stopped) }
        #expect(scenario.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 6))
    }

    @Test("A contradicting reading breaks the stop even when it is close to the last one")
    func closeContradictionBreaks() {
        var scenario = Scenario()
        scenario.extraHeld = [(10.3, .flagOnly)]
        #expect(scenario.inconclusiveReason?.contains("disagreed") == true)
    }

    @Test("A contradicting reading close to a charging one breaks a resume run")
    func closeContradictionBreaksResume() {
        var scenario = Scenario()
        // Charging from 6 s, with a stopped reading 0.3 s after the one at 10 s:
        // the run restarts at 12 s.
        scenario.afterReadings = [(2, .stopped), (4, .stopped), (6, .charging), (8, .charging), (10, .charging), (10.3, .stopped)]
            + stride(from: 12.0, through: 70, by: 2).map { ($0, .charging) }
        #expect(scenario.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 12))
    }

    @Test("A sustained run counts readings at least 1.5 s apart, needs 8 s and 2 battery updates")
    func sustainedRunRule() {
        func sample(_ time: Double, update: Int? = nil) -> Sample {
            var sample = Sample.Reading.stopped.sample(at: time, .held)
            if let update { sample.updateTime = update }
            return sample
        }
        var run = SustainedRun(first: sample(0))
        for time in [0.5, 1.0, 1.4] { run.add(sample(time)) }
        #expect(run.counted == 1)
        run.add(sample(1.5))
        #expect(run.counted == 2)
        for time in [3.5, 5.5, 7.5] { run.add(sample(time)) }
        #expect(run.counted == 5)
        #expect(run.span == 7.5)
        #expect(!run.isSustained())
        run.add(sample(9.5))
        #expect(run.isSustained())

        // Six readings 2 s apart that repeat one update are not sustained.
        var repeated = SustainedRun(first: sample(0, update: 7))
        for time in stride(from: 2.0, through: 10, by: 2) { repeated.add(sample(time, update: 7)) }
        #expect(repeated.counted == 6)
        #expect(!repeated.isSustained())
        repeated.add(sample(12, update: 8))
        #expect(repeated.isSustained())
    }

    // MARK: Sampling (finding: overdue deadlines ran back to back)

    @Test("The sampler never catches up: after a late reading, the next is due an interval later")
    func nextDeadline() {
        #expect(ProbeSchedule.nextDeadline(after: 10, readAt: 10.05) == 12)
        #expect(ProbeSchedule.nextDeadline(after: 10, readAt: 10.5) == 12)
        #expect(ProbeSchedule.nextDeadline(after: 10, readAt: 16) == 18)
        #expect(abs(ProbeSchedule.nextDeadline(after: 10, readAt: 10.6) - 12.6) < 1e-9)
        for lateness in stride(from: 0.0, through: 30, by: 0.05) {
            let readAt = 10 + lateness
            #expect(ProbeSchedule.nextDeadline(after: 10, readAt: readAt) - readAt >= 1.5 - 1e-9)
        }
    }

    @Test("A stall in the middle of a phase yields one late reading, not a burst")
    func stallSimulation() {
        // A sampler that wakes at its deadline, except that nothing runs
        // between 7 s and 15 s.
        var deadline = 0.0
        var times: [Double] = []
        while deadline <= 40 {
            let readAt = (7..<15).contains(deadline) ? 15 : deadline
            times.append(readAt)
            deadline = ProbeSchedule.nextDeadline(after: deadline, readAt: readAt)
        }
        let spacings = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(spacings.allSatisfy { $0 >= 1.5 })
        #expect(times.filter { $0 == 15 }.count == 1)
    }

    @Test("A single charging reading after the release is not a resume")
    func resumeFlicker() {
        var scenario = Scenario()
        scenario.after = { $0 == 10 ? .charging : .stopped }
        #expect(scenario.inconclusiveReason?.contains("never in 5 readings") == true)
    }

    @Test("A resume counts from the start of 5 charging readings in a row")
    func resumeAfterFlicker() {
        var scenario = Scenario()
        scenario.after = { seconds in
            switch seconds {
            case 10: .charging
            case ..<20: .stopped
            default: .charging
            }
        }
        #expect(scenario.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 20))
    }

    // MARK: Release (finding: a failed release could count as a recovery)

    @Test("A failed release is inconclusive, even when charging later resumes")
    func failedRelease() {
        var scenario = Scenario()
        scenario.releaseResult = Scenario.notFound
        scenario.releaseAttempts = 3
        // powerd's 210 s timeout fires 30 s after the intended release;
        // charging resuming then must not count.
        scenario.after = { $0 < 30 ? .stopped : .charging }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("0xe00002f0 (kIOReturnNotFound)") == true)
        #expect(reason?.contains("3 attempts") == true)
        #expect(reason?.contains("timeout (210 s after creation)") == true)
        #expect(reason?.contains("when the probe exits") == true)
        #expect(reason?.contains("no DisableInflow is listed") == true)
    }

    @Test("An assertion still listed after the release is inconclusive")
    func stillListed() {
        var scenario = Scenario()
        scenario.stillListed = true
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("still listed the probe's DisableInflow") == true)
        #expect(reason?.contains("unconfirmed") == true)
    }

    @Test("A release that could not be checked with pmset is inconclusive")
    func listingUnavailable() {
        var scenario = Scenario()
        scenario.stillListed = nil
        #expect(scenario.inconclusiveReason?.contains("could not be run after the release") == true)
    }

    @Test("A failed release is inconclusive even when the hold showed no effect")
    func failedReleaseNoEffect() {
        var scenario = Scenario()
        scenario.held = { _ in .charging }
        scenario.releaseResult = Scenario.notFound
        #expect(scenario.inconclusiveReason != nil)
    }

    @Test("An assertion the probe did not release itself: inconclusive")
    func notReleased() {
        var run = Scenario().run
        run.release = nil
        guard case .inconclusive = Verdict.evaluate(run) else {
            Issue.record("expected inconclusive, got \(Verdict.evaluate(run))")
            return
        }
    }

    // MARK: Baseline (finding: setup ate into the baseline)

    @Test("A baseline that is not charging steadily: inconclusive, and no assertion is needed to say so")
    func baselineNotCharging() {
        var scenario = Scenario()
        scenario.baseline = { $0 < 10 ? .charging : .stopped }
        #expect(scenario.inconclusiveReason?.contains("baseline") == true)
        let baseline = scenario.run.samples.filter { $0.phase == .baseline }
        #expect(Verdict.baselineProblem(baseline) != nil)
        #expect(Verdict.baselineProblem(Scenario().run.samples.filter { $0.phase == .baseline }) == nil)
    }

    @Test("A baseline with too few readings: inconclusive")
    func shortBaseline() {
        let samples = [0.0, 2, 4].map { Sample.Reading.charging.sample(at: $0, .baseline) }
        let verdict = Verdict.evaluate(ProbeRun(assertion: .disableInflow, samples: samples, creation: nil, release: nil))
        guard case let .inconclusive(reason) = verdict else {
            Issue.record("expected inconclusive, got \(verdict)")
            return
        }
        #expect(reason.contains("only 3 readings"))
    }

    @Test("A baseline that spans too little time, or too much: inconclusive")
    func baselineDuration() {
        var scenario = Scenario()
        scenario.baselineTimes = [10, 12, 14, 16, 18, 20]
        #expect(scenario.inconclusiveReason?.contains("spanned 10.0 s") == true)
        scenario.baselineTimes = Array(stride(from: -140.0, through: 20, by: 2))
        #expect(scenario.inconclusiveReason?.contains("spanned 160.0 s") == true)
    }

    @Test("A baseline with a gap between readings: inconclusive")
    func baselineGap() {
        var scenario = Scenario()
        scenario.baselineTimes = [0, 2, 4, 6, 14, 16, 18, 20]
        #expect(scenario.inconclusiveReason?.contains("gap of 8.0 s") == true)
    }

    @Test("An assertion created long after the last baseline reading: inconclusive")
    func creationLateAfterBaseline() {
        var scenario = Scenario()
        // 20 s of baseline that ended 6.5 s before the creation.
        scenario.baselineTimes = Array(stride(from: -6.0, through: 14, by: 2))
        #expect(scenario.inconclusiveReason?.contains("6.5 s old when the assertion") == true)
    }

    // MARK: Other inconclusive runs

    @Test("Unplugged while held after a stop: inconclusive")
    func unpluggedWhileHeld() {
        var scenario = Scenario()
        scenario.held = { seconds in
            switch seconds {
            case ..<4: .charging
            case ..<30: .stopped
            default: .unplugged
            }
        }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("battery power") == true)
        #expect(reason?.contains("while it was still held") == true)
        #expect(scenario.verdict.exitStatus == 2)
    }

    @Test("Unplugged after the release, before charging resumed after a stop: inconclusive")
    func unpluggedAfterRelease() {
        var scenario = Scenario()
        scenario.after = { $0 < 10 ? .stopped : .unplugged }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("on battery power") == true)
        #expect(reason?.contains("after the release") == true)
    }

    @Test("Reaching 100% while held: inconclusive, because a full battery stops charging by itself")
    func reachedFull() {
        var scenario = Scenario()
        scenario.held = { $0 < 20 ? .charging : .full }
        #expect(scenario.inconclusiveReason?.contains("100%") == true)
    }

    @Test("Readings after the release that end before the window is over: inconclusive, not 'did not resume'")
    func shortAfterPhase() {
        var scenario = Scenario()
        scenario.after = { _ in .stopped }
        scenario.afterDuration = 20
        #expect(scenario.inconclusiveReason?.contains("before the 120.0 s window was over") == true)
    }

    @Test("An effect later than 90 s after creation is not attributed to the assertion")
    func lateStop() {
        var scenario = Scenario()
        scenario.held = { $0 < 100 ? .charging : .stopped }
        #expect(scenario.inconclusiveReason?.contains("later than 90.0 s") == true)
        #expect(scenario.inconclusiveReason?.contains("cannot be attributed") == true)
    }

    @Test("Readings while held that cover less than the 90 s window: inconclusive")
    func holdTooShort() {
        var scenario = Scenario()
        scenario.hold = 80
        scenario.held = { _ in .charging }
        #expect(scenario.inconclusiveReason?.contains("cover less than 90.0 s") == true)
    }

    @Test("A flag that disagrees with the current, and never a clear stop: inconclusive")
    func mixedReadings() {
        var scenario = Scenario()
        scenario.held = { _ in .flagLagging }
        #expect(scenario.inconclusiveReason?.contains("disagreed") == true)
    }

    @Test("Unreadable values while held: inconclusive")
    func unreadable() {
        var scenario = Scenario()
        scenario.held = { $0 < 10 ? .stopped : .unreadable }
        #expect(scenario.inconclusiveReason?.contains("could not be read") == true)
    }

    @Test("An unknown battery presence, or no update time, counts as unreadable")
    func unknownBattery() {
        var sample = Sample.Reading.charging.sample(at: 0, .held)
        sample.batteryPresent = nil
        #expect(Verdict.problem(of: sample) == .unreadable)
        sample = Sample.Reading.charging.sample(at: 0, .held)
        sample.updateTime = nil
        #expect(Verdict.problem(of: sample) == .unreadable)
    }

    @Test("A gap in the readings (the Mac slept): inconclusive")
    func sleepGap() {
        var run = Scenario().run
        // Drop the held readings between 10 and 26 s after creation.
        let creation = Scenario().creationTime
        run.samples.removeAll { $0.phase == .held && $0.time > creation + 9 && $0.time < creation + 27 }
        guard case let .inconclusive(reason) = Verdict.evaluate(run) else {
            Issue.record("expected inconclusive, got \(Verdict.evaluate(run))")
            return
        }
        #expect(reason.contains("may have slept"))
    }

    @Test("Samples out of order are evaluated in time order")
    func unordered() {
        var run = Scenario().run
        run.samples.reverse()
        #expect(Verdict.evaluate(run) == .inhibited(stoppedAfter: 4, resumedAfter: 6))
    }

    @Test("A reading's state needs the power source, the flag and the current")
    func readingState() {
        #expect(Verdict.state(of: Sample.Reading.charging.sample(at: 0, .held)) == .charging)
        #expect(Verdict.state(of: Sample.Reading.stopped.sample(at: 0, .held)) == .stopped)
        #expect(Verdict.state(of: Sample.Reading.flagLagging.sample(at: 0, .held)) == .mixed)
        #expect(Verdict.state(of: Sample.Reading.flagOnly.sample(at: 0, .held)) == .mixed)
        #expect(Verdict.state(of: Sample.Reading.cut.sample(at: 0, .held)) == .discharging)
        #expect(Verdict.state(of: Sample.Reading.cutOnAC.sample(at: 0, .held)) == .discharging)
        #expect(Verdict.state(of: Sample.Reading.unplugged.sample(at: 0, .held)) == .discharging)
        var atThreshold = Sample.Reading.stopped.sample(at: 0, .held)
        atThreshold.instantCurrent = 50
        #expect(Verdict.state(of: atThreshold) == .stopped)
        atThreshold.instantCurrent = -99
        #expect(Verdict.state(of: atThreshold) == .stopped)
        atThreshold.instantCurrent = -100
        #expect(Verdict.state(of: atThreshold) == .discharging)
        // Battery power while the battery does not discharge disagrees.
        var onBatteryIdle = Sample.Reading.stopped.sample(at: 0, .held)
        onBatteryIdle.externalPower = false
        #expect(Verdict.state(of: onBatteryIdle) == .mixed)
    }
}
