@testable import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600
private let minute: TimeInterval = 60
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let bootA = "boot-A"
private let bootB = "boot-B"
private let run = UUID()
private let otherRun = UUID()

/// A stamp `hours` after the session's start: the wall clock and the
/// monotonic clock advance together unless `wallShift` moves the wall clock
/// alone. A stamp of another boot restarts the monotonic clock at 100 s.
private func at(_ hours: Double, wallShift: TimeInterval = 0, boot: String = bootA, monotonic: TimeInterval? = nil) -> CalibrationStamp {
    let elapsed = hours * hour
    let mono = monotonic ?? (boot == bootA ? 50_000 + elapsed : 100)
    return CalibrationStamp(wall: start.addingTimeInterval(elapsed + wallShift), monotonic: mono, boot: boot)
}

/// A usable reading, without a temperature as on macOS 27, unless given.
private func reading(_ percent: Int, _ source: PowerSource = .externalPower, charging: Bool? = nil, full: Bool? = false, temperature: Double? = nil) -> BatterySnapshot {
    snapshot(percent: percent, source: source, charging: charging, fullyCharged: full, temperature: temperature)
}

private func newSession(check: CalibrationTemperatureCheck = .ownerConfirmedCoolRoom) -> CalibrationSession {
    CalibrationSession.start(
        id: UUID(),
        at: at(0),
        ownerLimit: 90,
        cellKeeperLimit: 80,
        before: CalibrationCapacities(fullChargeMilliampHours: 6150, nominalMilliampHours: 6302, designMilliampHours: 6249, cycleCount: 56),
        temperatureCheck: check,
        optimizedCharging: .off
    )
}

private func observe(_ session: CalibrationSession, _ stamp: CalibrationStamp, _ reading: BatterySnapshot?, event: CalibrationObservation.Event = .check, held: Bool = true, paused: Bool = false, run observedRun: UUID = run) -> CalibrationProgress {
    session.advanced(by: CalibrationObservation(now: stamp, event: event, reading: reading, isFullLimitHeld: held, run: observedRun, isPaused: paused))
}

/// Applies an observation that must not end the session.
private func step(_ session: CalibrationSession, _ stamp: CalibrationStamp, _ reading: BatterySnapshot?, event: CalibrationObservation.Event = .check, held: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) -> CalibrationSession {
    let progress = observe(session, stamp, reading, event: event, held: held)
    #expect(progress.end == nil, sourceLocation: sourceLocation)
    return progress.session
}

/// A session in `target`, reached through the steps before it with every
/// condition met, at `hours` (each step taking an hour from the start).
private func session(in target: CalibrationStep) -> CalibrationSession {
    var s = newSession()
    if target == .chargeToFull { return s }
    s = step(s, at(1), reading(100, charging: false, full: true))
    if target == .restAtTop { return s }
    s = step(s, at(3.25), reading(100, charging: false, full: true))
    s = s.returnConfirmed(at: at(3.25)).session
    if target == .unplug { return s }
    s = step(s, at(4), reading(99, .battery))
    if target == .drain { return s }
    s = step(s, at(10), reading(20, .battery))
    if target == .restAtBottom { return s }
    s = step(s, at(15.5), reading(19, .battery))
    if target == .plugIn { return s }
    s = step(s, at(16), reading(19))
    return s
}

@Suite("Calibration: session")
struct CalibrationSessionTests {
    // MARK: - Start and the 100% steps

    @Test("A new session starts at step 1, asking for 100%, with its start recorded")
    func starts() {
        let s = newSession()
        #expect(s.step == .chargeToFull)
        #expect(s.asksForFullLimit)
        #expect(s.steps == [CalibrationStepEntry(step: .chargeToFull, enteredAt: start)])
        #expect(!s.hasSeenTemperature)
        #expect(newSession(check: .measured).hasSeenTemperature)
    }

    @Test("Only steps 1, 2 and 7 ask for 100%, and none while returning")
    func fullLimitSteps() {
        #expect(CalibrationStep.allCases.filter(\.asksForFullLimit) == [.chargeToFull, .restAtTop, .finalCharge])
        var s = session(in: .restAtTop)
        #expect(s.asksForFullLimit)
        s.isReturning = true
        #expect(!s.asksForFullLimit)
        for target in [CalibrationStep.unplug, .drain, .restAtBottom, .plugIn] {
            #expect(!session(in: target).asksForFullLimit)
        }
        #expect(session(in: .finalCharge).asksForFullLimit)
    }

    @Test("Step 1 ends when macOS reports the battery charged under a confirmed 100%: fully charged, or 100% and not charging")
    func chargeToFullEnds() {
        let s = newSession()
        let full = observe(s, at(1), reading(98, charging: false, full: true))
        #expect(full.session.step == .restAtTop)
        #expect(full.changes == [.entered(.restAtTop)])
        #expect(full.session.stepStartedAt == at(1))
        #expect(observe(s, at(1), reading(100, charging: false, full: false)).session.step == .restAtTop)
        // Still charging at 100%, not reported charged, or not under a
        // confirmed 100% (the reading may show the old limit): not yet.
        #expect(observe(s, at(1), reading(100, charging: true, full: false)).session.step == .chargeToFull)
        #expect(observe(s, at(1), reading(99, charging: false, full: false)).session.step == .chargeToFull)
        #expect(observe(s, at(1), reading(100, charging: false, full: true), held: false).session.step == .chargeToFull)
        #expect(observe(s, at(1), reading(100, charging: false, full: true), paused: true).session.step == .chargeToFull)
    }

