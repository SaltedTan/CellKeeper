import CellKeeperHelperCore
import Testing

@Suite("Helper engine: sleep and wake")
struct HelperSleepTests {
    @Test("Before sleep the adapter-disable is cleared and refused; a valid inhibit stays (R16)")
    func willSleep() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)

        await h.engine.systemWillSleep()
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(h.recorder.contains(.deactivated(.adapterDisabled, .interlock(.sleepImminent))))
        #expect(await session.readState().interlocks == .sleepImminent)
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await h.activate(.adapterDisabled, on: session) == .blockedByInterlock)

        await h.engine.systemDidWake()
        #expect(await session.readState().interlocks.isEmpty)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
    }

    @Test("An inhibit whose lease ran out during sleep is cleared at wake")
    func leaseLapsesDuringSleep() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)

        await h.engine.systemWillSleep()
        #expect(h.control.activeControls == [.chargingInhibited])
        // The monotonic clock counts sleep.
        h.clock.advance(by: 60 * 60)
        await h.engine.systemDidWake()
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.leaseEnded(session.id, .chargingInhibited, .expired)))
    }

    @Test("A sleep announcement without a wake ends after its window")
    func cancelledSleep() async {
        let h = Harness()
        let session = await h.startedSession()
        await h.engine.systemWillSleep()

        h.clock.advance(by: HelperEngine.sleepAnnouncementWindow - 1)
        await h.engine.tick()
        #expect(await session.readState().interlocks == .sleepImminent)

        h.clock.advance(by: 1)
        await h.engine.tick()
        #expect(await session.readState().interlocks.isEmpty)
    }

    @Test("After wake, a power state read before it is unavailable (R17)")
    func staleAfterWake() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        let beforeSleep = h.clock.uptime
        h.power.update { $0.readAtUptime = beforeSleep }

        await h.engine.systemWillSleep()
        h.clock.advance(by: 20)
        await h.engine.systemDidWake()
        #expect(h.control.activeControls.isEmpty)
        #expect(await session.readState().interlocks == .powerStateUnavailable)

        h.power.update { $0.readAtUptime = nil }
        await h.engine.tick()
        #expect(await session.readState().interlocks.isEmpty)
    }

    @Test("At wake the read-back is compared with what the engine set (R17, R27)")
    func wakeComparesReadBack() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)

        await h.engine.systemWillSleep()
        h.control.simulateOutsideChange(.chargingInhibited, active: false)
        await h.engine.systemDidWake()
        #expect(h.recorder.contains(.interlocksRaised(.externalModification)))
        #expect(h.recorder.contains(.restored(.externalModification)))
        #expect(await session.readState().interlocks == .externalModification)
    }
}

@Suite("Helper engine: outside changes")
struct HelperExternalModificationTests {
    @Test("An outside change restores defaults once and blocks activation until a client restores (R27)")
    func externalModification() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)

        h.control.simulateOutsideChange(.adapterDisabled, active: true)
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.restored(.externalModification)))
        var state = await session.readState()
        #expect(state.interlocks == .externalModification)
        // Leases are kept, but activation is refused.
        #expect(state.isLeaseHolder)
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await h.activate(.chargingInhibited, on: session) == .blockedByInterlock)

        // Ticks never clear it, and the engine does not fight the other tool.
        let writes = h.control.writeCount
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        await h.engine.tick()
        await h.engine.tick()
        #expect(h.control.writeCount == writes)
        state = await session.readState()
        #expect(state.active == [.chargingInhibited])
        #expect(state.interlocks == .externalModification)

        // A client's restore clears it once it reads back clean.
        #expect(await session.restoreDefaults() == .ok)
        #expect(h.control.writeCount == writes + 1)
        #expect(h.recorder.contains(.interlocksCleared(.externalModification)))
        #expect(await session.readState().interlocks.isEmpty)
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
    }

    @Test("A client restore that does not read back clean keeps the interlock")
    func failedRestoreKeepsInterlock() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.simulateOutsideChange(.chargingInhibited, active: false)
        await h.engine.tick()

        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        h.control.failNextRestores(1)
        #expect(await session.restoreDefaults() == .hardwareError)
        #expect(await session.readState().interlocks == [.externalModification, .hardwareFault])
        #expect(await session.restoreDefaults() == .ok)
        #expect(await session.readState().interlocks.isEmpty)
    }
}

@Suite("Helper engine: hardware failures")
struct HelperHardwareFailureTests {
    @Test("A failed activation restores defaults and reports the error")
    func failedApply() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.failNextApplies(1)

