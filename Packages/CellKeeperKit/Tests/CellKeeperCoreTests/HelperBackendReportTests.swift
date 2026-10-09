@testable import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper backend: why a hold ended")
struct HelperHoldEndTests {
    private func hold(_ mode: ChargeControlMode, _ rig: HelperRig) async throws {
        _ = try await rig.backend.setMode(mode)
        #expect(try await rig.backend.currentMode() == mode)
    }

    /// Another client of the helper, introduced.
    private func otherClient(_ rig: HelperRig) async -> HelperSession {
        let session = await rig.engine.openSession()
        _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        return session
    }

    @Test("A lapse is recognised from the helper's report, whatever CellKeeper's own clock says")
    func lapseFromHelperReport() async throws {
        // CellKeeper's clock runs far behind the helper's, so by its own
        // reckoning the lease is still valid.
        let rig = HelperRig(backendClockOffset: -5_000)
        try await hold(.inhibitCharging, rig)
        rig.clock.advance(by: 901)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.reportedModeOrigin() == .releasedByBackend(.leaseExpired))
    }

    @Test("Another client's restore that ends CellKeeper's hold is an outside change")
    func restoreByAnotherClient() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        #expect(await otherClient(rig).restoreDefaults() == .ok)
        #expect(try await rig.backend.currentMode() == .normal)
        guard case .changedOutside(let detail)? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected an outside change")
            return
        }
        #expect(detail.contains("another client"))
        #expect(detail.contains("restored"))
    }

    @Test("Another client's deactivation of CellKeeper's control is an outside change")
    func deactivationByAnotherClient() async throws {
        let rig = HelperRig()
        try await hold(.forceDischarge, rig)
        #expect(await otherClient(rig).setControl(control: HelperControl.adapterDisabled.rawValue, active: false) == .ok)
        #expect(try await rig.backend.currentMode() == .normal)
        guard case .changedOutside(let detail)? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected an outside change")
            return
        }
        #expect(detail.contains("lease on it ran on"))
    }

    @Test("A session the helper revoked ended CellKeeper's hold as a lost connection")
    func revokedSession() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        // Requests made on CellKeeper's session behind the backend's back.
        let session = try #require(rig.transport.latest?.session)
        for _ in 0...(HelperEngine.requestBurst + HelperEngine.maximumOverBudgetRequests) {
            _ = await session.readState()
        }
        #expect(rig.events.contains { if case .sessionRevoked = $0 { true } else { false } })
        rig.clock.advance(by: 10)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.reportedModeOrigin() == .releasedByBackend(.connectionLost))
        #expect(rig.transport.connections.count == 2)
    }

    @Test("A failed write blocks both modes until the user's fault reset restores defaults")
    func writeFailed() async throws {
        let rig = HelperRig()
        _ = await rig.backend.capabilities()
        rig.control.failNextApplies(1)
        await #expect(throws: BackendError.self) {
            try await rig.backend.setMode(.inhibitCharging)
        }
        #expect(await rig.observedState().interlocks.contains(.writeFailed))
        #expect(await rig.backend.capabilities().supportedModes == [.normal])
        #expect(HelperChargingBackend.describe(.writeFailed) == "a write to one of its controls failed")

        try await rig.backend.resetAfterFault()
        #expect(await rig.observedState().interlocks.isEmpty)
        #expect(await rig.backend.capabilities().supportedModes == ChargeControlMode.chargingModes)
    }

    @Test("A fault reset whose session ended before the restore connects again and tries once more")
    func resetRetriesOnce() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        _ = try await rig.backend.currentMode()
        rig.control.simulateOutsideChange(.chargingInhibited, active: true)
        let connections = rig.transport.connections.count
        rig.transport.latest?.endSessionBeforeNextRestore()

        try await rig.backend.resetAfterFault()
        #expect(rig.transport.connections.count == connections + 1)
        #expect(rig.control.activeControls.isEmpty)
        #expect(await rig.observedState().interlocks.isEmpty)
    }
}

@Suite("Helper backend: request budget")
struct HelperRequestPacingTests {
    @Test("Requests that need a token wait for one")
    func pacedRequests() {
        var pacer = RequestPacer(at: 0)
        for _ in 0..<Int(RequestPacer.capacity) {
            #expect(pacer.wait(needsToken: true, at: 0) == 0)
            pacer.take(at: 0)
        }
        #expect(pacer.wait(needsToken: true, at: 0) == 1 / HelperEngine.requestsPerSecond)
        #expect(pacer.wait(needsToken: true, at: 1 / HelperEngine.requestsPerSecond) == 0)
    }

