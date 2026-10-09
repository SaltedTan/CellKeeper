import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper engine: state report")
struct HelperStateReportTests {
    private func sessionNumber(_ session: HelperSession) -> UInt64 {
        UInt64(session.id.rawValue)
    }

    @Test("Every hardware error is counted, so a repeat of the same code is visible")
    func hardwareErrorCount() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await session.readState().hardwareErrorCount == 0)

        // A check that cannot read back restores defaults: one error.
        h.control.failNextReadBacks(1)
        await h.engine.tick()
        var state = await session.readState()
        #expect(state.lastHardwareError == HelperHardwareError.simulatedFailure.code)
        #expect(state.hardwareErrorCount == 1)

        // The same code again.
        h.control.failNextReadBacks(1)
        await h.engine.tick()
        state = await session.readState()
        #expect(state.lastHardwareError == HelperHardwareError.simulatedFailure.code)
        #expect(state.hardwareErrorCount == 2)
    }

    @Test("hello tells each session its number and the helper's instance")
    func sessionAndInstance() async {
        let h = Harness()
        await h.engine.start()
        let first = await h.engine.openSession()
        let second = await h.engine.openSession()
        let a = await first.hello(clientProtocolVersion: HelperProtocolVersion.current)
        let b = await second.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(a.sessionID == sessionNumber(first))
        #expect(b.sessionID == sessionNumber(second))
        #expect(a.sessionID != b.sessionID)
        #expect(a.helperInstance == b.helperInstance)
        #expect(a.helperInstance != 0)

        let other = Harness()
        let c = await other.startedSession().hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(c.helperInstance != a.helperInstance)
    }

    @Test("Each turn of a control on or off advances its generation; a lease ending alone does not")
    func generations() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await session.readState().change(for: .chargingInhibited) == HelperControlChange(generation: 0, cause: nil, interlocks: [], session: 0))

        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await session.readState().change(for: .chargingInhibited)
            == HelperControlChange(generation: 1, cause: .setByClient, interlocks: [], session: sessionNumber(session)))

        #expect(await session.releaseLease(control: HelperControl.chargingInhibited.rawValue) == .ok)
        let released = HelperControlChange(generation: 2, cause: .clearedByClient, interlocks: [], session: sessionNumber(session))
        #expect(await session.readState().change(for: .chargingInhibited) == released)

        // A lease on the inactive control that runs out changes nothing.
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 30)
        h.clock.advance(by: 31)
        #expect(await session.readState().change(for: .chargingInhibited) == released)
        #expect(await session.readState().change(for: .adapterDisabled).generation == 0)
    }

    @Test("A lease that runs out clears its control for that reason")
    func expired() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        h.clock.advance(by: TimeInterval(HelperControl.adapterDisabled.maximumLeaseSeconds))
        #expect(await session.readState().change(for: .adapterDisabled)
            == HelperControlChange(generation: 2, cause: .leaseExpired, interlocks: [], session: 0))
    }

    @Test("An interlock's clear is reported with the interlocks of the time, after they have lifted")
    func interlockHistory() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        h.power.update { $0.isThermalPressureHigh = true }
        await h.engine.tick()
        h.power.update { $0.isThermalPressureHigh = false }
        let state = await session.readState()
        #expect(state.interlocks.isEmpty)
        #expect(state.change(for: .adapterDisabled) == HelperControlChange(generation: 2, cause: .interlock, interlocks: .thermalPressure, session: 0))
    }

    @Test("A lease that runs out while an interlock's clear is written is cleared for the expiry, after it")
    func expiryDuringSlowClear() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.clock.advance(by: 870)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        h.power.update { $0.isThermalPressureHigh = true }
        let clock = h.clock
        h.control.performDuringNextApplies(1) { clock.advance(by: 40) }
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(await h.engine.latestChange(of: .adapterDisabled)
            == HelperControlChange(generation: 2, cause: .interlock, interlocks: .thermalPressure, session: 0))
        #expect(await h.engine.latestChange(of: .chargingInhibited)
            == HelperControlChange(generation: 2, cause: .leaseExpired, interlocks: [], session: 0))
    }

    @Test("A lease that runs out during a client's slow deactivation is cleared for the expiry when the call ends")
    func expiryAtEndOfCall() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.clock.advance(by: 870)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        let clock = h.clock
        h.control.performDuringNextApplies(1) { clock.advance(by: 40) }
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: false) == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(await h.engine.latestChange(of: .adapterDisabled)
            == HelperControlChange(generation: 2, cause: .clearedByClient, interlocks: [], session: sessionNumber(session)))
        #expect(await h.engine.latestChange(of: .chargingInhibited)
            == HelperControlChange(generation: 2, cause: .leaseExpired, interlocks: [], session: 0))
    }

    @Test("A power state that goes stale while a clear is written clears the other control for that interlock")
    func stalePowerDuringSlowClear() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        h.power.update { $0.isThermalPressureHigh = true }
        let clock = h.clock
        h.control.performDuringNextApplies(1) { clock.advance(by: HelperEngine.maximumPowerStateAge + 1) }
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(await h.engine.latestChange(of: .adapterDisabled)
            == HelperControlChange(generation: 2, cause: .interlock, interlocks: .thermalPressure, session: 0))
        #expect(await h.engine.latestChange(of: .chargingInhibited)
            == HelperControlChange(generation: 2, cause: .interlock, interlocks: .powerStateUnavailable, session: 0))
    }

    @Test("Another session's deactivation is attributed to it, and a later expiry does not hide it")
    func deactivationByAnotherSession() async {
        let h = Harness()
        let holder = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: holder) == .ok)
        let other = await h.introducedSession()
        #expect(await other.setControl(control: HelperControl.chargingInhibited.rawValue, active: false) == .ok)
        let cleared = HelperControlChange(generation: 2, cause: .clearedByClient, interlocks: [], session: sessionNumber(other))
        let state = await holder.readState()
        #expect(state.active.isEmpty)
        #expect(state.chargingInhibitedLeaseSeconds > 0)
        #expect(state.change(for: .chargingInhibited) == cleared)

        h.clock.advance(by: TimeInterval(HelperControl.chargingInhibited.maximumLeaseSeconds))
        #expect(await holder.readState().change(for: .chargingInhibited) == cleared)
    }

    @Test("Another session's restore is attributed to it")
    func restoreByAnotherSession() async {
        let h = Harness()
        let holder = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: holder) == .ok)
        let other = await h.introducedSession()
        #expect(await other.restoreDefaults() == .ok)
        #expect(await holder.readState().change(for: .chargingInhibited)
            == HelperControlChange(generation: 2, cause: .clearedByRestore, interlocks: [], session: sessionNumber(other)))
    }

    @Test("A holder's session that ended or was revoked is named as the cause")
    func sessionEndedOrRevoked() async {
        let h = Harness()
        let first = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: first) == .ok)
        await first.invalidate()
        let second = await h.introducedSession()
        #expect(await second.readState().change(for: .chargingInhibited)
            == HelperControlChange(generation: 2, cause: .sessionEnded, interlocks: [], session: sessionNumber(first)))

        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await h.activate(.chargingInhibited, on: second) == .ok)
        await h.exhaustBudget(of: second)
        for _ in 0..<HelperEngine.maximumOverBudgetRequests {
            _ = await second.readState()
        }
        #expect(h.recorder.contains(.sessionRevoked(second.id)))
        let third = await h.introducedSession()
        #expect(await third.readState().change(for: .chargingInhibited)
            == HelperControlChange(generation: 4, cause: .sessionRevoked, interlocks: [], session: sessionNumber(second)))
    }

    @Test("A change made outside the engine, and the restore after it, are reported as such")
    func outsideChange() async {
        let h = Harness()
        let session = await h.startedSession()
        h.control.simulateOutsideChange(.adapterDisabled, active: true)
        // The check sees the outside change, then restores.
        await h.engine.tick()
        #expect(await session.readState().change(for: .adapterDisabled)
            == HelperControlChange(generation: 2, cause: .restoredAfterOutsideChange, interlocks: [], session: 0))

        // A change that stays in the quiet state is reported as outside.
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        #expect(await session.readState().change(for: .chargingInhibited)
            == HelperControlChange(generation: 1, cause: .changedOutside, interlocks: [], session: 0))
    }

    @Test("A clear that fails at lease expiry is reported as the restore after a failed write, not as the expiry")
    func failedClearAtExpiry() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.control.failNextApplies(1)
        h.clock.advance(by: TimeInterval(HelperControl.chargingInhibited.maximumLeaseSeconds))
        let state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.interlocks.contains(.writeFailed))
        #expect(state.change(for: .chargingInhibited)
            == HelperControlChange(generation: 2, cause: .restoredAfterWriteFailure, interlocks: [], session: 0))
    }

    @Test("A restore after an activation the limits refused names the session that asked")
    func activationLimited() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: false) == .ok)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .rateLimited)
        #expect(await session.readState().change(for: .adapterDisabled)
            == HelperControlChange(generation: 2, cause: .activationLimited, interlocks: [], session: sessionNumber(session)))
    }

    @Test("The restore at shutdown is reported as such")
    func shutdown() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        await h.engine.terminate()
        #expect(await h.engine.latestChange(of: .chargingInhibited)
            == HelperControlChange(generation: 2, cause: .shutdown, interlocks: [], session: 0))
    }
}
