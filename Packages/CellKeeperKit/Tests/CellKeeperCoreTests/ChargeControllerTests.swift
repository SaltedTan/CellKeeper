import CellKeeperCore
import Foundation
import Testing

@Suite("Charge controller")
struct ChargeControllerTests {
    let clock = TestClock()

    private func makeController(
        percent: Int = 85,
        backend: any ChargingBackend = MockChargingBackend(),
        settings: ChargingSettings = .default
    ) -> (ChargeController, StubTelemetry) {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: percent), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: backend,
            settings: settings,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        return (controller, telemetry)
    }

    // MARK: - Execution and honesty

    @Test("Decisions are executed through the mock backend and reported as simulated")
    func simulatedExecution() async {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)

        let status = await controller.evaluate(.launch)
        #expect(status.decision?.action == .disableCharging)
        #expect(status.lastExecution?.result == .simulated)
        #expect(status.currentMode == .inhibitCharging)
        #expect(await backend.requestedModes == [.inhibitCharging])
        #expect(status.events.contains { $0.kind == .result && $0.message.contains("Simulated") })

        // A second evaluation with the same state requests nothing new.
        let again = await controller.evaluate(.periodic)
        #expect(again.decision?.action == .noAction)
        #expect(await backend.requestedModes == [.inhibitCharging])
    }

    @Test("A read-only backend refuses control but still computes the desired mode")
    func readOnlyBackend() async {
        let (controller, _) = makeController(percent: 85, backend: ReadOnlyChargingBackend(reason: "test"))
        let status = await controller.evaluate(.launch)
        #expect(status.decision?.desiredMode == .inhibitCharging)
        #expect(status.decision?.action == .refuse(.controlUnavailable("test")))
        #expect(status.lastExecution?.result == .refused(.controlUnavailable("test")))
        #expect(status.capabilities.availability == .unavailable(reason: "test"))
        #expect(status.consecutiveFailures == 0)
    }

    @Test("Changing the charge limit recalculates and executes the desired action")
    func limitChange() async throws {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 78, backend: backend)

        let initial = await controller.evaluate(.launch)
        #expect(initial.decision?.desiredMode == .normal)
        #expect(await backend.requestedModes.isEmpty)

        let lowered = try await controller.apply(settings: ChargingSettings.default.withChargeLimit(70))
        #expect(lowered.decision?.state == .holding)
        #expect(lowered.decision?.action == .disableCharging)
        #expect(lowered.currentMode == .inhibitCharging)
        #expect(await backend.requestedModes == [.inhibitCharging])
    }

    @Test("Invalid settings are rejected and the previous settings kept")
    func invalidSettingsRejected() async {
        let (controller, _) = makeController()
        await controller.evaluate(.launch)
        await #expect(throws: SettingsValidationError.self) {
            try await controller.apply(settings: ChargingSettings(chargeLimit: 150, resumeThreshold: 75))
        }
        #expect(await controller.status.settings == .default)
    }

    // MARK: - Failures and verification

    @Test("A failed request falls back to confirmed normal charging")
    func failureFallsBack() async {
        let backend = MockChargingBackend()
        await backend.failNextRequests(1)
        let (controller, _) = makeController(percent: 85, backend: backend)

        let status = await controller.evaluate(.launch)
        #expect(await backend.requestedModes == [.inhibitCharging, .normal])
        guard case .failed = status.lastExecution?.result else {
            Issue.record("expected failure, got \(String(describing: status.lastExecution))")
            return
        }
        #expect(status.currentMode == .normal)
        #expect(status.consecutiveFailures == 1)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("Restored normal charging") })
    }

    @Test("Repeated failures fault the backend; the fault persists until cleared")
    func circuitBreaker() async {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        for _ in 0..<ChargeController.maximumConsecutiveFailures {
            await backend.failNextRequests(1)
            await controller.evaluate(.periodic)
            clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        }
        let faulted = await controller.evaluate(.periodic)
        #expect(faulted.isBackendFaulted)
        #expect(faulted.currentMode == .normal)
        #expect(faulted.decision?.action == .refuse(.backendFaulted))

        let reset = await controller.resetBackendFault()
        #expect(reset.isBackendFaulted == false)
        #expect(reset.currentMode == .inhibitCharging)
    }

    @Test("A read-back mismatch counts as a failure and is not reported as applied")
    func readBackMismatch() async {
        let backend = MockChargingBackend()
        // The backend will claim to be in normal mode whatever is requested.
        await backend.overrideReadBack(.some(.normal))
        let (controller, _) = makeController(percent: 85, backend: backend)
        let status = await controller.evaluate(.launch)
        #expect(status.consecutiveFailures == 1)
        #expect(status.events.contains { $0.kind == .failure && $0.message.contains("Read-back mismatch") })
        guard case .failed = status.lastExecution?.result else {
            Issue.record("a mismatched read-back must not be reported as successful")
            return
        }
    }

    @Test("A backend that cannot report its mode is treated as failing")
    func unknownModeIsFailure() async {
        let backend = MockChargingBackend()
        await backend.overrideReadBack(.some(nil))
        let (controller, _) = makeController(percent: 85, backend: backend)
        let status = await controller.evaluate(.launch)
        #expect(status.consecutiveFailures >= 2)
        #expect(status.events.contains { $0.message.contains("did not report its mode") })
        guard case .failed = status.lastExecution?.result else {
            Issue.record("an unconfirmed request must not be reported as successful")
            return
        }
    }

    @Test("Mode-read errors count as failures")
    func modeReadErrors() async {
        let backend = MockChargingBackend()
        await backend.failNextModeReads(1)
        let (controller, _) = makeController(percent: 50, backend: backend)
        let status = await controller.evaluate(.launch)
        #expect(status.events.contains {
            $0.kind == .failure && $0.message.contains("Could not read") && $0.message.contains("consecutive failures: 1")
        })
    }

    @Test("A mode change made outside CellKeeper faults the backend and restores normal charging")
    func externalWriterDetected() async throws {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        await controller.evaluate(.launch)
        #expect(try await backend.currentMode() == .inhibitCharging)

        await backend.simulateExternalChange(to: .forceDischarge)
        let status = await controller.evaluate(.periodic)
        #expect(status.isBackendFaulted)
        #expect(status.currentMode == .normal)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("outside CellKeeper") })

        // The fault persists: no restriction is re-applied.
        clock.advance(by: 120)
        let later = await controller.evaluate(.periodic)
        #expect(later.isBackendFaulted)
        #expect(later.currentMode == .normal)
    }

    // MARK: - Overrides

    @Test("Temporary full charge runs to completion, then the limit applies again")
    func fullChargeLifecycle() async {
        let backend = MockChargingBackend()
        let (controller, telemetry) = makeController(percent: 85, backend: backend)
        await controller.evaluate(.launch)

        let started = await controller.startFullCharge()
        #expect(started.activeOverride?.kind == .fullCharge)
        #expect(started.decision?.state == .fullChargeOverride)
        #expect(started.currentMode == .normal)

        await telemetry.set(snapshot(percent: 100, charging: false, fullyCharged: true))
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let finished = await controller.evaluate(.powerSourceChanged)
        #expect(finished.activeOverride == nil)
        #expect(finished.decision?.overrideEnded == .completed)
        #expect(finished.decision?.state == .holding)
        #expect(await backend.requestedModes == [.inhibitCharging, .normal, .inhibitCharging])
    }

    @Test("A discharge session runs to the limit, then holds, and does not restart")
    func dischargeSession() async {
        let backend = MockChargingBackend()
        let (controller, telemetry) = makeController(percent: 90, backend: backend)
        let started = await controller.startDischargeToLimit()
        #expect(started.decision?.state == .discharging)
        #expect(started.currentMode == .forceDischarge)

        await telemetry.set(snapshot(percent: 80, charging: false))
        let done = await controller.evaluate(.powerSourceChanged)
        #expect(done.activeOverride == nil)
        #expect(done.decision?.overrideEnded == .completed)
        #expect(done.currentMode == .inhibitCharging)

        clock.advance(by: 3_600)
        await telemetry.set(snapshot(percent: 90))
        let later = await controller.evaluate(.periodic)
        #expect(later.currentMode == .inhibitCharging)
    }

    @Test("Sleep precautions persist until wake, not just for one evaluation")
    func sleepPrecautionPersists() async {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 78, backend: backend)
        await controller.evaluate(.launch)
        let announced = await controller.evaluate(.willSleep)
        #expect(announced.currentMode == .inhibitCharging)

        // A power notification before the Mac actually sleeps must not undo it.
        clock.advance(by: 5)
        let beforeSleep = await controller.evaluate(.powerSourceChanged)
        #expect(beforeSleep.currentMode == .inhibitCharging)

        let woke = await controller.evaluate(.didWake)
        #expect(woke.currentMode == .normal)
    }

    @Test("A will-sleep announcement without a wake expires on the monotonic clock")
    func sleepAnnouncementExpires() async {
        let (controller, _) = makeController(percent: 78)
        await controller.evaluate(.willSleep)
        clock.advance(by: ChargeController.sleepAnnouncementWindow + 1)
        let later = await controller.evaluate(.periodic)
        #expect(later.decision?.state == .charging)
    }

    @Test("Imminent sleep stops a discharge session")
    func sleepStopsDischarge() async {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 90, backend: backend)
        let awake = await controller.startDischargeToLimit()
        #expect(awake.currentMode == .forceDischarge)
        let sleeping = await controller.evaluate(.willSleep)
        #expect(sleeping.activeOverride == nil)
        #expect(sleeping.decision?.overrideEnded == .interrupted)
        #expect(sleeping.currentMode == .inhibitCharging)
    }

    @Test("A backend fault ends a discharge session; clearing the fault does not restart it")
    func faultEndsDischarge() async {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 90, backend: backend)
        await controller.startDischargeToLimit()
        await backend.simulateExternalChange(to: .normal)
        let faulted = await controller.evaluate(.periodic)
        #expect(faulted.isBackendFaulted)
        #expect(faulted.activeOverride == nil)

        clock.advance(by: 120)
        let reset = await controller.resetBackendFault()
        #expect(reset.currentMode == .inhibitCharging)
        #expect(await backend.requestedModes.last == .inhibitCharging)
        #expect(await backend.requestedModes.filter { $0 == .forceDischarge }.count == 1)
    }

    @Test("A temporary full charge cannot start while management is off")
    func fullChargeRequiresManagement() async throws {
        let (controller, _) = makeController(percent: 85)
        var settings = ChargingSettings.default
        settings.isManagementEnabled = false
        try await controller.apply(settings: settings)
        let status = await controller.startFullCharge()
        #expect(status.activeOverride == nil)
    }

    @Test("A discharge session cannot start without a valid target")
    func dischargeRequiresValidTarget() async throws {
        let (controller, _) = makeController(percent: 90)
        try await controller.apply(settings: ChargingSettings(chargeLimit: 100, resumeThreshold: 90))
        let status = await controller.startDischargeToLimit()
        #expect(status.activeOverride == nil)
        #expect(status.events.contains { $0.message.contains("Discharge not started") })
    }

    @Test("Turning management off cancels overrides and restores normal charging")
    func managementOff() async throws {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        await controller.evaluate(.launch)
        await controller.startFullCharge()

        var settings = ChargingSettings.default
        settings.isManagementEnabled = false
        let status = try await controller.apply(settings: settings)
        #expect(status.activeOverride == nil)
        #expect(status.decision?.state == .unmanaged)
        #expect(status.currentMode == .normal)
    }

    // MARK: - Lifecycle

    @Test("Telemetry failure fails safe and is reported")
    func telemetryFailure() async {
        let backend = MockChargingBackend(initialMode: .inhibitCharging)
        let (controller, telemetry) = makeController(percent: 85, backend: backend)
        await telemetry.fail(with: TelemetryTestError())
        let status = await controller.evaluate(.launch)
        #expect(status.snapshot == nil)
        #expect(status.telemetryError == "test telemetry failure")
        #expect(status.decision?.state == .failSafe)
        #expect(status.currentMode == .normal)
    }

    @Test("Switching backends restores normal charging on the old backend first")
    func switchBackend() async throws {
        let first = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: first)
        await controller.evaluate(.launch)
        #expect(try await first.currentMode() == .inhibitCharging)

        let status = await controller.switchBackend(to: ReadOnlyChargingBackend(reason: "test"))
        #expect(try await first.currentMode() == .normal)
        #expect(status.backend.identifier == "read-only")
        #expect(status.decision?.action == .refuse(.controlUnavailable("test")))
    }

    @Test("A backend switch is refused when normal charging cannot be confirmed")
    func switchRefusedWithoutRestore() async throws {
        let first = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: first)
        await controller.evaluate(.launch)
        await first.failNextRequests(1)

        let status = await controller.switchBackend(to: ReadOnlyChargingBackend(reason: "test"))
        #expect(status.backend.identifier == "simulated")
        #expect(try await first.currentMode() == .inhibitCharging)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("refused") })
    }

    @Test("After shutdown, queued and later commands do nothing")
    func shutdownIsTerminal() async {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        await controller.evaluate(.launch)
        let stopped = await controller.shutdown(reason: "quit")
        #expect(stopped.currentMode == .normal)
        let requestsAtShutdown = await backend.requestedModes

        clock.advance(by: 120)
        await controller.evaluate(.periodic)
        await controller.startDischargeToLimit()
        await controller.startFullCharge()
        #expect(await backend.requestedModes == requestsAtShutdown)
        #expect(await controller.status.currentMode == .normal)
    }

    @Test("Failures are forgotten after a failure-free hour")
    func failureCountDecays() async {
        // At 50% nothing needs requesting once normal charging is confirmed,
        // so only the passage of time can reset the count.
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 50, backend: backend)
        await controller.evaluate(.launch)
        await backend.failNextModeReads(2)
        await controller.evaluate(.periodic)
        let failing = await controller.evaluate(.periodic)
        #expect(failing.consecutiveFailures == 2)

        clock.advance(by: ChargeController.failureMemory + 1)
        let afterHour = await controller.evaluate(.periodic)
        #expect(afterHour.consecutiveFailures == 0)
    }

    @Test("A non-hardware backend can never report a hardware change")
    func appliedDowngraded() async {
        let (controller, _) = makeController(percent: 85, backend: OverclaimingBackend())
        let status = await controller.evaluate(.launch)
        #expect(status.lastExecution?.result == .simulated)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("not a hardware backend") })
    }

    @Test("Repeated rate-limit refusals are logged once")
    func rateLimitLoggedOnce() async {
        let (controller, telemetry) = makeController(percent: 85)
        await controller.evaluate(.launch)
        await telemetry.set(snapshot(percent: 50))
        await controller.evaluate(.periodic)
        await telemetry.set(snapshot(percent: 85))
        for _ in 0..<5 {
            clock.advance(by: 5)
            await controller.evaluate(.periodic)
        }
        let refusals = await controller.status.events.filter { $0.kind == .request && $0.message.hasPrefix("Refused") }
        #expect(refusals.count == 1)
    }

    @Test("Restoring system defaults requests and confirms normal charging")
    func restoreDefaults() async {
        let backend = MockChargingBackend()
        let (controller, _) = makeController(percent: 85, backend: backend)
        await controller.evaluate(.launch)
        let status = await controller.restoreSystemDefaults(reason: "quit")
        #expect(status.currentMode == .normal)
        #expect(await backend.requestedModes.last == .normal)
    }

    @Test("Rapid restricting changes are rate-limited; restoring normal charging is not")
    func rateLimited() async {
        let backend = MockChargingBackend()
        let (controller, telemetry) = makeController(percent: 85, backend: backend)
        await controller.evaluate(.launch)
        await telemetry.set(snapshot(percent: 50))
        let relaxed = await controller.evaluate(.powerSourceChanged)
        #expect(relaxed.currentMode == .normal)

        await telemetry.set(snapshot(percent: 85))
        let limited = await controller.evaluate(.powerSourceChanged)
        guard case .refuse(.rateLimited) = limited.decision?.action else {
            Issue.record("expected rate limiting, got \(String(describing: limited.decision?.action))")
            return
        }
        #expect(await backend.requestedModes == [.inhibitCharging, .normal])

        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let allowed = await controller.evaluate(.periodic)
        #expect(allowed.currentMode == .inhibitCharging)
    }

    // MARK: - Concurrency

    @Test("Concurrent evaluations never overlap backend requests")
    func serialized() async {
        // Telemetry alternates on every read and the clock advances past the
        // rate limit each time, so each evaluation makes exactly one request.
        let backend = ConcurrencyProbeBackend()
        let telemetry = AlternatingTelemetry(clock: clock)
        let clock = clock
        let controller = ChargeController(telemetry: telemetry, backend: backend, settings: .default, now: { clock.now }, uptime: { clock.uptime })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await controller.evaluate(.manual) }
            }
        }
        #expect(await backend.totalRequests == 20)
        #expect(await backend.maximumConcurrentRequests == 1)
    }

    @Test("The activity log is bounded")
    func boundedLog() async {
        let (controller, telemetry) = makeController(percent: 85)
        for index in 0..<(ChargeController.eventLimit) {
            await telemetry.set(snapshot(percent: index.isMultiple(of: 2) ? 85 : 50))
            await controller.evaluate(.periodic)
        }
        #expect(await controller.status.events.count == ChargeController.eventLimit)
    }
}