        #expect(await h.activate(.adapterDisabled, on: session) == .hardwareError)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.hardwareError(code: HelperHardwareError.simulatedFailure.code)))
        #expect(h.recorder.contains(.restored(.writeFailed)))
        let state = await session.readState()
        #expect(state.lastHardwareError == HelperHardwareError.simulatedFailure.code)
        // The restore read back clean, so the engine is not faulted.
        #expect(state.interlocks.isEmpty)
    }

    @Test("An activation that does not read back restores defaults")
    func readBackMismatch() async {
        let h = Harness()
        let session = await h.startedSession()
        h.control.ignoreNextApplies(1)

        #expect(await h.activate(.chargingInhibited, on: session) == .hardwareError)
        #expect(h.recorder.contains(.restored(.readBackMismatch)))
        let state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.lastHardwareError == HelperHardwareError.readBackMismatch.code)
    }

    @Test("A failed clear and a failed restore fault the engine; ticks retry until clean")
    func faultAndRetry() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.failNextApplies(1)
        h.control.failNextRestores(2)

        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: false) == .hardwareError)
        #expect(h.recorder.contains(.restoreFailed(.writeFailed)))
        var state = await session.readState()
        // Read-back state is reported, not the intended one.
        #expect(state.active == [.chargingInhibited])
        #expect(state.interlocks == .hardwareFault)
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await h.activate(.chargingInhibited, on: session) == .blockedByInterlock)

        let writes = h.control.writeCount
        await h.engine.tick()
        #expect(h.control.writeCount == writes + 1)
        #expect(h.recorder.contains(.restoreFailed(.faultRetry)))
        #expect(await session.readState().interlocks == .hardwareFault)

        await h.engine.tick()
        #expect(h.control.writeCount == writes + 2)
        state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.interlocks.isEmpty)
        #expect(h.recorder.contains(.restored(.faultRetry)))
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
    }

    @Test("A restore that does not read back clean faults the engine")
    func restoreNotConfirmed() async {
        let h = Harness(control: SimulatedChargeControl(initiallyActive: [.chargingInhibited]))
        h.control.ignoreNextRestores(1)

        #expect(await h.engine.start() == .hardwareError)
        #expect(h.recorder.contains(.restoreFailed(.start)))
        let session = await h.introducedSession()
        var state = await session.readState()
        #expect(state.active == [.chargingInhibited])
        #expect(state.interlocks == .hardwareFault)
        #expect(state.lastHardwareError == HelperHardwareError.restoreNotConfirmed.code)

        await h.engine.tick()
        state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.interlocks.isEmpty)
    }

    @Test("A state that cannot be read back is restored and then reported as unknown (R1)")
    func readBackFailure() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)

        h.control.failNextReadBacks(1)
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.restored(.readBackFailed)))

        h.control.failNextReadBacks(2)
        let state = await session.readState()
        #expect(state.status == .hardwareError)
        #expect(state.active.isEmpty)
        #expect(state.interlocks == .hardwareFault)

        await h.engine.tick()
        #expect(await session.readState() == HelperStateReply(
            status: .ok,
            activeControls: [],
            chargingInhibitedLeaseSeconds: 900,
            adapterDisabledLeaseSeconds: 0,
            isLeaseHolder: true,
            interlocks: [],
            lastHardwareError: HelperHardwareError.simulatedFailure.code
        ))
    }

    @Test("A failed clear at lease expiry falls back to a restore")
    func failedClearAtExpiry() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.failNextApplies(1)

        h.clock.advance(by: 900)
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(h.control.writes.suffix(2) == [.apply(.chargingInhibited, active: false), .restoreDefaults])
        #expect(h.recorder.contains(.restored(.writeFailed)))
        #expect(await session.readState().interlocks.isEmpty)
    }
}

@Suite("Helper engine: shutdown")
struct HelperShutdownTests {
    private func expectShutDown(_ h: Harness, _ session: HelperSession) async {
        #expect(await h.engine.isShuttingDown)
        let writes = h.control.writeCount
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .shuttingDown)
        #expect(await session.readState().status == .shuttingDown)
        #expect(await session.acquireOrRenewLease(control: 1, seconds: 60).status == .shuttingDown)
        #expect(await session.setControl(control: 1, active: true) == .shuttingDown)
        #expect(await session.setControl(control: 1, active: false) == .shuttingDown)
        #expect(await session.releaseLease(control: 1) == .shuttingDown)
        #expect(await session.restoreDefaults() == .shuttingDown)
        #expect(await session.restoreDefaultsAndExit() == .shuttingDown)
        #expect(await h.engine.terminate() == .shuttingDown)
        #expect(await h.engine.start() == .shuttingDown)
        await h.engine.tick()
        await h.engine.systemWillSleep()
        await h.engine.systemDidWake()
        await session.invalidate()
        #expect(h.control.writeCount == writes)
    }

    @Test("restoreDefaultsAndExit restores, then serves nothing more")
    func restoreAndExit() async {
        let h = Harness()
        let holder = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: holder) == .ok)
        #expect(await h.activate(.adapterDisabled, on: holder) == .ok)

        // Needs no hello: a newer app must be able to retire an older helper.
        let updater = await h.engine.openSession()
        #expect(await updater.restoreDefaultsAndExit() == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.leaseEnded(holder.id, .chargingInhibited, .shutdown)))
        #expect(h.recorder.contains(.shuttingDown(.exitRequested, restored: true)))
        await expectShutDown(h, holder)
    }

    @Test("terminate restores defaults and shuts down (R4)")
    func terminate() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)

        #expect(await h.engine.terminate() == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.shuttingDown(.terminate, restored: true)))
        await expectShutDown(h, session)
    }

    @Test("terminate restores even before start")
    func terminateBeforeStart() async {
        let h = Harness(control: SimulatedChargeControl(initiallyActive: [.chargingInhibited]))
        #expect(await h.engine.terminate() == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(await h.engine.isShuttingDown)
    }

    @Test("A restore that fails at exit is reported, and the engine still shuts down")
    func failedRestoreAtExit() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.failNextRestores(1)

        #expect(await h.engine.terminate() == .hardwareError)
        #expect(h.recorder.contains(.shuttingDown(.terminate, restored: false)))
        #expect(await h.engine.isShuttingDown)
    }
}
