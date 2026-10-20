import CellKeeperCore
import Foundation
import Testing

private let utc = TimeZone(identifier: "UTC")!
private let english = Locale(identifier: "en_US_POSIX")
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func session(_ step: CalibrationStep, plugInAfter: Date? = nil) -> CalibrationSession {
    var session = CalibrationSession.start(
        id: UUID(),
        at: CalibrationStamp(wall: start, monotonic: 1_000, boot: "b"),
        ownerLimit: 90,
        cellKeeperLimit: 80,
        before: CalibrationCapacities(fullChargeMilliampHours: 6150, nominalMilliampHours: 6302, designMilliampHours: 6249, cycleCount: 56),
        temperatureCheck: .ownerConfirmedCoolRoom,
        optimizedCharging: .off
    )
    session.step = step
    session.steps.append(CalibrationStepEntry(step: step, enteredAt: start))
    session.plugInAfter = plugInAfter
    return session
}

private func status(_ session: CalibrationSession?, paused: Bool = false, needsAnswer: Bool = false, confirmed: Bool = true, stepEndsAt: Date? = nil) -> CalibrationStatus {
    CalibrationStatus(isAvailable: true, session: session, isPaused: paused, needsRestAnswer: needsAnswer, stepEndsAt: stepEndsAt, isFullLimitConfirmed: confirmed)
}

private func line(_ status: CalibrationStatus, reading: BatterySnapshot? = nil, now: Date = start) -> String? {
    CalibrationWording.statusLine(status, cellKeeperLimit: 80, reading: reading, now: now, timeZone: utc, locale: english)
}

@Suite("Calibration: wording")
struct CalibrationWordingTests {
    let shown = start.addingTimeInterval(5 * 3600 + 40 * 60)

    @Test("The requests: unplug in step 3, rest in step 5 above 15% only, plug in in step 6; none while paused or returning")
    func requests() {
        #expect(CalibrationWording.request(status(session(.unplug)), reading: nil) == .unplug)
        #expect(CalibrationWording.request(status(session(.restAtBottom, plugInAfter: shown)), reading: snapshot(percent: 18, source: .battery)) == .rest(plugInAfter: shown))
        #expect(CalibrationWording.request(status(session(.restAtBottom, plugInAfter: shown)), reading: snapshot(percent: 15, source: .battery)) == nil)
        var again = session(.restAtBottom, plugInAfter: shown)
        again.isRestAgainRequested = true
        #expect(CalibrationWording.request(status(again), reading: nil) == .restAgain(plugInAfter: shown))
        #expect(CalibrationWording.request(status(session(.plugIn)), reading: nil) == .plugIn)
        for step in [CalibrationStep.chargeToFull, .restAtTop, .drain, .finalCharge] {
            #expect(CalibrationWording.request(status(session(step)), reading: nil) == nil)
        }
        #expect(CalibrationWording.request(status(session(.unplug), paused: true), reading: nil) == nil)
        var returning = session(.drain)
        returning.isReturning = true
        #expect(CalibrationWording.request(status(returning), reading: nil) == nil)
    }

    @Test("The rest's request carries the clock time to plug in again and says to do it even before opening CellKeeper (§7.5)")
    func restRequest() {
        let notification = CalibrationWording.text(.rest(plugInAfter: shown), atRequest: true, now: start, timeZone: utc, locale: english)
        #expect(notification == "Shut down your Mac now and leave it unplugged. Plug it in again after 1:40 PM (at least 5 hours from now), even before you open CellKeeper. CellKeeper continues when you open it again. If you cannot shut it down, put it to sleep instead.")
        let menu = CalibrationWording.text(.rest(plugInAfter: shown), atRequest: false, now: start, timeZone: utc, locale: english)
        #expect(menu.contains("after 1:40 PM (5 hours after the battery reached 20%), even before you open CellKeeper"))
        #expect(CalibrationWording.text(.unplug, atRequest: true, now: start) == "Unplug your Mac now; CellKeeper will watch the battery drain to 20%.")
        #expect(CalibrationWording.text(.restAgain(plugInAfter: shown), atRequest: true, now: start, timeZone: utc, locale: english).hasPrefix("Your Mac woke before 1:40 PM."))
    }

    @Test("A time on another day shows its day")
    func clockTime() {
        #expect(CalibrationWording.clockTime(shown, now: start, timeZone: utc, locale: english) == "1:40 PM")
        let tomorrow = start.addingTimeInterval(20 * 3600)
        #expect(CalibrationWording.clockTime(tomorrow, now: start, timeZone: utc, locale: english) == "Sat, Jan 16 at 4:00 AM")
    }

