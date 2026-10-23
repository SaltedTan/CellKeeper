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
            systemPowerInMilliwatts: 36_250,
            systemLoadMilliwatts: 34_848,
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
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
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
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
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

    /// A full charge the user started, with a schedule armed for later;
    /// then, once the user cancelled it, the schedule's own full charge.
    static func overrideAndSchedule() async throws -> (armed: ControllerStatus, started: ControllerStatus) {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 70), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: MockChargingBackend(),
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: InMemoryStorage()),
            now: { clock.now },
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
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
        let controller = ChargeController(telemetry: telemetry, backend: backend, settings: .default, now: { clock.now }, uptime: { clock.uptime }, chargeLimitSettleTime: 0)
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

    /// A temperature pause on the Simulated backend: the reason names
    /// temperatures as the policy writes them ("41.5°C").
    static func temperaturePause() async -> ControllerStatus {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 70, temperature: 41.5), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
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
    /// record.
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
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
        )
        return await controller.evaluate(.launch)
    }

    /// Like ``nativeLimitKeptOutsideChange()``, but changed to no limit;
    /// then a switch to the Simulated backend, which waits until the marker
    /// is saved.
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
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
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
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
        )
        let start = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(3600)))
        clock.advance(by: 3600)
        let waiting = await controller.evaluate(.periodic)
        clock.advance(by: 3600)
        let passed = await controller.evaluate(.periodic)
        return (waiting, passed)
    }

    /// The status before any evaluation: no reading, no decision and no
    /// activity yet.
    static func beforeFirstEvaluation() async -> ControllerStatus {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 78), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        return await controller.status
    }

    /// A backend that says it controls hardware (``AvailableBackend``), with
    /// temperature protection off and a reading without a charge or a
    /// temperature.
    static func availableBackend() async -> ControllerStatus {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: nil, temperature: nil), clock: clock)
        var settings = ChargingSettings.default
        settings.temperatureProtection.isEnabled = false
        let controller = ChargeController(telemetry: telemetry, backend: AvailableBackend(), settings: settings, now: { clock.now }, uptime: { clock.uptime })
        return await controller.evaluate(.launch)
    }

    /// The Simulated helper while macOS reports no active Charge Limit.
    static func macOSLimitOff() async -> ControllerStatus {
        let rig = HelperRig(macOSReader: StubMacOSChargeLimit(.noLimit))
        let (controller, _) = rig.controller(percent: 85)
        return await rig.confirmedEvaluation(controller)
    }

    /// Turning management on was refused: CellKeeper kept a change made
    /// outside it and could not remove its record.
    static func managementRefused() async throws -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let controller = nativeController(system: system, store: store, clock: clock, limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)
        store.removeFails = true
        return try await controller.apply(settings: ChargingSettings.default.withChargeLimit(90), adoptionsSeen: 1)
    }

    /// CellKeeper's limit is the user's own 80%, so nothing is changed.
    static func nativeLimitUnchanged() async -> ControllerStatus {
        let clock = TestClock()
        let controller = nativeController(system: FakeChargeLimitSystem(reading: .limit(80)), store: InMemoryRecordStore(), clock: clock, limit: 80)
        return await controller.evaluate(.launch)
    }

    /// A native-limit backend that has not read macOS's Charge Limit
    /// (``UnreadNativeLimitBackend``).
    static func nativeLimitNotRead() async -> ControllerStatus {
        let clock = TestClock()
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: UnreadNativeLimitBackend(), settings: ChargingSettings.default.withChargeLimit(85), now: { clock.now }, uptime: { clock.uptime }, chargeLimitSettleTime: 0)
        return await controller.evaluate(.launch)
    }

    /// macOS's Charge Limit backend without the user's shortcut.
    static func nativeLimitNoShortcut() async -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80), shortcutNames: [])
        let controller = nativeController(system: system, store: InMemoryRecordStore(), clock: clock, limit: 85)
        return await controller.evaluate(.launch)
    }

    /// Quitting could not restore the user's own limit: the shortcut failed.
    static func nativeLimitRestoreUnfinished() async -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let controller = nativeController(system: system, store: InMemoryRecordStore(), clock: clock, limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        system.runBehaviour = .fails
        return await controller.shutdown(reason: "CellKeeper is quitting")
    }

    /// Management turned off on battery power after macOS cleared its active
    /// limit: the restore waits for power and has written nothing.
    static func nativeLimitRestoreWaitingForPower() async throws -> ControllerStatus {
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
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
        )
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        await telemetry.set(snapshot(percent: 78, source: .battery))
        _ = await controller.evaluate(.periodic)
        clock.advance(by: 600)
        system.isActiveLimitCleared = true
        await telemetry.set(snapshot(percent: 70, source: .battery))
        _ = await controller.evaluate(.periodic)
        var settings = ChargingSettings.default.withChargeLimit(85)
        settings.isManagementEnabled = false
        return try await controller.apply(settings: settings)
    }

    /// Management turned off while the shortcut fails, so CellKeeper wants
    /// the user's own recorded limit back and has not restored it yet.
    static func nativeLimitRestorePending() async throws -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let controller = nativeController(system: system, store: InMemoryRecordStore(), clock: clock, limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        system.runBehaviour = .fails
        var settings = ChargingSettings.default.withChargeLimit(90)
        settings.isManagementEnabled = false
        return try await controller.apply(settings: settings)
    }

    /// The limit was changed outside CellKeeper before it last stopped; this
    /// session finds the change and keeps it.
    static func nativeLimitEarlierSessionAdoption() async -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let first = nativeController(system: system, store: store, clock: clock, limit: 90)
        await first.evaluate(.launch)
        clock.advance(by: 60)
        system.changeExternally(to: 95)
        await first.evaluate(.periodic)
        clock.advance(by: 60)
        let second = nativeController(system: system, store: store, clock: clock, limit: 90)
        return await second.evaluate(.launch)
    }

    /// A change outside CellKeeper found just before it wrote a new limit,
    /// so the request ended by keeping that change.
    static func nativeLimitAdoptedBeforeWrite() async throws -> ControllerStatus {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let controller = nativeController(system: system, store: InMemoryRecordStore(), clock: clock, limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        system.changeExternally(to: 85, afterReads: 1)
        return try await controller.apply(settings: ChargingSettings.default.withChargeLimit(95))
    }

    /// A schedule that starts while the battery is already full.
    static func scheduleAlreadyFull() async throws -> ControllerStatus {
        let clock = TestClock()
        let (controller, _) = scheduleController(clock: clock, reading: snapshot(percent: 100, charging: false, fullyCharged: true))
        let start = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(7200)))
        clock.advance(by: 3600)
        return await controller.evaluate(.periodic)
    }

    /// A schedule that starts while a shorter full charge the user started
    /// is running, so it extends that full charge.
    static func scheduleExtendedRunning() async throws -> ControllerStatus {
        let clock = TestClock()
        let (controller, _) = scheduleController(clock: clock, reading: snapshot(percent: 70))
        let start = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(7200)))
        clock.advance(by: 3000)
        await controller.startFullCharge(duration: 3600)
        clock.advance(by: 600)
        return await controller.evaluate(.periodic)
    }

    /// A schedule that starts while a longer full charge the user started is
    /// running, which continues unchanged.
    static func scheduleKeptRunning() async throws -> ControllerStatus {
        let clock = TestClock()
        let (controller, _) = scheduleController(clock: clock, reading: snapshot(percent: 70))
        await controller.startFullCharge()
        let start = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(7200)))
        clock.advance(by: 3600)
        return await controller.evaluate(.periodic)
    }

    /// A saved schedule that cannot be read is removed at the first command.
    static func scheduleDiscarded() async -> ControllerStatus {
        let clock = TestClock()
        let storage = InMemoryStorage()
        storage.set("not a schedule", forKey: FullChargeScheduleStore.key)
        let (controller, _) = scheduleController(clock: clock, reading: snapshot(percent: 70), storage: storage)
        return await controller.evaluate(.launch)
    }

    /// A schedule whose window passed with no check during it, so no reason
    /// it waited was seen.
    static func scheduleWindowPassedUnseen() async throws -> ControllerStatus {
        let clock = TestClock()
        let (controller, _) = scheduleController(clock: clock, reading: snapshot(percent: 70))
        let start = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(3600)))
        clock.advance(by: 3 * 3600)
        return await controller.evaluate(.periodic)
    }

    /// A schedule that starts while a full charge the user started is
    /// running with exactly the deadline the schedule would give, which
    /// continues unchanged.
    static func scheduleKeptRunningSameDeadline() async throws -> ControllerStatus {
        let clock = TestClock()
        let (controller, _) = scheduleController(clock: clock, reading: snapshot(percent: 70))
        let start = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(7200)))
        await controller.startFullCharge(duration: 3 * 3600)
        clock.advance(by: 3600)
        return await controller.evaluate(.periodic)
    }

    // MARK: - Weekly full charge

    private static func utc(_ text: String) -> Date {
        try! Date(text, strategy: .iso8601)
    }

    /// Saturdays at 20:00 for 12 hours in New York, due on Saturday
    /// 2026-10-31 while the Mac is on battery: its window runs from EDT into
    /// EST, so its two ends carry different offsets.
    static func weeklyDueAcrossOffsetChange() async throws -> ControllerStatus {
        let clock = TestClock(utc("2026-10-30T16:00:00Z"))
        let (controller, _) = weeklyController(clock: clock, zone: FixtureZone(TimeZone(identifier: "America/New_York")!), reading: snapshot(percent: 70, source: .battery))
        try await controller.setWeeklyFullCharge(WeeklyFullChargePattern(weekdays: [7], hour: 20, minute: 0, durationHours: 12))
        clock.advance(by: utc("2026-11-01T00:30:00Z").timeIntervalSince(clock.now))
        return await controller.evaluate(.periodic)
    }

    /// Fridays at 07:00, started in London; then the Mac is in New York, so
    /// the record's offset differs from the next occurrence's.
    static func weeklyStartedThenTravelled() async throws -> ControllerStatus {
        let clock = TestClock(utc("2026-10-22T12:00:00Z"))
        let zone = FixtureZone(TimeZone(identifier: "Europe/London")!)
        let (controller, _) = weeklyController(clock: clock, zone: zone, reading: snapshot(percent: 70))
        try await controller.setWeeklyFullCharge(WeeklyFullChargePattern(weekdays: [6], hour: 7, minute: 0, durationHours: 12))
        clock.advance(by: utc("2026-10-23T06:00:30Z").timeIntervalSince(clock.now))
        await controller.evaluate(.periodic)
        zone.current = TimeZone(identifier: "America/New_York")!
        return await controller.evaluate(.clockChanged)
    }

    /// A weekly full charge saved while its store drops every write.
    static func weeklyStoreNotSaved() async throws -> ControllerStatus {
        let clock = TestClock(utc("2026-10-22T12:00:00Z"))
        let storage = FlakyStorage()
        storage.set(mode: .droppingWrites)
        let (controller, _) = weeklyController(clock: clock, zone: FixtureZone(TimeZone(identifier: "Europe/London")!), reading: snapshot(percent: 70), storage: storage)
        return try await controller.setWeeklyFullCharge(WeeklyFullChargePattern(weekdays: [2, 4, 6], hour: 7, minute: 30, durationHours: 1))
    }

    /// A weekly full charge whose window passed, then removed: only the
    /// outcome is left.
    static func weeklyRemovedAfterPassing() async throws -> ControllerStatus {
        let clock = TestClock(utc("2026-10-22T12:00:00Z"))
        let (controller, _) = weeklyController(clock: clock, zone: FixtureZone(TimeZone(identifier: "Europe/London")!), reading: snapshot(percent: 70))
        try await controller.setWeeklyFullCharge(WeeklyFullChargePattern(weekdays: [6], hour: 7, minute: 0, durationHours: 12))
        clock.advance(by: utc("2026-10-23T19:00:00Z").timeIntervalSince(clock.now))
        await controller.evaluate(.didWake)
        return await controller.removeWeeklyFullCharge()
    }

    /// The one-shot and the weekly full charge due together with the same
    /// end: the one-shot starts a full charge, which the weekly one keeps.
    static func bothDueSameDeadline() async throws -> ControllerStatus {
        let clock = TestClock(utc("2026-10-22T12:00:00Z"))
        let (controller, _) = weeklyController(clock: clock, zone: FixtureZone(TimeZone(identifier: "Europe/London")!), reading: snapshot(percent: 70), withOneShot: true)
        try await controller.setWeeklyFullCharge(WeeklyFullChargePattern(weekdays: [6], hour: 7, minute: 0, durationHours: 12))
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: utc("2026-10-23T06:00:00Z"), endsAt: utc("2026-10-23T18:00:00Z")))
        clock.advance(by: utc("2026-10-23T06:00:30Z").timeIntervalSince(clock.now))
        return await controller.evaluate(.periodic)
    }

    /// Every fixture's status, named, for tests that check them all.
    static func all() async throws -> [(name: String, status: ControllerStatus)] {
        let (armed, started) = try await overrideAndSchedule()
        let (waiting, passed) = try await scheduleWaitingThenPassed()
        return [
            ("simulated", await simulated()),
            ("nativeLimit", await nativeLimit()),
            ("nativeLimitKeptOutsideChange", await nativeLimitKeptOutsideChange()),
            ("noTelemetry", await noTelemetry()),
            ("noBattery", await noBattery()),
            ("deferringToMacOS", await deferringToMacOS()),
            ("overrideAndSchedule.armed", armed),
            ("overrideAndSchedule.started", started),
            ("faulted", await faulted()),
            ("readOnlyConfirming", await readOnlyConfirming()),
            ("temperaturePause", await temperaturePause()),
            ("discharging", await discharging()),
            ("nativeLimitUnreadable", await nativeLimitUnreadable()),
            ("nativeLimitPendingSwitch", await nativeLimitPendingSwitch()),
            ("macOSLimitUnreadable", await macOSLimitUnreadable()),
            ("scheduleWaitingThenPassed.waiting", waiting),
            ("scheduleWaitingThenPassed.passed", passed),
            ("beforeFirstEvaluation", await beforeFirstEvaluation()),
            ("availableBackend", await availableBackend()),
            ("macOSLimitOff", await macOSLimitOff()),
            ("managementRefused", try await managementRefused()),
            ("nativeLimitUnchanged", await nativeLimitUnchanged()),
            ("nativeLimitNotRead", await nativeLimitNotRead()),
            ("nativeLimitNoShortcut", await nativeLimitNoShortcut()),
            ("nativeLimitRestoreUnfinished", await nativeLimitRestoreUnfinished()),
            ("nativeLimitRestoreWaitingForPower", try await nativeLimitRestoreWaitingForPower()),
            ("nativeLimitRestorePending", try await nativeLimitRestorePending()),
            ("nativeLimitEarlierSessionAdoption", await nativeLimitEarlierSessionAdoption()),
            ("nativeLimitAdoptedBeforeWrite", try await nativeLimitAdoptedBeforeWrite()),
            ("scheduleAlreadyFull", try await scheduleAlreadyFull()),
            ("scheduleExtendedRunning", try await scheduleExtendedRunning()),
            ("scheduleKeptRunning", try await scheduleKeptRunning()),
            ("scheduleDiscarded", await scheduleDiscarded()),
            ("scheduleWindowPassedUnseen", try await scheduleWindowPassedUnseen()),
            ("scheduleKeptRunningSameDeadline", try await scheduleKeptRunningSameDeadline()),
            ("weeklyDueAcrossOffsetChange", try await weeklyDueAcrossOffsetChange()),
            ("weeklyStartedThenTravelled", try await weeklyStartedThenTravelled()),
            ("weeklyStoreNotSaved", try await weeklyStoreNotSaved()),
            ("weeklyRemovedAfterPassing", try await weeklyRemovedAfterPassing()),
            ("bothDueSameDeadline", try await bothDueSameDeadline()),
        ]
    }

    /// A controller on the Simulated backend with a weekly store over
    /// `storage`, reading its local times in `zone`, and a one-shot schedule
    /// store if `withOneShot`.
    private static func weeklyController(clock: TestClock, zone: FixtureZone, reading: BatterySnapshot, storage: any KeyValueStorage = InMemoryStorage(), withOneShot: Bool = false) -> (ChargeController, StubTelemetry) {
        let telemetry = StubTelemetry(reading, clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: MockChargingBackend(),
            settings: .default,
            scheduleStore: withOneShot ? FullChargeScheduleStore(defaults: InMemoryStorage()) : nil,
            weeklyStore: WeeklyFullChargeStore(defaults: storage),
            now: { clock.now },
            timeZone: { zone.current },
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
        )
        return (controller, telemetry)
    }

    /// A controller on macOS's Charge Limit backend with the adoption marker
    /// in `store`, and a reading of 78%, charging.
    private static func nativeController(system: FakeChargeLimitSystem, store: InMemoryRecordStore, clock: TestClock, limit: Int) -> ChargeController {
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        return ChargeController(
            telemetry: telemetry,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(limit),
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
        )
    }

    /// A controller on the Simulated backend with a schedule store.
    private static func scheduleController(clock: TestClock, reading: BatterySnapshot, storage: InMemoryStorage = InMemoryStorage()) -> (ChargeController, StubTelemetry) {
        let telemetry = StubTelemetry(reading, clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: MockChargingBackend(),
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: storage),
            now: { clock.now },
            uptime: { clock.uptime },
            chargeLimitSettleTime: 0
        )
        return (controller, telemetry)
    }
}

