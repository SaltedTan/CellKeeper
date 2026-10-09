import CellKeeperHelperCore
import Testing

@Suite("Helper engine: sessions")
struct HelperSessionTests {
    @Test("Requests before hello are refused, except restores")
    func helloFirst() async {
        let h = Harness(control: SimulatedChargeControl(initiallyActive: []))
        await h.engine.start()
        let session = await h.engine.openSession()

        #expect(await session.readState().status == .notIntroduced)
        #expect(await session.acquireOrRenewLease(control: 1, seconds: 60).status == .notIntroduced)
        #expect(await session.setControl(control: 1, active: true) == .notIntroduced)
        #expect(await session.setControl(control: 1, active: false) == .notIntroduced)
        #expect(await session.releaseLease(control: 1) == .notIntroduced)
        #expect(h.recorder.contains(.requestRejected(session.id, .readState, .notIntroduced)))
        #expect(h.recorder.contains(.requestRejected(session.id, .acquireOrRenewLease, .notIntroduced)))

        #expect(await session.restoreDefaults() == .ok)
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        #expect(await session.readState().status == .ok)
    }

    @Test("Hello accepts only client versions in the supported range")
    func versionRange() async {
        let h = Harness()
        await h.engine.start()
        let session = await h.engine.openSession()

        for version in [HelperProtocolVersion.minimumSupportedClient - 1, HelperProtocolVersion.current + 1] {
            let reply = await session.hello(clientProtocolVersion: version)
            #expect(reply.status == .incompatibleProtocol)
            // Still filled in, so the client can tell which side is out of date.
            #expect(reply.helperProtocolVersion == HelperProtocolVersion.current)
            #expect(reply.build == 42)
            #expect(await session.readState().status == .notIntroduced)
        }
        #expect(h.recorder.contains(.requestRejected(session.id, .hello, .incompatibleProtocol)))

        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        #expect(await session.readState().status == .ok)

        // A later incompatible hello withdraws the introduction.
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current + 1).status == .incompatibleProtocol)
        #expect(await session.readState().status == .notIntroduced)
    }

    @Test("Unknown controls and durations of zero or less are invalid arguments")
    func invalidArguments() async {
        let h = Harness()
        let session = await h.startedSession()

        for raw in [0, 3, -1] {
            #expect(await session.acquireOrRenewLease(control: raw, seconds: 60) == HelperLeaseReply(status: .invalidArgument, grantedSeconds: 0))
        }
        for seconds in [0, -5] {
            #expect(await session.acquireOrRenewLease(control: 1, seconds: seconds).status == .invalidArgument)
        }
        #expect(await session.setControl(control: 7, active: true) == .invalidArgument)
        #expect(await session.setControl(control: 7, active: false) == .invalidArgument)
        #expect(await session.releaseLease(control: 99) == .invalidArgument)
        #expect(h.recorder.contains(.requestRejected(session.id, .setControl, .invalidArgument)))
        #expect(h.control.writeCount == 1)  // the start-up restore
        #expect(await session.readState().isLeaseHolder == false)
    }

    @Test("A control the helper cannot perform is refused")
    func unsupportedControl() async {
        let h = Harness(control: SimulatedChargeControl(capabilities: [.chargingInhibit]))
        let session = await h.startedSession()

        #expect(await session.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 60).status == .unsupportedControl)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .unsupportedControl)
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(h.control.activeControls == [.chargingInhibited])
    }

    @Test("Only one session holds leases at a time")
    func singleWriter() async {
        let h = Harness()
        let a = await h.startedSession()
        let b = await h.introducedSession()

        #expect(await h.activate(.chargingInhibited, on: a) == .ok)
        for control in HelperControl.allCases {
            #expect(await b.acquireOrRenewLease(control: control.rawValue, seconds: 60).status == .leaseHeldByOtherClient)
        }
        #expect(await b.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .noLease)
        // Nor may B use a lease A holds, whether its control is active or not.
        #expect(await b.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .noLease)
        #expect(await a.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 60).status == .ok)
        #expect(await b.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .noLease)
        #expect(h.control.activeControls == [.chargingInhibited])
        // B's attempts reserved nothing: only A's activation counts.
        #expect(await h.engine.activationHistory.map(\.control) == [.chargingInhibited])
        #expect(await b.readState().isLeaseHolder == false)
        #expect(await a.readState().isLeaseHolder)
        #expect(h.recorder.contains(.requestRejected(b.id, .acquireOrRenewLease, .leaseHeldByOtherClient)))

        #expect(await a.releaseLease(control: HelperControl.chargingInhibited.rawValue) == .ok)
        #expect(await b.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 60).status == .leaseHeldByOtherClient)
        #expect(await a.releaseLease(control: HelperControl.adapterDisabled.rawValue) == .ok)
        #expect(await b.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 60).status == .ok)
        #expect(await a.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 60).status == .leaseHeldByOtherClient)
    }

    @Test("Invalidating a session clears every control it holds at once (R1, R3)")
    func invalidationClears() async {
        let h = Harness()
        let a = await h.startedSession()
        let b = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: a) == .ok)
        #expect(await h.activate(.adapterDisabled, on: a) == .ok)
        #expect(h.control.activeControls == [.chargingInhibited, .adapterDisabled])

        await a.invalidate()
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.sessionInvalidated(a.id)))
        for control in HelperControl.allCases {
            #expect(h.recorder.contains(.leaseEnded(a.id, control, .sessionInvalidated)))
            #expect(h.recorder.contains(.deactivated(control, .sessionInvalidated)))
        }

        // A message that arrives after invalidation gets nothing.
        #expect(await a.acquireOrRenewLease(control: 1, seconds: 60).status == .notIntroduced)
        #expect(await a.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .notIntroduced)
        #expect(await b.acquireOrRenewLease(control: 1, seconds: 60).status == .ok)
    }

    @Test("Invalidating a session that holds no lease changes nothing")
    func invalidationOfBystander() async {
        let h = Harness()
        let a = await h.startedSession()
        let b = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: a) == .ok)
        let writes = h.control.writeCount

        await b.invalidate()
        await b.invalidate()
        #expect(h.control.writeCount == writes)
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await a.readState().isLeaseHolder)
    }

    @Test("Any session may restore defaults, ending the holder's leases")
    func restoreByAnotherSession() async {
        let h = Harness()
        let a = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: a) == .ok)

        let stranger = await h.engine.openSession()
        #expect(await stranger.restoreDefaults() == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.leaseEnded(a.id, .chargingInhibited, .restoredDefaults)))
        #expect(h.recorder.contains(.restored(.clientRequest)))
        #expect(await a.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .noLease)
    }

    @Test("Restoring defaults is idempotent: nothing is written when already at defaults")
    func restoreIdempotent() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        let writes = h.control.writeCount

        #expect(await session.restoreDefaults() == .ok)
        #expect(h.control.writeCount == writes + 1)
        #expect(h.control.writes.last == .restoreDefaults)
        let state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.chargingInhibitedLeaseSeconds == 0)
        #expect(state.adapterDisabledLeaseSeconds == 0)

        #expect(await session.restoreDefaults() == .ok)
        #expect(await session.restoreDefaults() == .ok)
        #expect(h.control.writeCount == writes + 1)
    }

    @Test("Events form an audit trail of what the engine did")
    func auditTrail() async {
        let h = Harness()
        h.clock.freeze()
        let now = h.clock.uptime
        await h.engine.start()
        let session = await h.engine.openSession()
        _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 300)
        _ = await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true)
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 300)
        _ = await session.releaseLease(control: HelperControl.chargingInhibited.rawValue)
        await session.invalidate()

        #expect(h.recorder.events == [
            .write(HelperWriteRecord(target: .restoreDefaults, outcome: .confirmed, readBack: [])),
            .restored(.start),
            .started(capabilities: [.chargingInhibit, .adapterDisable], isSimulated: true),
            .sessionOpened(session.id),
            .leaseGranted(session.id, .chargingInhibited, seconds: 300),
            .write(HelperWriteRecord(target: .control(.chargingInhibited, active: true), outcome: .confirmed, readBack: [.chargingInhibited])),
            .activationRecorded(HelperActivationRecord(control: .chargingInhibited, uptime: now)),
            .activated(.chargingInhibited, by: session.id),
            .leaseRenewed(session.id, .chargingInhibited, seconds: 300),
            .leaseEnded(session.id, .chargingInhibited, .released),
            .write(HelperWriteRecord(target: .control(.chargingInhibited, active: false), outcome: .confirmed, readBack: [])),
            .deactivated(.chargingInhibited, .leaseReleased),
            .sessionInvalidated(session.id),
        ])
    }

    @Test("An invalidated session can no longer restore or shut the engine down")
    func invalidatedSessionHasNoAuthority() async {
        let h = Harness()
        let a = await h.startedSession()
        await a.invalidate()
        let b = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: b) == .ok)
        let writes = h.control.writeCount

        // Messages from A that arrive after its connection ended.
        #expect(await a.restoreDefaults() == .notIntroduced)
        #expect(await a.restoreDefaultsAndExit() == .notIntroduced)
        #expect(h.recorder.contains(.requestRejected(a.id, .restoreDefaults, .notIntroduced)))
        #expect(h.control.writeCount == writes)
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await h.engine.isShuttingDown == false)
        let state = await b.readState()
        #expect(state.isLeaseHolder)
        #expect(state.chargingInhibitedLeaseSeconds > 0)
    }

    @Test("Any failed hello withdraws the introduction, also one refused by the budget")
    func failedHelloWithdrawsIntroduction() async {
        let h = Harness()
        let session = await h.startedSession()
        await h.exhaustBudget(of: session)

        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .rateLimited)
        h.clock.advance(by: 5)
        #expect(await session.readState().status == .notIntroduced)
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        #expect(await session.readState().status == .ok)
    }
}
