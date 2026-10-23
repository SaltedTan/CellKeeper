import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

extension PowerRig {
    /// The audit's interleaving (D118): the read after `reads` more reads
    /// is suspended (an evaluation started at a will-sleep notification, or
    /// frozen in a dark wake). Meanwhile `interval` passes, asleep or awake,
    /// the power source becomes `power`, and macOS clears its active limit,
    /// as about 300 s after an unplug (note 08, O20). Then the read returns.
    func suspendRead(after reads: Int = 0, asleep: Bool = true, for interval: TimeInterval = 601, power: PowerSource = .battery) {
        let clock = clock, telemetry = telemetry, system = system
        system.beforeRead(after: reads) {
            if asleep {
                clock.advanceAsleep(by: interval)
            } else {
                clock.advance(by: interval)
            }
            await telemetry.set(snapshot(percent: 74, source: power))
            system.isActiveLimitCleared = true
        }
    }
}

/// True if the activity log says a read was not judged because the Mac
/// slept during it.
private func saysSlept(_ status: ControllerStatus) -> Bool {
    status.events.contains { $0.kind == .telemetry && $0.message.hasPrefix("Your Mac slept while CellKeeper was reading macOS's Charge Limit, so it did not judge that read.") }
}

/// True if the activity log says a read was not judged because it returned
/// too long after the reading its evidence began at.
private func saysTooLate(_ status: ControllerStatus) -> Bool {
    status.events.contains { $0.kind == .telemetry && $0.message.hasPrefix("CellKeeper's read of macOS's Charge Limit returned more than 2 minutes after it last read the power source, so it did not judge that read") }
}

/// True if the activity log says any read was not judged after its gate
/// failed.
private func saysNotJudged(_ status: ControllerStatus) -> Bool {
    status.events.contains { $0.kind == .telemetry && $0.message.contains("did not judge that read") }
}

/// The record of the owner's own limit stands, and nothing replaced it.
private func expectRecordStands(_ rig: PowerRig, owner: Int = 80, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store)?.ownerLimit == owner, sourceLocation: sourceLocation)
    #expect(NativeChargeLimitBackend.pendingAdoption(in: rig.store) == nil, sourceLocation: sourceLocation)
}

/// A report of macOS's Charge Limit is judged only by power evidence that
/// brackets the read: settled when it starts and when it returns, with no
/// sleep and no change of power source in between (D118, from the audit of
/// the native backend, 2026-10-23).
@Suite("macOS's Charge Limit is judged only by power evidence that brackets the read")
struct NativeLimitReadBracketTests {
    // MARK: - The audit's scenario

    @Test("A read suspended while the Mac sleeps and is unplugged, returning after macOS cleared its limit, is not judged: nothing is adopted, Manage charging stays on, and on power the owner's 80% is confirmed with nothing written")
    func suspendedAcrossSleepAndUnplug() async {
        let rig = PowerRig(limit: 80)
        await rig.settledOnPower()
        #expect(rig.system.runInputs.isEmpty, "the owner's 80% is also CellKeeper's")

        rig.suspendRead()
        var status = await rig.controller.evaluate(.periodic)
        #expect(rig.system.isActiveLimitCleared, "the read suspended was this evaluation's")
        #expect(status.adoptionCount == 0)
        #expect(status.adoptedChange == nil)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .onBattery, "reported as not judged")
        #expect(status.nativeLimit?.reportedLimit == 100, "what macOS showed")
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(status.currentMode == .nativeLimit(percent: 80))
        #expect(status.consecutiveFailures == 0)
        #expect(!saysChangedOutside(status))
        #expect(saysSlept(status))
        expectRecordStands(rig)

        // The wake, queued behind that evaluation, on battery power.
        status = await rig.read(.battery, 73, .didWake)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.readDeferral == .onBattery)

