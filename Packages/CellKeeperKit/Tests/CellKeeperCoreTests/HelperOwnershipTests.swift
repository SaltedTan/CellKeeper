import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

private let adapter = HelperControl.adapterDisabled.rawValue

/// Another client of the helper, introduced.
private func otherClient(_ rig: HelperRig) async -> HelperSession {
    let session = await rig.engine.openSession()
    _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
    return session
}

private func managementOff() -> ChargingSettings {
    var settings = ChargingSettings.default
    settings.isManagementEnabled = false
    return settings
}

@Suite("Helper backend: ownership from the helper's history")
struct HelperOwnershipTests {
    enum Action: String, CaseIterable, Sendable {
        case evaluation, managementOff, backendSwitch
    }

    @Test("A control another client set after CellKeeper's lease ran out is never cleared by CellKeeper", arguments: Action.allCases)
    func leaseHandoff(action: Action) async throws {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 90)
        #expect(await controller.startDischargeToLimit().currentMode == .forceDischarge)
        // CellKeeper's adapter lease runs out before it reads again; another
        // client takes the adapter-disable.
        rig.clock.advance(by: 121)
        let other = await otherClient(rig)
        #expect(await other.acquireOrRenewLease(control: adapter, seconds: 120).status == .ok)
        #expect(await other.setControl(control: adapter, active: true) == .ok)
        let writes = rig.control.writes.count

        switch action {
        case .evaluation:
            rig.clock.advance(by: 5)
            let status = await controller.evaluate(.periodic)
            #expect(status.isBackendFaulted)
            #expect(status.events.contains { $0.message.contains("changed outside CellKeeper") })
        case .managementOff:
            rig.clock.advance(by: 5)
            let status = try await controller.apply(settings: managementOff())
            #expect(status.decision?.state == .unmanaged)
        case .backendSwitch:
            let status = await controller.switchBackend(to: MockChargingBackend())
            #expect(status.pendingBackend?.identifier == "simulated")
        }
        // The other client's control and lease are untouched.
        #expect(rig.control.activeControls == [.adapterDisabled])
        #expect(!rig.control.writes.dropFirst(writes).contains(.apply(.adapterDisabled, active: false)))
        #expect(!rig.control.writes.dropFirst(writes).contains(.restoreDefaults))
        #expect(await other.readState().isLeaseHolder)
    }

    @Test("Another client's deactivation stays an outside change after CellKeeper's lease runs out")
    func outsideDeactivationThenExpiry() async throws {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 90)
        #expect(await controller.startDischargeToLimit().currentMode == .forceDischarge)
        #expect(await otherClient(rig).setControl(control: adapter, active: false) == .ok)
        rig.clock.advance(by: 121)
        let status = await controller.evaluate(.periodic)
        #expect(status.isBackendFaulted)
        #expect(status.events.contains { $0.message.contains("another client of the helper cleared") })
        #expect(!status.events.contains { $0.message.contains("lease expired") })
        // Discharging is not asked for again.
        #expect(rig.control.writes.filter { $0 == .apply(.adapterDisabled, active: true) }.count == 1)
    }

    @Test("Another client's deactivation stays an outside change after CellKeeper's session ends")
    func outsideDeactivationThenSessionLoss() async throws {
        let rig = HelperRig()
        _ = try await rig.backend.setMode(.forceDischarge)
        #expect(await otherClient(rig).setControl(control: adapter, active: false) == .ok)
        await rig.transport.latest?.session.invalidate()
        #expect(try await rig.backend.currentMode() == .normal)
        guard case .changedOutside(let detail)? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected an outside change, got \(String(describing: await rig.backend.reportedModeOrigin()))")
            return
        }
        #expect(detail.contains("another client"))
    }

    enum TransientCondition: String, CaseIterable, Sendable {
        case thermalPressure, adapterAbsent, adapterPresenceUnknown, powerStateUnavailable, sleep

        func raise(on rig: HelperRig) async {
            switch self {
            case .thermalPressure: rig.power.update { $0.isThermalPressureHigh = true }
            case .adapterAbsent: rig.power.update { $0.isAdapterPresent = false }
            case .adapterPresenceUnknown: rig.power.update { $0.isAdapterPresent = nil }
            case .powerStateUnavailable: rig.power.update { $0.isUnavailable = true }
            case .sleep: await rig.engine.systemWillSleep()
            }
        }

        func lift(on rig: HelperRig) async {
            switch self {
            case .thermalPressure: rig.power.update { $0.isThermalPressureHigh = false }
            case .adapterAbsent, .adapterPresenceUnknown: rig.power.update { $0.isAdapterPresent = true }
            case .powerStateUnavailable: rig.power.update { $0.isUnavailable = false }
            case .sleep: await rig.engine.systemDidWake()
            }
        }

        var wording: String {
            switch self {
            case .thermalPressure: "thermal"
            case .adapterAbsent: "no power adapter"
            case .adapterPresenceUnknown: "cannot tell"
            case .powerStateUnavailable: "power reading"
            case .sleep: "sleep"
            }
        }
    }

    @Test("An interlock that cleared a hold and lifted before the next read is still the helper's release", arguments: TransientCondition.allCases)
    func transientInterlock(condition: TransientCondition) async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 90)
        #expect(await controller.startDischargeToLimit().currentMode == .forceDischarge)
        await condition.raise(on: rig)
        await rig.engine.tick()
        #expect(rig.control.activeControls.isEmpty)
        await condition.lift(on: rig)
        rig.clock.advance(by: 5)
        let status = await controller.evaluate(.periodic)
        #expect(!status.isBackendFaulted)
        #expect(status.consecutiveFailures == 0)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("itself") && $0.message.contains(condition.wording) })
        #expect(!status.events.contains { $0.message.contains("outside CellKeeper") })
    }

    enum FailurePoint: Int, CaseIterable, Sendable {
        // Requests of the evaluation that turns management off: two reads,
        // then the release's read, deactivation, lease release and final
        // read, then the controller's read-back.
        case afterDeactivation = 4
        case afterLeaseRelease = 5
        case afterFinalRead = 6
    }

    @Test("CellKeeper's own release is recognised after a lost connection, never as an outside change", arguments: FailurePoint.allCases)
    func ownReleaseAcrossReconnect(point: FailurePoint) async throws {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        rig.transport.latest?.failRequest(after: point.rawValue)
        rig.clock.advance(by: 5)
        _ = try await controller.apply(settings: managementOff())
        #expect(rig.control.activeControls.isEmpty)

        rig.clock.advance(by: 61)
        let status = await controller.evaluate(.periodic)
        #expect(!status.isBackendFaulted)
        #expect(status.currentMode == .normal)
        #expect(!status.events.contains { $0.message.contains("outside CellKeeper") })
        #expect(rig.transport.connections.count == 2)
    }
}

