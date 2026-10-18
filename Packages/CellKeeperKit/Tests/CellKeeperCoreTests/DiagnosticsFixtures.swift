import CellKeeperCore
import Foundation

/// Statuses for the diagnostics report's tests, each made by a controller on
/// a test clock, so every timestamp is fixed.
enum DiagnosticsFixture {
    static let environment = DiagnosticsEnvironment(appVersion: "0.1.0 (1)", systemVersion: "Version 27.0.1 (Build 26A434)", modelIdentifier: "Mac16,1")

    /// The account name in ``noTelemetry()``'s error, which the report must
    /// not contain.
    static let accountName = "alice.smith"

    /// The Simulated backend holding at the limit, with every battery value
    /// the report shows.
    static func simulated() async -> ControllerStatus {
        let clock = TestClock()
        let health = BatteryHealth(cycleCount: 54, fullChargeCapacityMilliampHours: 6131, designCapacityMilliampHours: 6249, condition: "Good")
        let reading = BatterySnapshot(
            timestamp: referenceDate,
            sourceTimestamp: referenceDate.addingTimeInterval(-20),
            chargePercent: 81,
            powerSource: .externalPower,
            isCharging: false,
            isFullyCharged: false,
            temperatureCelsius: 31,
            voltageMillivolts: 12_427,
            amperageMilliamps: -12,
            adapterWatts: 70,
            health: health
        )
        let telemetry = StubTelemetry(reading, clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        var later = reading
        later.sourceTimestamp = clock.now.addingTimeInterval(-20)
        await telemetry.set(later)
        return await controller.evaluate(.periodic)
    }

    /// macOS's Charge Limit backend with the user's own limit of 80%
    /// recorded and CellKeeper's 85% in effect.
    static func nativeLimit() async -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(85),
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        return await controller.evaluate(.launch)
    }

    /// macOS's Charge Limit changed to 95% outside CellKeeper, kept as the
    /// user's own, while the adoption marker cannot be saved.
    static func nativeLimitKeptOutsideChange() async -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(90),
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        store.saveFails = true
        system.changeExternally(to: 95)
        return await controller.evaluate(.periodic)
    }

    /// No reading: telemetry fails with an error whose path names the
    /// macOS account.
    static func noTelemetry() async -> ControllerStatus {
        struct FileError: Error, CustomStringConvertible {
            var description: String {
                "The file “battery.plist” couldn’t be opened. (NSFilePath=/Users/\(DiagnosticsFixture.accountName)/Library/Containers/io.github.saltedtan.CellKeeper/Data/battery.plist)"
            }
        }
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 78), clock: clock)
        await telemetry.fail(with: FileError())
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        return await controller.evaluate(.launch)
    }

    /// A reading of a Mac without a battery.
    static func noBattery() async -> ControllerStatus {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: nil, present: false), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        return await controller.evaluate(.launch)
    }

    /// The Simulated helper held charging at the limit; then macOS's own
    /// Charge Limit was turned on at 80%, so CellKeeper defers to it.
    static func deferringToMacOS() async -> ControllerStatus {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        reader.set(.limit(80))
        rig.clock.advance(by: 60)
        return await controller.evaluate(.periodic)
    }

    /// A full charge the user started, with a schedule armed for later.
    static func overrideAndSchedule() async throws -> (armed: ControllerStatus, started: ControllerStatus) {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 70), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: MockChargingBackend(),
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: InMemoryStorage()),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        await controller.evaluate(.launch)
        await controller.startFullCharge()
        let start = clock.now.addingTimeInterval(3600)
        let armed = try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(7200)))
        // The user's full charge ends; the schedule then starts its own.
        await controller.cancelOverride()
        clock.advance(by: 3600)
        let started = await controller.evaluate(.periodic)
        return (armed, started)
    }

    /// The Simulated backend failed every request until it faulted.
    static func faulted() async -> ControllerStatus {
        let clock = TestClock()
        let backend = MockChargingBackend()
        await backend.failNextRequests(10)
        let telemetry = StubTelemetry(snapshot(percent: 85), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: backend, settings: .default, now: { clock.now }, uptime: { clock.uptime })
        var status = await controller.evaluate(.launch)
        for _ in 0..<10 where !status.isBackendFaulted {
            clock.advance(by: 120)
            status = await controller.evaluate(.periodic)
        }
        return status
    }

    /// Read-only, which controls nothing, at a first reading at the limit,
    /// with the note that the next reading must confirm it.
    static func readOnlyConfirming() async -> ControllerStatus {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 81), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: ReadOnlyChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        return await controller.evaluate(.launch)
    }

    /// A discharge to the limit the user started while plugged in.
    static func discharging() async -> ControllerStatus {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 90), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        await controller.evaluate(.launch)
        return await controller.startDischargeToLimit()
    }

    /// macOS's Charge Limit backend that can read neither the limit nor its
    /// record, and finds no shortcut.
    static func nativeLimitUnreadable() async -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80), shortcutNames: [])
        system.readFails = true
        let store = InMemoryRecordStore()
        store.loadFails = true
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(85),
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        return await controller.evaluate(.launch)
    }

    /// ``nativeLimitKeptOutsideChange()``, then a switch to the Simulated
    /// backend, which waits until the marker is saved.
    static func nativeLimitPendingSwitch() async -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(90),
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        store.saveFails = true
        system.changeExternally(to: 100)
        await controller.evaluate(.periodic)
        return await controller.switchBackend(to: MockChargingBackend())
    }

    /// The Simulated helper while macOS's Charge Limit report cannot be read.
    static func macOSLimitUnreadable() async -> ControllerStatus {
        let reader = StubMacOSChargeLimit(.noLimit)
        reader.fail("pmset -g battlimit failed: exit status 1")
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        return await rig.confirmedEvaluation(controller)
    }

    /// An armed schedule that is due while the Mac is on battery, then
    /// passes before it could start.
    static func scheduleWaitingThenPassed() async throws -> (waiting: ControllerStatus, passed: ControllerStatus) {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 70, source: .battery), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: MockChargingBackend(),
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: InMemoryStorage()),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        let start = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(3600)))
        clock.advance(by: 3600)
        let waiting = await controller.evaluate(.periodic)
        clock.advance(by: 3600)
        let passed = await controller.evaluate(.periodic)
        return (waiting, passed)
    }
}
