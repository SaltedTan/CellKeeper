import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// The order across CellKeeper's own state and the helper: CellKeeper
/// restores normal charging first, then the helper restores and exits, then
/// it is unregistered; a failure stops the sequence at its step.
@Suite("Helper removal from the controller")
struct HelperRemovalControllerTests {
    private static let steps: Set<String> = ["backend.normal", "helper.restoreDefaultsAndExit", "registration.unregister"]

    private func controller(backend: any ChargingBackend) -> ChargeController {
        ChargeController(telemetry: StubTelemetry(snapshot(percent: 70)), backend: backend, settings: .default)
    }

    @Test("Normal charging first, then the helper's restore and exit, then unregistering")
    func ordering() async {
        let rig = RemovalRig()
        let controller = controller(backend: RecordingBackend(log: rig.log))
        let outcome = await controller.removeHelper(using: rig.removal())
        #expect(outcome == .helperRemoval(.removed(.simulated)))
        #expect(rig.log.order(of: Self.steps) == ["backend.normal", "helper.restoreDefaultsAndExit", "registration.unregister"])
        let events = await controller.status.events
        #expect(events.contains { $0.kind == .safety && $0.message.contains("Remove helper: confirming normal charging on Recording") })
        #expect(events.contains { $0.message.contains("Restored normal charging (removing the helper) (simulated; hardware unchanged)") })
        #expect(events.contains { $0.message.contains("restored its simulated controls") })
        #expect(outcome.summary.contains("CellKeeper first confirmed normal charging"))
    }

    @Test("If normal charging is not confirmed, the helper is not contacted and nothing is unregistered")
    func unconfirmedNormalChargingStops() async {
        let rig = RemovalRig()
        let backend = RecordingBackend(log: rig.log)
        await backend.failNormal()
        let controller = controller(backend: backend)
        let outcome = await controller.removeHelper(using: rig.removal(), force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .normalChargingNotConfirmed(backend: "Recording"))
        #expect(rig.log.count(of: "helper.connect") == 0)
        #expect(rig.registration.unregisterCount == 0)
        let events = await controller.status.events
        #expect(events.contains { $0.message.contains("Remove helper: CellKeeper could not confirm normal charging on Recording") })
    }

    @Test("A helper that does not confirm stops the sequence after CellKeeper's own restore")
    func unconfirmedHelperStops() async {
        let rig = RemovalRig()
        rig.transport.replaceRestoreReply(with: .hardwareError)
        let controller = controller(backend: RecordingBackend(log: rig.log))
        let outcome = await controller.removeHelper(using: rig.removal())
        #expect(outcome == .helperRemoval(.restoreNotConfirmed(.refused(.hardwareError), helper: .simulated)))
        #expect(rig.log.order(of: Self.steps) == ["backend.normal", "helper.restoreDefaultsAndExit"])
        let events = await controller.status.events
        #expect(events.contains { $0.message.contains("so CellKeeper did not remove it") })
    }

    @Test("An unregistering that fails is reported after the restores")
    func unregisterFailureIsReported() async {
        let rig = RemovalRig()
        rig.registration.failUnregister()
        rig.registration.statusAfterUnregister = .enabled
        let controller = controller(backend: RecordingBackend(log: rig.log))
        let outcome = await controller.removeHelper(using: rig.removal())
        #expect(outcome == .helperRemoval(.unregisterIncomplete(.simulated, status: .enabled, error: "test unregister failure")))
        #expect(rig.log.order(of: Self.steps) == ["backend.normal", "helper.restoreDefaultsAndExit", "registration.unregister"])
    }

    @Test("A forced removal still restores CellKeeper's own state first")
    func forcedRemovalRestoresFirst() async {
        let rig = RemovalRig()
        rig.transport.fail(at: .connect)
        let controller = controller(backend: RecordingBackend(log: rig.log))
        let outcome = await controller.removeHelper(using: rig.removal(), force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .helperRemoval(.removedWithoutConfirmedRestore(.connectFailed("test transport failure"))))
        #expect(rig.log.order(of: Self.steps) == ["backend.normal", "registration.unregister"])
    }