    @Test("Unplugging during step 1 ends the session, also while paused")
    func unplugInChargeEnds() {
        let s = newSession()
        #expect(observe(s, at(1), reading(70, .battery)).end == .unplugged(.chargeToFull))
        #expect(observe(s, at(1), reading(70, .battery), paused: true).end == .unplugged(.chargeToFull))
    }

    @Test("Step 1 ends the session at its 6-hour bound, by the monotonic clock within a boot")
    func chargeBound() {
        let s = newSession()
        #expect(observe(s, at(6 - 1 / hour), reading(90)).end == nil)
        #expect(observe(s, at(6), reading(90)).end == .stepBound(.chargeToFull))
        // A clock set back two hours changes nothing within the boot.
        #expect(observe(s, at(6, wallShift: -2 * hour), reading(90)).end == .stepBound(.chargeToFull))
        // Without a reading the bound still applies.
        #expect(observe(s, at(6), nil).end == .stepBound(.chargeToFull))
    }

    @Test("Step 2 rests 2 hours on the monotonic clock, then asks for the normal limit and waits for its confirmation")
    func topRest() {
        let s = session(in: .restAtTop)
        let early = observe(s, at(3 - 1 / hour), reading(100, charging: false, full: true))
        #expect(!early.session.isReturning)
        // A clock moved forward does not shorten it.
        #expect(!observe(s, at(2, wallShift: 5 * hour), reading(100, charging: false, full: true)).session.isReturning)
        let done = observe(s, at(3), reading(100, charging: false, full: true))
        #expect(done.session.isReturning)
        #expect(done.session.step == .restAtTop)
        #expect(!done.session.asksForFullLimit)
        #expect(done.changes == [.returning(from: .restAtTop)])
        // Paused: no progress.
        #expect(!observe(s, at(3), reading(100, charging: false, full: true), paused: true).session.isReturning)

        let confirmed = done.session.returnConfirmed(at: at(3.2))
        #expect(confirmed.session.step == .unplug)
        #expect(confirmed.session.stepStartedAt == at(3.2))
        #expect(confirmed.changes == [.returnConfirmed, .entered(.unplug)])
        #expect(confirmed.end == nil)
    }

    @Test("Step 2 has no bound of its own: the return may wait as long as the policy's rate limits make it")
    func returnWaits() {
        var s = session(in: .restAtTop)
        s = step(s, at(3), reading(100, charging: false, full: true))
        #expect(observe(s, at(9), reading(100, charging: false, full: true)).end == nil)
        #expect(observe(s, at(9), reading(100, charging: false, full: true)).session.isReturning)
    }

    @Test("Unplugging during step 2 moves to the drain at once, the top rest short and the return requested")
    func earlyUnplug() {
        let s = session(in: .restAtTop)
        let early = observe(s, at(2), reading(99, .battery))
        #expect(early.end == nil)
        #expect(early.session.step == .drain)
        #expect(early.session.isReturning)
        #expect(early.session.shortRests == [.restAtTop])
        #expect(early.changes == [.earlyUnplug(restShort: true), .returning(from: .restAtTop), .entered(.drain)])

        // After the 2 hours, waiting for the return: not short.
        let rested = step(s, at(3), reading(100, charging: false, full: true))
        let late = observe(rested, at(3.05), reading(99, .battery))
        #expect(late.session.step == .drain)
        #expect(late.session.isReturning)
        #expect(late.session.shortRests.isEmpty)
        #expect(late.changes == [.earlyUnplug(restShort: false), .entered(.drain)])

        // The return confirmed in the drain only clears it.
        let returned = early.session.returnConfirmed(at: at(2.1))
        #expect(returned.session.step == .drain)
        #expect(!returned.session.isReturning)
        #expect(returned.end == nil)
    }

    @Test("An unplug first seen after the rest's 2 hours, before any check asked for the return, is not short")
    func unplugAfterRestDeadline() {
        let s = session(in: .restAtTop)
        let late = observe(s, at(3.05), reading(99, .battery))
        #expect(late.session.step == .drain)
        #expect(late.session.isReturning, "the return is asked for at once")
        #expect(late.session.shortRests.isEmpty)
        #expect(late.changes == [.earlyUnplug(restShort: false), .returning(from: .restAtTop), .entered(.drain)])
        // A clock set forward within the boot does not make it count.
        #expect(observe(s, at(2.5, wallShift: hour), reading(99, .battery)).session.shortRests == [.restAtTop])
    }

    // MARK: - Unplug and drain