/// A backend that says it controls hardware, which no backend in this
/// version does, so that the report's "available" is exercised. It changes
/// nothing; a request takes effect at once and is read back.
actor AvailableBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "test-available", displayName: "Test hardware", summary: "")
    private var mode: ChargeControlMode = .normal

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .available, supportedModes: ChargeControlMode.chargingModes)
    }

    func currentMode() -> ChargeControlMode? { mode }

    func setMode(_ newMode: ChargeControlMode) -> ControlOutcome {
        defer { mode = newMode }
        return newMode == mode ? .unchanged : .applied
    }
}

/// A native-limit backend that never reads macOS's Charge Limit, so its
/// status has no read time. The real backend reads the limit at every
/// evaluation; this exists only so that the report's branch for a status
/// without a read time is exercised.
actor UnreadNativeLimitBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "test-unread-native", displayName: "Test Charge Limit", summary: "")

    func capabilities() -> ControlCapabilities {
        .nativeLimit(availability: .unavailable(reason: "The test backend reads nothing."), steps: NativeChargeLimitBackend.supportedLimits)
    }

    func currentMode() -> ChargeControlMode? { nil }

    func setMode(_ mode: ChargeControlMode) throws -> ControlOutcome {
        throw BackendError.unavailable("The test backend reads nothing.")
    }

    func nativeLimitStatus() -> NativeLimitStatus? {
        NativeLimitStatus()
    }
}

/// The time zone a fixture's controller reads, which the fixture may
/// change between evaluations.
final class FixtureZone: @unchecked Sendable {
    private let lock = NSLock()
    private var zone: TimeZone

    init(_ zone: TimeZone) { self.zone = zone }

    var current: TimeZone {
        get { lock.withLock { zone } }
        set { lock.withLock { zone = newValue } }
    }
}
