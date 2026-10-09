import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper engine: combined failures")
struct HelperCombinedFailureTests {
    enum FollowUp: String, CaseIterable, Sendable {
        case tick, expiry, invalidation, floor, sleep
    }

    @Test("A restore that fails after an outside change is retried until the engine's own control is cleared", arguments: FollowUp.allCases)
    func failedRestoreAfterOutsideChange(followUp: FollowUp) async {
        let h = Harness()
        let holder = await h.startedSession()
        let observer = await h.introducedSession()
        #expect(await h.activate(.adapterDisabled, on: holder) == .ok)
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        h.control.failNextRestores(1)

        await h.engine.tick()
        #expect(h.control.activeControls == [.chargingInhibited, .adapterDisabled])
        #expect(await observer.readState().interlocks == [.externalModification, .hardwareFault])

        switch followUp {
        case .tick:
            await h.engine.tick()
        case .expiry:
            h.clock.advance(by: TimeInterval(HelperControl.adapterDisabled.maximumLeaseSeconds))
            await h.engine.tick()
        case .invalidation:
            // Retried at once, without waiting for a tick.
            await holder.invalidate()
        case .floor:
            h.power.update { $0.stateOfCharge = 0 }
            await h.engine.tick()
        case .sleep:
            await h.engine.systemWillSleep()
        }
        #expect(h.control.activeControls.isEmpty)
        #expect(await observer.readState().interlocks.contains(.hardwareFault) == false)

        // Only now does the quiet state begin: another outside change is
        // reported but not fought.
        let writes = h.control.writeCount
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        await h.engine.tick()
        #expect(h.control.writeCount == writes)
        let state = await observer.readState()
        #expect(state.active == [.chargingInhibited])
        #expect(state.interlocks.contains(.externalModification))
    }

    @Test("An owed restore is retried once per tick or system event, never by requests, and refuses activation meanwhile")
    func boundedRetries() async {
        let h = Harness()
        let holder = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: holder) == .ok)
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        h.control.failNextRestores(3)
        let writes = h.control.writeCount

        await h.engine.tick()
        #expect(h.control.writeCount == writes + 1)
        for _ in 0..<3 {
            _ = await holder.readState()
        }
        _ = await holder.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 60)
        #expect(await holder.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .blockedByInterlock)
        #expect(h.control.writeCount == writes + 1)

        await h.engine.tick()
        #expect(h.control.writeCount == writes + 2)
        await h.engine.systemWillSleep()
        #expect(h.control.writeCount == writes + 3)
        #expect(h.control.activeControls == [.chargingInhibited, .adapterDisabled])
        await h.engine.systemDidWake()
        #expect(h.control.writeCount == writes + 4)
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("A lease that runs out while the checks run is not used to write")
    func leaseExpiresDuringChecks() async {
        let h = Harness()
        let session = await h.startedSession()
        let inhibit = HelperControl.chargingInhibited.rawValue
        #expect(await session.acquireOrRenewLease(control: inhibit, seconds: 1).grantedSeconds == 1)
        // Reading the power state takes two seconds.
        h.power.update { $0.readDuration = 2 }
        let writes = h.control.writeCount

        #expect(await session.setControl(control: inhibit, active: true) == .noLease)
        #expect(h.control.writeCount == writes)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.leaseEnded(session.id, .chargingInhibited, .expired)))
        #expect(await h.engine.activationHistory.isEmpty)

        // The same for a control already active: it is cleared, not kept.
        h.power.update { $0.readDuration = 0 }
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await session.acquireOrRenewLease(control: inhibit, seconds: 1).status == .ok)
        #expect(await session.setControl(control: inhibit, active: true) == .ok)
        h.power.update { $0.readDuration = 2 }
        #expect(await session.setControl(control: inhibit, active: true) == .noLease)
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("A write that takes effect and then throws is not assumed to have failed cleanly")
    func writeAppliedThenThrew() async {
        let h = Harness()
        let session = await h.startedSession()
        let inhibit = HelperControl.chargingInhibited.rawValue
        h.control.failNextAppliesAfterApplying(1)
        h.control.failNextRestores(2)

        #expect(await h.activate(.chargingInhibited, on: session) == .hardwareError)
        #expect(h.recorder.writes.contains(HelperWriteRecord(
            target: .control(.chargingInhibited, active: true),
            outcome: .threw(code: HelperHardwareError.simulatedFailure.code),
            readBack: nil
        )))
        var state = await session.readState()
        #expect(state.active == [.chargingInhibited])
        #expect(state.interlocks == [.hardwareFault, .writeFailed])

        // The write may have taken effect, so a deactivation retries the
        // restore rather than answering ok at once.
        #expect(await session.setControl(control: inhibit, active: false) == .hardwareError)
        #expect(h.control.activeControls == [.chargingInhibited])

        await h.engine.tick()
        state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.interlocks == .writeFailed)
    }

    @Test("A write whose read-back fails is not assumed to have done nothing")
    func writeReadBackFailed() async {
        let h = Harness()
        let session = await h.startedSession()
        let inhibit = HelperControl.chargingInhibited.rawValue
        h.control.failReadBacksAfterNextApplies(1)
        h.control.failNextRestores(2)

        #expect(await h.activate(.chargingInhibited, on: session) == .hardwareError)
        #expect(h.recorder.writes.contains(HelperWriteRecord(
            target: .control(.chargingInhibited, active: true),
            outcome: .readBackFailed(code: HelperHardwareError.simulatedFailure.code),
            readBack: nil
        )))
        #expect(await session.setControl(control: inhibit, active: false) == .hardwareError)
        #expect(h.control.activeControls == [.chargingInhibited])

        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("A write that changes the other control is caught by the read-back, and the stray control is restored")
    func writeChangedOtherControl() async {
        let h = Harness()
        let session = await h.startedSession()
        h.control.misapplyNextApplies(1)
        h.control.failNextRestores(2)

        // Asked for the adapter-disable; the inhibit was set instead.
        #expect(await h.activate(.adapterDisabled, on: session) == .hardwareError)
        #expect(h.recorder.writes.contains(HelperWriteRecord(
            target: .control(.adapterDisabled, active: true), outcome: .readBackMismatch, readBack: [.chargingInhibited]
        )))
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await session.readState().interlocks == [.hardwareFault, .writeFailed])

        // The stray control is the engine's doing: deactivating it retries
        // the restore instead of answering ok.
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: false) == .hardwareError)
        #expect(h.control.activeControls == [.chargingInhibited])

        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
    }
}