/// A simulated backend that wrongly claims its changes reached hardware.
actor OverclaimingBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "overclaiming", displayName: "Overclaiming", summary: "")
    private var mode: ChargeControlMode = .normal

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .simulated, supportedModes: Set(ChargeControlMode.allCases))
    }

    func currentMode() -> ChargeControlMode? { mode }

    func setMode(_ newMode: ChargeControlMode) -> ControlOutcome {
        mode = newMode
        return .applied
    }
}

/// Alternates between 85% and 50% on each read and advances the clock past
/// the restricting-request interval.
actor AlternatingTelemetry: TelemetryProvider {
    private let clock: TestClock
    private var reads = 0

    init(clock: TestClock) {
        self.clock = clock
    }

    func currentSnapshot() -> BatterySnapshot {
        reads += 1
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval + 1)
        return snapshot(percent: reads.isMultiple(of: 2) ? 50 : 85, at: clock.now)
    }

    nonisolated func powerSourceChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// Records how many `setMode` calls are in flight at once. Suspends inside
/// each call so overlapping callers would be observable.
actor ConcurrencyProbeBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "probe", displayName: "Probe", summary: "")
    private var mode: ChargeControlMode = .normal
    private var inFlight = 0
    private(set) var totalRequests = 0
    private(set) var maximumConcurrentRequests = 0

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .simulated, supportedModes: Set(ChargeControlMode.allCases))
    }

    func currentMode() -> ChargeControlMode? { mode }

    func setMode(_ newMode: ChargeControlMode) async -> ControlOutcome {
        inFlight += 1
        totalRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, inFlight)
        for _ in 0..<5 { await Task.yield() }
        mode = newMode
        inFlight -= 1
        return .simulated
    }
}
