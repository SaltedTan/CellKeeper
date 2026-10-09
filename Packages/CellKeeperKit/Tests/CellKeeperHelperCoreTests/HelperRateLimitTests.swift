import CellKeeperHelperCore
import Testing

@Suite("Helper engine: rate limits")
struct HelperRateLimitTests {
    private func set(_ control: HelperControl, _ active: Bool, on session: HelperSession) async -> HelperStatus {
        await session.setControl(control: control.rawValue, active: active)
    }

    private func renew(_ control: HelperControl, on session: HelperSession) async -> HelperStatus {
        await session.acquireOrRenewLease(control: control.rawValue, seconds: control.maximumLeaseSeconds).status
    }

    @Test("Each control is activated at most once a minute (R13)")
    func minimumInterval() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await set(.chargingInhibited, false, on: session) == .ok)

        h.clock.advance(by: HelperEngine.minimumActivationInterval - 1)
        #expect(await set(.chargingInhibited, true, on: session) == .rateLimited)
        #expect(h.recorder.contains(.requestRejected(session.id, .setControl, .rateLimited)))
        // The interval is per control.
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)

        h.clock.advance(by: 1)
        #expect(await set(.chargingInhibited, true, on: session) == .ok)
        #expect(h.control.activeControls == [.chargingInhibited, .adapterDisabled])
    }

    @Test("At most 20 activations per rolling hour, all controls together (R13)")
    func hourlyCap() async {
        let h = Harness()
        let session = await h.startedSession()
        for index in 0..<HelperEngine.maximumActivationsPerHour {
            let control: HelperControl = index.isMultiple(of: 2) ? .chargingInhibited : .adapterDisabled
            #expect(await renew(control, on: session) == .ok)
            #expect(await set(control, true, on: session) == .ok, "activation \(index + 1)")
            #expect(await set(control, false, on: session) == .ok)
            h.clock.advance(by: HelperEngine.minimumActivationInterval)
        }
        // 20 activations in the last 20 minutes: both controls are refused.
        for control in HelperControl.allCases {
            #expect(await renew(control, on: session) == .ok)
            #expect(await set(control, true, on: session) == .rateLimited)
        }

        // The first activation leaves the window an hour after it was made.
        h.clock.advance(by: 60 * 60 - 20 * HelperEngine.minimumActivationInterval - 1)
        #expect(await renew(.chargingInhibited, on: session) == .ok)
        #expect(await set(.chargingInhibited, true, on: session) == .rateLimited)
        h.clock.advance(by: 1)
        #expect(await set(.chargingInhibited, true, on: session) == .ok)
    }

    @Test("A request for the state already in effect writes nothing and is not counted")
    func idempotentRequests() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        let writes = h.control.writeCount

        h.clock.advance(by: 30)
        #expect(await set(.chargingInhibited, true, on: session) == .ok)
        #expect(await set(.chargingInhibited, true, on: session) == .ok)
        #expect(await set(.adapterDisabled, false, on: session) == .ok)
        #expect(h.control.writeCount == writes)

        // Had the repeats counted, the next activation would wait until
        // 60 s after them.
        h.clock.advance(by: 30)
        #expect(await set(.chargingInhibited, false, on: session) == .ok)
        #expect(await set(.chargingInhibited, false, on: session) == .ok)
        #expect(h.control.writeCount == writes + 1)
        #expect(await set(.chargingInhibited, true, on: session) == .ok)
        #expect(h.control.writeCount == writes + 2)
    }

    @Test("Deactivations and restores are never rate-limited")
    func safetyNeverLimited() async {
        let h = Harness()
        let session = await h.startedSession()
        for index in 0..<HelperEngine.maximumActivationsPerHour {
            let control: HelperControl = index.isMultiple(of: 2) ? .chargingInhibited : .adapterDisabled
            _ = await renew(control, on: session)
            #expect(await set(control, true, on: session) == .ok)
            if index < HelperEngine.maximumActivationsPerHour - 2 {
                #expect(await set(control, false, on: session) == .ok)
            }
            h.clock.advance(by: HelperEngine.minimumActivationInterval)
        }
        #expect(h.control.activeControls == [.chargingInhibited, .adapterDisabled])
        #expect(await set(.chargingInhibited, true, on: session) == .ok)  // already active
        _ = await session.releaseLease(control: HelperControl.chargingInhibited.rawValue)
        #expect(await renew(.chargingInhibited, on: session) == .ok)
        #expect(await set(.chargingInhibited, true, on: session) == .rateLimited)

        // Use up the request budget as well.
        for _ in 0..<HelperEngine.requestBurst {
            _ = await session.readState()
        }
        #expect(await session.readState().status == .rateLimited)

        #expect(await set(.adapterDisabled, false, on: session) == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(await session.releaseLease(control: HelperControl.adapterDisabled.rawValue) == .ok)
        #expect(await session.restoreDefaults() == .ok)
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        #expect(await session.restoreDefaults() == .ok)
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("Each session has its own request budget")
    func requestBudget() async {
        let h = Harness()
        await h.engine.start()
        let session = await h.engine.openSession()
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        for _ in 1..<HelperEngine.requestBurst {
            #expect(await session.readState().status == .ok)
        }
        #expect(await session.readState().status == .rateLimited)
        #expect(await session.acquireOrRenewLease(control: 1, seconds: 60).status == .rateLimited)
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .rateLimited)
        // Reported once, not for every refused request.
        let refusals = h.recorder.events.filter {
            if case .requestRejected(_, _, .rateLimited) = $0 { return true }
            return false
        }
        #expect(refusals == [.requestRejected(session.id, .readState, .rateLimited)])

        // Another session is unaffected.
        let other = await h.introducedSession()
        #expect(await other.readState().status == .ok)

        // Two requests a second, sustained.
        h.clock.advance(by: 1 / HelperEngine.requestsPerSecond)
        #expect(await session.readState().status == .ok)
        #expect(await session.readState().status == .rateLimited)

        // The bucket refills to the burst size and no further.
        h.clock.advance(by: 60)
        for _ in 0..<HelperEngine.requestBurst {
            #expect(await session.readState().status == .ok)
        }
        #expect(await session.readState().status == .rateLimited)
    }
}