    @Test("Step 3 ends when the Mac is on battery power, or ends the session after 4 hours")
    func unplugStep() {
        let s = session(in: .unplug)
        #expect(observe(s, at(3.5), reading(100)).session.step == .unplug)
        #expect(observe(s, at(3.5), reading(100, .battery)).session.step == .drain)
        #expect(observe(s, at(3.5), reading(100, .battery), paused: true).session.step == .unplug)
        #expect(observe(s, at(7.25 - 1 / hour), reading(100)).end == nil)
        #expect(observe(s, at(7.25), reading(100)).end == .stepBound(.unplug))
    }

    @Test("Step 4 moves to the rest at 20% or below, ends the session at 15% or below, and on a plug-in")
    func drain() throws {
        let s = session(in: .drain)
        #expect(observe(s, at(5), reading(21, .battery)).session.step == .drain)
        let rest = observe(s, at(5), reading(20, .battery))
        #expect(rest.session.step == .restAtBottom)
        #expect(rest.session.plugInAfter == CalibrationSession.plugInTime(after: at(5).wall))
        let shown = try #require(rest.session.plugInAfter)
        #expect(shown.timeIntervalSince(at(5).wall) >= 5 * hour)
        #expect(observe(s, at(5), reading(16, .battery)).session.step == .restAtBottom)
        #expect(observe(s, at(5), reading(15, .battery)).end == .lowBattery(percent: 15))
        #expect(observe(s, at(5), reading(9, .battery)).end == .lowBattery(percent: 9))
        #expect(observe(s, at(5), reading(40)).end == .pluggedInDuringDrain)
        // Paused: the endings apply, the progress does not.
        #expect(observe(s, at(5), reading(20, .battery), paused: true).session.step == .drain)
        #expect(observe(s, at(5), reading(15, .battery), paused: true).end == .lowBattery(percent: 15))
        #expect(observe(s, at(5), reading(40), paused: true).end == .pluggedInDuringDrain)
    }

    @Test("A sleep announced as the drain reaches 20% begins the rest at once")
    func sleepAtTarget() {
        let s = session(in: .drain)
        let progress = observe(s, at(5), reading(19, .battery), event: .willSleep)
        #expect(progress.session.step == .restAtBottom)
        #expect(progress.session.restSleep == CalibrationSleep(at: at(5), run: run, percent: 19, isOnBattery: true))
    }

    @Test("The time shown is rounded up to a whole minute, at least 5 hours ahead")
    func plugInTime() {
        let exact = Date(timeIntervalSinceReferenceDate: 60 * 1_000)
        #expect(CalibrationSession.plugInTime(after: exact) == exact.addingTimeInterval(5 * hour))
        let late = exact.addingTimeInterval(1)
        #expect(CalibrationSession.plugInTime(after: late) == exact.addingTimeInterval(5 * hour + minute))
    }

    // MARK: - The rest at the bottom

    /// Step 5, entered at 20% at 10 h (the time shown is 15 h), with the
    /// Mac announcing sleep at `sleepPercent` at 10.1 h.
    private func asleep(sleepPercent: Int = 18) -> CalibrationSession {
        var s = session(in: .restAtBottom)
        s = step(s, at(10.1), reading(sleepPercent, .battery), event: .willSleep)
        #expect(s.restSleep?.percent == sleepPercent)
        return s
    }

    @Test("A sleep of 5 hours on battery power at 15–20%, waking on battery power within 3 points, counts")
    func countedSleep() {
        let s = asleep()
        let woke = observe(s, at(15.2), reading(17, .battery), event: .didWake)
        #expect(woke.end == nil)
        #expect(woke.session.step == .plugIn)
        #expect(woke.session.restResult == .counted(sleptFor: 5.1 * hour, fromPercent: 18, toPercent: 17))
        #expect(woke.session.shortRests.isEmpty)
        #expect(woke.changes.contains(.wakeRecorded))
        #expect(observe(s, at(15.2), reading(15, .battery), event: .didWake).session.restResult == .counted(sleptFor: 5.1 * hour, fromPercent: 18, toPercent: 15))
    }

    @Test("A counted sleep moves on even before the time shown, which rounding up can put up to a minute later")
    func countedBeforeTimeShown() throws {
        // Entered 30 s past a whole minute, so the time shown is 5 h 30 s
        // later; the Mac sleeps at once and wakes exactly 5 h later.
        func seconds(_ elapsed: TimeInterval) -> CalibrationStamp {
            CalibrationStamp(wall: start.addingTimeInterval(elapsed), monotonic: 50_000 + elapsed, boot: bootA)
        }
        let entry: TimeInterval = 10 * hour + 30
        var s = step(session(in: .drain), seconds(entry), reading(20, .battery), event: .willSleep)
        let plugInAfter = try #require(s.plugInAfter)
        #expect(plugInAfter == start.addingTimeInterval(15 * hour + minute))
        s = step(s, seconds(entry + 5 * hour), nil, event: .didWake)
        #expect(!s.isRestTimeReached(at: seconds(entry + 5 * hour)))
        let woke = observe(s, seconds(entry + 5 * hour), reading(20, .battery))
        #expect(woke.session.step == .plugIn)
        #expect(woke.session.restResult == .counted(sleptFor: 5 * hour, fromPercent: 20, toPercent: 20))
        #expect(woke.session.shortRests.isEmpty)
    }

