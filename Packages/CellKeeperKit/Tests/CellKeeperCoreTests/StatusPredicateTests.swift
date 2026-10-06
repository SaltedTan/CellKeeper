import CellKeeperCore
import Foundation
import Testing

/// The status predicates the menu uses to choose safety-relevant messages.
@Suite("Status predicates")
struct StatusPredicateTests {
    let clock = TestClock()
    let system = FakeChargeLimitSystem(reading: .limit(80))
    let store = InMemoryRecordStore()

    private func makeController(limit: Int = 90, backend: (any ChargingBackend)? = nil) -> (ChargeController, StubTelemetry) {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: 75), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: backend ?? makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(limit),
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        return (controller, telemetry)
    }

    // MARK: - Settled

    @Test("A confirmed native limit is settled, and stays so while nothing changes")
    func settledAfterConfirmedChange() async {
        let (controller, _) = makeController(limit: 90)
        #expect(await controller.evaluate(.launch).isNativeLimitSettled)
        #expect(await controller.evaluate(.periodic).isNativeLimitSettled)
    }

    @Test("A refused change is not settled")
    func refusedIsNotSettled() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        // A second restricting change within a minute is rate-limited.
        let refused = try await controller.apply(settings: ChargingSettings.default.withChargeLimit(85))
        guard case .refused? = refused.lastExecution?.result else {
            Issue.record("expected a refusal, got \(String(describing: refused.lastExecution?.result))")
            return
        }
        #expect(!refused.isNativeLimitSettled)
    }

    @Test("A failed change is not settled")
    func failedIsNotSettled() async {
        system.runBehaviour = .hasNoEffect
        let (controller, _) = makeController(limit: 90)
        let status = await controller.evaluate(.launch)
        guard case .failed? = status.lastExecution?.result else {
            Issue.record("expected a failure, got \(String(describing: status.lastExecution?.result))")
            return
        }
        #expect(!status.isNativeLimitSettled)
    }

    @Test("An unavailable native backend is not settled")
    func unavailableIsNotSettled() async {
        system.names = ["Something else"]
        let (controller, _) = makeController(limit: 80)
        let status = await controller.evaluate(.launch)
        #expect(!status.capabilities.availability.acceptsRequests)
        #expect(!status.isNativeLimitSettled)
    }

    @Test("A temporary full charge is not settled")
    func fullChargeIsNotSettled() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let full = await controller.startFullCharge()
        #expect(full.decision?.state == .fullChargeOverride)
        #expect(!full.isNativeLimitSettled)
    }

    @Test("A pending backend switch is not settled")
    func pendingSwitchIsNotSettled() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.runBehaviour = .fails
        let switching = await controller.switchBackend(to: MockChargingBackend())
        #expect(switching.pendingBackend != nil)
        #expect(!switching.isNativeLimitSettled)
    }

    @Test("Other backends are never settled in this sense")
    func otherBackendsAreNotSettled() async {
        let (controller, _) = makeController(limit: 90, backend: MockChargingBackend())
        #expect(!(await controller.evaluate(.launch).isNativeLimitSettled))
    }

    // MARK: - Restore pending

    @Test("A failed restore is pending until it is confirmed")
    func failedRestoreIsPending() async throws {
        let (controller, _) = makeController(limit: 90)
        let applied = await controller.evaluate(.launch)
        #expect(!applied.isOwnLimitRestorePending)

        system.runBehaviour = .fails
        var off = ChargingSettings.default.withChargeLimit(90)
        off.isManagementEnabled = false
        let failed = try await controller.apply(settings: off)
        #expect(failed.nativeLimit?.ownerLimit == 80)
        #expect(failed.isOwnLimitRestorePending)

        system.runBehaviour = .applies
        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let restored = await controller.evaluate(.periodic)
        #expect(restored.nativeLimit?.ownerLimit == nil)
        #expect(!restored.isOwnLimitRestorePending)
    }

    @Test("A record left by an earlier session is pending until it is restored")
    func earlierSessionRecordIsPending() async {
        storeOwnershipRecord(owner: 80, target: 90, in: store)
        system.reading = .limit(90)
        system.runBehaviour = .fails
        let (controller, _) = makeController(limit: 90)
        let launch = await controller.evaluate(.launch)
        #expect(launch.decision?.reason == .releaseRequired(.restoreUnfinished))
        #expect(launch.nativeLimit?.ownerLimit == 80)
        #expect(launch.isOwnLimitRestorePending)

        system.runBehaviour = .applies
        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let restored = await controller.evaluate(.periodic)
        #expect(system.reading == .limit(80))
        #expect(restored.nativeLimit?.ownerLimit == nil)
        #expect(!restored.isOwnLimitRestorePending)
    }
}