    @Test("Requests toward safety go at once, but never more than a few in a row beyond the budget")
    func unpacedStreakIsBounded() {
        var pacer = RequestPacer(at: 0)
        for _ in 0..<Int(RequestPacer.capacity) {
            pacer.take(at: 0)
        }
        for _ in 0..<RequestPacer.maximumUnpacedStreak {
            #expect(pacer.wait(needsToken: false, at: 0) == 0)
            pacer.take(at: 0)
        }
        #expect(pacer.overBudgetStreak == RequestPacer.maximumUnpacedStreak)
        #expect(pacer.wait(needsToken: false, at: 0) > 0)
        #expect(RequestPacer.maximumUnpacedStreak * 4 <= HelperEngine.maximumOverBudgetRequests)

        // A request within the budget ends the streak.
        pacer.take(at: 1)
        #expect(pacer.overBudgetStreak == 0)
    }

    @Test("A burst of holds and releases never exceeds the helper's budget")
    func burstStaysWithinBudget() async throws {
        let rig = HelperRig()
        for _ in 0..<6 {
            _ = try await rig.backend.setMode(.inhibitCharging)
            _ = try await rig.backend.currentMode()
            try await rig.backend.renewHold(.inhibitCharging)
            _ = try await rig.backend.setMode(.normal)
            _ = await rig.backend.capabilities()
            rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        }
        #expect(!rig.events.contains { if case .requestRejected(_, _, .rateLimited) = $0 { true } else { false } })
        #expect(!rig.events.contains { if case .sessionRevoked = $0 { true } else { false } })
    }

    @Test("A session the in-process helper revokes is a closed connection, and the backend reconnects")
    func inProcessRevocation() async throws {
        let clock = TestClock()
        let control = SimulatedChargeControl()
        let transport = InProcessHelperTransport(
            control: control,
            power: StubHelperPower(clock: clock),
            build: 1,
            uptime: { clock.uptime },
            tickInterval: .seconds(3_600)
        )
        // Without pacing, the backend floods its own session.
        let backend = HelperChargingBackend(
            descriptor: HelperRig.descriptor,
            transport: transport,
            uptime: { clock.uptime },
            pause: { _ in },
            activity: RecordingLeaseActivity()
        )
        _ = try await backend.setMode(.inhibitCharging)
        var closed = false
        for _ in 0..<(HelperEngine.requestBurst + HelperEngine.maximumOverBudgetRequests + 5) {
            do {
                _ = try await backend.currentMode()
            } catch {
                if String(describing: error).contains("revoked") {
                    closed = true
                    break
                }
            }
        }
        #expect(closed)
        #expect(control.activeControls.isEmpty)

        clock.advance(by: 10)
        #expect(try await backend.currentMode() == .normal)
        #expect(await backend.reportedModeOrigin() == .releasedByBackend(.connectionLost))
    }

    @Test("The in-process transport closes a revoked session's connection")
    func transportClosesRevokedConnection() async throws {
        let clock = TestClock()
        let transport = InProcessHelperTransport(
            control: SimulatedChargeControl(),
            power: StubHelperPower(clock: clock),
            build: 1,
            uptime: { clock.uptime },
            tickInterval: .seconds(3_600)
        )
        let connection = try await transport.connect()
        #expect(try await connection.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        var thrown: (any Error)?
        for _ in 0...(HelperEngine.requestBurst + HelperEngine.maximumOverBudgetRequests) {
            do {
                _ = try await connection.readState()
            } catch {
                thrown = error
                break
            }
        }
        #expect(thrown as? HelperTransportError == .sessionRevoked)
        await #expect(throws: HelperTransportError.sessionRevoked) {
            try await connection.restoreDefaults()
        }
        // A new connection is served.
        let fresh = try await transport.connect()
        #expect(try await fresh.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
    }
}

@Suite("Helper backend: App Nap")
struct HelperLeaseActivityTests {
    @Test("The activity is held exactly while CellKeeper holds a control")
    func heldWhileHolding() async throws {
        let rig = HelperRig()
        _ = await rig.backend.capabilities()
        #expect(rig.activity.changes.isEmpty)

        _ = try await rig.backend.setMode(.inhibitCharging)
        #expect(rig.activity.changes == [true])
        rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        // Switching keeps holding a control throughout.
        _ = try await rig.backend.setMode(.forceDischarge)
        #expect(rig.activity.changes == [true])
        _ = try await rig.backend.setMode(.normal)
        #expect(rig.activity.changes == [true, false])
    }

    @Test("The activity ends when the helper releases the hold")
    func endsOnRelease() async throws {
        let rig = HelperRig()
        _ = try await rig.backend.setMode(.inhibitCharging)
        rig.clock.advance(by: 901)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(rig.activity.changes == [true, false])
    }

    @Test("A refused hold takes no activity")
    func refusedHold() async {
        let rig = HelperRig()
        rig.power.update { $0.isThermalPressureHigh = true }
        _ = try? await rig.backend.setMode(.forceDischarge)
        #expect(rig.activity.isHolding == false)
    }

    @Test("The process activity is taken once and ended once")
    func processActivity() {
        let activity = ProcessLeaseActivity()
        #expect(!activity.isActive)
        activity.setHolding(true)
        activity.setHolding(true)
        #expect(activity.isActive)
        activity.setHolding(false)
        #expect(!activity.isActive)
        activity.setHolding(false)
        #expect(!activity.isActive)
    }
}