    @Test("The first usable reading after waking decides: a wake without one is noted, and the next usable reading decides")
    func firstUsableReading() {
        let s = asleep()
        let woke = observe(s, at(15.2), nil, event: .didWake)
        #expect(woke.session.step == .restAtBottom)
        #expect(woke.session.isAwaitingReadingAfterWake)
        #expect(woke.session.restWake == at(15.2))
        #expect(woke.changes == [.wakeRecorded])
        let later = observe(woke.session, at(15.3), reading(17, .battery))
        #expect(later.session.step == .plugIn)
        #expect(later.session.restResult == .counted(sleptFor: 5.1 * hour, fromPercent: 18, toPercent: 17))
        // On power, the plug-in's time is not known.
        let onPower = observe(woke.session, at(15.3), reading(17))
        #expect(onPower.session.step == .finalCharge)
        #expect(onPower.session.restResult == .notConfirmed(.firstReadingOnPower))
    }

    @Test("Not counted: too short, the clock moved, the charge up or more than 3 points down, or asleep above 20%")
    func notCounted() {
        // 4.9 h of sleep, waking after the time shown.
        var s = session(in: .restAtBottom)
        s = step(s, at(10.5), reading(18, .battery), event: .willSleep)
        #expect(observe(s, at(15.4), reading(17, .battery), event: .didWake).session.restResult == .notConfirmed(.sleptTooShort))

        let base = asleep()
        // The wall clock moved 11 minutes during the sleep.
        #expect(observe(base, at(15.2, wallShift: 11 * minute), reading(17, .battery), event: .didWake).session.restResult == .notConfirmed(.clockMoved))
        #expect(observe(base, at(15.2, wallShift: 10 * minute), reading(17, .battery), event: .didWake).session.restResult?.isCounted == true)
        #expect(observe(base, at(15.2, wallShift: -11 * minute), reading(17, .battery), event: .didWake).session.restResult == .notConfirmed(.clockMoved))
        #expect(observe(base, at(15.2), reading(19, .battery), event: .didWake).session.restResult == .notConfirmed(.chargeChanged))
        #expect(observe(base, at(15.2), reading(14 + 1, .battery), event: .didWake).session.restResult?.isCounted == true)
        let low = asleep(sleepPercent: 19)
        #expect(observe(low, at(15.2), reading(15, .battery), event: .didWake).session.restResult == .notConfirmed(.chargeChanged))

        // Fell asleep at 21% (the drain was paused while it crossed 20%).
        var high = session(in: .restAtBottom)
        high = step(high, at(10.1), reading(21, .battery), event: .willSleep)
        #expect(observe(high, at(15.2), reading(20, .battery), event: .didWake).session.restResult == .notConfirmed(.chargeOutsideRangeAtSleep))
    }

    @Test("A wake seen by another run of CellKeeper is not this rest's wake")
    func wakeInOtherRun() {
        let s = asleep()
        let woke = observe(s, at(15.2), reading(17, .battery), event: .didWake, run: otherRun)
        #expect(!woke.changes.contains(.wakeRecorded))
        #expect(woke.session.restResult == .notConfirmed(.noWakeSeen))
        #expect(s.countedResult(firstReading: 17, run: otherRun) == .notConfirmed(.noWakeSeen))
        #expect(session(in: .restAtBottom).countedResult(firstReading: 17, run: run) == .notConfirmed(.noSleepSeen))
        var wokeHere = s
        wokeHere.restWake = at(15.2)
        #expect(wokeHere.countedResult(firstReading: 17, run: otherRun) == .notConfirmed(.cellKeeperRestarted))
    }

    @Test("A first reading after waking on power moves to step 7, the result not confirmed, short before the time shown")
    func wokeOnPower() {
        let s = asleep()
        let early = observe(s, at(12), reading(18), event: .didWake)
        #expect(early.session.step == .finalCharge)
        #expect(early.session.restResult == .notConfirmed(.firstReadingOnPower))
        #expect(early.session.shortRests == [.restAtBottom])
        #expect(early.changes.contains(.earlyPlugIn))
        let late = observe(s, at(15.2), reading(18), event: .didWake)
        #expect(late.session.step == .finalCharge)
        #expect(late.session.shortRests.isEmpty)
        #expect(!late.changes.contains(.earlyPlugIn))
    }

    @Test("Waking early on battery power asks once to rest again until the time first shown; a second early wake moves to step 6, short")
    func restAgain() throws {
        let s = asleep()
        let shown = try #require(s.plugInAfter)
        let first = observe(s, at(12), reading(18, .battery), event: .didWake)
        #expect(first.session.step == .restAtBottom)
        #expect(first.session.isRestAgainRequested)
        #expect(first.session.plugInAfter == shown, "the time is never moved later")
        #expect(first.changes == [.wakeRecorded, .restAgainRequested])

        // Asleep again, and a sleep after the second wake counts if it
        // meets every condition on its own.
        var again = step(first.session, at(12.1), reading(18, .battery), event: .willSleep)
        let second = observe(again, at(13), reading(18, .battery), event: .didWake)
        #expect(second.session.step == .plugIn)
        #expect(second.session.shortRests == [.restAtBottom])
        #expect(second.session.restResult == .notConfirmed(.sleptTooShort))

        again = step(first.session, at(12.1), reading(18, .battery), event: .willSleep)
        let long = observe(again, at(17.2), reading(17, .battery), event: .didWake)
        #expect(long.session.restResult?.isCounted == true)
        #expect(long.session.shortRests.isEmpty)
    }

