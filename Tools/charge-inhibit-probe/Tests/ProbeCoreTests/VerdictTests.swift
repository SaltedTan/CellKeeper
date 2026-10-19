import ProbeCore
import Testing

/// Builds synthetic runs on the probe's real schedule: baseline readings at
/// 0, 2, … 20 s, the assertion at 20.5 s, readings every 2 s while it is
/// held, the release, and readings every 2 s after it.
struct Scenario {
    static let creationTime = 20.5
    static let notPrivileged = Int32(bitPattern: 0xE000_02C1)

    var hold = 60
    var creationResult: Int32 = 0
    /// The reading at `seconds` after creation; default: charging stopped
    /// from 4 s on.
    var held: (Double) -> Sample.Reading = { $0 < 4 ? .charging : .stopped }
    /// The reading at `seconds` after the release; default: resumed from 6 s.
    var after: (Double) -> Sample.Reading = { $0 < 6 ? .stopped : .charging }
    var afterDuration = 60.0
    var baseline: (Double) -> Sample.Reading = { _ in .charging }

    var run: ProbeRun {
        var samples = stride(from: 0.0, through: 20, by: 2).map { baseline($0).sample(at: $0, .baseline) }
        let creation = ProbeRun.Creation(time: Self.creationTime, result: creationResult)
        guard creationResult == 0 else {
            return ProbeRun(samples: samples, creation: creation, releasedAt: nil)
        }
        let heldTimes = stride(from: 2.0, through: Double(hold), by: 2)
        samples += heldTimes.map { held($0).sample(at: Self.creationTime + $0, .held) }
        let releasedAt = Self.creationTime + Double(hold) + 0.5
        samples += stride(from: 2.0, through: afterDuration, by: 2).map { after($0).sample(at: releasedAt + $0, .after) }
        return ProbeRun(samples: samples, creation: creation, releasedAt: releasedAt)
    }

    var verdict: Verdict { Verdict.evaluate(run) }
}