        // Plugged in: macOS shows its 80% at once, and once power has
        // settled a judged read confirms it.
        rig.system.isActiveLimitCleared = false
        _ = await rig.read(.externalPower, 73, .powerSourceChanged)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 74)
        #expect(status.nativeLimit?.readDeferral == nil)
        #expect(status.isNativeLimitSettled)
        #expect(status.currentMode == .nativeLimit(percent: 80))
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(rig.system.runInputs.isEmpty, "nothing written")
        expectRecordStands(rig)
    }

    // MARK: - Each part of the bracket

    @Test("A sleep during a read, on power throughout, keeps that read from being judged, and the settle time starts again: a change outside CellKeeper is judged only a minute later")
    func sleepOnPowerThroughout() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // Woken on power before macOS created its limit again (unplugged and
        // plugged in while asleep).
        rig.suspendRead(for: hour, power: .externalPower)
        var status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(saysSlept(status))
        expectRecordStands(rig)

        // macOS shows its limit again, now one set outside CellKeeper (O15).
        // No wake notification has arrived.
        rig.system.isActiveLimitCleared = false
        rig.system.changeExternally(to: 90)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0, "the settle time started again")
        #expect(status.nativeLimit?.readDeferral == .settling)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime - 1)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0)
        rig.clock.advance(by: 1)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptedChange?.limit == 90, "judged once settled again")
        #expect(!status.settings.isManagementEnabled)
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("A sleep of a minute during a read, well within two minutes and on power throughout, still keeps it from being judged")
    func shortSleepOnPowerThroughout() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.suspendRead(for: 60, power: .externalPower)
        let status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(saysSlept(status))
        #expect(!saysTooLate(status))
        expectRecordStands(rig)
    }

    @Test("An unplug during a read, with no sleep, keeps it from being judged; plugged in again before the next check, the settle time has started again")
    func unplugDuringReadWithoutSleep() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // The audit's own interleaving: the time passes awake.
        rig.suspendRead(asleep: false)
        var status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .onBattery)
        #expect(!saysSlept(status))
        #expect(status.events.contains { $0.kind == .telemetry && $0.message.hasPrefix("Your Mac was on battery power when CellKeeper's read of macOS's Charge Limit returned") })
        expectRecordStands(rig)

        // Plugged in again at once, before macOS shows its limit.
        status = await rig.read(.externalPower, 74)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.readDeferral == .settling)
        rig.system.isActiveLimitCleared = false
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 75)
        #expect(status.isNativeLimitSettled)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("A power source that cannot be read after a read keeps it from being judged")
    func powerUnknownAfterRead() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        let telemetry = rig.telemetry, system = rig.system
        system.beforeRead {
            await telemetry.fail(with: TelemetryTestError())
            system.isActiveLimitCleared = true
        }
        let status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .powerUnknown)
        #expect(status.events.contains { $0.kind == .telemetry && $0.message.hasPrefix("CellKeeper could not tell whether your Mac was still on power") })
        expectRecordStands(rig)
    }

    @Test("Once a read was not judged, no later read in that evaluation is, even with power back")
    func laterReadsInTheOperationStayUnjudged() async throws {
        let rig = PowerRig(limit: 80)
        await rig.settledOnPower()
        let clock = rig.clock, telemetry = rig.telemetry, system = rig.system
        // The mode's read returns on battery power; before the request's own
        // read the Mac is plugged in again, and macOS shows no limit yet.
        system.beforeRead {
            clock.advance(by: 601)
            await telemetry.set(snapshot(percent: 74, source: .battery))
            system.isActiveLimitCleared = true
            system.beforeRead { await telemetry.set(snapshot(percent: 74)) }
        }
        let status = try await rig.controller.apply(settings: rig.settings(limit: 85))
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(rig.system.runInputs.isEmpty)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        expectRecordStands(rig)
    }

    @Test("The clocks count a sleep before an evaluation as a wake, even before the wake's notification arrives")
    func sleepBeforeEvaluationRestartsSettle() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.clock.advanceAsleep(by: hour)
        // Woken on power before macOS created its limit again; a periodic
        // check runs before the wake is announced.
        rig.system.isActiveLimitCleared = true
        var status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .settling)
        status = await rig.read(.externalPower, 75, .didWake)
        #expect(status.adoptionCount == 0)
        rig.system.isActiveLimitCleared = false
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 75)
        #expect(status.isNativeLimitSettled)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(rig.system.runInputs == ["85"])
    }

    // MARK: - How long the evidence lasts

    @Test("An unplug and a plug-in while awake, both while a read waits to run, keep it from being judged although both ends show power: the limit macOS cleared is not adopted, Manage charging stays on, the settle time starts again, and a minute later reads are judged")
    func awakeUnplugAndPlugInDuringRead() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        let clock = rig.clock, telemetry = rig.telemetry, system = rig.system
        // Review r1 of #113: the operation waits before the read runs;
        // meanwhile the Mac is unplugged for 601 s, awake, and macOS clears
        // its limit; it is plugged in again just before the read, before
        // macOS creates the limit again (note 08, O20).
        system.beforeRead {
            await telemetry.set(snapshot(percent: 74, source: .battery))
            clock.advance(by: 601)
            system.isActiveLimitCleared = true
            await telemetry.set(snapshot(percent: 74, source: .externalPower))
        }
        var status = await rig.controller.evaluate(.periodic)
        #expect(rig.system.isActiveLimitCleared, "the read suspended was this evaluation's")
        #expect(status.adoptionCount == 0)
        #expect(status.adoptedChange == nil)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(status.consecutiveFailures == 0)
        #expect(!saysChangedOutside(status))
        #expect(!saysSlept(status))
        #expect(saysTooLate(status))
        expectRecordStands(rig)

        // macOS shows its limit again, now one set outside CellKeeper (O15).
        rig.system.isActiveLimitCleared = false
        rig.system.changeExternally(to: 90)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0, "the settle time started again")
        #expect(status.nativeLimit?.readDeferral == .settling)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptedChange?.limit == 90, "judged a minute later")
        #expect(!status.settings.isManagementEnabled)
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("A read that returns exactly two minutes after the clocks its evidence begins at is judged")
    func bracketAtTheBound() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        let clock = rig.clock, system = rig.system
        system.beforeRead {
            clock.advance(by: ChargeLimitReadGate.maximumSpan)
            system.changeExternally(to: 90)
        }
        let status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptedChange?.limit == 90)
        #expect(!status.settings.isManagementEnabled)
        #expect(!saysNotJudged(status))
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("A read that returns half a second more than two minutes after the clocks its evidence begins at is not judged, on power throughout, and the settle time starts again")
    func bracketJustOverTheBound() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        let clock = rig.clock, system = rig.system
        system.beforeRead {
            clock.advance(by: ChargeLimitReadGate.maximumSpan + 0.5)
            system.changeExternally(to: 90)
        }
        var status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(saysTooLate(status))
        expectRecordStands(rig)

        status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0, "the settle time started again")
        #expect(status.nativeLimit?.readDeferral == .settling)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime - 1)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0)
        rig.clock.advance(by: 1)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptedChange?.limit == 90, "judged once settled again")
    }

    @Test("Readings more than two minutes apart start the settle time again, as a wake does: a change made outside CellKeeper is judged only a minute later")
    func gapJustOverTheBound() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // No check for a while, awake (App Nap can defer one): an unplug
        // long enough for macOS to clear its limit could have fitted unseen.
        rig.clock.advance(by: ChargeLimitReadGate.maximumSpan + 0.5)
        rig.system.changeExternally(to: 90)
        var status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(!saysNotJudged(status), "found before the read, not after it")
        expectRecordStands(rig)

        rig.clock.advance(by: ChargeController.chargeLimitSettleTime - 1)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0)
        rig.clock.advance(by: 1)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptedChange?.limit == 90, "judged once settled again")
    }

    @Test("Readings exactly two minutes apart keep the settle time: a change made outside CellKeeper is judged at once")
    func gapAtTheBound() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.clock.advance(by: ChargeLimitReadGate.maximumSpan)
        rig.system.changeExternally(to: 90)
        let status = await rig.read(.externalPower, 75)
        #expect(status.adoptedChange?.limit == 90)
        #expect(!status.settings.isManagementEnabled)
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("A short unplug during a read, with no sleep and no long gap, still starts the settle time again: plugged in again before the next check, that check does not judge")
    func shortUnplugDuringRead() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.suspendRead(asleep: false, for: 30)
        var status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.readDeferral == .onBattery)
        #expect(!saysTooLate(status))
        expectRecordStands(rig)

        rig.clock.advance(by: 30)
        status = await rig.read(.externalPower, 74, .powerSourceChanged)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.readDeferral == .settling, "power began at this reading")
        expectRecordStands(rig)
    }

    // MARK: - Reads that fail

    @Test("A read that fails across a sleep and an unplug is asked about too: a calibration's launch check waits instead of taking the unreadable limit for the owner's change, and Manage charging stays on")
    func failedReadAcrossSleepAtPendingCalibrationCheck() async {
        let rig = CalibrationRig.settling()
        _ = await rig.startedSettled()
        _ = await rig.controller.shutdown(reason: "quit")
        rig.system.isActiveLimitCleared = true
        let second = rig.relaunched(reading: calibrationReading(85))
        let initial = await second.controller.evaluate(.launch)
        #expect(initial.calibration.session != nil)
        #expect(initial.settings.isManagementEnabled)
        second.clock.advance(by: ChargeController.chargeLimitSettleTime)
        let clock = second.clock, telemetry = second.telemetry, system = second.system
        system.beforeRead {
            clock.advanceAsleep(by: 601)
            await telemetry.set(calibrationReading(80, .battery))
            system.readFails = true
        }
        let status = await second.controller.evaluate(.periodic)
        #expect(second.system.reads > 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.calibration.last?.end != .unaccountedLimit(found: nil, expected: 90))
        #expect(status.calibration.last?.end == .controlUnavailable, "as when the read fails on battery power")
        #expect(status.adoptionCount == 0)
        #expect(saysSlept(status))
    }

    @Test("Control: a launch check still pending, whose read fails on battery power, does not turn Manage charging off")
    func unreadableStartupKnownOnBattery() async {
        let rig = CalibrationRig.settling()
        _ = await rig.startedSettled()
        _ = await rig.controller.shutdown(reason: "quit")
        rig.system.isActiveLimitCleared = true
        let second = rig.relaunched(reading: calibrationReading(85))
        _ = await second.controller.evaluate(.launch)
        second.clock.advance(by: ChargeController.chargeLimitSettleTime)
        await second.telemetry.set(calibrationReading(80, .battery))
        second.system.readFails = true
        let status = await second.controller.evaluate(.periodic)
        #expect(status.settings.isManagementEnabled)
        #expect(status.calibration.last?.end == .controlUnavailable)
        #expect(status.adoptionCount == 0)
    }

    @Test("A launch check still pending, whose read fails on settled power with nothing amiss, ends the session as before: the limit could not be read, so it is not accounted for")
    func unreadableStartupOnSettledPower() async {
        let rig = CalibrationRig.settling()
        _ = await rig.startedSettled()
        _ = await rig.controller.shutdown(reason: "quit")
        rig.system.isActiveLimitCleared = true
        let second = rig.relaunched(reading: calibrationReading(85))
        _ = await second.controller.evaluate(.launch)
        second.clock.advance(by: ChargeController.chargeLimitSettleTime)
        second.system.readFails = true
        let status = await second.controller.evaluate(.periodic)
        #expect(status.calibration.last?.end == .unaccountedLimit(found: nil, expected: 90))
        #expect(!status.settings.isManagementEnabled)
        #expect(!saysNotJudged(status))
    }

    @Test("A read that fails on settled power, with nothing amiss, is handled as before: the problem is shown and counted, no read is reported as not judged, and the next check judges at once")
    func failedReadOnSettledPower() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        let probes = await rig.telemetry.powerSourceReads
        rig.system.readFails = true
        var status = await rig.read(.externalPower, 75)
        #expect(status.nativeLimit?.readProblem == "read failed")
        // The mode's read, then the fail-safe restore's, as before D118.
        #expect(status.consecutiveFailures == 2)
        #expect(status.events.contains { $0.message.hasPrefix("Could not read the backend's mode: Operation failed: Could not read macOS's Charge Limit: read failed") })
        #expect(status.settings.isManagementEnabled)
        #expect(status.adoptionCount == 0)
        #expect(!saysNotJudged(status))
        let probesAfter = await rig.telemetry.powerSourceReads
        #expect(probesAfter > probes, "asked about after the failed reads too")
        expectRecordStands(rig)

        rig.system.readFails = false
        rig.system.changeExternally(to: 90)
        status = await rig.read(.externalPower, 75)
        #expect(status.nativeLimit?.readProblem == nil)
        #expect(status.adoptedChange?.limit == 90, "judged at once: the settle time did not start again")
    }

    // MARK: - Every place a read is judged

    @Test("A read-back after a change, suspended across a sleep and an unplug, waits for its confirmation instead of adopting what it shows; on power it is confirmed")
    func readBackAcrossSleep() async throws {
        let rig = PowerRig(limit: 80)
        await rig.settledOnPower()
        // The mode's read, the request's read, then the read-back.
        rig.suspendRead(after: 2)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85))
        #expect(rig.system.runInputs == ["85"])
        #expect(status.lastExecution?.result == .deferred(written: true))
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.consecutiveFailures == 0)
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(status.nativeLimit?.pendingLimits == [85], "still counted as CellKeeper's")
        #expect(saysSlept(status), "noted in the same evaluation")
        #expect(!status.events.contains { $0.message.contains("safety fallback") })
        expectRecordStands(rig)

        rig.system.isActiveLimitCleared = false
        _ = await rig.read(.externalPower, 74, .powerSourceChanged)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 75)
        #expect(status.isNativeLimitSettled)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(status.nativeLimit?.pendingLimits == [])
        #expect(status.adoptionCount == 0)
        #expect(rig.system.runInputs == ["85"], "nothing written again")
    }

    @Test("Turning Manage charging off: a restore whose read is suspended across a sleep and an unplug waits, writing nothing; on power it restores the owner's limit")
    func restoreAcrossSleep() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // The mode's read, then the restore's.
        rig.suspendRead(after: 1)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(rig.system.runInputs == ["85"], "nothing written over it")
        #expect(status.adoptionCount == 0)
        #expect(status.adoptedChange == nil)
        #expect(status.nativeLimit?.ownerLimit == 80, "still owed")
        #expect(status.consecutiveFailures == 0)
        expectRecordStands(rig)

        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 74, .powerSourceChanged)
        #expect(rig.system.runInputs == ["85", "80"])
        #expect(rig.system.reading == .limit(80))
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
        #expect(status.adoptionCount == 0)
    }

    @Test("Quitting: a restore whose read is suspended across a sleep and an unplug writes nothing and leaves the record for the next launch")
    func quitAcrossSleep() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.suspendRead()
        let status = await rig.controller.shutdown(reason: "quit")
        #expect(status.adoptedChange == nil)
        #expect(status.adoptionCount == 0)
        #expect(rig.system.runInputs == ["85"])
        #expect(status.nativeLimit?.readDeferral == .onBattery)
        #expect(saysSlept(status), "noted before the controller stops")
        expectRecordStands(rig)
    }

    @Test("Quitting after a sleep, before any check since: the restore's own reading of the power source shows the sleep, so the settle time starts again and the restore's read is not judged")
    func quitAfterSleepBeforeAnyCheck() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // A short sleep, well within the time between readings.
        rig.clock.advanceAsleep(by: 30)
        rig.system.isActiveLimitCleared = true
        let status = await rig.controller.shutdown(reason: "quit")
        #expect(status.adoptedChange == nil)
        #expect(status.adoptionCount == 0)
        #expect(rig.system.runInputs == ["85"])
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(!saysNotJudged(status), "found before the read, not after it")
        expectRecordStands(rig)
    }

    @Test("Quitting 90 s after the last check, when its reading is too old to use: the restore reads the power source itself, so its read is judged, and a change made outside CellKeeper is kept at once")
    func quitTakesItsOwnReading() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.clock.advance(by: 90)
        rig.system.changeExternally(to: 90)
        let probes = await rig.telemetry.powerSourceReads
        let status = await rig.controller.shutdown(reason: "quit")
        #expect(status.adoptedChange?.limit == 90)
        #expect(!status.settings.isManagementEnabled)
        #expect(rig.system.runInputs == ["85"], "nothing written over it")
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
        let probesAfter = await rig.telemetry.powerSourceReads
        #expect(probesAfter == probes + 2, "the restore's own reading, and one after its read")
    }

    @Test("Quitting more than two minutes after the last check, after an unplug no check saw: the restore's own reading on power starts the settle time again, so the no limit macOS shows is not kept, nothing is written, and the record stays for the next launch")
    func quitLongAfterTheLastReading() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // Unplugged for 601 s with no check (App Nap can defer one), and
        // plugged in again just before quitting, before macOS creates its
        // limit again (note 08, O20).
        rig.clock.advance(by: 601)
        rig.system.isActiveLimitCleared = true
        let status = await rig.controller.shutdown(reason: "quit")
        #expect(status.adoptedChange == nil)
        #expect(status.adoptionCount == 0)
        #expect(rig.system.runInputs == ["85"])
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.events.contains { $0.message.contains("waits; nothing was changed") })
        expectRecordStands(rig)
    }

    @Test("Quitting more than two minutes after the last check, on power throughout with CellKeeper's limit active: the settle time starts again, but an active limit the record accounts for is evidence, so the owner's limit is restored and the record cleared (D116)")
    func quitAfterIdleACWithActiveOwnedLimit() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.clock.advance(by: 601)
        let status = await rig.controller.shutdown(reason: "quit")
        #expect(rig.system.runInputs == ["85", "80"])
        #expect(rig.system.reading == .limit(80))
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
        #expect(status.adoptionCount == 0)
    }

    // MARK: - Restores whose read fails

    @Test("Quitting: a restore whose read fails after a sleep or a long wait, while the owner changes the limit, writes nothing over it and leaves the record for the next launch", arguments: [true, false])
    func failedRestoreReadAcrossSleep(asleep: Bool) async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        let clock = rig.clock, telemetry = rig.telemetry, system = rig.system
        system.beforeRead {
            if asleep {
                clock.advanceAsleep(by: 601)
            } else {
                clock.advance(by: 601)
            }
            await telemetry.set(snapshot(percent: 74, source: .externalPower))
            system.changeExternally(to: 90)
            system.failNextReads(1)
        }
        let status = await rig.controller.shutdown(reason: "quit")
        #expect(asleep ? saysSlept(status) : saysTooLate(status))
        #expect(rig.system.runInputs == ["85"], "nothing written over the owner's 90%")
        #expect(rig.system.reading == .limit(90))
        #expect(status.nativeLimit?.readProblem == "read failed")
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.events.contains { $0.message.contains("waits; nothing was changed") })
        #expect(status.adoptionCount == 0)
        #expect(status.consecutiveFailures == 0)
        expectRecordStands(rig)
    }

    @Test("Turning Manage charging off on battery power: a restore whose read fails writes nothing and waits; on power it restores the owner's limit")
    func failedRestoreReadOnBattery() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.readFails = true
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(rig.system.runInputs == ["85"], "nothing written blind")
        #expect(status.nativeLimit?.readDeferral == .onBattery)
        #expect(status.nativeLimit?.ownerLimit == 80, "still owed")
        #expect(status.adoptionCount == 0)
        expectRecordStands(rig)

        rig.system.readFails = false
        status = await rig.read(.externalPower, 74, .powerSourceChanged)
        #expect(rig.system.runInputs == ["85", "80"])
        #expect(rig.system.reading == .limit(80))
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
    }

    @Test("Quitting on settled power, the restore's read failing with its evidence intact: the restore goes ahead without it, as before, and its read-back confirms it")
    func failedRestoreReadOnSettledPower() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        rig.system.failNextReads(1)
        let status = await rig.controller.shutdown(reason: "quit")
        #expect(rig.system.runInputs == ["85", "80"])
        #expect(rig.system.reading == .limit(80))
        #expect(!saysNotJudged(status))
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
        #expect(status.adoptionCount == 0)
    }

    @Test("Recovering a record left by an earlier session: its read suspended across a sleep and an unplug adopts nothing; on power the owner's limit is restored")
    func recoveryAcrossSleep() async {
        let store = InMemoryRecordStore()
        storeOwnershipRecord(owner: 80, target: 85, in: store)
        let rig = PowerRig(reading: .limit(85), limit: 85, store: store)
        // At launch power has not settled; the restore's shortcut fails, so
        // the recovery is still owed once it has.
        rig.system.scheduleRuns([.fails])
        var status = await rig.controller.evaluate(.launch)
        #expect(status.consecutiveFailures == 1)
        #expect(status.nativeLimit?.ownerLimit == 80)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        // The mode's read, then the restore's.
        rig.suspendRead(after: 1)
        status = await rig.controller.evaluate(.periodic)
        #expect(status.adoptionCount == 0)
        #expect(status.adoptedChange == nil)
        #expect(status.settings.isManagementEnabled)
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(rig.system.runInputs == ["80"], "only the failed run")
        expectRecordStands(rig)

        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 74, .powerSourceChanged)
        #expect(rig.system.runInputs == ["80", "80"])
        #expect(rig.system.reading == .limit(80))
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
        #expect(status.adoptionCount == 0)
    }

    @Test("Nothing is recorded as the owner's own, and no confirmation of no limit is asked for, from a read across a sleep")
    func firstRecordAcrossSleep() async {
        let rig = PowerRig(reading: .limit(80), limit: 85)
        var status = await rig.controller.evaluate(.launch)
        #expect(status.nativeLimit?.ownerLimit == nil, "not before power settled")
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        rig.suspendRead(for: hour, power: .externalPower)
        status = await rig.controller.evaluate(.periodic)
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(status.nativeLimit?.needsNoLimitConfirmation == false)
        #expect(status.capabilities.availability.acceptsRequests)
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(rig.system.runInputs.isEmpty)
        #expect(rig.store.data == nil)

        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 75)
        #expect(status.nativeLimit?.ownerLimit == nil, "the settle time started again")
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 75)
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(rig.system.runInputs == ["85"])
    }

    // MARK: - Calibration

    @Test("Step 3: a read suspended while the owner unplugs and the Mac sleeps adopts nothing and ends nothing; the drain then begins and asks for the normal limit")
    func stepThreeHoldAcrossSleep() async {
        let rig = CalibrationRig.settling(system: FakeChargeLimitSystem(reading: .limit(80)))
        _ = await rig.startedSettled()
        rig.clock.advance(by: hour)
        _ = await rig.read(calibrationReading(100, charging: false, full: true))
        rig.clock.advance(by: 2 * hour)
        var status = await rig.read(calibrationReading(100, charging: false, full: true))
        #expect(status.calibration.session?.step == .unplug)

        let clock = rig.clock, telemetry = rig.telemetry, system = rig.system
        system.beforeRead {
            clock.advanceAsleep(by: 1800)
            await telemetry.set(calibrationReading(96, .battery))
            system.isActiveLimitCleared = true
        }
        status = await rig.controller.evaluate(.periodic)
        #expect(rig.system.isActiveLimitCleared, "the read suspended was this evaluation's")
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.calibration.last == nil)
        #expect(!saysChangedOutside(status))
        #expect(rig.system.runInputs == ["100"])

        status = await rig.read(calibrationReading(96, .battery), .didWake)
        #expect(status.calibration.session?.step == .drain)
        #expect(status.calibration.session?.drainStartPercent == 96)
        #expect(rig.system.runInputs == ["100", "80"])
        #expect(status.adoptionCount == 0)
        #expect(status.calibration.last == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.records)?.ownerLimit == 80)
    }

    @Test("The evidence a calibration kept from a launch is not taken for the owner's change from a read across a sleep and an unplug")
    func retainedEvidenceAcrossSleep() async {
        let rig = CalibrationRig()
        _ = await rig.started()
        await rig.controller.shutdown(reason: "quit")
        rig.system.readFails = true
        let second = rig.relaunched(reading: calibrationReading(85))
        var status = await second.controller.evaluate(.launch)
        #expect(status.calibration.last?.end == .unaccountedLimit(found: nil, expected: 90))
        #expect(status.calibration.isEvidenceRetained)

        second.system.readFails = false
        let clock = second.clock, telemetry = second.telemetry, system = second.system
        system.beforeRead {
            clock.advanceAsleep(by: 900)
            await telemetry.set(calibrationReading(80, .battery))
            system.isActiveLimitCleared = true
        }
        status = await second.controller.evaluate(.periodic)
        #expect(second.system.isActiveLimitCleared, "the read suspended was this evaluation's")
        #expect(status.calibration.isEvidenceRetained, "kept until a read that can be judged")
        #expect(NativeChargeLimitBackend.pendingAdoption(in: second.records) == nil, "no limit is not kept as the owner's")
        #expect(!status.events.contains { $0.message.contains("is 100%, not your own 90%") })

        second.system.isActiveLimitCleared = false
        status = await second.read(calibrationReading(80), .powerSourceChanged)
        #expect(!status.calibration.isEvidenceRetained, "the owner's own 90%, shown")
        #expect(NativeChargeLimitBackend.pendingAdoption(in: second.records) == nil)
    }

    // MARK: - Unchanged

    @Test("On settled power a read is judged at once, with no read of macOS's limit added and one reading of the power source after it; a change outside CellKeeper is adopted in that check")
    func settledReadsStayJudged() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        let reads = rig.system.reads
        let probes = await rig.telemetry.powerSourceReads
        var status = await rig.read(.externalPower, 75)
        #expect(status.isNativeLimitSettled)
        #expect(rig.system.reads == reads + 1, "the mode's read only")
        let probesAfter = await rig.telemetry.powerSourceReads
        #expect(probesAfter == probes + 1)

        rig.system.changeExternally(to: 90)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptedChange?.limit == 90)
        #expect(!status.settings.isManagementEnabled)
        #expect(!saysSlept(status))
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("A read that is not judged anyway reads the power source no further")
    func unjudgedReadsReadNothingMore() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        let probes = await rig.telemetry.powerSourceReads
        _ = await rig.read(.battery, 74)
        let probesAfter = await rig.telemetry.powerSourceReads
        #expect(probesAfter == probes)
    }
}

