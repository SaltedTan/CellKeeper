import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// A simulated backend that records renewals and can fail them.
actor RenewalProbeBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "renewal-probe", displayName: "Renewal probe", summary: "")
    private var mode: ChargeControlMode = .normal
    private var pendingRenewalFailures = 0
    private var pendingModeReadFailures = 0
    private(set) var renewals: [ChargeControlMode] = []
    private(set) var requests: [ChargeControlMode] = []

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)
    }

    func currentMode() throws -> ChargeControlMode? {
        if pendingModeReadFailures > 0 {
            pendingModeReadFailures -= 1
            throw BackendError.operationFailed("injected mode-read failure")
        }
        return mode
    }

    func setMode(_ newMode: ChargeControlMode) -> ControlOutcome {
        requests.append(newMode)
        mode = newMode
        return .simulated
    }

    func renewHold(_ held: ChargeControlMode) throws {
        renewals.append(held)
        if pendingRenewalFailures > 0 {
            pendingRenewalFailures -= 1
            throw BackendError.operationFailed("injected renewal failure")
        }
    }

    func failNextRenewals(_ count: Int) {
        pendingRenewalFailures += count
    }

    func failNextModeReads(_ count: Int) {
        pendingModeReadFailures += count
    }

    func simulateExternalChange(to newMode: ChargeControlMode) {
        mode = newMode
    }
}

@Suite("Charge controller: hold renewal")
struct HoldRenewalTests {
    let clock = TestClock()

    private func makeController(percent: Int, backend: any ChargingBackend) -> (ChargeController, StubTelemetry) {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: percent), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: backend, settings: .default, now: { clock.now }, uptime: { clock.uptime })
        return (controller, telemetry)
    }

    /// Takes a first reading, then a second, distinct one a minute later, so
    /// that a charge at or above the limit is acted on (rule R14).
    @discardableResult
    private func confirmedEvaluation(_ controller: ChargeController) async -> ControllerStatus {
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        return await controller.evaluate(.periodic)
    }

    @Test("Every evaluation that keeps a confirmed hold renews it, including those that change nothing")
    func renewedEveryEvaluation() async {
        let backend = RenewalProbeBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        let reading = await controller.evaluate(.launch)
        #expect(reading.decision?.desiredMode == .normal)
        #expect(await backend.renewals.isEmpty)
        clock.advance(by: 60)
        let first = await controller.evaluate(.periodic)
        #expect(first.decision?.action == .disableCharging)
        #expect(await backend.renewals == [.inhibitCharging])
        for _ in 0..<2 {
            clock.advance(by: 60)
            let again = await controller.evaluate(.periodic)
            #expect(again.decision?.action == .noAction)
        }
        #expect(await backend.renewals == [.inhibitCharging, .inhibitCharging, .inhibitCharging])
        #expect(await backend.requests == [.inhibitCharging])
    }

    @Test("No renewal once the policy wants another mode")
    func noRenewalForOtherMode() async {
        let backend = RenewalProbeBackend()
        let (controller, telemetry) = makeController(percent: 85, backend: backend)
        await confirmedEvaluation(controller)
        await telemetry.set(snapshot(percent: 70))
        let relaxed = await controller.evaluate(.periodic)
        #expect(relaxed.decision?.desiredMode == .normal)
        #expect(await backend.requests == [.inhibitCharging, .normal])
        #expect(await backend.renewals == [.inhibitCharging])
    }

    @Test("No renewal while a different mode is wanted, even if the hold stays in effect")
    func noRenewalWhileOtherModeWaits() async {
        let backend = RenewalProbeBackend()
        let (controller, _) = makeController(percent: 90, backend: backend)
        await confirmedEvaluation(controller)
        clock.advance(by: 5)
        // Discharging is a restricting change within a minute of the last one.
        let waiting = await controller.startDischargeToLimit()
        #expect(waiting.decision?.desiredMode == .forceDischarge)
        guard case .refuse(.rateLimited)? = waiting.decision?.action else {
            Issue.record("expected a rate-limited refusal, got \(String(describing: waiting.decision?.action))")
            return
        }
        #expect(waiting.currentMode == .inhibitCharging)
        #expect(await backend.renewals == [.inhibitCharging])
    }

    @Test("Normal charging is never renewed")
    func noRenewalOfNormal() async {
        let backend = RenewalProbeBackend()
        let (controller, _) = makeController(percent: 50, backend: backend)
        for _ in 0..<3 {
            await controller.evaluate(.periodic)
            clock.advance(by: 60)
        }
        #expect(await backend.renewals.isEmpty)
    }

    @Test("No renewal in an evaluation that could not read the hold back")
    func noRenewalWhenUnread() async {
        let backend = RenewalProbeBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        await confirmedEvaluation(controller)
        await backend.failNextModeReads(1)
        clock.advance(by: 60)
        let status = await controller.evaluate(.periodic)
        #expect(status.decision?.reason == .releaseRequired(.stateUnverified))
        #expect(await backend.renewals == [.inhibitCharging])
    }

    @Test("No renewal while the backend is faulted")
    func noRenewalWhileFaulted() async {
        let backend = RenewalProbeBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        await confirmedEvaluation(controller)
        await backend.simulateExternalChange(to: .forceDischarge)
        clock.advance(by: 60)
        let faulted = await controller.evaluate(.periodic)
        #expect(faulted.isBackendFaulted)
        for _ in 0..<2 {
            clock.advance(by: 60)
            await controller.evaluate(.periodic)
        }
        #expect(await backend.renewals == [.inhibitCharging])
    }

    @Test("A failed renewal counts as a failure and requests normal charging at once")
    func failedRenewal() async {
        let backend = RenewalProbeBackend()
        await backend.failNextRenewals(1)
        let (controller, _) = makeController(percent: 85, backend: backend)
        let status = await confirmedEvaluation(controller)
        #expect(await backend.requests == [.inhibitCharging, .normal])
        #expect(status.consecutiveFailures == 1)
        #expect(status.currentMode == .normal)
        guard case .failed(let message)? = status.lastExecution?.result else {
            Issue.record("expected a failed execution, got \(String(describing: status.lastExecution))")
            return
        }
        #expect(message.contains("injected renewal failure"))
        #expect(status.events.contains { $0.kind == .failure && $0.message.contains("Could not renew") })
    }

    @Test("Backends whose holds do not lapse request nothing more while holding")
    func nonLeasingBackendsUnaffected() async {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        for _ in 0..<3 {
            await controller.evaluate(.periodic)
            clock.advance(by: 60)
        }
        #expect(await backend.requestedModes == [.inhibitCharging])
        #expect(await controller.status.consecutiveFailures == 0)
    }
}