    @Test("No rest is requested at 15% or below: an early wake there moves to step 6, short")
    func noRestAgainWhenLow() {
        let s = asleep()
        let woke = observe(s, at(12), reading(15, .battery), event: .didWake)
        #expect(woke.session.step == .plugIn)
        #expect(!woke.session.isRestAgainRequested)
        #expect(woke.session.shortRests == [.restAtBottom])
    }

    @Test("At 15% or below before the rest has begun, the session ends and asks to plug in; after it began, step 6")
    func lowBeforeRest() {
        let s = session(in: .restAtBottom)
        #expect(observe(s, at(11), reading(15, .battery)).end == .lowBattery(percent: 15))
        #expect(observe(s, at(11), reading(15, .battery), event: .willSleep).end == .lowBattery(percent: 15))
        #expect(observe(s, at(11), reading(16, .battery)).end == nil)
        // After a sleep was announced the rest has begun.
        let asleep = asleep()
        let low = observe(asleep, at(12.5), reading(14, .battery))
        #expect(low.end == nil)
        #expect(low.session.step == .plugIn)
        #expect(low.session.restResult == .notConfirmed(.noWakeSeen))
    }

    @Test("Plugging in during step 5 moves to step 7: before the time shown it is accepted and the rest recorded short")
    func plugInDuringRest() {
        let s = session(in: .restAtBottom)
        let early = observe(s, at(12), reading(19))
        #expect(early.end == nil)
        #expect(early.session.step == .finalCharge)
        #expect(early.session.shortRests == [.restAtBottom])
        #expect(early.session.restResult == .notConfirmed(.noSleepSeen))
        #expect(early.changes.contains(.earlyPlugIn))
        #expect(early.session.asksForFullLimit)

        let late = observe(s, at(15.1), reading(19))
        #expect(late.session.step == .finalCharge)
        #expect(late.session.shortRests.isEmpty)
        let asleep = asleep()
        #expect(observe(asleep, at(15.5), reading(17)).session.restResult == .notConfirmed(.pluggedInAwake))
    }

    @Test("The time shown, reached awake on battery power, moves to step 6")
    func timeReachedAwake() {
        let s = session(in: .restAtBottom)
        #expect(observe(s, at(14.9), reading(18, .battery)).session.step == .restAtBottom)
        let reached = observe(s, at(15), reading(18, .battery))
        #expect(reached.session.step == .plugIn)
        #expect(reached.session.restResult == .notConfirmed(.noSleepSeen))
        #expect(reached.session.shortRests.isEmpty)
    }

    @Test("The time shown is reached by the wall clock or, within the boot, the monotonic clock: a clock set back never lengthens the rest")
    func restTimeClocks() {
        let s = session(in: .restAtBottom)
        #expect(!s.isRestTimeReached(at: at(14.99)))
        #expect(s.isRestTimeReached(at: at(15)))
        #expect(s.isRestTimeReached(at: at(15, wallShift: -2 * hour)), "monotonic")
        #expect(s.isRestTimeReached(at: at(12, wallShift: 3 * hour)), "the wall clock shows the time")
        // Across a restart only the wall clock counts.
        #expect(!s.isRestTimeReached(at: at(14, boot: bootB)))
        #expect(s.isRestTimeReached(at: at(15, boot: bootB)))
        #expect(!s.isRestTimeReached(at: at(16, wallShift: -2 * hour, boot: bootB)))
        #expect(!session(in: .drain).isRestTimeReached(at: at(20)))
    }

    @Test("The rest records the latest reading and when it changed, for the owner's account after a restart")
    func lastRestReading() {
        var s = session(in: .restAtBottom)
        s = step(s, at(10.5), reading(19, .battery))
        #expect(s.lastRestReading == CalibrationReading(at: at(10.5).wall, percent: 19, powerSource: .battery))
        s = step(s, at(10.6), reading(19, .battery))
        #expect(s.lastRestReading?.at == at(10.5).wall, "unchanged readings keep the time it changed")
        s = step(s, at(10.7), reading(19, .battery), event: .willSleep)
        #expect(s.lastRestReading?.at == at(10.7).wall, "a sleep always records it")
    }

    @Test("A daylight-saving change during the rest leaves the time shown exactly 5 hours later as an instant")
    func restAcrossDST() throws {
        // 2026-10-25 00:30Z is 01:30 BST in London; clocks go back at 01:00Z.
        let entry = try Date("2026-10-25T00:30:00Z", strategy: .iso8601)
        let shown = CalibrationSession.plugInTime(after: entry)
        #expect(shown == entry.addingTimeInterval(5 * hour))
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        // 01:30 BST then 05:30 GMT on the clock: four hours apart on the
        // clock face, five as elapsed time.
        #expect(london.dateComponents([.hour, .minute], from: entry) == DateComponents(hour: 1, minute: 30))
        #expect(london.dateComponents([.hour, .minute], from: shown) == DateComponents(hour: 5, minute: 30))
        let s = step(session(in: .drain), CalibrationStamp(wall: entry, monotonic: 60_000, boot: bootA), reading(20, .battery))
        #expect(s.plugInAfter == shown)
        #expect(!s.isRestTimeReached(at: CalibrationStamp(wall: shown.addingTimeInterval(-1), monotonic: 60_000 + 5 * hour - 1, boot: bootA)))
        #expect(s.isRestTimeReached(at: CalibrationStamp(wall: shown, monotonic: 60_000 + 5 * hour, boot: bootA)))
    }

