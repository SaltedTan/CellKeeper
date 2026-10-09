@testable import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper backend")
struct HelperChargingBackendTests {
    /// Holds `mode` through the rig's backend and checks it took effect.
    private func hold(_ mode: ChargeControlMode, _ rig: HelperRig) async throws {
        _ = try await rig.backend.setMode(mode)
        #expect(try await rig.backend.currentMode() == mode)
    }

    /// How many leases on `control` for `seconds` the engine granted
    /// (`granted`) or renewed.
    private func leaseEvents(_ rig: HelperRig, granted: Bool, _ control: HelperControl, seconds: Int) -> Int {
        rig.events.count { event in
            switch event {
            case .leaseGranted(_, let leased, let duration): granted && leased == control && duration == seconds
            case .leaseRenewed(_, let leased, let duration): !granted && leased == control && duration == seconds
            default: false
            }
        }
    }

    // MARK: - Capabilities

    @Test("A simulated helper is Simulated and offers both charging modes")
    func simulatedCapabilities() async {
        let rig = HelperRig()
        let capabilities = await rig.backend.capabilities()
        #expect(capabilities.availability == .simulated)
        #expect(capabilities.style == .chargingModes)
        #expect(capabilities.supportedModes == ChargeControlMode.chargingModes)
    }

    @Test("A helper that changes hardware is experimental")
    func experimentalCapabilities() async {
        let rig = HelperRig(isSimulated: false)
        #expect(await rig.backend.capabilities().availability == .experimental)
    }

    @Test("A helper that cannot be reached is unavailable, and is reached again later")
    func unreachable() async throws {
        let rig = HelperRig()
        rig.transport.isReachable = false
        let capabilities = await rig.backend.capabilities()
        guard case .unavailable(let reason) = capabilities.availability else {
            Issue.record("expected unavailable, got \(capabilities.availability)")
            return
        }
        #expect(reason.contains("cannot be reached"))
        #expect(capabilities.supportedModes.isEmpty)
        // Unknown, like a backend that accepts no requests: not a failure.
        #expect(try await rig.backend.currentMode() == nil)

        rig.transport.isReachable = true
        #expect(await rig.backend.capabilities().availability == .simulated)
    }

