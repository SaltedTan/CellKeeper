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

    @Test("A power state stamped at the wake time itself does not count as read after the wake")
    func equalTimestampAtWake() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.clock.freeze()
        let cachedAt = h.clock.uptime
        h.power.update { $0.readAtUptime = cachedAt }

        await h.engine.systemWillSleep()
        #expect(h.control.activeControls == [.chargingInhibited])
        // Sleep and wake while the clock still reads the cached sample's time.
        await h.engine.systemDidWake()
        #expect(h.control.activeControls.isEmpty)
        #expect(await session.readState().interlocks == .powerStateUnavailable)
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
        // Nothing of the engine's is set, so ticks do not retry: that would
        // fight the other tool. Only a client's restore does.
        let writes = h.control.writeCount
        await h.engine.tick()
        await h.engine.tick()
        #expect(h.control.writeCount == writes)
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await session.restoreDefaults() == .ok)
        #expect(await session.readState().interlocks.isEmpty)
    }
}

@Suite("Helper engine: hardware failures")
struct HelperHardwareFailureTests {
    private let simulatedFailure = HelperHardwareError.simulatedFailure.code

    @Test("A failed activation restores defaults and refuses activations until a client restores (R11)")
    func failedApply() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.failNextApplies(1)

        #expect(await h.activate(.adapterDisabled, on: session) == .hardwareError)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.hardwareError(code: simulatedFailure)))
        #expect(h.recorder.contains(.restored(.writeFailed)))
        #expect(h.recorder.writes.suffix(2) == [
            HelperWriteRecord(target: .control(.adapterDisabled, active: true), outcome: .threw(code: simulatedFailure), readBack: nil),
            HelperWriteRecord(target: .restoreDefaults, outcome: .confirmed, readBack: []),
        ])
        let state = await session.readState()
        #expect(state.lastHardwareError == simulatedFailure)
        // No restore is owed, but the control is no longer trusted.
        #expect(state.interlocks == .writeFailed)
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await h.activate(.chargingInhibited, on: session) == .blockedByInterlock)
        #expect(await h.activate(.adapterDisabled, on: session) == .blockedByInterlock)

        // A client's restore is the deliberate acknowledgement.
        #expect(await session.restoreDefaults() == .ok)
        #expect(h.recorder.contains(.interlocksCleared(.writeFailed)))
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
    }

    @Test("A failed write refuses activations for an hour after it, then lifts on its own")
    func writeFailureBackoff() async {
        let h = Harness()
        let session = await h.startedSession()
        h.control.failNextApplies(1)
        #expect(await h.activate(.chargingInhibited, on: session) == .hardwareError)

        h.clock.advance(by: HelperEngine.writeFailureBackoff - 1)
        await h.engine.tick()
        #expect(await session.readState().interlocks == .writeFailed)
        h.clock.advance(by: 1)
        await h.engine.tick()
        #expect(await session.readState().interlocks.isEmpty)
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
    }

    @Test("An activation that does not read back restores defaults")
    func readBackMismatch() async {
        let h = Harness()
        let session = await h.startedSession()
        h.control.ignoreNextApplies(1)

        #expect(await h.activate(.chargingInhibited, on: session) == .hardwareError)
        #expect(h.recorder.contains(.restored(.readBackMismatch)))
        #expect(h.recorder.writes.contains(
            HelperWriteRecord(target: .control(.chargingInhibited, active: true), outcome: .readBackMismatch, readBack: [])
        ))
        let state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.interlocks == .writeFailed)
        #expect(state.lastHardwareError == HelperHardwareError.readBackMismatch.code)
    }

    @Test("A failed clear and a failed restore: ticks retry the restore until clean; the write failure stays")
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
        #expect(state.interlocks == [.hardwareFault, .writeFailed])
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await h.activate(.chargingInhibited, on: session) == .blockedByInterlock)

        let writes = h.control.writeCount
        await h.engine.tick()
        #expect(h.control.writeCount == writes + 1)
        #expect(h.recorder.contains(.restoreFailed(.faultRetry)))
        #expect(await session.readState().interlocks == [.hardwareFault, .writeFailed])

        await h.engine.tick()
        #expect(h.control.writeCount == writes + 2)
        state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.interlocks == .writeFailed)
        #expect(h.recorder.contains(.restored(.faultRetry)))
        #expect(await h.activate(.chargingInhibited, on: session) == .blockedByInterlock)
        #expect(await session.restoreDefaults() == .ok)
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
    }

    @Test("While a restore is owed, a deactivation retries it and reports success only once the control reads back inactive")
    func deactivationWhileRestoreOwed() async {
        let h = Harness()
        let session = await h.startedSession()
        let inhibit = HelperControl.chargingInhibited.rawValue
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.failNextApplies(1)
        h.control.failNextRestores(2)
        #expect(await session.setControl(control: inhibit, active: false) == .hardwareError)

        let writes = h.control.writeCount
        #expect(await session.setControl(control: inhibit, active: false) == .hardwareError)
        #expect(h.control.writeCount == writes + 1)
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await session.setControl(control: inhibit, active: false) == .ok)
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("A restore that does not read back clean means a restore is owed")
    func restoreNotConfirmed() async {
        let h = Harness(control: SimulatedChargeControl(initiallyActive: [.chargingInhibited]))
        h.control.ignoreNextRestores(1)

        #expect(await h.engine.start() == .hardwareError)
        #expect(h.recorder.contains(.restoreFailed(.start)))
        #expect(h.recorder.writes == [
            HelperWriteRecord(target: .restoreDefaults, outcome: .readBackMismatch, readBack: [.chargingInhibited]),
        ])
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
        #expect(h.recorder.writes.last == HelperWriteRecord(
            target: .restoreDefaults, outcome: .readBackFailed(code: simulatedFailure), readBack: nil
        ))

        await h.engine.tick()
        #expect(await session.readState() == HelperStateReply(
            status: .ok,
            activeControls: [],
            chargingInhibitedLeaseSeconds: 900,
            adapterDisabledLeaseSeconds: 0,
            isLeaseHolder: true,
            interlocks: [],
            lastHardwareError: simulatedFailure
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
        #expect(await session.readState().interlocks == .writeFailed)
    }
}

