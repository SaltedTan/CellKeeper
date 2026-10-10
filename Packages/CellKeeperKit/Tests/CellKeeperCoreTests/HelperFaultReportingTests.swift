import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

// Regressions from the fifth review of the macOS Charge Limit coexistence
// work; the first three are the reviewer's reproductions.

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
