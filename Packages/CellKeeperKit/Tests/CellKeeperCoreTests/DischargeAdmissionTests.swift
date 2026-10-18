import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// A confirmed discharge while an override is live changes nothing, whoever
/// started that override, like a manual full charge: starts queued behind one
/// another give one discharge with the first one's deadline, and a discharge
/// confirmed after a full charge started meanwhile leaves the full charge
/// running.
@Suite("Discharge to limit: admission")
struct DischargeAdmissionTests {
    let clock = TestClock()
    let storage = InMemoryStorage()

    private func makeController(percent: Int = 90, backend: MockChargingBackend = MockChargingBackend()) -> ChargeController {
        let clock = clock
        return ChargeController(
            telemetry: StubTelemetry(snapshot(percent: percent), clock: clock),
            backend: backend,
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: storage),
            now: { clock.now },
            uptime: { clock.uptime }
        )
    }

    private func notStartedEvents(_ status: ControllerStatus) -> [String] {
        status.events.filter { $0.kind == .override && $0.message.hasPrefix("Discharge not started") }.map(\.message)
    }

    private func requestedEvents(_ status: ControllerStatus) -> [String] {
        status.events.filter { $0.kind == .override && $0.message.hasPrefix("Discharge to 80% requested") }.map(\.message)
    }

    @Test("A second start while a discharge runs keeps the first one and its deadline, and says so in the log")
    func secondStartKeepsFirst() async throws {
        let backend = MockChargingBackend()
        let controller = makeController(backend: backend)
        let first = try #require(await controller.startDischargeToLimit().activeOverride)
        #expect(first.kind == .dischargeToLimit)
        let requestsAfterFirst = await backend.requestedModes
        clock.advance(by: 60)
        let second = await controller.startDischargeToLimit()
        #expect(second.activeOverride == first)
        #expect(second.overridesEnded == 0)
        #expect(second.lastEndedOverride == nil)
        #expect(notStartedEvents(second) == ["Discharge not started: a discharge to the limit is already running."])
        #expect(requestedEvents(second).count == 1)
        #expect(await backend.requestedModes == requestsAfterFirst)
    }

    @Test("Starts queued at the same time give one discharge, with one start logged and the other refused")
    func queuedStartsGiveOne() async throws {
        let controller = makeController()
        async let a = controller.startDischargeToLimit()
        async let b = controller.startDischargeToLimit()
        _ = await (a, b)
        let status = await controller.status
        #expect(requestedEvents(status).count == 1)
        #expect(notStartedEvents(status).count == 1)
        #expect(status.activeOverride?.kind == .dischargeToLimit)
    }

    @Test("A start while a full charge runs leaves the full charge and its deadline as they are, and requests no discharge")
    func startBehindFullCharge() async throws {
        let backend = MockChargingBackend()
        let controller = makeController(backend: backend)
        let started = await controller.startFullCharge()
        let fullCharge = try #require(started.activeOverride)
        #expect(fullCharge.kind == .fullCharge)
        clock.advance(by: 60)
        let status = await controller.startDischargeToLimit()
        #expect(status.activeOverride == fullCharge)
        #expect(status.decision?.state == .fullChargeOverride)
        #expect(status.overridesEnded == started.overridesEnded)
        #expect(notStartedEvents(status) == ["Discharge not started: a temporary full charge is running."])
        #expect(requestedEvents(status).isEmpty)
        let requested = await backend.requestedModes
        #expect(!requested.contains(.forceDischarge))
    }

    @Test("A start while a full charge a schedule started runs leaves it as it is, still the schedule's")
    func startBehindScheduledFullCharge() async throws {
        let controller = makeController()
        let start = clock.now.addingTimeInterval(hour)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(4 * hour)))
        clock.advance(by: hour + 60)
        let started = await controller.evaluate(.periodic)
        let scheduled = try #require(started.activeOverride)
        #expect(scheduled.source == .schedule)

        clock.advance(by: 60)
        let status = await controller.startDischargeToLimit()
        #expect(status.activeOverride == scheduled)
        #expect(status.overridesEnded == started.overridesEnded)
        #expect(status.fullChargeScheduleOutcome == started.fullChargeScheduleOutcome)
        #expect(notStartedEvents(status) == ["Discharge not started: a temporary full charge is running."])
    }

    @Test("An override whose monotonic deadline passed before any evaluation ended it is replaced by the discharge", arguments: [ChargeOverride.Kind.dischargeToLimit, .fullCharge])
    func expiredOverrideReplaced(kind: ChargeOverride.Kind) async throws {
        let controller = makeController()
        let started = kind == .fullCharge ? await controller.startFullCharge() : await controller.startDischargeToLimit()
        let first = try #require(started.activeOverride)
        #expect(first.kind == kind)
        clock.advance(by: first.expiresAtUptime - clock.uptime + 1)
        let status = await controller.startDischargeToLimit()
        let replacement = try #require(status.activeOverride)
        #expect(replacement.kind == .dischargeToLimit)
        #expect(replacement.expiresAtUptime > first.expiresAtUptime)
        #expect(notStartedEvents(status).isEmpty)
        #expect(requestedEvents(status).count == (kind == .dischargeToLimit ? 2 : 1))
    }

    @Test("With a limit outside 20–95% the start is refused with the same message as before, also while a full charge runs", arguments: [false, true])
    func limitCheckedFirst(fullChargeRunning: Bool) async throws {
        let controller = makeController()
        var running: ChargeOverride?
        if fullChargeRunning {
            let fullCharge = try #require(await controller.startFullCharge().activeOverride)
            #expect(fullCharge.kind == .fullCharge)
            running = fullCharge
        }
        try await controller.apply(settings: ChargingSettings(chargeLimit: 100, resumeThreshold: 90))
        clock.advance(by: 60)
        let status = await controller.startDischargeToLimit()
        #expect(status.activeOverride == running)
        #expect(notStartedEvents(status) == ["Discharge not started: requires charge management on and a limit of 20–95%."])
    }

    @Test("With Manage charging off the start is refused with the same message as before")
    func managementCheckedFirst() async throws {
        let controller = makeController()
        var settings = ChargingSettings.default
        settings.isManagementEnabled = false
        try await controller.apply(settings: settings)
        let status = await controller.startDischargeToLimit()
        #expect(status.activeOverride == nil)
        #expect(notStartedEvents(status) == ["Discharge not started: requires charge management on and a limit of 20–95%."])
    }
}