@Suite("Helper engine: shutdown")
struct HelperShutdownTests {
    private func expectShutDown(_ h: Harness, _ session: HelperSession) async {
        #expect(await h.engine.isShuttingDown)
        #expect(await h.engine.isSafeToExit)
        let writes = h.control.writeCount
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .shuttingDown)
        #expect(await session.readState().status == .shuttingDown)
        #expect(await session.acquireOrRenewLease(control: 1, seconds: 60).status == .shuttingDown)
        #expect(await session.setControl(control: 1, active: true) == .shuttingDown)
        #expect(await session.setControl(control: 1, active: false) == .shuttingDown)
        #expect(await session.releaseLease(control: 1) == .shuttingDown)
        // Restores are still served; with defaults confirmed they write nothing.
        #expect(await session.restoreDefaults() == .ok)
        #expect(await session.restoreDefaultsAndExit() == .ok)
        #expect(await h.engine.terminate() == .ok)
        #expect(await h.engine.start() == .shuttingDown)
        await h.engine.tick()
        await h.engine.systemWillSleep()
        await h.engine.systemDidWake()
        await session.invalidate()
        #expect(h.control.writeCount == writes)
    }

    @Test("restoreDefaultsAndExit restores, then serves only restores")
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
        #expect(h.recorder.events.suffix(2) == [.shuttingDown(.exitRequested, restored: true), .safeToExit])
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
        #expect(await h.engine.isSafeToExit)
    }

    @Test("After a failed shutdown restore, ticks retry it until it is safe to exit", arguments: [false, true])
    func recoveryAfterFailedShutdownRestore(requestedByClient: Bool) async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        h.control.failNextRestores(2)

        if requestedByClient {
            #expect(await session.restoreDefaultsAndExit() == .hardwareError)
        } else {
            #expect(await h.engine.terminate() == .hardwareError)
        }
        #expect(await h.engine.isShuttingDown)
        #expect(await h.engine.isSafeToExit == false)
        #expect(h.recorder.contains(.shuttingDown(requestedByClient ? .exitRequested : .terminate, restored: false)))
        #expect(h.control.activeControls == [.adapterDisabled])
        // Only restores are served.
        #expect(await session.acquireOrRenewLease(control: 2, seconds: 60).status == .shuttingDown)
        #expect(await session.setControl(control: 2, active: true) == .shuttingDown)

        await h.engine.tick()
        #expect(h.control.activeControls == [.adapterDisabled])
        #expect(await h.engine.isSafeToExit == false)
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(await h.engine.isSafeToExit)
        #expect(h.recorder.events.last == .safeToExit)
        #expect(await h.engine.terminate() == .ok)
    }

    @Test("During shutdown, terminate and a client's restore both retry the owed restore")
    func retriesDuringShutdown() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.failNextRestores(2)

        #expect(await h.engine.terminate() == .hardwareError)
        #expect(await h.engine.terminate() == .hardwareError)
        #expect(await session.restoreDefaults() == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(await h.engine.isSafeToExit)
    }
}
