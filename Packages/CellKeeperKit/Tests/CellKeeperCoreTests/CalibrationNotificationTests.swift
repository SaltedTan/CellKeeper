import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// A planner fed the statuses a calibration rig produces, in order, with
/// what each posted.
private final class Planned {
    var planner = NotificationPlanner()
    var posted: [PlannedNotification] = []
    var uptime: TimeInterval = 0
    var isDelivering = true

    func observe(_ status: ControllerStatus, _ trigger: EvaluationTrigger) {
        uptime += 1
        posted += planner.plan(status, trigger: trigger, uptime: uptime, isDelivering: isDelivering)
    }

    var kinds: [NotificationKind] { posted.map(\.kind) }
}

@Suite("Calibration: notifications")
struct CalibrationNotificationTests {
    @Test("A calibration posts its requests once each, as they begin, and its end: unplug, rest, plug in, finished")
    func wholeCalibration() async throws {
        let rig = CalibrationRig()
        let planned = Planned()
        planned.observe(await rig.controller.evaluate(.launch), .launch)
        rig.clock.advance(by: 120)
        planned.observe(await rig.controller.startCalibration(allConfirmed, isNotifying: true), .overrideChanged)
        rig.clock.advance(by: hour)
        planned.observe(await rig.read(calibrationReading(100, charging: false, full: true)), .periodic)
        rig.clock.advance(by: 2 * hour)
        planned.observe(await rig.read(calibrationReading(100, charging: false, full: true)), .periodic)
        #expect(planned.kinds == [.calibrationUnplug])
        planned.observe(await rig.read(calibrationReading(100, charging: false, full: true)), .periodic)
        #expect(planned.kinds == [.calibrationUnplug], "a request still shown is not posted again")

        planned.observe(await rig.read(calibrationReading(99, .battery), .powerSourceChanged), .powerSourceChanged)
        rig.clock.advance(by: 4 * hour)
        let resting = await rig.read(calibrationReading(20, .battery))
        planned.observe(resting, .periodic)
        #expect(planned.kinds == [.calibrationUnplug, .calibrationRest])
        let rest = try #require(planned.posted.last)
        let shown = try #require(resting.calibration.session?.plugInAfter)
        let now = try #require(resting.lastEvaluation)
        #expect(rest.title == "Calibration: rest your Mac unplugged")
        #expect(rest.body == CalibrationWording.text(.rest(plugInAfter: shown), atRequest: true, now: now))
        #expect(rest.body.contains("(at least 5 hours from now), even before you open CellKeeper"))

        planned.observe(await rig.read(calibrationReading(18, .battery), .willSleep), .willSleep)
        rig.clock.advance(by: 5.1 * hour)
        planned.observe(await rig.read(calibrationReading(17, .battery), .didWake), .didWake)
        #expect(planned.kinds.last == .calibrationPlugIn)
        planned.observe(await rig.read(calibrationReading(17), .powerSourceChanged), .powerSourceChanged)
        rig.clock.advance(by: 2 * hour)
        planned.observe(await rig.read(calibrationReading(100, charging: false, full: true)), .periodic)
        #expect(planned.kinds == [.calibrationUnplug, .calibrationRest, .calibrationPlugIn, .calibrationFinished])
        #expect(planned.posted.last?.title == "Calibration finished")
        #expect(Set(planned.kinds.map(\.replacementKey)) == ["calibration"])
    }

    @Test("A request asked again after an early wake is posted again")
    func restAgain() async {
        let rig = CalibrationRig()
        let planned = Planned()
        planned.observe(await rig.drive(to: .restAtBottom), .periodic)
        planned.observe(await rig.read(calibrationReading(19, .battery), .willSleep), .willSleep)
        rig.clock.advance(by: hour)
        let woke = await rig.read(calibrationReading(19, .battery), .didWake)
        #expect(woke.calibration.session?.isRestAgainRequested == true)
        planned.observe(woke, .didWake)
        #expect(planned.kinds == [.calibrationRest])
        #expect(planned.posted.first?.body.hasPrefix("Your Mac woke before") == true)
    }

    @Test("Nothing true at the first status is posted: a request already shown, or a session already ended")
    func noReplay() async {
        let rig = CalibrationRig()
        let status = await rig.drive(to: .unplug)
        let planned = Planned()
        planned.observe(status, .launch)
        planned.observe(await rig.controller.evaluate(.periodic), .periodic)
        #expect(planned.kinds.isEmpty)
    }

    @Test("An end by itself posts “ended early”, asking for a plug-in after a low battery; a cancel posts nothing")
    func endings() async {
        let rig = CalibrationRig()
        let planned = Planned()
        planned.observe(await rig.drive(to: .drain), .periodic)
        rig.clock.advance(by: hour)
        planned.observe(await rig.read(calibrationReading(15, .battery)), .periodic)
        #expect(planned.kinds == [.calibrationEndedEarly])
        #expect(planned.posted.first?.title == "Calibration ended: plug in your Mac now")
        #expect(planned.posted.first?.body.hasPrefix("Plug in your Mac now: the battery is at 15%.") == true)

        let other = CalibrationRig()
        let cancelled = Planned()
        cancelled.observe(await other.drive(to: .chargeToFull), .periodic)
        cancelled.observe(await other.controller.cancelCalibration(), .overrideChanged)
        #expect(cancelled.kinds.isEmpty)
    }

    @Test("Requests made by the owner's own command are not posted: the menu shows them")
    func ownCommand() async {
        let rig = CalibrationRig()
        let resting = await rig.drive(to: .restAtBottom)
        await rig.controller.shutdown(reason: "quit")
        rig.clock.advance(by: hour)
        let second = rig.relaunched(reading: calibrationReading(18, .battery))
        let planned = Planned()
        planned.observe(await second.controller.evaluate(.launch), .launch)
        #expect(resting.calibration.session != nil)
        let continued = await second.controller.continueCalibration()
        #expect(continued.calibration.session?.isRestAgainRequested == true)
        planned.observe(continued, .overrideChanged)
        #expect(planned.kinds.isEmpty)
    }

    @Test("While notifications are not delivered, requests post nothing and are not replayed later")
    func notDelivering() async {
        let rig = CalibrationRig()
        let planned = Planned()
        planned.isDelivering = false
        planned.observe(await rig.drive(to: .restAtTop), .periodic)
        rig.clock.advance(by: 2 * hour)
        planned.observe(await rig.read(calibrationReading(100, charging: false, full: true)), .periodic)
        planned.isDelivering = true
        planned.observe(await rig.controller.evaluate(.periodic), .periodic)
        #expect(planned.kinds.isEmpty)
    }
}
