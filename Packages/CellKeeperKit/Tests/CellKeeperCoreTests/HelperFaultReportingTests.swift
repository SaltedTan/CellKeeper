import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

// Regressions from the fifth and sixth reviews of the macOS Charge Limit
// coexistence work; the first three are the fifth review's reproductions.

/// A backend whose reads keep reporting an outside change, with recorded
/// changes the test sets, and which refuses normal charging as an outside
/// change, as the helper does while another tool's control is active.
actor ScriptedOutsideChangeBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "scripted-outside", displayName: "Scripted", summary: "")
    private var evidence: Set<RecordedChange> = []

    func setEvidence(_ evidence: Set<RecordedChange>) {
        self.evidence = evidence
    }

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)
    }

    func currentMode() -> ChargeControlMode? {
        .forceDischarge
    }

    func setMode(_ mode: ChargeControlMode) throws -> ControlOutcome {
        throw BackendError.changedOutside(expected: mode, found: .forceDischarge)
    }

    func reportedModeOrigin() -> ReportedModeOrigin? {
        .changedOutside("another tool disabled the adapter")
    }

    func outsideChangeEvidence() -> Set<RecordedChange> {
        evidence
    }
}

/// A backend whose read confirming a restriction fails, reporting a problem
/// it waits to have acknowledged.
actor FaultOnConfirmationBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "fault-on-confirmation", displayName: "Fault on confirmation", summary: "")
    private var mode: ChargeControlMode = .normal
    private var origin: ReportedModeOrigin?
    private var failsNextRead = false

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)
    }

    func currentMode() throws -> ChargeControlMode? {
        origin = nil
        if failsNextRead {
            failsNextRead = false
            origin = .needsAcknowledgement("the test backend's own failure")
            throw BackendError.operationFailed("read-back failed")
        }
        return mode
    }

    func setMode(_ newMode: ChargeControlMode) -> ControlOutcome {
        mode = newMode
        failsNextRead = newMode != .normal
        return .simulated
    }

    func reportedModeOrigin() -> ReportedModeOrigin? {
        origin
    }
}

