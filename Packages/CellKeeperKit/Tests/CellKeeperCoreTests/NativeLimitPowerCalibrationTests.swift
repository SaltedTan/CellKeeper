import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

extension CalibrationRig {
    /// A rig with the production settle window.
    static func settling(system: FakeChargeLimitSystem = FakeChargeLimitSystem(reading: .limit(90))) -> CalibrationRig {
        CalibrationRig(system: system, settleTime: ChargeController.chargeLimitSettleTime)
    }

    /// Launches on power, lets the settle window pass so the owner's limit
    /// is recorded and CellKeeper's set, waits out the rate limit, and
    /// starts a calibration: 100% confirmed for step 1.
    func startedSettled(sourceLocation: SourceLocation = #_sourceLocation) async -> ControllerStatus {
        await controller.evaluate(.launch)
        clock.advance(by: settleTime)
        _ = await read(calibrationReading(70))
        clock.advance(by: 120)
        let status = await controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.refusal == nil, sourceLocation: sourceLocation)
        #expect(status.calibration.isFullLimitConfirmed, sourceLocation: sourceLocation)
        return status
    }
}

/// A guided calibration while macOS's Charge Limit cannot be judged (on
/// battery power, or before power settles; research note 08, O20).
@Suite("Calibration: macOS's Charge Limit on battery power")
struct NativeLimitPowerCalibrationTests {
    @Test("The 2026-10-21 run: macOS clearing its limit during the drain is no outside change; the session runs on, and after the plug-in the limit is confirmed")
    func clearedDuringDrain() async throws {
        // Management on at 80%, the owner's own limit 80%.
        let rig = CalibrationRig.settling(system: FakeChargeLimitSystem(reading: .limit(80)))
        _ = await rig.startedSettled()
        #expect(rig.system.runInputs == ["100"])
        rig.clock.advance(by: hour)
        var status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .restAtTop)
        rig.clock.advance(by: 2 * hour)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .unplug)
        #expect(rig.system.runInputs == ["100"], "100% stays until the unplug")

        // 16:49:19, unplugged: step 4, and the return to 80% at once.
        rig.clock.advance(by: 2 * hour)
        status = await rig.read(calibrationReading(97, .battery), .powerSourceChanged)
        #expect(status.calibration.session?.step == .drain)
        #expect(status.calibration.session?.drainStartPercent == 97)
        #expect(rig.system.runInputs == ["100", "80"])

        // 16:54:20, PowerUIAgent clears its limit; 16:54:45, a periodic
        // check reads "no limit".
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 326)
        status = await rig.read(calibrationReading(96, .battery))
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.calibration.session?.step == .drain, "the session runs on")
        #expect(status.calibration.last == nil)
        #expect(!saysChangedOutside(status))
        #expect(!status.events.contains { $0.message.hasPrefix("Calibration ended") })
        #expect(NativeChargeLimitBackend.pendingAdoption(in: rig.records) == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.records)?.ownerLimit == 80, "nothing recorded as the owner's own: the record stands")
        #expect(status.nativeLimit?.readDeferral == .onBattery)
        #expect(status.currentMode == .nativeLimit(percent: 80))
        #expect(status.consecutiveFailures == 0)

        // Hours of draining, still on battery.
        for percent in [80, 60, 40] {
            rig.clock.advance(by: hour)
            status = await rig.read(calibrationReading(percent, .battery))
            #expect(status.calibration.session?.step == .drain)
            #expect(status.adoptionCount == 0)
        }
        #expect(rig.system.runInputs == ["100", "80"])

        // 20:05:14, plugged in at 35%: macOS creates its 80% limit at once.
        // A plug-in during the drain ends the session by its own rule.
        rig.system.isActiveLimitCleared = false
        rig.clock.advance(by: hour)
        status = await rig.read(calibrationReading(35), .powerSourceChanged)
        #expect(status.calibration.last?.end == .pluggedInDuringDrain)
        #expect(status.settings.isManagementEnabled)
        #expect(status.adoptionCount == 0)
        #expect(status.currentMode == .nativeLimit(percent: 80))

        rig.clock.advance(by: 61)
        status = await rig.read(calibrationReading(36))
        #expect(status.nativeLimit?.readDeferral == nil)
        #expect(status.isNativeLimitSettled)
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(rig.system.runInputs == ["100", "80"])
        #expect(!saysChangedOutside(status))
    }

    @Test("An early unplug whose return macOS shows no limit for on battery: the return waits for power, the rest and the plug-in are still asked for, and step 7 starts afresh")
    func earlyUnplugReturnWaitsForPower() async throws {
        let rig = CalibrationRig.settling()
        _ = await rig.startedSettled()
        rig.clock.advance(by: hour)
        var status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .restAtTop)

        // Unplugged 30 minutes into the rest. macOS shows "no limit" for
        // the 100% setting; the return is written, and macOS creates no
        // limit for it on battery power.
        rig.clock.advance(by: 1800)
        rig.system.scheduleRuns([.appliesWithoutActiveLimit])
        status = await rig.read(calibrationReading(99, .battery), .powerSourceChanged)
        #expect(status.calibration.session?.step == .drain)
        #expect(status.calibration.session?.shortRests == [.restAtTop])
        #expect(status.calibration.isReturning, "pending until macOS confirms it")
        #expect(rig.system.runInputs.last == "80")
        #expect(rig.system.reading == .limit(80), "the setting")
        #expect(status.lastExecution?.result == .deferred(written: true))
        #expect(status.consecutiveFailures == 0)
        let line = try #require(CalibrationWording.statusLine(for: status))
        #expect(line.contains("returning to your limit"))
        #expect(line.contains("macOS confirms it once your Mac has been on power for a minute"))
        let writes = rig.system.runInputs.count

        rig.clock.advance(by: 2 * hour)
        status = await rig.read(calibrationReading(50, .battery))
        #expect(status.calibration.session?.step == .drain)
        rig.clock.advance(by: 2 * hour)
        status = await rig.read(calibrationReading(20, .battery))
        #expect(status.calibration.session?.step == .restAtBottom)
        #expect(status.calibration.isReturning)
        guard case .rest? = CalibrationWording.request(for: status) else {
            Issue.record("the rest is not asked for: \(String(describing: CalibrationWording.request(for: status)))")
            return
        }
        #expect(CalibrationWording.statusLine(for: status)?.contains("shut down your Mac now") == true)

        status = await rig.read(calibrationReading(18, .battery), .willSleep)
        rig.clock.advance(by: 5.1 * hour)
        status = await rig.read(calibrationReading(17, .battery), .didWake)
        #expect(status.calibration.session?.step == .plugIn)
        #expect(CalibrationWording.request(for: status) == .plugIn)
        #expect(rig.system.runInputs.count == writes, "nothing written again on battery power")
        #expect(status.consecutiveFailures == 0)

        // Plugged in: macOS shows the 80% written on battery, and step 7
        // asks for 100% afresh; the old return cannot complete it.
        rig.system.isActiveLimitCleared = false
        status = await rig.read(calibrationReading(17), .powerSourceChanged)
        #expect(status.calibration.session?.step == .finalCharge)
        #expect(!status.calibration.isReturning)
        #expect(status.events.contains { $0.message.contains("Now confirmed: a macOS Charge Limit of 80%") })
        #expect(rig.system.runInputs.last == "100")
        #expect(!status.calibration.isFullLimitConfirmed, "a no-limit read-back is confirmed only once power has settled")
        #expect(status.calibration.last == nil)

        rig.clock.advance(by: 61)
        status = await rig.read(calibrationReading(25))
        #expect(status.calibration.isFullLimitConfirmed)
        rig.clock.advance(by: 2 * hour)
        status = await rig.read(calibrationReading(100, charging: false, full: true))
        let report = try #require(status.calibration.last)
        #expect(report.end == .completed)
        #expect(report.stepsDone == [.chargeToFull, .restAtTop, .drain, .restAtBottom, .plugIn, .finalCharge], "the early unplug skips step 3")
        #expect(report.shortRests == [.restAtTop])
        #expect(rig.system.reading == .limit(80))
    }

    @Test("A calibration that ends on an unplug in step 7, before its 100% is confirmed, asks for the return at once")
    func finalChargeUnpluggedBeforeConfirmed() async throws {
        let rig = CalibrationRig.settling()
        _ = await rig.startedSettled()
        rig.clock.advance(by: hour)
        _ = await rig.read(calibrationReading(100, charging: false, full: true))
        rig.clock.advance(by: 2 * hour)
        _ = await rig.read(calibrationReading(100, charging: false, full: true))
        rig.clock.advance(by: 600)
        _ = await rig.read(calibrationReading(99, .battery), .powerSourceChanged)
        rig.clock.advance(by: 4 * hour)
        _ = await rig.read(calibrationReading(20, .battery))
        _ = await rig.read(calibrationReading(18, .battery), .willSleep)
        rig.clock.advance(by: 5.1 * hour)
        var status = await rig.read(calibrationReading(17, .battery), .didWake)
        #expect(status.calibration.session?.step == .plugIn)

        // Plugged in: step 7 writes 100%, which a no-limit read-back inside
        // the settle window cannot confirm yet.
        status = await rig.read(calibrationReading(17), .powerSourceChanged)
        #expect(status.calibration.session?.step == .finalCharge)
        #expect(rig.system.runInputs.last == "100")
        #expect(rig.system.reading == .noLimit)
        #expect(status.nativeLimit?.pendingLimits == [100])
        #expect(!status.calibration.isFullLimitConfirmed)

        // Unplugged again before that: the session ends, and the return to
        // 80% is asked for at once, not skipped for the 80% last confirmed.
        rig.clock.advance(by: 61)
        status = await rig.read(calibrationReading(18, .battery), .powerSourceChanged)
        #expect(status.calibration.last?.end == .unplugged(.finalCharge))
        #expect(rig.system.runInputs.last == "80")
        #expect(rig.system.reading == .limit(80))
        #expect(status.currentMode == .nativeLimit(percent: 80))
        #expect(status.consecutiveFailures == 0)
    }

    @Test("Opened again on battery power after a quit in step 5: the check against the owner's own limit waits for power, and then passes or ends the session as before")
    func launchCheckWaitsForPower() async throws {
        for found in [90, 95] {
            let rig = CalibrationRig.settling()
            _ = await rig.startedSettled()
            rig.clock.advance(by: hour)
            _ = await rig.read(calibrationReading(100, charging: false, full: true))
            rig.clock.advance(by: 2 * hour)
            _ = await rig.read(calibrationReading(100, charging: false, full: true))
            rig.clock.advance(by: 600)
            _ = await rig.read(calibrationReading(99, .battery), .powerSourceChanged)
            rig.clock.advance(by: 4 * hour)
            var status = await rig.read(calibrationReading(20, .battery))
            #expect(status.calibration.session?.step == .restAtBottom)
            // Quitting gives back the owner's own 90% and deletes the record.
            await rig.controller.shutdown(reason: "quit")
            #expect(rig.system.reading == .limit(90))
            rig.system.changeExternally(to: found)
            rig.system.isActiveLimitCleared = true
            rig.clock.advance(by: hour)

            let second = rig.relaunched(reading: calibrationReading(18, .battery))
            status = await second.controller.evaluate(.launch)
            #expect(status.calibration.isPaused)
            #expect(status.calibration.last == nil, "nothing ended on a no-limit report")
            #expect(status.settings.isManagementEnabled)
            #expect(status.adoptionCount == 0)
            #expect(status.events.contains { $0.kind == .calibration && $0.message.contains("still your own 90% once your Mac has been on power for a minute") })
            second.clock.advance(by: 600)
            status = await second.read(calibrationReading(18, .battery))
            #expect(status.calibration.isPaused)
            #expect(NativeChargeLimitBackend.outstandingRecord(in: second.records) == nil, "nothing recorded meanwhile")

            // On power: inside the window nothing is judged; after it the
            // check runs as at a launch on power.
            second.system.isActiveLimitCleared = false
            status = await second.read(calibrationReading(18), .powerSourceChanged)
            #expect(status.calibration.session != nil)
            second.clock.advance(by: ChargeController.chargeLimitSettleTime)
            status = await second.read(calibrationReading(19))
            if found == 90 {
                #expect(status.calibration.session != nil)
                #expect(status.settings.isManagementEnabled)
                #expect(status.adoptionCount == 0)
            } else {
                #expect(status.calibration.last?.end == .unaccountedLimit(found: 95, expected: 90))
                #expect(!status.settings.isManagementEnabled)
                #expect(status.adoptedChange?.limit == 95)
            }
        }
    }

    @Test("Opened again on battery power with the owner's own limit still shown, the launch check passes at once")
    func launchCheckPassesOnShownLimit() async {
        let rig = CalibrationRig.settling()
        _ = await rig.startedSettled()
        rig.clock.advance(by: hour)
        _ = await rig.read(calibrationReading(100, charging: false, full: true))
        rig.clock.advance(by: 2 * hour)
        _ = await rig.read(calibrationReading(100, charging: false, full: true))
        rig.clock.advance(by: 600)
        _ = await rig.read(calibrationReading(99, .battery), .powerSourceChanged)
        rig.clock.advance(by: 600)
        await rig.controller.shutdown(reason: "quit")
        #expect(rig.system.reading == .limit(90))
        // Within 300 s of the unplug macOS still shows the owner's 90%.
        let second = rig.relaunched(reading: calibrationReading(95, .battery))
        let status = await second.controller.evaluate(.launch)
        #expect(status.calibration.isPaused)
        #expect(status.calibration.session?.step == .drain)
        #expect(!status.events.contains { $0.message.contains("is still your own 90%") }, "nothing left to check")
        #expect(status.settings.isManagementEnabled)
        #expect(status.adoptionCount == 0)
    }

    @Test("A limit that could not be read at launch is not kept from a no-limit report on battery power; on power it is judged as before")
    func retainedEvidenceWaitsForPower() async throws {
        let rig = CalibrationRig()
        _ = await rig.started()
        await rig.controller.shutdown(reason: "quit")
        rig.system.readFails = true
        let second = rig.relaunched(reading: calibrationReading(85))
        var status = await second.controller.evaluate(.launch)
        #expect(status.calibration.last?.end == .unaccountedLimit(found: nil, expected: 90))
        #expect(status.calibration.isEvidenceRetained)

        second.system.readFails = false
        second.system.isActiveLimitCleared = true
        second.clock.advance(by: 600)
        status = await second.read(calibrationReading(80, .battery), .powerSourceChanged)
        #expect(status.calibration.isEvidenceRetained, "kept until a read that can be judged")
        #expect(NativeChargeLimitBackend.pendingAdoption(in: second.records) == nil, "no limit is not kept as the owner's")

        second.system.isActiveLimitCleared = false
        status = await second.read(calibrationReading(80), .powerSourceChanged)
        #expect(!status.calibration.isEvidenceRetained, "the owner's own 90%, shown")
        #expect(NativeChargeLimitBackend.pendingAdoption(in: second.records) == nil)
    }

    @Test("A calibration does not start until macOS's Charge Limit has been read once power settled")
    func admissionWaitsForSettle() async throws {
        let rig = CalibrationRig.settling(system: FakeChargeLimitSystem(reading: .noLimit))
        await rig.controller.confirmNoLimitIsOwnerLimit()
        var status = await rig.controller.evaluate(.launch)
        #expect(status.nativeLimit?.readDeferral == .settling)
        status = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.session == nil)
        #expect(status.calibration.refusal == "CellKeeper checks macOS's Charge Limit once your Mac has been on power for a minute. Try again then.")
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        _ = await rig.read(calibrationReading(70))
        rig.clock.advance(by: 120)
        status = await rig.controller.startCalibration(allConfirmed, isNotifying: true)
        #expect(status.calibration.refusal == nil)
        #expect(status.calibration.session?.ownerLimit == 100)
    }

    @Test("An end that keeps an outside change says that nothing more is asked of macOS, not that read-backs follow")
    func endLineWhenNothingFollows() async {
        let rig = CalibrationRig()
        _ = await rig.started()
        rig.system.changeExternally(to: 85)
        let status = await rig.read(calibrationReading(80))
        #expect(status.calibration.last?.end == .outsideChange)
        let line = status.events.last { $0.kind == .calibration && $0.message.hasPrefix("Calibration ended") }?.message ?? ""
        #expect(line.contains("Manage charging is off, so CellKeeper asks macOS for nothing and leaves its Charge Limit as it is."))
        #expect(!line.contains("the lines that follow"))
    }
}