    @Test("A helper with an incompatible protocol is unavailable and says to update")
    func incompatibleProtocol() async {
        let rig = HelperRig()
        rig.transport.helloStatus = .incompatibleProtocol
        guard case .unavailable(let reason) = await rig.backend.capabilities().availability else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("protocol version"))
        #expect(reason.contains("Update"))
    }

    @Test("A helper that cannot control this Mac is unavailable: CellKeeper only monitors (R12a)")
    func monitorOnly() async {
        let rig = HelperRig(chargeControl: UnknownHardwareChargeControl())
        guard case .unavailable(let reason) = await rig.backend.capabilities().availability else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("only monitors"))
    }

    @Test("Modes follow the helper's capability bits")
    func capabilityBits() async throws {
        let rig = HelperRig(chargeControl: SimulatedChargeControl(capabilities: [.chargingInhibit]))
        #expect(await rig.backend.capabilities().supportedModes == [.normal, .inhibitCharging])
        await #expect(throws: BackendError.unsupportedMode(.forceDischarge)) {
            try await rig.backend.setMode(.forceDischarge)
        }
        await #expect(throws: BackendError.unsupportedMode(.nativeLimit(percent: 80))) {
            try await rig.backend.setMode(.nativeLimit(percent: 80))
        }
    }

    enum Condition: String, CaseIterable, Sendable {
        case notOnExternalPower, adapterAbsent, adapterPresenceUnknown, thermalPressure, adapterFloor, batteryFloor, powerStateUnavailable, sleep

        func apply(to rig: HelperRig) async {
            switch self {
            case .notOnExternalPower: rig.power.update { $0.isOnExternalPower = false }
            case .adapterAbsent: rig.power.update { $0.isAdapterPresent = false }
            case .adapterPresenceUnknown: rig.power.update { $0.isAdapterPresent = nil }
            case .thermalPressure: rig.power.update { $0.isThermalPressureHigh = true }
            case .adapterFloor: rig.power.update { $0.stateOfCharge = HelperEngine.adapterFloor }
            case .batteryFloor: rig.power.update { $0.stateOfCharge = HelperEngine.batteryFloor }
            case .powerStateUnavailable: rig.power.update { $0.isUnavailable = true }
            case .sleep: await rig.engine.systemWillSleep()
            }
        }

        var remainingModes: Set<ChargeControlMode> {
            switch self {
            // Cutting the adapter makes the Mac report battery power, so
            // only physical presence decides the adapter-disable.
            case .notOnExternalPower: [.normal, .forceDischarge]
            case .adapterAbsent, .adapterPresenceUnknown, .thermalPressure, .adapterFloor, .sleep: [.normal, .inhibitCharging]
            case .batteryFloor, .powerStateUnavailable: [.normal]
            }
        }
    }

    @Test("Modes a helper interlock blocks are not offered, so the policy refuses them instead of counting failures", arguments: Condition.allCases)
    func interlockBlockedModes(condition: Condition) async {
        let rig = HelperRig()
        #expect(await rig.backend.capabilities().supportedModes == ChargeControlMode.chargingModes)
        await condition.apply(to: rig)
        let capabilities = await rig.backend.capabilities()
        #expect(capabilities.availability == .simulated)
        #expect(capabilities.supportedModes == condition.remainingModes)
    }

    // MARK: - Reading the mode

    @Test("The mode is read back from the helper's controls")
    func modeMapping() async throws {
        let rig = HelperRig()
        #expect(try await rig.backend.currentMode() == .normal)
        try await hold(.inhibitCharging, rig)
        rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        try await hold(.forceDischarge, rig)
        #expect(rig.control.activeControls == [.adapterDisabled])
        #expect(HelperChargingBackend.mode(for: [.chargingInhibited, .adapterDisabled]) == nil)
        #expect(HelperChargingBackend.mode(for: []) == .normal)
    }

    @Test("A read-back the helper cannot make is an error, never a mode")
    func readBackFailure() async {
        let rig = HelperRig()
        _ = await rig.backend.capabilities()
        // The check's read, the restore's read before it, and its
        // read-back all fail.
        rig.control.failNextReadBacks(3)
        await #expect(throws: BackendError.self) {
            try await rig.backend.currentMode()
        }
    }

    @Test("A hold the helper cleared after a hardware error is a failure, not a release")
    func clearedAfterHardwareError() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        // The helper's check cannot read back, so it restores defaults (R1).
        rig.control.failNextReadBacks(1)
        do {
            _ = try await rig.backend.currentMode()
            Issue.record("expected a failure")
        } catch {
            #expect(String(describing: error).contains("hardware error"))
        }
        #expect(rig.control.activeControls.isEmpty)
    }

    @Test("A hold that ended under the helper's hardware-fault interlock is a failure, not a routine release")
    func clearedUnderHardwareFault() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        // A tick's check cannot read back; the restore clears the control
        // but cannot read before or confirm it either, so the helper raises
        // hardwareFault.
        rig.control.failNextReadBacks(3)
        await rig.engine.tick()
        #expect(rig.control.activeControls.isEmpty)
        #expect(await rig.observedState().interlocks.contains(.hardwareFault))
        do {
            _ = try await rig.backend.currentMode()
            Issue.record("expected a failure")
        } catch {
            #expect(String(describing: error).contains("hardware error"))
        }
    }

    // MARK: - Setting modes

    @Test("Inhibiting charging takes the 15-minute lease and activates the control")
    func inhibit() async throws {
        let rig = HelperRig()
        #expect(try await rig.backend.setMode(.inhibitCharging) == .simulated)
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(leaseEvents(rig, granted: true, .chargingInhibited, seconds: HelperControl.chargingInhibited.maximumLeaseSeconds) == 1)
        #expect(HelperControl.chargingInhibited.maximumLeaseSeconds == 900)
        #expect(try await rig.backend.currentMode() == .inhibitCharging)
    }

    @Test("Discharging takes the 2-minute adapter lease and disables the adapter")
    func discharge() async throws {
        let rig = HelperRig()
        #expect(try await rig.backend.setMode(.forceDischarge) == .simulated)
        #expect(rig.control.activeControls == [.adapterDisabled])
        #expect(leaseEvents(rig, granted: true, .adapterDisabled, seconds: 120) == 1)
    }

    @Test("Switching between inhibit and discharge sets the new control before clearing the old one")
    func switchingOrder() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        let afterInhibit = rig.control.writes.count
        rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        try await hold(.forceDischarge, rig)
        #expect(Array(rig.control.writes.dropFirst(afterInhibit)) == [
            .apply(.adapterDisabled, active: true),
            .apply(.chargingInhibited, active: false),
        ])
        #expect(rig.events.contains { if case .leaseEnded(_, .chargingInhibited, .released) = $0 { true } else { false } })

        let afterDischarge = rig.control.writes.count
        rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        try await hold(.inhibitCharging, rig)
        #expect(Array(rig.control.writes.dropFirst(afterDischarge)) == [
            .apply(.chargingInhibited, active: true),
            .apply(.adapterDisabled, active: false),
        ])
        #expect((await rig.observedState()).adapterDisabledLeaseSeconds == 0)
    }

    @Test("Normal releases CellKeeper's controls and leases, and restores nothing else")
    func normalReleases() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        #expect(try await rig.backend.setMode(.normal) == .simulated)
        #expect(rig.control.activeControls.isEmpty)
        let state = await rig.observedState()
        #expect(state.chargingInhibitedLeaseSeconds == 0)
        #expect(rig.events.contains { if case .leaseEnded(_, .chargingInhibited, .released) = $0 { true } else { false } })
        // Only the engine's own restore at start.
        #expect(rig.control.writes.filter { $0 == .restoreDefaults }.count == 1)
        #expect(try await rig.backend.currentMode() == .normal)
    }

    @Test("A helper that changes hardware reports applied, then unchanged when already in effect")
    func realOutcomes() async throws {
        let rig = HelperRig(isSimulated: false)
        #expect(try await rig.backend.setMode(.inhibitCharging) == .applied)
        #expect(try await rig.backend.setMode(.inhibitCharging) == .unchanged)
        #expect(try await rig.backend.setMode(.normal) == .applied)
        #expect(try await rig.backend.setMode(.normal) == .unchanged)
    }

    @Test("A simulated helper never reports applied or unchanged")
    func simulatedOutcomes() async throws {
        let rig = HelperRig()
        for mode in [ChargeControlMode.inhibitCharging, .inhibitCharging, .normal, .normal] {
            #expect(try await rig.backend.setMode(mode) == .simulated)
        }
    }

    @Test("A read-back that does not show the requested control is a verification failure")
    func verificationFailure() async throws {
        let rig = HelperRig()
        _ = await rig.backend.capabilities()
        rig.transport.latest?.reportMismatchAfterNextActivation()
        await #expect(throws: BackendError.verificationFailed(expected: .inhibitCharging, actual: .normal)) {
            try await rig.backend.setMode(.inhibitCharging)
        }
        // What CellKeeper set is still released by the fallback.
        _ = try await rig.backend.setMode(.normal)
        #expect(rig.control.activeControls.isEmpty)
    }

    @Test("An activation an interlock refuses fails without being taken for an outside change")
    func interlockRefusal() async {
        let rig = HelperRig()
        _ = await rig.backend.capabilities()
        rig.power.update { $0.isThermalPressureHigh = true }
        do {
            _ = try await rig.backend.setMode(.forceDischarge)
            Issue.record("expected a refusal")
        } catch let error as BackendError {
            guard case .operationFailed(let message) = error else {
                Issue.record("expected operationFailed, got \(error)")
                return
            }
            #expect(message.contains("thermal"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - Leases

    @Test("Renewing extends the lease, so the hold outlasts its first grant")
    func renewal() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        rig.clock.advance(by: 600)
        try await rig.backend.renewHold(.inhibitCharging)
        #expect(leaseEvents(rig, granted: false, .chargingInhibited, seconds: 900) == 1)
        rig.clock.advance(by: 600)
        #expect(try await rig.backend.currentMode() == .inhibitCharging)
        #expect(await rig.backend.reportedModeOrigin() == nil)
    }

    @Test("Renewing the adapter-disable renews its 2-minute lease")
    func adapterRenewal() async throws {
        let rig = HelperRig()
        try await hold(.forceDischarge, rig)
        rig.clock.advance(by: 100)
        try await rig.backend.renewHold(.forceDischarge)
        #expect(leaseEvents(rig, granted: false, .adapterDisabled, seconds: 120) == 1)
        rig.clock.advance(by: 100)
        #expect(try await rig.backend.currentMode() == .forceDischarge)
    }

    @Test("Without renewal the lease lapses, and the helper's release is reported as such (R3)")
    func lapse() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        rig.clock.advance(by: 901)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.reportedModeOrigin() == .releasedByBackend(.leaseExpired))
        #expect(rig.control.activeControls.isEmpty)
        // The report stays until CellKeeper's next request.
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.reportedModeOrigin() == .releasedByBackend(.leaseExpired))
        _ = try await rig.backend.setMode(.normal)
        _ = try await rig.backend.currentMode()
        #expect(await rig.backend.reportedModeOrigin() == nil)
    }

    @Test("A renewal after the lease's deadline does not start a new lease on a cleared control")
    func lateRenewal() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        rig.clock.advance(by: 901)
        try await rig.backend.renewHold(.inhibitCharging)
        #expect(leaseEvents(rig, granted: false, .chargingInhibited, seconds: 900) == 0)
        #expect(leaseEvents(rig, granted: true, .chargingInhibited, seconds: 900) == 1)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.reportedModeOrigin() == .releasedByBackend(.leaseExpired))
    }

    @Test("Renewing a mode CellKeeper does not hold fails; renewing normal does nothing")
    func renewalWithoutHold() async throws {
        let rig = HelperRig()
        try await rig.backend.renewHold(.normal)
        await #expect(throws: BackendError.self) {
            try await rig.backend.renewHold(.inhibitCharging)
        }
    }

    struct InterlockRelease: Sendable, CustomTestStringConvertible {
        var held: ChargeControlMode
        var condition: Condition
        var wording: String
        var testDescription: String { "\(held) cleared by \(condition.rawValue)" }
    }

    static let interlockReleases = [
        InterlockRelease(held: .inhibitCharging, condition: .batteryFloor, wording: "10% floor"),
        InterlockRelease(held: .inhibitCharging, condition: .notOnExternalPower, wording: "not on external power"),
        InterlockRelease(held: .inhibitCharging, condition: .powerStateUnavailable, wording: "power reading"),
        InterlockRelease(held: .forceDischarge, condition: .adapterAbsent, wording: "no power adapter"),
        InterlockRelease(held: .forceDischarge, condition: .adapterPresenceUnknown, wording: "cannot tell"),
        InterlockRelease(held: .forceDischarge, condition: .adapterFloor, wording: "floor for running"),
        InterlockRelease(held: .forceDischarge, condition: .thermalPressure, wording: "thermal"),
        InterlockRelease(held: .forceDischarge, condition: .sleep, wording: "sleep"),
    ]

    @Test("A hold an interlock of the helper cleared is reported as the helper's release", arguments: interlockReleases)
    func interlockRelease(release: InterlockRelease) async throws {
        let rig = HelperRig()
        try await hold(release.held, rig)
        await release.condition.apply(to: rig)
        #expect(try await rig.backend.currentMode() == .normal)
        guard case .releasedByBackend(.interlock(let interlocks))? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected a release by an interlock, got \(String(describing: await rig.backend.reportedModeOrigin()))")
            return
        }
        #expect(interlocks.contains(release.wording))
    }

    // MARK: - Connections

    @Test("After a transport failure the backend reconnects and reads the state, never assuming it")
    func reconnect() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        rig.transport.latest?.failNextRequests(1)
        await #expect(throws: BackendError.self) {
            try await rig.backend.currentMode()
        }
        // The helper ended the session and cleared what it held (R1).
        #expect(rig.control.activeControls.isEmpty)

        #expect(try await rig.backend.currentMode() == .normal)
        #expect(rig.transport.connections.count == 2)
        #expect(await rig.backend.reportedModeOrigin() == .releasedByBackend(.connectionLost))
        rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(try await rig.backend.setMode(.inhibitCharging) == .simulated)
    }

    @Test("A session the helper no longer knows is replaced, and the state read afresh")
    func sessionLost() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        await rig.transport.latest?.session.invalidate()
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(rig.transport.connections.count == 2)
        #expect(await rig.backend.reportedModeOrigin() == .releasedByBackend(.connectionLost))
    }

    @Test("Releasing the backend ends its session, so the helper clears what it held")
    func releasedBackendEndsSession() async throws {
        let clock = TestClock()
        let control = SimulatedChargeControl()
        let engine = HelperEngine(control: control, power: StubHelperPower(clock: clock), build: 1, uptime: { clock.uptime }, events: { _ in })
        var backend: HelperChargingBackend? = HelperChargingBackend(
            descriptor: HelperRig.descriptor,
            transport: TestHelperTransport(engine: engine),
            uptime: { clock.uptime },
            pause: { clock.advance(by: $0) }
        )
        _ = try await backend?.setMode(.inhibitCharging)
        #expect(control.activeControls == [.chargingInhibited])
        backend = nil
        for _ in 0..<200 where !control.activeControls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(control.activeControls.isEmpty)
    }

    @Test("Requests are paced to stay within the helper's request budget")
    func pacing() async throws {
        let rig = HelperRig()
        let start = rig.clock.uptime
        for _ in 0..<30 {
            _ = try await rig.backend.currentMode()
        }
        #expect(!rig.events.contains { if case .requestRejected(_, _, .rateLimited) = $0 { true } else { false } })
        // 31 requests with a budget of 9 and 2 more per second.
        #expect(rig.clock.uptime - start >= 10)
    }

    // MARK: - Outside changes

    @Test("An outside change the helper found is reported, and blocks CellKeeper's writes (R27)")
    func outsideChange() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        #expect(try await rig.backend.currentMode() == .normal)
        guard case .changedOutside(let detail)? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected an outside change")
            return
        }
        #expect(detail.contains("another tool"))

        let writes = rig.control.writes.count
        rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        await #expect(throws: BackendError.changedOutside(expected: .normal, found: .normal)) {
            try await rig.backend.setMode(.inhibitCharging)
        }
        // Nothing is active, so normal is in effect, and confirmed without
        // writing or restoring defaults.
        #expect(try await rig.backend.setMode(.normal) == .simulated)
        #expect(rig.control.writes.count == writes)
        #expect(await rig.observedState().interlocks.contains(.externalModification))
    }

    @Test("A control another tool keeps active is reported and never overridden by normal (R26)")
    func foreignControlKept() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        _ = try? await rig.backend.currentMode()
        // The helper restored defaults once; the other tool sets its control
        // again, and the helper no longer fights it.
        rig.control.simulateOutsideChange(.chargingInhibited, active: true)
        #expect(try await rig.backend.currentMode() == .inhibitCharging)
        guard case .changedOutside? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected an outside change")
            return
        }
        let writes = rig.control.writes.count
        await #expect(throws: BackendError.changedOutside(expected: .normal, found: .inhibitCharging)) {
            try await rig.backend.setMode(.normal)
        }
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(rig.control.writes.count == writes)
    }

    @Test("A control another client of the helper set is reported, never cleared")
    func otherClientsControl() async throws {
        let rig = HelperRig()
        _ = await rig.backend.capabilities()
        let other = await rig.engine.openSession()
        _ = await other.hello(clientProtocolVersion: HelperProtocolVersion.current)
        _ = await other.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await other.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)

        #expect(try await rig.backend.currentMode() == .inhibitCharging)
        guard case .changedOutside(let detail)? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected an outside change")
            return
        }
        #expect(detail.contains("did not set"))
        await #expect(throws: BackendError.changedOutside(expected: .normal, found: .inhibitCharging)) {
            try await rig.backend.setMode(.normal)
        }
        await #expect(throws: BackendError.self) {
            try await rig.backend.setMode(.forceDischarge)
        }
        #expect(rig.control.activeControls == [.chargingInhibited])
    }

    @Test("Clearing the fault restores the helper's defaults when it waits for that, and only then")
    func resetAfterFault() async throws {
        let rig = HelperRig()
        try await hold(.inhibitCharging, rig)
        var writes = rig.control.writes.count
        try await rig.backend.resetAfterFault()
        // Nothing to acknowledge: CellKeeper's own hold stays.
        #expect(rig.control.writes.count == writes)
        #expect(rig.control.activeControls == [.chargingInhibited])

        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        _ = try await rig.backend.currentMode()
        rig.control.simulateOutsideChange(.chargingInhibited, active: true)
        writes = rig.control.writes.count
        try await rig.backend.resetAfterFault()
        #expect(Array(rig.control.writes.dropFirst(writes)) == [.restoreDefaults])
        #expect(rig.control.activeControls.isEmpty)
        #expect(await rig.observedState().interlocks.isEmpty)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.reportedModeOrigin() == nil)
        rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(try await rig.backend.setMode(.inhibitCharging) == .simulated)
    }
}
