import ProbeCore
import Testing

/// Builds synthetic runs on the probe's real schedule: baseline readings at
/// 0, 2, … 20 s, the assertion at 20.5 s, readings every 2 s while it is
/// held, the release, and readings every 2 s after it.
struct Scenario {
    static let creationTime = 20.5
    static let notPrivileged = Int32(bitPattern: 0xE000_02C1)
    static let notFound = Int32(bitPattern: 0xE000_02F0)

    var hold = 60
    var creationResult: Int32 = 0
    /// The reading at `seconds` after creation; default: charging stopped
    /// from 4 s on.
    var held: (Double) -> Sample.Reading = { $0 < 4 ? .charging : .stopped }
    /// The reading at `seconds` after the release; default: resumed from 6 s.
    var after: (Double) -> Sample.Reading = { $0 < 6 ? .stopped : .charging }
    var afterDuration = 60.0
    var baselineTimes = Array(stride(from: 0.0, through: 20, by: 2))
    var baseline: (Double) -> Sample.Reading = { _ in .charging }
    var releaseResult: Int32 = 0
    var releaseAttempts = 1
    var stillListed: Bool? = false

    var run: ProbeRun {
        var samples = baselineTimes.map { baseline($0).sample(at: $0, .baseline) }
        let creation = ProbeRun.Creation(time: Self.creationTime, result: creationResult, timeout: hold + 30)
        guard creationResult == 0 else {
            return ProbeRun(samples: samples, creation: creation, release: nil)
        }
        let heldTimes = stride(from: 2.0, through: Double(hold), by: 2)
        samples += heldTimes.map { held($0).sample(at: Self.creationTime + $0, .held) }
        let releasedAt = Self.creationTime + Double(hold) + 0.5
        samples += stride(from: 2.0, through: afterDuration, by: 2).map { after($0).sample(at: releasedAt + $0, .after) }
        let release = ProbeRun.Release(time: releasedAt, result: releaseResult, attempts: releaseAttempts, stillListed: stillListed)
        return ProbeRun(samples: samples, creation: creation, release: release)
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
        case unplugged
        case full
        case unreadable

        func sample(at time: Double, _ phase: Sample.Phase) -> Sample {
            var sample = Sample(
                time: time, phase: phase, externalPower: true, batteryPresent: true, percent: 62,
                isCharging: true, isCharged: false, averageCurrent: 1500, instantCurrent: 1480,
                registryIsCharging: true, registryExternalConnected: true
            )
            switch self {
            case .charging:
                break
            case .stopped:
                sample.isCharging = false
                sample.averageCurrent = 0
                sample.instantCurrent = 0
            case .flagLagging:
                sample.instantCurrent = 10
            case .flagOnly:
                sample.isCharging = false
            case .unplugged:
                sample.externalPower = false
                sample.isCharging = false
                sample.instantCurrent = -900
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
    // MARK: Definitive verdicts

    @Test("Charging stops after creation and resumes after the release: inhibited")
    func inhibited() {
        let verdict = Scenario().verdict
        #expect(verdict == .inhibited(stoppedAfter: 4, resumedAfter: 6))
        #expect(verdict.title == "inhibited")
        #expect(verdict.exitStatus == 0)
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

    @Test("Charging continues while the assertion is held: no effect observed during the measured hold")
    func noEffect() {
        var scenario = Scenario()
        scenario.held = { _ in .charging }
        scenario.after = { _ in .charging }
        let verdict = scenario.verdict
        #expect(verdict == .noEffect(heldFor: 60))
        #expect(verdict.title == "no effect observed")
        #expect(verdict.explanation().contains("during the measured hold"))
        #expect(verdict.exitStatus == 0)
    }

    @Test("A creation that does not succeed is refused, whatever follows")
    func refused() {
        var scenario = Scenario()
        scenario.creationResult = Scenario.notPrivileged
        let verdict = scenario.verdict
        #expect(verdict == .refused(result: Scenario.notPrivileged))
        #expect(verdict.title == "refused")
        #expect(verdict.explanation().contains("0xe00002c1 (kIOReturnNotPrivileged)"))
    }

    @Test("Charging resumes, but later than 60 s after the release: inhibited, resumed late")
    func resumedLate() {
        var scenario = Scenario()
        scenario.after = { $0 < 90 ? .stopped : .charging }
        scenario.afterDuration = 100
        let verdict = scenario.verdict
        #expect(verdict == .inhibitedResumedLate(stoppedAfter: 4, resumedAfter: 90))
        #expect(verdict.title == "inhibited, resumed late")
    }

    @Test("Charging resumes exactly at the end of the 60 s window and stays: still inhibited")
    func resumedAtWindowEdge() {
        var scenario = Scenario()
        scenario.after = { $0 < 60 ? .stopped : .charging }
        scenario.afterDuration = 70
        #expect(scenario.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 60))
    }

    @Test("Charging never resumes: a distinct verdict that sends the owner to the recovery steps")
    func neverResumed() {
        var scenario = Scenario()
        scenario.after = { _ in .stopped }
        scenario.afterDuration = 180
        let verdict = scenario.verdict
        #expect(verdict == .inhibitedDidNotResume(stoppedAfter: 4, watchedFor: 180))
        #expect(verdict.title == "inhibited, did not resume")
        #expect(verdict.exitStatus == 3)
        let explanation = verdict.explanation()
        #expect(explanation.contains("recovery steps"))
        #expect(explanation.contains("docs/safety.md"))
        #expect(explanation.contains("pmset -g assertions"))
        #expect(explanation.contains("restart"))
    }

    // MARK: Sustained stop (finding: a mixed sequence gave a false "inhibited")

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
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("disagreed") == true)
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
        scenario.hold = 34
        scenario.held = { $0 < 28 ? .charging : .stopped }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("only 4 readings") == true)
        #expect(reason?.contains("5 needed") == true)
    }

    @Test("Exactly 5 stopped readings are enough")
    func stopExactlySustained() {
        var scenario = Scenario()
        scenario.hold = 40
        scenario.held = { $0 < 30 ? .charging : .stopped }
        #expect(scenario.verdict == .inhibited(stoppedAfter: 30, resumedAfter: 6))
    }

    @Test("A single charging reading after the release is not a resume")
    func resumeFlicker() {
        var scenario = Scenario()
        scenario.after = { $0 == 10 ? .charging : .stopped }
        scenario.afterDuration = 180
        #expect(scenario.inconclusiveReason?.contains("never in 5 readings in a row") == true)
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
        // With the default 60 s hold, powerd's 90 s timeout fires 30 s after the
        // intended release; charging resuming then must not count.
        scenario.after = { $0 < 30 ? .stopped : .charging }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("0xe00002f0 (kIOReturnNotFound)") == true)
        #expect(reason?.contains("3 attempts") == true)
        #expect(reason?.contains("timeout (90 s after creation)") == true)
        #expect(reason?.contains("when the probe exits") == true)
    }