    // MARK: - Plug in and the final charge

    @Test("Step 6 moves to step 7 on a plug-in, not while paused")
    func plugInStep() {
        let s = session(in: .plugIn)
        #expect(observe(s, at(16), reading(18, .battery)).session.step == .plugIn)
        #expect(observe(s, at(16), reading(18)).session.step == .finalCharge)
        #expect(observe(s, at(16), reading(18), paused: true).session.step == .plugIn)
        // No bound but the cap.
        #expect(observe(s, at(71), reading(10, .battery)).end == nil)
    }

    @Test("Step 7 returns once charged under a confirmed 100%, and completes when the return is confirmed")
    func finalCharge() {
        let s = session(in: .finalCharge)
        #expect(s.asksForFullLimit)
        #expect(!observe(s, at(18), reading(100, charging: false, full: true), held: false).session.isReturning)
        let charged = observe(s, at(18), reading(100, charging: false, full: true))
        #expect(charged.session.isReturning)
        #expect(charged.changes == [.returning(from: .finalCharge)])
        let done = charged.session.returnConfirmed(at: at(18.1))
        #expect(done.end == .completed)
        #expect(done.changes == [.returnConfirmed])
    }

    @Test("Unplugging during step 7 before full ends the session; while returning it does not")
    func finalChargeUnplug() {
        let s = session(in: .finalCharge)
        #expect(observe(s, at(17), reading(60, .battery)).end == .unplugged(.finalCharge))
        let charged = step(s, at(18), reading(100, charging: false, full: true))
        #expect(observe(charged, at(18.1), reading(100, .battery)).end == nil)
    }

    @Test("Step 7 ends the session at its 6-hour bound, but not while returning")
    func finalChargeBound() {
        let s = session(in: .finalCharge)
        #expect(observe(s, at(16 + 6), reading(90)).end == .stepBound(.finalCharge))
        let charged = step(s, at(18), reading(100, charging: false, full: true))
        #expect(observe(charged, at(16 + 7), reading(100, charging: false, full: true)).end == nil)
    }

    // MARK: - The cap, temperature, and clocks

    @Test("Every step ends at 72 hours: by the monotonic clock within the boot, by the wall clock across a restart")
    func cap() {
        for target in CalibrationStep.allCases {
            let s = session(in: target)
            #expect(observe(s, at(72), nil).end == .sessionCap, "step \(target.rawValue)")
            #expect(observe(s, at(72, wallShift: -10 * hour), nil).end == .sessionCap)
        }
        let s = session(in: .plugIn)
        #expect(observe(s, at(71.9), nil).end == nil)
        #expect(observe(s, at(71.9, wallShift: 2 * hour), nil).end == nil, "a clock moved forward within the boot changes nothing")
        #expect(observe(s, at(72, boot: bootB), nil).end == .sessionCap)
        #expect(observe(s, at(71, boot: bootB), nil).end == nil)
        // An unknown boot is never the same boot.
        #expect(observe(s, CalibrationStamp(wall: start.addingTimeInterval(72 * hour), monotonic: 0, boot: nil), nil).end == .sessionCap)
    }

    @Test("A non-finite clock counts as past every bound")
    func nonFinite() {
        let s = newSession()
        let broken = CalibrationStamp(wall: start, monotonic: .nan, boot: bootA)
        #expect(observe(s, broken, nil).end == .sessionCap)
    }

    @Test("With a temperature reading, R23's 10–40 °C applies; a reading disappearing ends the session")
    func temperature() {
        let s = newSession(check: .measured)
        #expect(observe(s, at(1), reading(80, temperature: 10)).end == nil)
        #expect(observe(s, at(1), reading(80, temperature: 40)).end == nil)
        #expect(observe(s, at(1), reading(80, temperature: 9.9)).end == .temperatureOutOfRange(celsius: 9.9))
        #expect(observe(s, at(1), reading(80, temperature: 40.1)).end == .temperatureOutOfRange(celsius: 40.1))
        #expect(observe(s, at(1), reading(80)).end == .temperatureLost)
        // Paused too.
        #expect(observe(s, at(1), reading(80), paused: true).end == .temperatureLost)
        // No usable reading is not a lost temperature.
        #expect(observe(s, at(1), nil).end == nil)

        // Where it cannot be read, nothing ends; a reading that appears is
        // checked, and its loss then ends the session.
        let room = newSession()
        #expect(observe(room, at(1), reading(80)).end == nil)
        let seen = step(room, at(1), reading(80, temperature: 30))
        #expect(seen.hasSeenTemperature)
        #expect(observe(seen, at(2), reading(80)).end == .temperatureLost)
        #expect(observe(room, at(1), reading(80, temperature: 45)).end == .temperatureOutOfRange(celsius: 45))
    }