@Suite("Helper backend: unresolved holds")
struct HelperUnresolvedHoldTests {
    @Test("While the helper cannot confirm a release, a backend switch waits; it completes once the restarted helper shows defaults")
    func switchWaitsForConfirmedRelease() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        // The helper shuts down, and its restore fails.
        rig.control.failNextRestores(1)
        #expect(await rig.engine.terminate() == .hardwareError)
        #expect(await rig.engine.isSafeToExit == false)
        #expect(rig.control.activeControls == [.chargingInhibited])

        rig.clock.advance(by: 5)
        let pending = await controller.switchBackend(to: MockChargingBackend())
        #expect(pending.backend.identifier == HelperRig.descriptor.identifier)
        #expect(pending.pendingBackend?.identifier == "simulated")
        #expect(!pending.events.contains { $0.message.contains("nothing to restore") })
        for _ in 0..<2 {
            rig.clock.advance(by: 61)
            let status = await controller.evaluate(.periodic)
            #expect(status.pendingBackend != nil)
            #expect(status.capabilities.supportedModes == [.normal])
        }

        // launchd starts the helper again; its start restores defaults (R2).
        rig.transport.relaunch()
        rig.clock.advance(by: 61)
        let done = await controller.evaluate(.periodic)
        #expect(done.backend.identifier == "simulated")
        #expect(done.pendingBackend == nil)
        #expect(rig.control.activeControls.isEmpty)
        #expect(done.events.contains { $0.message.contains("stopped or restarted") })
    }

    @Test("A hold the helper cannot be asked about keeps normal requested, and the activity ends with the session")
    func unreachableHold() async throws {
        let rig = HelperRig()
        _ = try await rig.backend.setMode(.inhibitCharging)
        #expect(rig.activity.changes == [true])

        rig.transport.latest?.failNextRequests(1)
        rig.transport.isReachable = false
        await #expect(throws: BackendError.self) {
            try await rig.backend.currentMode()
        }
        #expect(rig.activity.changes == [true, false])
        do {
            _ = try await rig.backend.currentMode()
            Issue.record("expected an unknown mode")
        } catch {
            #expect(String(describing: error).contains("may still have"))
        }
        let capabilities = await rig.backend.capabilities()
        #expect(capabilities.availability.acceptsRequests)
        #expect(capabilities.supportedModes == [.normal])
        await #expect(throws: BackendError.self) {
            try await rig.backend.setMode(.normal)
        }
        #expect(rig.activity.changes == [true, false])
    }
}

@Suite("Helper backend: helper failures")
struct HelperFailureReportTests {
    @Test("A failed write faults at once as needing acknowledgement, never as a benign expiry; clearing the fault restores defaults")
    func writeFailedFaultsAtOnce() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        // The clear at lease expiry fails.
        rig.control.failNextApplies(1)
        rig.clock.advance(by: 901)
        let faulted = await controller.evaluate(.periodic)
        #expect(faulted.isBackendFaulted)
        #expect(faulted.events.contains { $0.kind == .safety && $0.message.contains("stopped making changes") && $0.message.contains("write") })
        #expect(!faulted.events.contains { $0.message.contains("outside CellKeeper") })
        #expect(!faulted.events.contains { $0.message.contains("lease expired") })
        #expect(await rig.observedState().interlocks.contains(.writeFailed))

        rig.clock.advance(by: 61)
        let cleared = await controller.resetBackendFault()
        #expect(!cleared.isBackendFaulted)
        #expect(await rig.observedState().interlocks.isEmpty)
    }

    @Test("A new hardware error the helper recovered from counts as a failure")
    func newHardwareErrorCounted() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 50)
        await controller.evaluate(.launch)
        rig.control.failNextReadBacks(1)
        await rig.engine.tick()
        rig.clock.advance(by: 5)
        let status = await controller.evaluate(.periodic)
        // Counted like any failed mode read; normal charging is then
        // confirmed, which ends the count.
        #expect(status.events.filter { $0.kind == .failure && $0.message.contains("new hardware error") && $0.message.contains("consecutive failures: 1") }.count == 1)
        #expect(!status.isBackendFaulted)
        rig.clock.advance(by: 5)
        let later = await controller.evaluate(.periodic)
        #expect(later.events.filter { $0.message.contains("new hardware error") }.count == 1)
    }
}