/// What a gate on its own reads after a read, set by the test.
private final class GateInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var clocks = ChargeLimitReadGate.Clocks(uptime: 1_000, awake: 500)
    private var _power: PowerSource? = .externalPower
    private var _probes = 0

    var now: ChargeLimitReadGate.Clocks { lock.withLock { clocks } }
    var probes: Int { lock.withLock { _probes } }

    var power: PowerSource? {
        get { lock.withLock { _power } }
        set { lock.withLock { _power = newValue } }
    }

    /// `awake` seconds pass awake, then `asleep` seconds asleep.
    func pass(_ awake: TimeInterval, asleep: TimeInterval = 0) {
        lock.withLock {
            clocks.uptime += awake + asleep
            clocks.awake += awake
        }
    }

    func probe() -> PowerSource? {
        lock.withLock {
            _probes += 1
            return _power
        }
    }

    func gate(_ condition: ChargeLimitReadCondition = .settled, since: TimeInterval? = 900) -> ChargeLimitReadGate {
        ChargeLimitReadGate(
            condition: condition,
            clocks: now,
            externalPowerSince: since,
            settleTime: 60,
            powerSource: { self.probe() },
            readClocks: { self.now }
        )
    }
}

@Suite("Charge Limit read gate")
struct ChargeLimitReadGateTests {
    @Test("On power, settled, with no sleep: judged; half a second asleep is no sleep")
    func judged() async {
        let inputs = GateInputs()
        let gate = inputs.gate()
        inputs.pass(5, asleep: 0.5)
        #expect(await gate.conditionAfterRead() == .settled)
        #expect(gate.failure == nil)
        #expect(inputs.probes == 1)
    }

