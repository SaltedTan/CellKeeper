import CellKeeperHelperCore
import Foundation
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
        // The activation limit is used up, and so is the request budget.
        #expect(h.control.activeControls == [.chargingInhibited, .adapterDisabled])
        #expect(await set(.chargingInhibited, true, on: session) == .ok)  // already active
        await h.exhaustBudget(of: session)
        #expect(await session.readState().status == .rateLimited)

        #expect(await set(.adapterDisabled, false, on: session) == .ok)
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await session.releaseLease(control: HelperControl.chargingInhibited.rawValue) == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(await session.restoreDefaults() == .ok)
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        #expect(await session.restoreDefaults() == .ok)
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("An activation refused by the activation limits restores defaults, without a degraded mode (R13)")
    func refusedActivationRestores() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await set(.chargingInhibited, false, on: session) == .ok)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)

        h.clock.advance(by: 30)
        #expect(await set(.chargingInhibited, true, on: session) == .rateLimited)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.restored(.activationLimited)))
        let state = await session.readState()
        #expect(state.interlocks.isEmpty)
        #expect(state.isLeaseHolder)

        h.clock.advance(by: 30)
        #expect(await set(.chargingInhibited, true, on: session) == .ok)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
    }

    @Test("A relaunched engine given the earlier history keeps enforcing the activation limits")
    func historyAcrossRelaunch() async {
        let clock = HelperTestClock()
        let first = Harness(clock: clock)
        let session = await first.startedSession()
        #expect(await first.activate(.chargingInhibited, on: session) == .ok)
        let history = await first.engine.activationHistory
        #expect(history.map(\.control) == [.chargingInhibited])
        #expect(first.recorder.contains(.activationRecorded(history[0])))
        _ = await session.restoreDefaultsAndExit()

        // launchd relaunches the helper; the app reconnects 10 s later.
        clock.advance(by: 10)
        let second = Harness(clock: clock, activationHistory: history)
        let reconnected = await second.startedSession()
        #expect(await second.activate(.chargingInhibited, on: reconnected) == .rateLimited)
        #expect(await second.activate(.adapterDisabled, on: reconnected) == .ok)
        clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await second.activate(.chargingInhibited, on: reconnected) == .ok)
    }

    @Test("The hourly cap holds across a relaunch; records older than an hour or from the future are dropped")
    func historyHourlyCap() async {
        let clock = HelperTestClock()
        let now = clock.uptime
        let full = (0..<HelperEngine.maximumActivationsPerHour).map {
            HelperActivationRecord(control: .adapterDisabled, uptime: now - 3_000 + Double($0) * 60)
        }
        let capped = Harness(clock: clock, activationHistory: full)
        let session = await capped.startedSession()
        #expect(await capped.activate(.chargingInhibited, on: session) == .rateLimited)
        #expect(await capped.engine.activationHistory == full)

        let stale = [
            HelperActivationRecord(control: .chargingInhibited, uptime: now - 3_600),
            HelperActivationRecord(control: .chargingInhibited, uptime: now + 10_000),
        ]
        let fresh = Harness(clock: clock, activationHistory: stale + Array(full.dropFirst()))
        let other = await fresh.startedSession()
        #expect(await fresh.activate(.chargingInhibited, on: other) == .ok)
    }

    @Test("A session that keeps exceeding its budget is revoked and its controls cleared")
    func revocation() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        await h.exhaustBudget(of: session)

        // Refused requests count, up to the limit.
        for _ in 0..<(HelperEngine.maximumOverBudgetRequests - 1) {
            #expect(await session.readState().status == .rateLimited)
        }
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(h.recorder.contains(.sessionRevoked(session.id)) == false)

        #expect(await session.readState().status == .rateLimited)
        #expect(h.recorder.contains(.sessionRevoked(session.id)))
        #expect(h.recorder.contains(.leaseEnded(session.id, .chargingInhibited, .sessionInvalidated)))
        #expect(h.control.activeControls.isEmpty)
        h.clock.advance(by: 60)
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .notIntroduced)
        #expect(await session.restoreDefaults() == .notIntroduced)
    }

    @Test("Requests beyond the budget that only move toward safety are served, do no needless work, and count toward revocation")
    func exemptRequestsCount() async {
        let h = Harness()
        let session = await h.startedSession()
        await h.exhaustBudget(of: session)  // streak 1
        let reads = h.control.readBackCount
        let writes = h.control.writeCount

        // Nothing of the engine's is set: no read, no write.
        for _ in 0..<9 {
            #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: false) == .ok)
        }
        #expect(h.control.readBackCount == reads)
        // A restore always reads afresh, but writes only if something is set.
        for _ in 0..<10 {
            #expect(await session.restoreDefaults() == .ok)
        }
        #expect(h.control.readBackCount == reads + 10)
        #expect(h.control.writeCount == writes)

        // The 21st request in a row beyond the budget.
        #expect(await session.restoreDefaults() == .rateLimited)
        #expect(h.recorder.contains(.sessionRevoked(session.id)))
    }

    @Test("A request within the budget ends the over-budget streak")
    func streakResets() async {
        let h = Harness()
        let session = await h.startedSession()
        await h.exhaustBudget(of: session)
        for _ in 0..<(HelperEngine.maximumOverBudgetRequests - 2) {
            _ = await session.readState()
        }
        h.clock.advance(by: 1 / HelperEngine.requestsPerSecond)
        #expect(await session.readState().status == .ok)
        for _ in 0..<HelperEngine.maximumOverBudgetRequests {
            #expect(await session.readState().status == .rateLimited)
        }
        #expect(h.recorder.contains(.sessionRevoked(session.id)) == false)
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