@Suite("Helper faults: every path, every writer")
struct HelperFaultReportingTests {
    @Test("A fault thrown while restoring faults the backend at once, in every restore path", arguments: ["restore", "switch", "shutdown"])
    func everyRestorePathFaults(_ operation: String) async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        let initial = await rig.confirmedEvaluation(controller)
        #expect(initial.currentMode == .inhibitCharging)
        #expect(initial.consecutiveFailures == 0)
        // The helper stops without confirming its restore, and restarts; its
        // start restore keeps failing, so CellKeeper's inhibit stays active.
        rig.control.failNextRestores(50)
        _ = await rig.engine.terminate()
        rig.transport.relaunch()
        let result: ControllerStatus
        switch operation {
        case "restore": result = await controller.restoreSystemDefaults(reason: "review reproduction")
        case "switch": result = await controller.switchBackend(to: MockChargingBackend())
        default: result = await controller.shutdown(reason: "review reproduction")
        }
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(result.isBackendFaulted, "operation \(operation): failures=\(result.consecutiveFailures)")
        #expect(result.consecutiveFailures == ChargeController.maximumConsecutiveFailures)
        let faults = result.events.filter { $0.kind == .safety && $0.message.contains("found charging inhibited active when it started") }
        #expect(faults.count == 1)
        #expect(faults.first?.message.contains("Backend faulted") == true)
        #expect(!result.events.contains { $0.message.localizedCaseInsensitiveContains("changed outside CellKeeper") })
        if operation == "switch" {
            #expect(result.pendingBackend != nil)
        }
    }

    @Test("A new outside activation while a restore is owed is still reported as an outside change")
    func outsideDuringOwedRestore() async throws {
        let rig = HelperRig()
        let (controller, telemetry) = rig.controller(percent: 85)
        _ = await rig.confirmedEvaluation(controller)
        await telemetry.set(snapshot(percent: 70))
        rig.control.failNextApplies(1)
        rig.control.failNextRestores(50)
        rig.clock.advance(by: 60)
        _ = await controller.evaluate(.periodic)
        // Another read settles the unconfirmed writes' attribution.
        _ = try await rig.backend.currentMode()
        let before = await rig.observedState()
        #expect(before.activeControls.controls == [.chargingInhibited])
        #expect(before.interlocks.contains(.hardwareFault))
        #expect(!before.interlocks.contains(.externalModification))
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        let after = await rig.observedState()
        #expect(after.change(for: .adapterDisabled).cause == .changedOutside)
        #expect(!after.interlocks.contains(.externalModification))
        #expect(after.hardwareErrorCount == before.hardwareErrorCount)
        _ = try await rig.backend.currentMode()
        let origin = await rig.backend.reportedModeOrigin()
        guard case .changedOutside(let detail)? = origin else {
            Issue.record("a new outside activation was downgraded: \(String(describing: origin))")
            return
        }
        #expect(detail.contains("the adapter disabled was changed outside the helper"))
    }

    @Test("A helper failure already handled does not hide a later outside change: it is logged as its own safety event, not counted again")
    func laterOutsideChangeIsLogged() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        _ = await controller.evaluate(.launch)
        rig.control.failNextApplies(1)
        rig.clock.advance(by: 60)
        let ownFailure = await controller.evaluate(.periodic)
        #expect(ownFailure.isBackendFaulted)
        #expect(ownFailure.currentMode == .normal)
        #expect(!ownFailure.events.contains { $0.message.contains("another tool") })
        let failures = ownFailure.consecutiveFailures
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        rig.clock.advance(by: 5)
        let outside = await controller.evaluate(.periodic)
        #expect(outside.isBackendFaulted)
        let origin = await rig.backend.reportedModeOrigin()
        if case .changedOutside? = origin {} else { Issue.record("the backend did not report the outside change: \(String(describing: origin))") }
        let notices = outside.events.filter { $0.kind == .safety && $0.message.contains("another tool may be controlling charging") }
        #expect(notices.count == 1)
        #expect(outside.consecutiveFailures == failures)
        // The same outside change, read again, is not logged again.
        rig.clock.advance(by: 60)
        let again = await controller.evaluate(.periodic)
        #expect(again.events.filter { $0.kind == .safety && $0.message.contains("another tool may be controlling charging") }.count == 1)
        let report = DiagnosticsReport.text(status: again, environment: DiagnosticsEnvironment(appVersion: "1", systemVersion: "27", modelIdentifier: nil), generatedAt: referenceDate)
        #expect(report.contains("another tool may be controlling charging"))
    }

    /// The safety events that report an outside change, read or thrown.
    private func outsideChangeEvents(_ status: ControllerStatus) -> Int {
        status.events.filter {
            $0.kind == .safety && ($0.message.contains("Charging control changed outside CellKeeper") || $0.message.contains("It may have been changed in System Settings or by another tool"))
        }.count
    }

    @Test("Each new outside change of the same control is logged once; reading the same change again logs nothing and counts nothing")
    func repeatedOutsideChangesOfOneControl() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        _ = await rig.confirmedEvaluation(controller)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        rig.clock.advance(by: 5)
        let first = await controller.evaluate(.periodic)
        #expect(first.isBackendFaulted)
        let failures = first.consecutiveFailures
        var logged = outsideChangeEvents(first)
        #expect(logged == 1)
        // The helper stays quiet (D28); another tool turns the
        // adapter-disable on, off and on again: three new generations.
        for active in [true, false, true] {
            let generationBefore = await rig.observedState().change(for: .adapterDisabled).generation
            rig.control.simulateOutsideChange(.adapterDisabled, active: active)
            rig.clock.advance(by: 61)
            let changed = await controller.evaluate(.periodic)
            let state = await rig.observedState()
            #expect(state.change(for: .adapterDisabled).generation == generationBefore + 1)
            #expect(state.change(for: .adapterDisabled).cause == .changedOutside)
            logged += 1
            #expect(outsideChangeEvents(changed) == logged)
            #expect(changed.consecutiveFailures == failures)
            rig.clock.advance(by: 61)
            let again = await controller.evaluate(.periodic)
            #expect(outsideChangeEvents(again) == logged)
            #expect(again.consecutiveFailures == failures)
        }
    }

    @Test("An outside change is identified by the helper process, the control and the generation, not by its message")
    func outsideChangesAcrossHelperProcesses() async {
        let clock = TestClock()
        let backend = ScriptedOutsideChangeBackend()
        let controller = ChargeController(telemetry: StubTelemetry(snapshot(percent: 85), clock: clock), backend: backend, settings: .default, now: { clock.now }, uptime: { clock.uptime })
        func evaluate(_ evidence: Set<RecordedChange>) async -> ControllerStatus {
            await backend.setEvidence(evidence)
            clock.advance(by: 61)
            return await controller.evaluate(.periodic)
        }
        let adapter = HelperControl.adapterDisabled.rawValue
        let first = await evaluate([RecordedChange(source: 1, control: adapter, generation: 1)])
        #expect(first.isBackendFaulted)
        let failures = first.consecutiveFailures
        #expect(outsideChangeEvents(first) == 1)
        // The same recorded change, read and thrown again: nothing new.
        let same = await evaluate([RecordedChange(source: 1, control: adapter, generation: 1)])
        #expect(outsideChangeEvents(same) == 1)
        // A restarted helper's change of the same control and generation is
        // another change, though the message is the same.
        let restarted = await evaluate([RecordedChange(source: 2, control: adapter, generation: 1)])
        #expect(outsideChangeEvents(restarted) == 2)
        let restartedAgain = await evaluate([RecordedChange(source: 2, control: adapter, generation: 1)])
        #expect(outsideChangeEvents(restartedAgain) == 2)
        let newer = await evaluate([RecordedChange(source: 2, control: adapter, generation: 2)])
        #expect(outsideChangeEvents(newer) == 3)
        #expect(newer.consecutiveFailures == failures)
    }

    @Test("A fault reported with a request's confirmation is counted once, not again as the request's failure")
    func confirmationFaultCountedOnce() async {
        let clock = TestClock()
        let backend = FaultOnConfirmationBackend()
        let controller = ChargeController(telemetry: StubTelemetry(snapshot(percent: 85), clock: clock), backend: backend, settings: .default, now: { clock.now }, uptime: { clock.uptime })
        _ = await controller.evaluate(.launch)
        clock.advance(by: 60)
        let status = await controller.evaluate(.periodic)
        #expect(status.isBackendFaulted)
        #expect(status.consecutiveFailures == ChargeController.maximumConsecutiveFailures)
        #expect(status.events.filter { $0.kind == .safety && $0.message.contains("the test backend's own failure") }.count == 1)
        #expect(!status.events.contains { $0.kind == .failure && $0.message.contains("Backend failed to apply") })
        // The fallback still confirms normal charging.
        #expect(status.currentMode == .normal)
    }

    @Test("Refusing an unattributed activation still lets normal charging through after recovery", arguments: [false, true])
    func normalAfterRecovery(_ userAcknowledges: Bool) async throws {
        let rig = HelperRig()
        rig.control.simulateOutsideChange(.chargingInhibited, active: true)
        rig.control.failNextRestores(1)
        _ = try await rig.backend.currentMode()
        #expect(await rig.backend.isReportedModeOwn() == nil)
        let writes = rig.control.writeCount
        do {
            _ = try await rig.backend.setMode(.inhibitCharging)
            Issue.record("activation accepted without acknowledgement")
        } catch BackendError.needsAcknowledgement {
        } catch BackendError.changedOutside {
        } catch {
            Issue.record("unexpected activation refusal: \(error)")
        }
        #expect(rig.control.writeCount == writes)
        if userAcknowledges {
            try await rig.backend.resetAfterFault()
        } else {
            await rig.engine.tick()
        }
        _ = try await rig.backend.setMode(.normal)
        let mode = try await rig.backend.currentMode()
        #expect(mode == .normal)
        #expect(rig.control.activeControls.isEmpty)
    }
}
