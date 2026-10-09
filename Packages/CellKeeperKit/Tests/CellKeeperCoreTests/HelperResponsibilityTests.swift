import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

// Regression tests from the second review of the helper backend; the hooks
// and the first five tests are the reviewer's probes.

/// Code to run inside a connection's requests, once each.
private final class RequestHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var readHook: (@Sendable () async throws -> Void)?
    private var activationHook: (@Sendable () async throws -> Void)?

    /// Runs after the next `readState` has been served, before its reply
    /// reaches the backend; throwing loses the reply.
    func onNextRead(_ hook: @escaping @Sendable () async throws -> Void) {
        lock.withLock { readHook = hook }
    }

    /// Runs after the next activation has been served, before its reply
    /// reaches the backend; throwing loses the reply.
    func onNextActivation(_ hook: @escaping @Sendable () async throws -> Void) {
        lock.withLock { activationHook = hook }
    }

    func takeRead() -> (@Sendable () async throws -> Void)? {
        lock.withLock { defer { readHook = nil }; return readHook }
    }

    func takeActivation() -> (@Sendable () async throws -> Void)? {
        lock.withLock { defer { activationHook = nil }; return activationHook }
    }
}

private struct HookedTransport: HelperTransport {
    let base: TestHelperTransport
    let hooks: RequestHooks

    func connect() async throws -> any HelperConnection {
        HookedConnection(base: try await base.connect(), hooks: hooks)
    }
}

private struct HookedConnection: HelperConnection {
    let base: any HelperConnection
    let hooks: RequestHooks

    func hello(clientProtocolVersion: Int) async throws -> HelperHelloReply {
        try await base.hello(clientProtocolVersion: clientProtocolVersion)
    }

    func readState() async throws -> HelperStateReply {
        let state = try await base.readState()
        if let hook = hooks.takeRead() { try await hook() }
        return state
    }

    func acquireOrRenewLease(control: Int, seconds: Int) async throws -> HelperLeaseReply {
        try await base.acquireOrRenewLease(control: control, seconds: seconds)
    }

    func releaseLease(control: Int) async throws -> HelperStatus {
        try await base.releaseLease(control: control)
    }

    func setControl(control: Int, active: Bool) async throws -> HelperStatus {
        let status = try await base.setControl(control: control, active: active)
        if active, status == .ok, let hook = hooks.takeActivation() { try await hook() }
        return status
    }

    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64) async throws -> HelperStatus {
        try await base.clearControlIfUnchanged(control: control, generation: generation, helperInstance: helperInstance)
    }

    func restoreDefaults() async throws -> HelperStatus { try await base.restoreDefaults() }
    func restoreDefaultsAndExit() async throws -> HelperStatus { try await base.restoreDefaultsAndExit() }
    func invalidate() async { await base.invalidate() }
}

private extension HelperRig {
    /// A backend on this rig's helper whose requests run `hooks`.
    func hookedBackend(_ hooks: RequestHooks) -> HelperChargingBackend {
        let clock = clock
        return HelperChargingBackend(
            descriptor: HelperRig.descriptor,
            transport: HookedTransport(base: transport, hooks: hooks),
            uptime: { clock.uptime },
            pause: { clock.advance(by: $0) },
            activity: activity
        )
    }

    func controller(on backend: HelperChargingBackend, percent: Int) -> ChargeController {
        let clock = clock
        return ChargeController(
            telemetry: StubTelemetry(snapshot(percent: percent), clock: clock),
            backend: backend,
            settings: .default,
            now: { clock.now },
            uptime: { clock.uptime }
        )
    }

    /// Another client of the helper, introduced.
    func otherClient() async -> HelperSession {
        let session = await engine.openSession()
        _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        return session
    }
}

private let inhibit = HelperControl.chargingInhibited.rawValue
private let adapter = HelperControl.adapterDisabled.rawValue

