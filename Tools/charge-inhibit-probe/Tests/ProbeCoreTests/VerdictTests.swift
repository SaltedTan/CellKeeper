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
    /// Extra readings while held, at seconds after creation.
    var extraHeld: [(Double, Sample.Reading)] = []
    /// If set, exactly these readings after the release, at seconds after it.
    var afterReadings: [(Double, Sample.Reading)]?

    var run: ProbeRun {
        var samples = baselineTimes.map { baseline($0).sample(at: $0, .baseline) }
        let creation = ProbeRun.Creation(time: Self.creationTime, result: creationResult, timeout: hold + 30)
        guard creationResult == 0 else {
            return ProbeRun(samples: samples, creation: creation, release: nil)
        }
        let heldTimes = stride(from: 2.0, through: Double(hold), by: 2)
        samples += heldTimes.map { held($0).sample(at: Self.creationTime + $0, .held) }
        samples += extraHeld.map { $0.1.sample(at: Self.creationTime + $0.0, .held) }
        let releasedAt = Self.creationTime + Double(hold) + 0.5
        let afterReadings = afterReadings ?? stride(from: 2.0, through: afterDuration, by: 2).map { ($0, after($0)) }
        samples += afterReadings.map { $0.1.sample(at: releasedAt + $0.0, .after) }
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
        #expect(reason?.contains("5 readings at least 1.5 s apart, spanning at least 8.0 s needed") == true)
    }

    @Test("Exactly 5 stopped readings, 2 s apart and spanning 8 s, are enough")
    func stopExactlySustained() {
        var scenario = Scenario()
        scenario.hold = 38
        scenario.held = { $0 < 30 ? .charging : .stopped }
        let stopped = scenario.run.samples.filter { $0.phase == .held && Verdict.state(of: $0) == .stopped }
        #expect(stopped.map(\.time) == [30, 32, 34, 36, 38].map { Scenario.creationTime + $0 })
        #expect(scenario.verdict == .inhibited(stoppedAfter: 30, resumedAfter: 6))
    }

    // MARK: Clustered readings (finding: clustered samples confirmed a stop or a resume)

    @Test("The reviewer's case: four charging readings within 0.1 s and one more are not a resume")
    func reviewerClusteredResume() {
        var scenario = Scenario()
        let charging: [(Double, Sample.Reading)] = [9.900, 9.901, 9.902, 9.903, 10.000].map { ($0, .charging) }
        let stopped: [(Double, Sample.Reading)] = stride(from: 12.0, through: 180, by: 2).map { ($0, .stopped) }
        scenario.afterReadings = [(2, .stopped), (4, .stopped), (6, .stopped), (8, .stopped)] + charging + stopped
        let verdict = scenario.verdict
        #expect(verdict.title == "inconclusive")
        #expect(scenario.inconclusiveReason?.contains("never in 5 readings in a row") == true)
    }

    @Test("Clustered charging readings after the release count as one")
    func clusteredResumeCountsOnce() {
        var scenario = Scenario()
        let cluster: [(Double, Sample.Reading)] = stride(from: 6.0, through: 6.8, by: 0.1).map { ($0, .charging) }
        // One cluster, then two more charging readings 2 s apart: three counted, not five.
        scenario.afterReadings = [(2, .stopped), (4, .stopped)] + cluster + [(8.8, .charging), (10.8, .charging)]
            + stride(from: 12.8, through: 180, by: 2).map { ($0, .stopped) }
        #expect(scenario.inconclusiveReason?.contains("never in 5 readings in a row") == true)
    }

    @Test("Five charging readings 1.5 s apart span only 6 s; the resume counts once the run spans 8 s")
    func resumeNeedsSpan() {
        let fiveOnly: [(Double, Sample.Reading)] = [6, 7.5, 9, 10.5, 12].map { ($0, .charging) }
        var short = Scenario()
        short.afterReadings = [(2, .stopped), (4, .stopped)] + fiveOnly
            + stride(from: 14.0, through: 180, by: 2).map { ($0, .stopped) }
        #expect(short.inconclusiveReason?.contains("never in 5 readings in a row") == true)

        var long = Scenario()
        long.afterReadings = [(2, .stopped), (4, .stopped)] + fiveOnly + [(13.5, .charging), (15, .charging)]
            + stride(from: 17.0, through: 70, by: 2).map { ($0, .charging) }
        #expect(long.verdict == .inhibited(stoppedAfter: 4, resumedAfter: 6))
    }

    @Test("Clustered stopped readings do not make a sustained stop")
    func clusteredStop() {
        var scenario = Scenario()
        scenario.hold = 30
        scenario.held = { $0 < 28 ? .charging : .stopped }
        scenario.extraHeld = [28.4, 28.8, 29.2, 29.6].map { ($0, .stopped) }
        let reason = scenario.inconclusiveReason
        #expect(reason?.contains("only 2 readings") == true)
    }

    @Test("Five stopped readings 1.5 s apart span only 6 s: not a sustained stop")
    func stopNeedsSpan() {
        var scenario = Scenario()
        scenario.hold = 30
        scenario.held = { $0 < 24 ? .charging : .stopped }
        // Replace the regular stopped readings with ones 1.5 s apart.
        var run = scenario.run
        run.samples.removeAll { $0.phase == .held && $0.time >= Scenario.creationTime + 24 }
        run.samples += [24, 25.5, 27, 28.5, 30].map { Sample.Reading.stopped.sample(at: Scenario.creationTime + $0, .held) }
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

    @Test("A sustained run counts readings at least 1.5 s apart and needs 8 s")
    func sustainedRunRule() {
        func sample(_ time: Double) -> Sample { Sample.Reading.stopped.sample(at: time, .held) }
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

    // MARK: Baseline freshness at creation

    @Test("The assertion is created only while the last baseline reading is at most 4 s old")
    func baselineFreshness() {
        #expect(Verdict.baselineFreshnessProblem(lastBaselineTime: 20, now: 20.5) == nil)
        #expect(Verdict.baselineFreshnessProblem(lastBaselineTime: 20, now: 24) == nil)
        let stale = Verdict.baselineFreshnessProblem(lastBaselineTime: 20, now: 26)
        #expect(stale?.contains("6.0 s old") == true)
        #expect(stale?.contains("nothing was created") == true)
        #expect(Verdict.baselineFreshnessProblem(lastBaselineTime: nil, now: 1) != nil)
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