    @Test("Without a usable reading nothing moves but the bounds")
    func noReading() {
        for target in CalibrationStep.allCases {
            let s = session(in: target)
            let later = CalibrationStamp(wall: s.stepStartedAt.wall.addingTimeInterval(1800), monotonic: s.stepStartedAt.monotonic + 1800, boot: bootA)
            let progress = observe(s, later, nil)
            #expect(progress.end == nil)
            #expect(progress.session == s)
        }
    }

    // MARK: - Continue

    @Test("Continue needs a reading")
    func continueNeedsReading() {
        let s = session(in: .drain)
        #expect(s.continued(at: at(5), reading: nil, run: run, restAnswer: nil, bootTime: nil) == .refused("CellKeeper has no current battery reading. Try again in a moment."))
    }

    @Test("Continue in step 2 starts the rest timer again, on power; on battery power it is the early unplug")
    func continueTopRest() throws {
        var s = session(in: .restAtTop)
        s.isReturning = true
        guard case .progress(let resumed) = s.continued(at: at(5), reading: reading(100, charging: false, full: true), run: run, restAnswer: nil, bootTime: nil) else {
            Issue.record("refused")
            return
        }
        #expect(resumed.session.stepStartedAt == at(5))
        #expect(!resumed.session.isReturning)
        #expect(resumed.session.resumedAt == [at(5).wall])
        #expect(resumed.changes == [.continued, .topRestRestarted])
        #expect(!observe(resumed.session, at(6.9), reading(100, charging: false, full: true)).session.isReturning)
        #expect(observe(resumed.session, at(7), reading(100, charging: false, full: true)).session.isReturning)

        guard case .progress(let unplugged) = session(in: .restAtTop).continued(at: at(2), reading: reading(95, .battery), run: run, restAnswer: nil, bootTime: nil) else {
            Issue.record("refused")
            return
        }
        #expect(unplugged.session.step == .drain)
        #expect(unplugged.session.isReturning)
        #expect(unplugged.session.shortRests == [.restAtTop])
    }

    @Test("Continue applies the endings first: an unplug in step 1 or 7, a plug-in in step 4")
    func continueEndings() {
        if case .progress(let one) = session(in: .chargeToFull).continued(at: at(1), reading: reading(80, .battery), run: run, restAnswer: nil, bootTime: nil) {
            #expect(one.end == .unplugged(.chargeToFull))
        } else {
            Issue.record("refused")
        }
        if case .progress(let drain) = session(in: .drain).continued(at: at(5), reading: reading(60), run: run, restAnswer: nil, bootTime: nil) {
            #expect(drain.end == .pluggedInDuringDrain)
        } else {
            Issue.record("refused")
        }
    }

    @Test("Continue in step 1, 3, 4, 6 or 7 changes no step; the next check judges the power")
    func continueOthers() {
        for target in [CalibrationStep.chargeToFull, .unplug, .drain, .plugIn, .finalCharge] {
            let s = session(in: target)
            let power: PowerSource = target == .drain || target == .plugIn ? .battery : .externalPower
            let later = CalibrationStamp(wall: s.stepStartedAt.wall.addingTimeInterval(1800), monotonic: s.stepStartedAt.monotonic + 1800, boot: bootA)
            guard case .progress(let resumed) = s.continued(at: later, reading: reading(50, power), run: run, restAnswer: nil, bootTime: nil) else {
                Issue.record("refused in step \(target.rawValue)")
                continue
            }
            #expect(resumed.end == nil)
            #expect(resumed.session.step == target)
            #expect(resumed.session.stepStartedAt == s.stepStartedAt, "the bound counts from the step's start")
            #expect(resumed.changes == [.continued])
        }
    }

    @Test("Continue in step 5 after a restart, once the time shown has come, needs the owner's answer and records it")
    func continueAfterRestart() throws {
        var s = session(in: .restAtBottom)
        s = step(s, at(10.2), reading(19, .battery), event: .willSleep)
        let boot = Date(timeIntervalSince1970: 1_800_100_000)
        let now = at(15.5, boot: bootB)
        #expect(s.needsRestAnswer(at: now))
        #expect(!s.needsRestAnswer(at: at(14, boot: bootB)))
        #expect(!s.needsRestAnswer(at: at(15.5)), "the same boot")
        #expect(s.continued(at: now, reading: reading(19, .battery), run: otherRun, restAnswer: nil, bootTime: boot) == .refused("Answer whether your Mac stayed shut down and unplugged until the time shown."))

        guard case .progress(let yes) = s.continued(at: now, reading: reading(19, .battery), run: otherRun, restAnswer: true, bootTime: boot) else {
            Issue.record("refused")
            return
        }
        #expect(yes.session.step == .plugIn)
        #expect(yes.session.restResult == .ownersAccount(bootTime: boot, lastReading: CalibrationReading(at: at(10.2).wall, percent: 19, powerSource: .battery)))
        guard case .progress(let no) = s.continued(at: now, reading: reading(19), run: otherRun, restAnswer: false, bootTime: boot) else {
            Issue.record("refused")
            return
        }
        #expect(no.session.step == .finalCharge)
        #expect(no.session.restResult == .notConfirmed(.ownerSaidNo))
        #expect(no.session.shortRests.isEmpty)
    }