    @Test("A sleep of a second and a half: not judged, then or later")
    func sleep() async {
        let inputs = GateInputs()
        let gate = inputs.gate()
        inputs.pass(1, asleep: 1.5)
        #expect(await gate.conditionAfterRead() == .settling)
        #expect(gate.failure == ChargeLimitReadGate.Failure(condition: .settling, didSleep: true))
        inputs.pass(1)
        #expect(await gate.conditionAfterRead() == .settling)
    }

    @Test("The power source after the read decides, and the gate stays failed when power returns", arguments: [(PowerSource?.some(.battery), ChargeLimitReadCondition.onBattery), (.some(.unknown), .powerUnknown), (nil, .powerUnknown)])
    func powerAfter(power: PowerSource?, expected: ChargeLimitReadCondition) async {
        let inputs = GateInputs()
        let gate = inputs.gate()
        inputs.power = power
        #expect(await gate.conditionAfterRead() == expected)
        #expect(gate.failure == ChargeLimitReadGate.Failure(condition: expected, didSleep: false))
        inputs.power = .externalPower
        #expect(await gate.conditionAfterRead() == expected)
    }

    @Test("A read is judged up to exactly two minutes after the evidence was taken, and not after, whatever the power source shows")
    func span() async {
        let inputs = GateInputs()
        let gate = inputs.gate()
        inputs.pass(ChargeLimitReadGate.maximumSpan)
        #expect(await gate.conditionAfterRead() == .settled)
        #expect(gate.failure == nil)
        inputs.pass(0.5)
        #expect(await gate.conditionAfterRead() == .settling)
        #expect(gate.failure == ChargeLimitReadGate.Failure(condition: .settling, didSleep: false, isTooLate: true))

        let onBattery = inputs.gate()
        inputs.pass(ChargeLimitReadGate.maximumSpan + 0.5)
        inputs.power = .battery
        #expect(await onBattery.conditionAfterRead() == .onBattery)
        #expect(onBattery.failure == ChargeLimitReadGate.Failure(condition: .onBattery, didSleep: false, isTooLate: true))
    }