extension Sample {
    /// Shorthands for the readings a run can see.
    enum Reading {
        case charging
        case stopped
        /// Charging flag still on while the current has already fallen.
        case flagLagging
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
    @Test("Charging stops after creation and resumes after the release: inhibited")
    func inhibited() {
        let verdict = Scenario().verdict
        #expect(verdict == .inhibited(stoppedAfter: 4, resumedAfter: 6))
        #expect(verdict.title == "inhibited")
        #expect(verdict.exitStatus == 0)
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

    @Test("Charging continues while the assertion is held: no effect")
    func noEffect() {
        var scenario = Scenario()
        scenario.held = { _ in .charging }
        scenario.after = { _ in .charging }
        let verdict = scenario.verdict
        #expect(verdict == .noEffect)
        #expect(verdict.title == "no effect")
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
        let verdict = scenario.verdict
        guard case let .inconclusive(reason) = verdict else {
            Issue.record("expected inconclusive, got \(verdict)")
            return
        }
        #expect(reason.contains("on battery power"))
        #expect(reason.contains("while it was held"))
        #expect(verdict.exitStatus == 2)
    }

    @Test("Unplugged after the release, before charging resumed: inconclusive")
    func unpluggedAfterRelease() {
        var scenario = Scenario()
        scenario.after = { $0 < 10 ? .stopped : .unplugged }
        guard case let .inconclusive(reason) = scenario.verdict else {
            Issue.record("expected inconclusive, got \(scenario.verdict)")
            return
        }
        #expect(reason.contains("after the release"))
    }

    @Test("Reaching 100% while held: inconclusive, because a full battery stops charging by itself")
    func reachedFull() {
        var scenario = Scenario()
        scenario.held = { $0 < 20 ? .charging : .full }
        guard case let .inconclusive(reason) = scenario.verdict else {
            Issue.record("expected inconclusive, got \(scenario.verdict)")
            return
        }
        #expect(reason.contains("100%"))
    }

    @Test("Charging resumes, but later than 60 s after the release: inhibited, resumed late")
    func resumedLate() {
        var scenario = Scenario()
        scenario.after = { $0 < 90 ? .stopped : .charging }
        scenario.afterDuration = 90
        let verdict = scenario.verdict
        #expect(verdict == .inhibitedResumedLate(stoppedAfter: 4, resumedAfter: 90))
        #expect(verdict.title == "inhibited, resumed late")
    }

    @Test("Charging resumes exactly at the end of the 60 s window: still inhibited")
    func resumedAtWindowEdge() {
        var scenario = Scenario()
        scenario.after = { $0 < 60 ? .stopped : .charging }
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

    @Test("Readings after the release that end before the window is over: inconclusive, not 'did not resume'")
    func shortAfterPhase() {
        var scenario = Scenario()
        scenario.after = { _ in .stopped }
        scenario.afterDuration = 20
        guard case let .inconclusive(reason) = scenario.verdict else {
            Issue.record("expected inconclusive, got \(scenario.verdict)")
            return
        }
        #expect(reason.contains("before the 60.0 s window was over"))
    }

    @Test("A stop later than 30 s after creation is not attributed to the assertion")
    func lateStop() {
        var scenario = Scenario()
        scenario.held = { $0 < 40 ? .charging : .stopped }
        guard case let .inconclusive(reason) = scenario.verdict else {
            Issue.record("expected inconclusive, got \(scenario.verdict)")
            return
        }
        #expect(reason.contains("cannot be attributed"))
    }

    @Test("Charging that starts again while the assertion is still held: inconclusive")
    func restartedWhileHeld() {
        var scenario = Scenario()
        scenario.held = { ($0 >= 4 && $0 < 20) ? .stopped : .charging }
        guard case let .inconclusive(reason) = scenario.verdict else {
            Issue.record("expected inconclusive, got \(scenario.verdict)")
            return
        }
        #expect(reason.contains("started again"))
    }

    @Test("A flag that disagrees with the current, and never a clear stop: inconclusive")
    func mixedReadings() {
        var scenario = Scenario()
        scenario.held = { _ in .flagLagging }
        guard case let .inconclusive(reason) = scenario.verdict else {
            Issue.record("expected inconclusive, got \(scenario.verdict)")
            return
        }
        #expect(reason.contains("disagreed"))
    }

    @Test("A baseline that is not charging steadily: inconclusive, and no assertion is needed to say so")
    func baselineNotCharging() {
        var scenario = Scenario()
        scenario.baseline = { $0 < 10 ? .charging : .stopped }
        guard case let .inconclusive(reason) = scenario.verdict else {
            Issue.record("expected inconclusive, got \(scenario.verdict)")
            return
        }
        #expect(reason.contains("baseline"))
        let baseline = scenario.run.samples.filter { $0.phase == .baseline }
        #expect(Verdict.baselineProblem(baseline) != nil)
        #expect(Verdict.baselineProblem(Scenario().run.samples.filter { $0.phase == .baseline }) == nil)
    }

    @Test("A baseline with too few readings: inconclusive")
    func shortBaseline() {
        let samples = [0.0, 2, 4].map { Sample.Reading.charging.sample(at: $0, .baseline) }
        let verdict = Verdict.evaluate(ProbeRun(samples: samples, creation: nil, releasedAt: nil))
        guard case let .inconclusive(reason) = verdict else {
            Issue.record("expected inconclusive, got \(verdict)")
            return
        }
        #expect(reason.contains("only 3 readings"))
    }

    @Test("Unreadable values while held: inconclusive")
    func unreadable() {
        var scenario = Scenario()
        scenario.held = { $0 < 10 ? .stopped : .unreadable }
        guard case let .inconclusive(reason) = scenario.verdict else {
            Issue.record("expected inconclusive, got \(scenario.verdict)")
            return
        }
        #expect(reason.contains("could not be read"))
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

    @Test("An assertion the probe did not release itself: inconclusive")
    func notReleased() {
        var run = Scenario().run
        run.releasedAt = nil
        guard case .inconclusive = Verdict.evaluate(run) else {
            Issue.record("expected inconclusive, got \(Verdict.evaluate(run))")
            return
        }
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
        var flagOffCurrentOn = Sample.Reading.charging.sample(at: 0, .held)
        flagOffCurrentOn.isCharging = false
        #expect(Verdict.state(of: flagOffCurrentOn) == .mixed)
        var atThreshold = Sample.Reading.stopped.sample(at: 0, .held)
        atThreshold.instantCurrent = 50
        #expect(Verdict.state(of: atThreshold) == .stopped)
    }
}