    @Test("Continue in step 5 before the time shown: not confirmed, and on battery power above 15% one request to rest again")
    func continueBeforeTime() {
        let s = session(in: .restAtBottom)
        guard case .progress(let restarted) = s.continued(at: at(12, boot: bootB), reading: reading(19, .battery), run: otherRun, restAnswer: true, bootTime: nil) else {
            Issue.record("refused")
            return
        }
        #expect(restarted.session.step == .restAtBottom)
        #expect(restarted.session.isRestAgainRequested)
        #expect(restarted.session.restFallback == .restartedBeforeTime)
        #expect(restarted.changes == [.continued, .restAgainRequested])
        // With no sleep in this run, the time then moves to step 6 with the
        // reason found at the continue.
        let reached = observe(restarted.session, at(15.1, boot: bootB), reading(18, .battery), run: otherRun)
        #expect(reached.session.step == .plugIn)
        #expect(reached.session.restResult == .notConfirmed(.restartedBeforeTime))

        guard case .progress(let sameBoot) = s.continued(at: at(12), reading: reading(19), run: otherRun, restAnswer: nil, bootTime: nil) else {
            Issue.record("refused")
            return
        }
        #expect(sameBoot.session.step == .finalCharge)
        #expect(sameBoot.session.restResult == .notConfirmed(.cellKeeperRestarted))
        #expect(sameBoot.session.shortRests == [.restAtBottom])

        guard case .progress(let low) = s.continued(at: at(12), reading: reading(15, .battery), run: otherRun, restAnswer: nil, bootTime: nil) else {
            Issue.record("refused")
            return
        }
        #expect(low.session.step == .plugIn)
        #expect(low.session.shortRests == [.restAtBottom])

        var asked = s
        asked.isRestAgainRequested = true
        guard case .progress(let twice) = asked.continued(at: at(12), reading: reading(19, .battery), run: otherRun, restAnswer: nil, bootTime: nil) else {
            Issue.record("refused")
            return
        }
        #expect(twice.session.step == .plugIn)
    }

    @Test("While paused in step 5 nothing applies, not even a low charge: the rest may have begun")
    func pausedRest() {
        let s = session(in: .restAtBottom)
        let paused = observe(s, at(12), reading(12, .battery), paused: true)
        #expect(paused.end == nil)
        #expect(paused.session == s)
    }

    // MARK: - Display and the report

    @Test("The step's end is estimated from the monotonic clock: the bounds, the top rest, and the time shown")
    func estimates() {
        let one = newSession()
        #expect(one.stepEndEstimate(at: at(1)) == at(6).wall)
        #expect(one.stepEndEstimate(at: at(1, wallShift: hour)) == at(7).wall, "derived at now, so a clock change shows")
        #expect(session(in: .restAtTop).stepEndEstimate(at: at(2)) == at(3).wall)
        #expect(session(in: .unplug).stepEndEstimate(at: at(4)) == at(7.25).wall)
        #expect(session(in: .drain).stepEndEstimate(at: at(5)) == nil)
        #expect(session(in: .restAtBottom).stepEndEstimate(at: at(11)) == CalibrationSession.plugInTime(after: at(10).wall))
        var returning = session(in: .restAtTop)
        returning.isReturning = true
        #expect(returning.stepEndEstimate(at: at(3)) == nil)
        #expect(one.capEstimate(at: at(10)) == at(72).wall)
        #expect(one.capEstimate(at: at(80)) == at(80).wall)
    }

    @Test("The report keeps what §7.9 lists, and the steps done")
    func report() {
        let s = session(in: .finalCharge)
        let after = CalibrationCapacities(fullChargeMilliampHours: 6100, nominalMilliampHours: 6290, designMilliampHours: 6249, cycleCount: 57)
        let done = CalibrationReport(s, end: .completed, at: at(18).wall, after: after)
        #expect(done.stepsDone == CalibrationStep.allCases)
        #expect(done.before == s.before)
        #expect(done.after == after)
        #expect(done.restResult == s.restResult)
        #expect(done.lastStep == .finalCharge)
        let early = CalibrationReport(session(in: .drain), end: .pluggedInDuringDrain, at: at(5).wall, after: nil)
        #expect(early.stepsDone == [.chargeToFull, .restAtTop, .unplug])
    }

    @Test("A session survives encoding with every field")
    func codable() throws {
        var s = asleep()
        s = step(s, at(12), reading(18, .battery), event: .didWake)
        s.shortRests = [.restAtTop]
        s.resumedAt = [at(11).wall]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(CalibrationSession.self, from: data) == s)
        let report = CalibrationReport(s, end: .unaccountedLimit(found: nil, expected: 90), at: at(12).wall, after: nil)
        #expect(try JSONDecoder().decode(CalibrationReport.self, from: JSONEncoder().encode(report)) == report)
    }
}