    @Test("The span counts time asleep and awake alike")
    func spanCountsSleep() {
        let earlier = ChargeLimitReadGate.Clocks(uptime: 1_000, awake: 500)
        #expect(!ChargeLimitReadGate.Clocks(uptime: 1_120, awake: 620).exceedsMaximumSpan(since: earlier))
        #expect(ChargeLimitReadGate.Clocks(uptime: 1_120.5, awake: 620.5).exceedsMaximumSpan(since: earlier))
        #expect(ChargeLimitReadGate.Clocks(uptime: 1_121, awake: 501).exceedsMaximumSpan(since: earlier))
        #expect(!ChargeLimitReadGate.Clocks(uptime: 1_100, awake: 501).exceedsMaximumSpan(since: earlier))
    }

    @Test("The settle time must still hold when the read returns")
    func settleTimeAtReturn() async {
        let inputs = GateInputs()
        let gate = inputs.gate(since: 970)
        #expect(await gate.conditionAfterRead() == .settling)
        #expect(gate.failure == ChargeLimitReadGate.Failure(condition: .settling, didSleep: false))
    }

    @Test("A gate not settled when made, or one without evidence, answers with its condition and reads nothing", arguments: [ChargeLimitReadCondition.onBattery, .settling, .powerUnknown])
    func notSettled(condition: ChargeLimitReadCondition) async {
        let inputs = GateInputs()
        let gate = inputs.gate(condition)
        inputs.pass(1, asleep: hour)
        #expect(await gate.conditionAfterRead() == condition)
        #expect(gate.failure == nil)
        #expect(inputs.probes == 0)
        #expect(await ChargeLimitReadGate.fixed(condition).conditionAfterRead() == condition)
        #expect(await ChargeLimitReadGate.fixed(.settled).conditionAfterRead() == .settled)
    }
}
