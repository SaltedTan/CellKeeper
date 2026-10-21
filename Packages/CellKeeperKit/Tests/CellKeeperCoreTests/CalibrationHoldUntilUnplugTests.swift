import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// Step 3 keeps macOS's Charge Limit at 100% until the owner unplugs
/// (owner decision, 2026-10-21): on AC power macOS drains the battery down
/// to a lower limit (note 08, O21), which would start the drain short of
/// full (note 12, first run).
@Suite("Calibration: 100% until the unplug")
struct CalibrationHoldUntilUnplugTests {
    @Test("Step 2's end asks for nothing: 100% stays, and the owner is asked to unplug, in the menu and a notification")
    func restEndKeepsFull() async throws {
        let rig = CalibrationRig()
        var planner = NotificationPlanner()
        _ = planner.plan(await rig.drive(to: .restAtTop), trigger: .periodic, uptime: 1, isDelivering: true)
        let writes = rig.system.runInputs
        rig.clock.advance(by: 2 * hour)
        let status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .unplug)
        #expect(rig.system.runInputs == writes, "no request for the normal limit")
        #expect(rig.system.reading == .noLimit, "macOS stays at 100%")
        #expect(status.decision?.state == .calibrating)
        #expect(status.decision?.desiredMode == .nativeLimit(percent: 100))
        #expect(status.calibration.isFullLimitConfirmed)
        #expect(!status.calibration.isReturning)
        #expect(status.events.contains { $0.kind == .calibration && $0.message.contains("Step 3 (unplug) began: CellKeeper keeps macOS's Charge Limit at 100%") })
        #expect(!status.events.contains { $0.kind == .calibration && $0.message.contains("is done; CellKeeper asks for its own limit again") })

        #expect(CalibrationWording.request(for: status) == .unplug)
        let line = try #require(CalibrationWording.statusLine(for: status))
        #expect(line.contains("unplug your Mac now. CellKeeper keeps macOS's Charge Limit at 100% until you do, then returns to your limit"))
        let posted = planner.plan(status, trigger: .periodic, uptime: 2, isDelivering: true)
        let unplug = try #require(posted.first { $0.kind == .calibrationUnplug })
        #expect(unplug.body.hasPrefix("Unplug your Mac now. CellKeeper keeps macOS's Charge Limit at 100% until you do"))