    @Test("An assertion still listed after the release is inconclusive")
    func stillListed() {
        var scenario = Scenario()
        scenario.stillListed = true
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("still listed") == true)
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
        let verdict = Verdict.evaluate(ProbeRun(samples: samples, creation: nil, release: nil))
        guard case let .inconclusive(reason) = verdict else {
            Issue.record("expected inconclusive, got \(verdict)")
            return
        }
        #expect(reason.contains("only 3 readings"))
    }

    @Test("A baseline that spans too little time: inconclusive")
    func baselineTooBrief() {
        var scenario = Scenario()
        scenario.baselineTimes = [10, 12, 14, 16, 18, 20]
        #expect(scenario.inconclusiveReason?.contains("spanned 10.0 s") == true)
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
        #expect(scenario.inconclusiveReason?.contains("after the last baseline reading") == true)
    }

    // MARK: Other inconclusive runs

    @Test("Unplugged while held: inconclusive, even after charging had stopped")
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
        #expect(reason?.contains("on battery power") == true)
        #expect(reason?.contains("while it was held") == true)
        #expect(scenario.verdict.exitStatus == 2)
    }

    @Test("Unplugged after the release, before charging resumed: inconclusive")
    func unpluggedAfterRelease() {
        var scenario = Scenario()
        scenario.after = { $0 < 10 ? .stopped : .unplugged }
        #expect(scenario.inconclusiveReason?.contains("after the release") == true)
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
        #expect(scenario.inconclusiveReason?.contains("before the 60.0 s window was over") == true)
    }

    @Test("A stop later than 30 s after creation is not attributed to the assertion")
    func lateStop() {
        var scenario = Scenario()
        scenario.held = { $0 < 40 ? .charging : .stopped }
        #expect(scenario.inconclusiveReason?.contains("cannot be attributed") == true)
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

    @Test("An unknown battery presence counts as unreadable")
    func unknownBattery() {
        var sample = Sample.Reading.charging.sample(at: 0, .held)
        sample.batteryPresent = nil
        #expect(Verdict.problem(of: sample) == .unreadable)
    }

    @Test("A gap in the readings (the Mac slept): inconclusive")
    func sleepGap() {
        var run = Scenario().run
        // Drop the held readings between 10 and 26 s after creation.
        run.samples.removeAll { $0.phase == .held && $0.time > Scenario.creationTime + 9 && $0.time < Scenario.creationTime + 27 }
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

    @Test("A reading's state needs both the flag and the current")
    func readingState() {
        #expect(Verdict.state(of: Sample.Reading.charging.sample(at: 0, .held)) == .charging)
        #expect(Verdict.state(of: Sample.Reading.stopped.sample(at: 0, .held)) == .stopped)
        #expect(Verdict.state(of: Sample.Reading.flagLagging.sample(at: 0, .held)) == .mixed)
        #expect(Verdict.state(of: Sample.Reading.flagOnly.sample(at: 0, .held)) == .mixed)
        var atThreshold = Sample.Reading.stopped.sample(at: 0, .held)
        atThreshold.instantCurrent = 50
        #expect(Verdict.state(of: atThreshold) == .stopped)
    }
}