@Suite("Helper backend: responsibility for what it may have set")
struct HelperResponsibilityTests {
    @Test("A successful request for normal charging keeps an outside change it found reported, and the controller faults")
    func outsideNoticeSurvivesRelease() async throws {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        #expect(await rig.otherClient().setControl(control: inhibit, active: false) == .ok)

        let released = await controller.restoreSystemDefaults(reason: "test")
        #expect(released.currentMode == .normal)
        #expect(released.isBackendFaulted)
        #expect(released.events.contains { $0.kind == .safety && $0.message.contains("another client of the helper cleared") })
        rig.clock.advance(by: 61)
        let next = await controller.evaluate(.periodic)
        #expect(next.isBackendFaulted)
        #expect(rig.control.writes.filter { $0 == .apply(.chargingInhibited, active: true) }.count == 1)
    }

    @Test("A backend's successful release keeps the outside change it found until a read reports it, once")
    func outsideNoticeKeptUntilReported() async throws {
        let rig = HelperRig()
        _ = try await rig.backend.setMode(.inhibitCharging)
        #expect(await rig.otherClient().setControl(control: inhibit, active: false) == .ok)
        _ = try await rig.backend.setMode(.normal)
        #expect(try await rig.backend.currentMode() == .normal)
        guard case .changedOutside(let detail)? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected an outside change, got \(String(describing: await rig.backend.reportedModeOrigin()))")
            return
        }
        #expect(detail.contains("another client"))
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.reportedModeOrigin() == nil)
    }

    @Test("An activation that may have taken effect, whose outcome cannot be read, keeps the backend unresolved and a switch pending")
    func unsettledActivationBlocksSwitch() async throws {
        let rig = HelperRig()
        let hooks = RequestHooks()
        let backend = rig.hookedBackend(hooks)
        let controller = rig.controller(on: backend, percent: 85)
        hooks.onNextActivation {
            // The read that would settle it loses the connection; the
            // session's cleanup cannot clear the control or restore defaults;
            // and the helper cannot be reached again.
            rig.control.failNextApplies(1)
            rig.control.failNextRestores(1)
            rig.transport.isReachable = false
            hooks.onNextRead {
                await rig.transport.latest?.session.invalidate()
                throw TransportTestError()
            }
        }
        await controller.evaluate(.launch)
        rig.clock.advance(by: 60)
        _ = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.chargingInhibited])
        let capabilities = await backend.capabilities()
        #expect(capabilities.availability.acceptsRequests)
        #expect(capabilities.supportedModes == [.normal])
        await #expect(throws: BackendError.self) { _ = try await backend.currentMode() }
        let switched = await controller.switchBackend(to: MockChargingBackend())
        #expect(switched.backend.identifier == HelperRig.descriptor.identifier)
        #expect(switched.pendingBackend != nil)
    }

    @Test("The helper checks the generation right before it clears: a control another client took meanwhile stays")
    func conditionalReleaseKeepsNewOwner() async throws {
        let rig = HelperRig()
        let hooks = RequestHooks()
        let backend = rig.hookedBackend(hooks)
        _ = try await backend.setMode(.forceDischarge)
        let other = await rig.otherClient()
        hooks.onNextRead {
            // After the read CellKeeper checks ownership with, its lease runs
            // out and another client sets the same control.
            rig.clock.advance(by: 121)
            #expect(await other.acquireOrRenewLease(control: adapter, seconds: 120).status == .ok)
            #expect(await other.setControl(control: adapter, active: true) == .ok)
        }
        let writes = rig.control.writes.count
        await #expect(throws: BackendError.self) { _ = try await backend.setMode(.normal) }
        #expect(rig.control.activeControls == [.adapterDisabled])
        #expect(!rig.control.writes.dropFirst(writes + 2).contains(.apply(.adapterDisabled, active: false)))
        #expect(await other.readState().isLeaseHolder)
        #expect(rig.events.contains(where: { if case .requestRejected(_, .clearControlIfUnchanged, .controlChanged) = $0 { true } else { false } }))
    }

    @Test("An activation that applied before it threw is CellKeeper's, and the helper's failure needs acknowledging")
    func failedOwnActivationIsNotForeign() async throws {
        let rig = HelperRig()
        _ = await rig.backend.capabilities()
        rig.control.failNextAppliesAfterApplying(1)
        rig.control.failNextRestores(1)
        await #expect(throws: BackendError.self) { _ = try await rig.backend.setMode(.inhibitCharging) }
        #expect(rig.control.activeControls == [.chargingInhibited])
        _ = try await rig.backend.currentMode()
        guard case .needsAcknowledgement? = await rig.backend.reportedModeOrigin() else {
            Issue.record("expected the helper's own failure, got \(String(describing: await rig.backend.reportedModeOrigin()))")
            return
        }
    }

    @Test("A restore the helper owes while it cannot read its controls back faults at once")
    func unreadableHardwareFaultFaultsAtOnce() async throws {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        rig.control.failNextReadBacks(100)
        rig.clock.advance(by: 61)
        let status = await controller.evaluate(.periodic)
        #expect(status.isBackendFaulted)
        #expect(status.currentMode == nil)
        #expect(status.events.contains { $0.message.contains("stopped making changes") && $0.message.contains("restore") })
        // The fault is reported once, not counted again on every failed read.
        rig.clock.advance(by: 61)
        let later = await controller.evaluate(.periodic)
        #expect(later.events.filter { $0.message.contains("stopped making changes") }.count == 1)
    }

    @Test("An activation whose reply was lost grants no ownership: a control another client set meanwhile is never cleared")
    func pendingActivationGrantsNoOwnership() async throws {
        let rig = HelperRig()
        let hooks = RequestHooks()
        let backend = rig.hookedBackend(hooks)
        _ = await backend.capabilities()
        let other = await rig.otherClient()
        hooks.onNextActivation {
            // The activation took effect, but its reply is lost: the
            // connection drops, which ends the session and clears the
            // control. Another client then sets the same control.
            await rig.transport.latest?.session.invalidate()
            rig.clock.advance(by: HelperEngine.minimumActivationInterval + 1)
            #expect(await other.acquireOrRenewLease(control: inhibit, seconds: 900).status == .ok)
            #expect(await other.setControl(control: inhibit, active: true) == .ok)
            throw TransportTestError()
        }
        await #expect(throws: BackendError.self) { _ = try await backend.setMode(.inhibitCharging) }
        let writes = rig.control.writes.count
        await #expect(throws: BackendError.self) { _ = try await backend.setMode(.normal) }
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(!rig.control.writes.dropFirst(writes).contains(.apply(.chargingInhibited, active: false)))
        #expect(await other.readState().isLeaseHolder)
        _ = try await backend.currentMode()
        guard case .changedOutside? = await backend.reportedModeOrigin() else {
            Issue.record("expected an outside change, got \(String(describing: await backend.reportedModeOrigin()))")
            return
        }
    }

    @Test("Another client's clear of an activation not yet confirmed is an outside change: CellKeeper faults and does not set it again", arguments: [false, true])
    func pendingActivationClearedByAnotherClient(losesReply: Bool) async throws {
        let rig = HelperRig()
        let hooks = RequestHooks()
        let backend = rig.hookedBackend(hooks)
        let controller = rig.controller(on: backend, percent: 85)
        await controller.evaluate(.launch)
        let other = await rig.otherClient()
        hooks.onNextActivation {
            // Before CellKeeper's first confirming read, another client
            // clears the control; the reply arrives, or is lost.
            #expect(await other.setControl(control: inhibit, active: false) == .ok)
            if losesReply { throw TransportTestError() }
        }
        rig.clock.advance(by: 60)
        let failed = await controller.evaluate(.periodic)
        #expect(failed.isBackendFaulted)
        #expect(failed.events.contains { $0.kind == .safety && $0.message.contains("another client of the helper cleared") })
        rig.clock.advance(by: 61)
        let next = await controller.evaluate(.periodic)
        #expect(next.isBackendFaulted)
        #expect(rig.control.writes.filter { $0 == .apply(.chargingInhibited, active: true) }.count == 1)
        #expect(rig.control.activeControls.isEmpty)
    }

    @Test("The helper's own release of an activation not yet confirmed is not an outside change")
    func pendingActivationReleasedByHelper() async throws {
        let rig = HelperRig()
        let hooks = RequestHooks()
        let backend = rig.hookedBackend(hooks)
        let controller = rig.controller(on: backend, percent: 85)
        hooks.onNextActivation {
            // External power is lost before CellKeeper reads: the helper
            // clears the inhibit under its own interlock.
            rig.power.update { $0.isOnExternalPower = false }
            await rig.engine.tick()
        }
        let status = await rig.confirmedEvaluation(controller)
        #expect(!status.isBackendFaulted)
        #expect(!status.events.contains { $0.message.contains("outside CellKeeper") })
        #expect(rig.control.activeControls.isEmpty)
    }

    @Test("An outside change found earlier survives a failed read and is reported once")
    func outsideNoticeSurvivesFailedRead() async throws {
        let rig = HelperRig()
        _ = try await rig.backend.setMode(.inhibitCharging)
        #expect(await rig.otherClient().setControl(control: inhibit, active: false) == .ok)
        _ = try await rig.backend.setMode(.normal)
        rig.transport.latest?.failNextRequests(1)
        await #expect(throws: BackendError.self) { _ = try await rig.backend.currentMode() }
        guard case .changedOutside? = await rig.backend.reportedModeOrigin() else {
            Issue.record("the outside change was lost on a failed read")
            return
        }
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.reportedModeOrigin() == nil)
    }

    enum Resolution: String, CaseIterable, Sendable {
        case helperRecovers, userStays
    }

    @Test("A switch that waits for an unsettled activation completes once the helper recovers, or is cancelled by staying", arguments: Resolution.allCases)
    func unsettledSwitchResolves(resolution: Resolution) async throws {
        let rig = HelperRig()
        let hooks = RequestHooks()
        let backend = rig.hookedBackend(hooks)
        let controller = rig.controller(on: backend, percent: 85)
        hooks.onNextActivation {
            rig.control.failNextApplies(1)
            rig.control.failNextRestores(1)
            rig.transport.isReachable = false
            hooks.onNextRead {
                await rig.transport.latest?.session.invalidate()
                throw TransportTestError()
            }
        }
        _ = await rig.confirmedEvaluation(controller)
        let pending = await controller.switchBackend(to: MockChargingBackend())
        #expect(pending.pendingBackend != nil)
        switch resolution {
        case .helperRecovers:
            rig.transport.isReachable = true
            rig.clock.advance(by: 61)
            let recovered = await controller.evaluate(.periodic)
            #expect(recovered.pendingBackend == nil)
            #expect(recovered.backend.identifier == "simulated")
            #expect(rig.control.activeControls.isEmpty)
        case .userStays:
            let stayed = await controller.switchBackend(to: backend)
            #expect(stayed.pendingBackend == nil)
            #expect(stayed.backend.identifier == HelperRig.descriptor.identifier)
        }
    }

    @Test("An activation whose reply was lost is settled by a later read: CellKeeper's own once the helper names it")
    func pendingActivationSettlesAsOwn() async throws {
        let rig = HelperRig()
        let hooks = RequestHooks()
        let backend = rig.hookedBackend(hooks)
        _ = await backend.capabilities()
        hooks.onNextActivation {
            // The reply is lost with the connection; the session's cleanup
            // cannot clear the control, nor can the restore after it.
            rig.control.failNextApplies(1)
            rig.control.failNextRestores(1)
            await rig.transport.latest?.session.invalidate()
            throw TransportTestError()
        }
        await #expect(throws: BackendError.self) { _ = try await backend.setMode(.inhibitCharging) }
        #expect(rig.control.activeControls == [.chargingInhibited])

        // The helper names CellKeeper's earlier session as the setter: it is
        // CellKeeper's, and what is wrong is the helper's own failure.
        #expect(try await backend.currentMode() == .inhibitCharging)
        guard case .needsAcknowledgement? = await backend.reportedModeOrigin() else {
            Issue.record("expected the helper's own failure, got \(String(describing: await backend.reportedModeOrigin()))")
            return
        }
        try await backend.resetAfterFault()
        #expect(rig.control.activeControls.isEmpty)
        #expect(try await backend.currentMode() == .normal)
        #expect(await backend.reportedModeOrigin() == nil)
    }
}