    @Test("With no helper registered, CellKeeper's charging is left as it is")
    func nothingRegisteredChangesNothing() async {
        let rig = RemovalRig(registration: .notRegistered)
        let controller = controller(backend: RecordingBackend(log: rig.log))
        let outcome = await controller.removeHelper(using: rig.removal())
        #expect(outcome == .nothingToRemove(.notRegistered))
        #expect(rig.log.count(of: "backend.normal") == 0)
        #expect(rig.log.count(of: "helper.connect") == 0)
    }

    @Test("After the controller has shut down, nothing is contacted")
    func shutDownControllerDoesNothing() async {
        let rig = RemovalRig()
        let controller = controller(backend: RecordingBackend(log: rig.log))
        await controller.shutdown(reason: "quit")
        let outcome = await controller.removeHelper(using: rig.removal())
        #expect(outcome == .controllerShutDown)
        #expect(rig.log.count(of: "registration.status") == 0)
        #expect(rig.log.count(of: "helper.connect") == 0)
    }

    @Test("With macOS's Charge Limit, your own limit is restored and its record deleted before the helper is asked")
    func nativeLimitRestoredFirst() async {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        var settings = ChargingSettings.default.withChargeLimit(90)
        settings.isManagementEnabled = true
        let controller = ChargeController(
            telemetry: StubTelemetry(snapshot(percent: 75), clock: clock),
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: settings,
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        await controller.evaluate(.launch)
        #expect(system.reading == .limit(90))
        #expect(store.data != nil)

        let rig = RemovalRig()
        let seen = Observed<(reading: NativeChargeLimitReading, isRecordDeleted: Bool)>()
        rig.transport.observeRestore { seen.value = (system.reading, store.data == nil) }
        let outcome = await controller.removeHelper(using: rig.removal())

        #expect(outcome == .helperRemoval(.removed(.simulated)))
        #expect(seen.value?.reading == .limit(80))
        #expect(seen.value?.isRecordDeleted == true)
        #expect(system.runInputs == ["90", "80"])
        let events = await controller.status.events
        #expect(events.contains { $0.message.contains("Restored your own macOS Charge Limit of 80% (removing the helper)") })
    }

    @Test("If your own Charge Limit cannot be restored, the helper is not contacted and the record is kept")
    func nativeRestoreFailureStops() async {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        var settings = ChargingSettings.default.withChargeLimit(90)
        settings.isManagementEnabled = true
        let backend = makeNativeBackend(system: system, store: store, clock: clock)
        let controller = ChargeController(
            telemetry: StubTelemetry(snapshot(percent: 75), clock: clock),
            backend: backend,
            settings: settings,
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        await controller.evaluate(.launch)
        system.runBehaviour = .fails

        let rig = RemovalRig()
        let outcome = await controller.removeHelper(using: rig.removal())

        #expect(outcome == .normalChargingNotConfirmed(backend: backend.descriptor.displayName))
        #expect(store.data != nil)
        #expect(system.reading == .limit(90))
        #expect(rig.log.count(of: "helper.connect") == 0)
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("With the helper backend, CellKeeper releases its own hold first, then the helper restores and exits")
    func helperBackendReleasesFirst() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        #expect(rig.control.activeControls == [.chargingInhibited])

        let registration = FakeHelperRegistration(.enabled)
        let outcome = await controller.removeHelper(using: HelperRemoval(transport: rig.transport, registration: registration))

        #expect(outcome == .helperRemoval(.removed(.simulated)))
        #expect(rig.control.activeControls.isEmpty)
        // CellKeeper's own release cleared the inhibit; the helper's restore
        // then found nothing to clear.
        let change = await rig.engine.latestChange(of: .chargingInhibited)
        #expect(change.cause == .clearedByClient)
        let isSafeToExit = await rig.engine.isSafeToExit
        #expect(isSafeToExit)
        #expect(registration.unregisterCount == 1)
    }
}