        // Still plugged in later in step 3: still 100%, nothing written.
        rig.clock.advance(by: hour)
        let later = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(later.calibration.session?.step == .unplug)
        #expect(rig.system.runInputs == writes)
    }

    @Test("An unplug in step 3 asks for the normal limit at once, records the charge, and the drain begins")
    func unplugReturnsAtOnce() async throws {
        let rig = CalibrationRig()
        await rig.drive(to: .unplug)
        rig.clock.advance(by: 1800)
        let status = await rig.read(calibrationReading(98, .battery), .powerSourceChanged)
        #expect(status.calibration.session?.step == .drain)
        #expect(rig.system.runInputs.suffix(2) == ["100", "80"])
        #expect(rig.system.reading == .limit(80))
        #expect(!status.calibration.isReturning, "confirmed in the same evaluation")
        #expect(status.calibration.session?.drainStartPercent == 98)
        #expect(status.calibration.session?.shortRests == [], "the rest at the top was complete")
        #expect(status.events.contains { $0.kind == .calibration && $0.message == "Calibration: step 4 (drain) began at 98%: the battery drains to 20% while you use your Mac on battery power." })
    }

    @Test("With the return deferred on battery power, the drain proceeds, the rest and the plug-in are asked for, and step 7 starts afresh, completing only after its charge")
    func deferredReturnDoesNotHoldTheDrain() async throws {
        let rig = CalibrationRig.settling()
        _ = await rig.startedSettled()
        rig.clock.advance(by: hour)
        _ = await rig.read(calibrationReading(100, charging: false, full: true))
        rig.clock.advance(by: 2 * hour)
        var status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .unplug)

        // The unplug: 80% is written, and macOS creates no limit for it on
        // battery power.
        rig.clock.advance(by: hour)
        rig.system.scheduleRuns([.appliesWithoutActiveLimit])
        status = await rig.read(calibrationReading(99, .battery), .powerSourceChanged)
        #expect(status.calibration.session?.step == .drain)
        #expect(status.calibration.isReturning)
        #expect(status.lastExecution?.result == .deferred(written: true))
        #expect(status.consecutiveFailures == 0)
        let writes = rig.system.runInputs.count

        rig.clock.advance(by: 3 * hour)
        status = await rig.read(calibrationReading(20, .battery))
        #expect(status.calibration.session?.step == .restAtBottom)
        guard case .rest? = CalibrationWording.request(for: status) else {
            Issue.record("the rest is not asked for")
            return
        }
        _ = await rig.read(calibrationReading(18, .battery), .willSleep)
        rig.clock.advance(by: 5.1 * hour)
        status = await rig.read(calibrationReading(17, .battery), .didWake)
        #expect(status.calibration.session?.step == .plugIn)
        #expect(CalibrationWording.request(for: status) == .plugIn)
        #expect(rig.system.runInputs.count == writes)

        rig.system.isActiveLimitCleared = false
        status = await rig.read(calibrationReading(17), .powerSourceChanged)
        #expect(status.calibration.session?.step == .finalCharge)
        #expect(!status.calibration.isReturning)
        #expect(status.calibration.last == nil, "the old return does not complete the session")
        rig.clock.advance(by: 61)
        status = await rig.read(calibrationReading(30))
        #expect(status.calibration.isFullLimitConfirmed)
        rig.clock.advance(by: 2 * hour)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        let report = try #require(status.calibration.last)
        #expect(report.end == .completed)
        #expect(report.drainStartPercent == 99)
        #expect(report.stepsDone == CalibrationStep.allCases)
    }

    @Test("Still plugged in after 4 hours in step 3: the session ends, the normal policy asks for its limit at once, and the end says macOS may then draw the battery down")
    func capEndsWithNormalPolicy() async throws {
        let rig = CalibrationRig()
        await rig.drive(to: .unplug)
        let writes = rig.system.runInputs
        rig.clock.advance(by: 4 * hour - 60)
        var status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .unplug)
        #expect(rig.system.runInputs == writes)
        rig.clock.advance(by: 60)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session == nil)
        let report = try #require(status.calibration.last)
        #expect(report.end == .stepBound(.unplug))
        #expect(report.drainStartPercent == nil)
        #expect(rig.system.runInputs == writes + ["80"], "the normal limit, asked for at once")
        #expect(rig.system.reading == .limit(80))
        #expect(status.decision?.state == .osEnforcedLimit)
        let line = CalibrationWording.outcomeLine(report, status: status)
        #expect(line == "Calibration ended: step 3 (unplug) reached its 4-hour limit. CellKeeper's 80% limit applies again, confirmed by macOS. While your Mac stays plugged in, macOS may run it from the battery until the charge is down to the limit. The report is in Settings › Charging.")
    }

    @Test("The charge at the unplug is in the report, its lines and the log's summary")
    func drainStartInReport() async throws {
        let rig = CalibrationRig()
        await rig.drive(to: .unplug)
        rig.clock.advance(by: 600)
        _ = await rig.read(calibrationReading(97, .battery), .powerSourceChanged)
        let status = await rig.controller.cancelCalibration()
        let report = try #require(status.calibration.last)
        #expect(report.drainStartPercent == 97)
        let lines = CalibrationWording.reportLines(report, now: rig.clock.now)
        #expect(lines.contains { $0.label == "Drain began at" && $0.value == "97%" })
        #expect(CalibrationWording.reportSummary(report).contains("The drain began at 97%."))
        #expect(rig.stored == .stored(CalibrationStored(last: report)), "stored with the report")
    }

    @Test("A stored session or report with a drain start outside 0–100% is not used")
    func drainStartValidated() throws {
        let storage = InMemoryStorage()
        let store = CalibrationStore(defaults: storage)
        var session = CalibrationSession.start(id: UUID(), at: CalibrationStamp(wall: referenceDate, monotonic: 1, boot: "b"), ownerLimit: 90, cellKeeperLimit: 80, before: CalibrationCapacities(), temperatureCheck: .ownerConfirmedCoolRoom, optimizedCharging: .off)
        session.drainStartPercent = 101
        try store.saveCalibration(CalibrationStored(session: session))
        guard case .unusable = store.loadCalibration() else {
            Issue.record("a session with a drain start of 101% was used")
            return
        }
        session.drainStartPercent = 80
        try store.saveCalibration(CalibrationStored(session: session))
        #expect(store.loadCalibration() == .stored(CalibrationStored(session: session)))
    }
}
