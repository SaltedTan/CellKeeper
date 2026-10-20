import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// The menu's line for the session that ended, as the status now shows it.
private func outcome(_ status: ControllerStatus) throws -> String {
    let report = try #require(status.calibration.outcome)
    return CalibrationWording.outcomeLine(report, status: status)
}

/// What a session's end says about the limit follows what a read-back
/// confirmed, never what CellKeeper intends (R30).
@Suite("Calibration: what the end says about the limit")
struct CalibrationEndMessageTests {
    @Test("A return that fails, with a fallback to the owner's limit that fails too, says the limit is not confirmed and how to set it, in the menu and the notification")
    func failedFallback() async throws {
        let rig = CalibrationRig()
        var planner = NotificationPlanner()
        _ = planner.plan(await rig.drive(to: .restAtTop), trigger: .periodic, uptime: 1, isDelivering: true)
        rig.clock.advance(by: 2 * hour)
        rig.system.scheduleRuns([.fails, .fails])
        var status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.last?.end == .returnFailed)
        #expect(rig.system.reading == .noLimit, "macOS still at 100%")
        let line = try outcome(status)
        #expect(!line.contains("applies again"))
        #expect(line.contains("macOS has not confirmed CellKeeper's limit back yet: it still reports its Charge Limit at 100%."))
        #expect(line.contains("set your own limit, 90%, in System Settings › Battery › Charging"))
        let posted = planner.plan(status, trigger: .periodic, uptime: 2, isDelivering: true)
        let ended = try #require(posted.first { $0.kind == .calibrationEndedEarly })
        #expect(ended.body == line)

        // Once a read-back confirms a limit, the line says which.
        rig.clock.advance(by: 61)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        rig.clock.advance(by: 61)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(rig.system.reading == .limit(80))
        #expect(try outcome(status).contains("CellKeeper's 80% limit applies again, confirmed by macOS."))
    }

    @Test("A cancellation whose return the rate limit defers says it is not confirmed yet; once it is, the line says so")
    func rateLimitedCancel() async throws {
        let rig = CalibrationRig()
        var planner = NotificationPlanner()
        _ = planner.plan(await rig.started(), trigger: .overrideChanged, uptime: 1, isDelivering: true)
        rig.clock.advance(by: 10)
        var status = await rig.controller.cancelCalibration()
        #expect(status.calibration.last?.end == .cancelled)
        #expect(rig.system.reading == .noLimit)
        let line = try outcome(status)
        #expect(line.hasPrefix("Calibration cancelled."))
        #expect(!line.contains("applies again"))
        #expect(line.contains("it still reports its Charge Limit at 100%"))
        #expect(line.contains("set your own limit, 90%, in System Settings › Battery › Charging"))
        // The owner's own command posts nothing, and nothing claims the limit.
        #expect(planner.plan(status, trigger: .overrideChanged, uptime: 2, isDelivering: true).isEmpty)

        rig.clock.advance(by: 61)
        status = await rig.controller.evaluate(.periodic)
        #expect(rig.system.reading == .limit(80))
        #expect(try outcome(status) == "Calibration cancelled. CellKeeper's 80% limit applies again, confirmed by macOS. The report is in Settings › Charging.")
    }

    @Test("An end by itself whose return is still deferred posts that the limit is not confirmed yet")
    func deferredReturnNotified() async throws {
        let rig = CalibrationRig()
        var planner = NotificationPlanner()
        _ = planner.plan(await rig.started(), trigger: .overrideChanged, uptime: 1, isDelivering: true)
        rig.clock.advance(by: 10)
        let status = await rig.read(calibrationReading(80, .battery), .powerSourceChanged)
        #expect(status.calibration.last?.end == .unplugged(.chargeToFull))
        let ended = try #require(planner.plan(status, trigger: .powerSourceChanged, uptime: 2, isDelivering: true).first { $0.kind == .calibrationEndedEarly })
        #expect(!ended.body.contains("applies again"))
        #expect(ended.body.contains("macOS has not confirmed CellKeeper's limit back yet"))
    }

    @Test("Turning Manage charging off ends the session with the owner's own limit back, confirmed")
    func ownLimitBack() async throws {
        let rig = CalibrationRig()
        _ = await rig.started()
        var off = ChargingSettings.default.withChargeLimit(80)
        off.isManagementEnabled = false
        let status = try await rig.controller.apply(settings: off)
        #expect(rig.system.reading == .limit(90))
        #expect(try outcome(status) == "Calibration ended: Manage charging was turned off. Your own Charge Limit of 90% applies again, confirmed by macOS. The report is in Settings › Charging.")
    }
}