    @Test("The menu's line says the step, what to do, and when it ends; returning and paused say so")
    func statusLines() {
        let end = start.addingTimeInterval(6 * 3600)
        #expect(line(status(session(.chargeToFull), stepEndsAt: end)) == "Calibration, step 1 of 7: charging to 100%. Leave your Mac plugged in; this step ends when macOS reports the battery charged, at the latest at 2:00 PM.")
        #expect(line(status(session(.chargeToFull), confirmed: false))?.hasSuffix("CellKeeper has asked for 100%; macOS has not confirmed it yet.") == true)
        #expect(line(status(session(.restAtTop), stepEndsAt: end)) == "Calibration, step 2 of 7: resting at 100% until about 2:00 PM. Leave your Mac plugged in.")
        #expect(line(status(session(.unplug), stepEndsAt: end)) == "Calibration, step 3 of 7: unplug your Mac now; CellKeeper will watch the battery drain to 20%. If your Mac is still plugged in at 2:00 PM, the calibration ends.")
        #expect(line(status(session(.drain)), reading: snapshot(percent: 54, source: .battery)) == "Calibration, step 4 of 7: draining to 20% (now 54%). Use your Mac on battery power as usual.")
        #expect(line(status(session(.plugIn))) == "Calibration, step 6 of 7: plug in your Mac now; CellKeeper will charge it to 100% once more, then return to your limit.")
        var returning = session(.restAtTop)
        returning.isReturning = true
        #expect(line(status(returning)) == "Calibration, step 2 of 7: returning to your limit. CellKeeper asks macOS for its 80% limit again and waits for macOS to confirm it.")
        #expect(line(status(session(.drain), paused: true)) == "Calibration paused in step 4 of 7 (drain): CellKeeper was not running. Continue to go on, or cancel it. Meanwhile your 80% limit applies.")
        #expect(line(status(session(.restAtBottom, plugInAfter: shown), paused: true, needsAnswer: true)) == "Calibration paused in step 5 of 7: CellKeeper started again after a restart. Did your Mac stay shut down and unplugged until 1:40 PM?")
        #expect(line(status(nil)) == nil)
    }

    @Test("The outcome asks to plug in after a low-battery end, points to the report otherwise, and says only what macOS confirmed about the limit")
    func outcomes() {
        let s = session(.drain)
        let confirmed = CalibrationLimitAfter.cellKeeperLimit(80)
        #expect(CalibrationWording.outcomeLine(CalibrationReport(s, end: .lowBattery(percent: 14), at: start, after: nil), limit: confirmed, ownerLimit: 90) == "Plug in your Mac now: the battery is at 14%. The calibration has ended. CellKeeper's 80% limit applies again, confirmed by macOS.")
        #expect(CalibrationWording.outcomeLine(CalibrationReport(s, end: .completed, at: start, after: nil), limit: confirmed, ownerLimit: 90) == "Calibration finished. CellKeeper's 80% limit applies again, confirmed by macOS. The report is in Settings › Charging.")
        #expect(CalibrationWording.outcomeLine(CalibrationReport(s, end: .pluggedInDuringDrain, at: start, after: nil), limit: .ownLimit(90), ownerLimit: 90) == "Calibration ended: the Mac was plugged in before the battery drained to 20%. Your own Charge Limit of 90% applies again, confirmed by macOS. The report is in Settings › Charging.")
        #expect(CalibrationWording.limitSentence(.unconfirmed(reported: nil), ownerLimit: 90) == "macOS has not confirmed CellKeeper's limit back yet, so its Charge Limit may still be at 100%. CellKeeper keeps asking; if it does not change, set your own limit, 90%, in System Settings › Battery › Charging.")
        #expect(CalibrationWording.limitSentence(.unconfirmed(reported: 85), ownerLimit: 90).hasPrefix("macOS has not confirmed CellKeeper's limit back yet: it reports 85%."))
    }

    @Test("The report lists §7.9's items and says that the gauge decides and the result cannot be checked")
    func report() {
        var s = session(.finalCharge)
        s.restResult = .counted(sleptFor: 5.1 * 3600, fromPercent: 18, toPercent: 17)
        s.shortRests = [.restAtTop]
        let report = CalibrationReport(s, end: .completed, at: start.addingTimeInterval(86_400), after: CalibrationCapacities(fullChargeMilliampHours: 6100, cycleCount: 57))
        let lines = Dictionary(CalibrationWording.reportLines(report, now: start, timeZone: utc, locale: english).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(lines["Before"] == "full-charge capacity 6150 mAh, nominal 6302 mAh, design 6249 mAh, 56 cycles")
        #expect(lines["After"] == "full-charge capacity 6100 mAh, 57 cycles")
        #expect(lines["Rest at the bottom"] == "counted: your Mac slept for 5 hours, 6 minutes on battery power, from 18% to 17%")
        #expect(lines["Recorded as short"] == "rest at the top")
        #expect(lines["Temperature"] == "not checked: this Mac does not report it; you confirmed a cool room")
        #expect(lines["Steps done"]?.hasPrefix("1 (charge to full)") == true)
        let summary = CalibrationWording.reportSummary(report)
        #expect(summary.contains(CalibrationWording.gaugeNote))
        #expect(CalibrationWording.gaugeNote.contains("cannot check"))
    }

    @Test("The recovery gives the value to set in System Settings › Battery")
    func recovery() {
        #expect(CalibrationWording.recovery(ownerLimit: 90).hasSuffix("set the limit yourself in System Settings › Battery › Charging: your own limit is 90%."))
        #expect(CalibrationWording.recovery(ownerLimit: 100).hasSuffix("your own limit is 100% (no limit)."))
    }

    @Test("Every change of the session has a log line or is said by another")
    func logLines() {
        let changes: [CalibrationChange] = CalibrationStep.allCases.map { .entered($0) } + [
            .returning(from: .restAtTop), .returnConfirmed, .earlyUnplug(restShort: true), .earlyPlugIn, .restShort(.restAtBottom),
            .restAgainRequested, .sleepRecorded(percent: 18, isOnBattery: true), .wakeRecorded,
            .restResult(.notConfirmed(.sleptTooShort)), .continued, .topRestRestarted,
        ]
        let silent: [CalibrationChange] = [.entered(.chargeToFull), .restShort(.restAtBottom)]
        for change in changes {
            #expect((CalibrationWording.logLine(change) == nil) == silent.contains(change), "\(change)")
        }
    }
}
