import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// A manual "Charge to 100% once" while an override is live changes nothing,
/// whoever started that override, so starts queued behind one another (a
/// double-click, several Shortcuts actions) give one full charge with the
/// first one's deadline.
@Suite("Manual full charge: admission")
struct FullChargeAdmissionTests {
    let clock = TestClock()
    let storage = InMemoryStorage()

    private func makeController(percent: Int = 70) -> ChargeController {
        let clock = clock
        return ChargeController(
            telemetry: StubTelemetry(snapshot(percent: percent), clock: clock),
            backend: MockChargingBackend(),
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: storage),
            now: { clock.now },
            uptime: { clock.uptime }
        )
    }

    private func notStartedEvents(_ status: ControllerStatus) -> [String] {
        status.events.filter { $0.kind == .override && $0.message.hasPrefix("Temporary full charge not started") }.map(\.message)
    }

    @Test("A second start while a full charge runs keeps the first one and its deadline, and says so in the log")
    func secondStartKeepsFirst() async throws {
        let controller = makeController()
        let first = try #require(await controller.startFullCharge().activeOverride)
        clock.advance(by: 60)
        let second = await controller.startFullCharge()
        let running = try #require(second.activeOverride)
        #expect(running.startedAt == first.startedAt)
        #expect(running.expiresAtUptime == first.expiresAtUptime)
        #expect(notStartedEvents(second) == ["Temporary full charge not started: a temporary full charge is already running."])
    }

    @Test("Starts queued at the same time give one full charge, with one start logged and the other refused")
    func queuedStartsGiveOne() async throws {
        let controller = makeController()
        async let a = controller.startFullCharge()
        async let b = controller.startFullCharge()
        _ = await (a, b)
        let status = await controller.status
        let started = status.events.filter { $0.kind == .override && $0.message.hasPrefix("Temporary full charge requested") }
        #expect(started.count == 1)
        #expect(notStartedEvents(status).count == 1)
        #expect(status.activeOverride?.kind == .fullCharge)
    }

    @Test("A start while a discharge runs leaves the discharge and its deadline as they are")
    func startBehindDischarge() async throws {
        let controller = makeController(percent: 90)
        let discharge = try #require(await controller.startDischargeToLimit().activeOverride)
        #expect(discharge.kind == .dischargeToLimit)
        clock.advance(by: 60)
        let status = await controller.startFullCharge()
        #expect(status.activeOverride == discharge)
        #expect(notStartedEvents(status) == ["Temporary full charge not started: a discharge to the limit is running."])
    }

    @Test("A start while a full charge a schedule started runs leaves it as it is, still the schedule's")
    func startBehindScheduledFullCharge() async throws {
        let controller = makeController()
        let start = clock.now.addingTimeInterval(hour)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(4 * hour)))
        clock.advance(by: hour + 60)
        let scheduled = try #require(await controller.evaluate(.periodic).activeOverride)
        #expect(scheduled.source == .schedule)

        clock.advance(by: 60)
        let status = await controller.startFullCharge()
        let running = try #require(status.activeOverride)
        #expect(running.source == .schedule)
        #expect(running.expiresAtUptime == scheduled.expiresAtUptime)
        #expect(notStartedEvents(status) == ["Temporary full charge not started: a temporary full charge is already running."])
    }

    @Test("An override whose monotonic deadline passed before any evaluation ended it is replaced")
    func expiredOverrideReplaced() async throws {
        let controller = makeController()
        let first = try #require(await controller.startFullCharge().activeOverride)
        clock.advance(by: first.expiresAtUptime - clock.uptime + 1)
        let status = await controller.startFullCharge()
        let replacement = try #require(status.activeOverride)
        #expect(replacement.expiresAtUptime > first.expiresAtUptime)
        #expect(notStartedEvents(status).isEmpty)
    }
}
