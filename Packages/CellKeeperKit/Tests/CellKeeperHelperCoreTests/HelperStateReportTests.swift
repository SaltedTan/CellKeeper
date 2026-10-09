import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper engine: state report")
struct HelperStateReportTests {
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

    @Test("A lease that ran out is reported as expired")
    func expired() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await session.readState().chargingInhibitedLeaseEnd == 0)

        h.clock.advance(by: TimeInterval(HelperControl.chargingInhibited.maximumLeaseSeconds))
        let state = await session.readState()
        #expect(state.leaseEnd(for: .chargingInhibited) == .expired)
        #expect(state.chargingInhibitedLeaseEnd == HelperLeaseEndReason.expired.rawValue)
        #expect(state.leaseEnd(for: .adapterDisabled) == nil)
    }

    @Test("A lease its holder released is reported as released")
    func released() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        #expect(await session.releaseLease(control: HelperControl.adapterDisabled.rawValue) == .ok)
        let state = await session.readState()
        #expect(state.leaseEnd(for: .adapterDisabled) == .released)
        #expect(state.leaseEnd(for: .chargingInhibited) == nil)
    }

    @Test("A lease another client's restore ended is reported to its holder")
    func restoredByAnotherClient() async {
        let h = Harness()
        let holder = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: holder) == .ok)
        let other = await h.introducedSession()
        #expect(await other.restoreDefaults() == .ok)
        let state = await holder.readState()
        #expect(state.leaseEnd(for: .chargingInhibited) == .restoredDefaults)
        #expect(state.active.isEmpty)
    }

    @Test("A lease whose holder's session ended or was revoked says so to a new session")
    func sessionEnded() async {
        let h = Harness()
        let first = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: first) == .ok)
        await first.invalidate()
        let second = await h.introducedSession()
        #expect(await second.readState().leaseEnd(for: .chargingInhibited) == .sessionInvalidated)

        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await h.activate(.chargingInhibited, on: second) == .ok)
        await h.exhaustBudget(of: second)
        for _ in 0..<HelperEngine.maximumOverBudgetRequests {
            _ = await second.readState()
        }
        #expect(h.recorder.contains(.sessionRevoked(second.id)))
        let third = await h.introducedSession()
        #expect(await third.readState().leaseEnd(for: .chargingInhibited) == .revoked)
    }

    @Test("While a lease on a control is active, no earlier end is reported")
    func activeLeaseReportsNothing() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await session.releaseLease(control: HelperControl.chargingInhibited.rawValue) == .ok)
        #expect(await session.readState().leaseEnd(for: .chargingInhibited) == .released)

        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 60)
        let state = await session.readState()
        #expect(state.chargingInhibitedLeaseEnd == 0)
        #expect(state.leaseEnd(for: .chargingInhibited) == nil)
    }

    @Test("A deactivation by another session ends no lease: the holder sees its lease still running")
    func deactivationByAnotherSession() async {
        let h = Harness()
        let holder = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: holder) == .ok)
        let other = await h.introducedSession()
        #expect(await other.setControl(control: HelperControl.chargingInhibited.rawValue, active: false) == .ok)
        let state = await holder.readState()
        #expect(state.active.isEmpty)
        #expect(state.chargingInhibitedLeaseSeconds > 0)
        #expect(state.leaseEnd(for: .chargingInhibited) == nil)
    }
}
