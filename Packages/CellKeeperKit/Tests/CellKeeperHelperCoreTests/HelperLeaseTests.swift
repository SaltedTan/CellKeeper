import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper engine: leases")
struct HelperLeaseTests {
    @Test("A lease is clamped to its control's maximum", arguments: HelperControl.allCases)
    func clamping(control: HelperControl) async {
        let h = Harness()
        let session = await h.startedSession()

        let long = await session.acquireOrRenewLease(control: control.rawValue, seconds: 100_000)
        #expect(long == HelperLeaseReply(status: .ok, grantedSeconds: control.maximumLeaseSeconds))
        #expect(await session.readState().leaseSeconds(for: control) == control.maximumLeaseSeconds)
        #expect(h.recorder.contains(.leaseGranted(session.id, control, seconds: control.maximumLeaseSeconds)))

        let short = await session.acquireOrRenewLease(control: control.rawValue, seconds: 30)
        #expect(short == HelperLeaseReply(status: .ok, grantedSeconds: 30))
        #expect(await session.readState().leaseSeconds(for: control) == 30)
    }

    @Test("Remaining lease time is reported rounded up")
    func remainingRoundedUp() async {
        let h = Harness()
        let session = await h.startedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 30)
        h.clock.advance(by: 0.5)
        let state = await session.readState()
        #expect(state.chargingInhibitedLeaseSeconds == 30)
        #expect(state.adapterDisabledLeaseSeconds == 0)
        #expect(state.isLeaseHolder)
    }

    @Test("An expired lease clears its control (R3)", arguments: HelperControl.allCases)
    func expiry(control: HelperControl) async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(control, on: session) == .ok)

        h.clock.advance(by: TimeInterval(control.maximumLeaseSeconds) - 1)
        await h.engine.tick()
        #expect(h.control.activeControls == [control])

        h.clock.advance(by: 1)
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.leaseEnded(session.id, control, .expired)))
        #expect(h.recorder.contains(.deactivated(control, .leaseExpired)))

        let state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.leaseSeconds(for: control) == 0)
        #expect(state.isLeaseHolder == false)
        #expect(await session.setControl(control: control.rawValue, active: true) == .noLease)
    }

    @Test("Any request runs the expiry check, not only ticks")
    func expiryOnRequest() async {
        let h = Harness()
        let a = await h.startedSession()
        let b = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: a) == .ok)

        h.clock.advance(by: 900)
        #expect(await b.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 60).status == .ok)
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("Renewing a lease extends it")
    func renewal() async {
        let h = Harness()
        let session = await h.startedSession()
        let inhibit = HelperControl.chargingInhibited.rawValue
        _ = await session.acquireOrRenewLease(control: inhibit, seconds: 100)
        #expect(await session.setControl(control: inhibit, active: true) == .ok)

        h.clock.advance(by: 90)
        #expect(await session.acquireOrRenewLease(control: inhibit, seconds: 100) == HelperLeaseReply(status: .ok, grantedSeconds: 100))
        #expect(h.recorder.contains(.leaseRenewed(session.id, .chargingInhibited, seconds: 100)))

        h.clock.advance(by: 90)
        await h.engine.tick()
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await session.readState().chargingInhibitedLeaseSeconds == 10)

        h.clock.advance(by: 10)
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("Releasing a lease clears its control and ends the lease")
    func release() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)

        #expect(await session.releaseLease(control: HelperControl.chargingInhibited.rawValue) == .ok)
        #expect(h.control.activeControls == [.adapterDisabled])
        #expect(h.recorder.contains(.leaseEnded(session.id, .chargingInhibited, .released)))
        #expect(await session.releaseLease(control: HelperControl.chargingInhibited.rawValue) == .noLease)
        #expect(await session.readState().isLeaseHolder)
    }

    @Test("Activation needs this session's lease on that control")
    func activationNeedsLease() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .noLease)
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 60)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .noLease)
        #expect(h.recorder.contains(.requestRejected(session.id, .setControl, .noLease)))
        #expect(h.control.writeCount == 1)  // the start-up restore
    }

    @Test("Deactivation needs no lease and leaves the holder's lease in place")
    func deactivationWithoutLease() async {
        let h = Harness()
        let holder = await h.startedSession()
        let other = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: holder) == .ok)

        #expect(await other.setControl(control: HelperControl.chargingInhibited.rawValue, active: false) == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.deactivated(.chargingInhibited, .clientRequest)))
        let state = await holder.readState()
        #expect(state.isLeaseHolder)
        #expect(state.chargingInhibitedLeaseSeconds == 900)
    }
}