@Suite("Charge controller with the helper")
struct HelperControllerTests {
    @Test("A limit below 80% is held through the helper")
    func lowLimit() async throws {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 35, settings: ChargingSettings.default.withChargeLimit(30))
        let status = await rig.confirmedEvaluation(controller)
        #expect(status.decision?.state == .holding)
        #expect(status.currentMode == .inhibitCharging)
        #expect(status.lastExecution?.result == .simulated)
        #expect(rig.control.activeControls == [.chargingInhibited])
    }

    @Test("A helper that cannot be reached is unavailable and never counts failures")
    func unreachableHelper() async {
        let rig = HelperRig()
        rig.transport.isReachable = false
        let (controller, _) = rig.controller(percent: 85)
        await controller.evaluate(.launch)
        rig.clock.advance(by: 60)
        for _ in 0..<4 {
            let status = await controller.evaluate(.periodic)
            #expect(status.consecutiveFailures == 0)
            guard case .refuse(.controlUnavailable)? = status.decision?.action else {
                Issue.record("expected an unavailable refusal, got \(String(describing: status.decision?.action))")
                return
            }
            rig.clock.advance(by: 60)
        }
        // Switching away needs nothing restored.
        let switched = await controller.switchBackend(to: MockChargingBackend())
        #expect(switched.backend.identifier == "simulated")
    }

    @Test("While evaluations keep running, the lease is renewed and never lapses")
    func renewedWhileRunning() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        for _ in 0..<10 {
            rig.clock.advance(by: 300)
            let status = await controller.evaluate(.periodic)
            #expect(status.currentMode == .inhibitCharging)
        }
        // 3,000 s on a 900 s lease.
        #expect(!rig.events.contains { if case .leaseEnded(_, _, .expired) = $0 { true } else { false } })
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(rig.control.writes.filter { $0 == .apply(.chargingInhibited, active: true) }.count == 1)
    }

    @Test("A stalled loop lets the lease lapse; the release is logged, not a fault, and the hold is taken again (R3)")
    func lapse() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        rig.clock.advance(by: 901)
        let status = await controller.evaluate(.periodic)
        #expect(rig.events.contains { if case .leaseEnded(_, .chargingInhibited, .expired) = $0 { true } else { false } })
        #expect(!status.isBackendFaulted)
        #expect(status.consecutiveFailures == 0)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("itself") && $0.message.contains("lease expired") })
        #expect(!status.events.contains { $0.message.contains("outside CellKeeper") })
        #expect(status.currentMode == .inhibitCharging)
    }

    @Test("A hold the helper's interlock cleared is logged, not a fault", arguments: HelperChargingBackendTests.interlockReleases)
    func interlockRelease(release: HelperChargingBackendTests.InterlockRelease) async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: release.held == .forceDischarge ? 90 : 85)
        let held = release.held == .forceDischarge ? await controller.startDischargeToLimit() : await rig.confirmedEvaluation(controller)
        #expect(held.currentMode == release.held)

        await release.condition.apply(to: rig)
        rig.clock.advance(by: 5)
        let status = await controller.evaluate(.periodic)
        #expect(!status.isBackendFaulted)
        #expect(status.consecutiveFailures == 0)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("itself") && $0.message.contains(release.wording) })
        #expect(!status.events.contains { $0.message.contains("outside CellKeeper") })
        // The blocked mode is refused as unsupported, never as a failure.
        #expect(!status.capabilities.supports(release.held))
    }

    @Test("A change made outside CellKeeper still faults at once, and is logged once (R27)")
    func outsideChangeFaults() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        let held = await rig.confirmedEvaluation(controller)
        #expect(held.currentMode == .inhibitCharging)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        rig.clock.advance(by: 5)
        let faulted = await controller.evaluate(.periodic)
        #expect(faulted.isBackendFaulted)
        #expect(faulted.currentMode == .normal)
        for _ in 0..<3 {
            rig.clock.advance(by: 60)
            await controller.evaluate(.periodic)
        }
        let status = await controller.status
        #expect(status.isBackendFaulted)
        #expect(status.events.filter { $0.message.contains("changed outside CellKeeper") }.count == 1)
        // The helper's own single restore, and nothing from CellKeeper.
        #expect(rig.control.writes.filter { $0 == .restoreDefaults }.count == 2)
        #expect(rig.control.activeControls.isEmpty)
    }

    @Test("An outside change faults even while CellKeeper holds nothing")
    func outsideChangeWithoutHold() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 50)
        let first = await controller.evaluate(.launch)
        #expect(first.currentMode == .normal)
        rig.control.simulateOutsideChange(.chargingInhibited, active: true)
        rig.clock.advance(by: 5)
        let status = await controller.evaluate(.periodic)
        #expect(status.isBackendFaulted)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("changed outside CellKeeper") })
    }

    @Test("A control another tool keeps active is never overridden; clearing the fault restores defaults once")
    func foreignControlUntilFaultCleared() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        rig.clock.advance(by: 5)
        await controller.evaluate(.periodic)
        // The other tool sets its control again; the helper no longer fights it.
        rig.control.simulateOutsideChange(.chargingInhibited, active: true)
        for _ in 0..<3 {
            rig.clock.advance(by: 61)
            let status = await controller.evaluate(.periodic)
            #expect(status.isBackendFaulted)
            // Normal is requested and refused as an outside change, so it is
            // never reported as in effect.
            #expect(status.currentMode != .normal)
            #expect(status.lastExecution?.result == .failed(String(describing: BackendError.changedOutside(expected: .normal, found: .inhibitCharging))))
        }
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(rig.control.writes.filter { $0 == .restoreDefaults }.count == 2)

        let cleared = await controller.resetBackendFault()
        #expect(rig.control.writes.filter { $0 == .restoreDefaults }.count == 3)
        #expect(!cleared.isBackendFaulted)
        #expect(cleared.consecutiveFailures == 0)
        // CellKeeper's own hold, taken again after the user's acknowledgement.
        #expect(cleared.currentMode == .inhibitCharging)
        #expect(await rig.observedState().interlocks.isEmpty)
    }
}
