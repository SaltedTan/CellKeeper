@testable import CellKeeperCore
import Foundation
import Testing

/// The owner's state after 2026-10-21: macOS's "no limit" on battery power
/// was kept as an outside change. Manage charging is off, and the adoption
/// marker holds 100% (no limit), the owner's 80% before it, and CellKeeper's
/// 80%. System Settings still shows 80%.
let ownersAdoptionMarker = Data(#"{"adoptedLimit":100,"isNoLimit":true,"previousOwnerLimit":80,"expectedLimit":80,"adoptedAt":0}"#.utf8)

/// A controller on macOS's Charge Limit with the production settle window
/// (``ChargeController/chargeLimitSettleTime``), on a fake macOS that clears
/// its active limit as on battery power (research note 08, O20).
struct PowerRig {
    let clock: TestClock
    let system: FakeChargeLimitSystem
    let store: InMemoryRecordStore
    let telemetry: StubTelemetry
    let controller: ChargeController

    init(reading: NativeChargeLimitReading = .limit(80), limit: Int = 80, managed: Bool = true, power: PowerSource = .externalPower, store: InMemoryRecordStore = InMemoryRecordStore()) {
        let clock = TestClock()
        self.clock = clock
        system = FakeChargeLimitSystem(reading: reading)
        self.store = store
        telemetry = StubTelemetry(snapshot(percent: 75, source: power), clock: clock)
        var settings = ChargingSettings.default.withChargeLimit(limit)
        settings.isManagementEnabled = managed
        controller = ChargeController(
            telemetry: telemetry,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: settings,
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
    }

    func settings(limit: Int = 80, managed: Bool = true) -> ChargingSettings {
        var settings = ChargingSettings.default.withChargeLimit(limit)
        settings.isManagementEnabled = managed
        return settings
    }

    /// An evaluation with a reading at `percent` on `power`.
    func read(_ power: PowerSource, _ percent: Int = 75, _ trigger: EvaluationTrigger = .periodic) async -> ControllerStatus {
        await telemetry.set(snapshot(percent: percent, source: power))
        return await controller.evaluate(trigger)
    }

    /// Launches on external power and waits out the settle window: the
    /// owner's limit is recorded and CellKeeper's set, as a minute after
    /// any launch on power.
    @discardableResult
    func settledOnPower(sourceLocation: SourceLocation = #_sourceLocation) async -> ControllerStatus {
        await controller.evaluate(.launch)
        clock.advance(by: ChargeController.chargeLimitSettleTime)
        let status = await read(.externalPower)
        #expect(status.nativeLimit?.ownerLimit != nil, "recorded once settled", sourceLocation: sourceLocation)
        #expect(status.nativeLimit?.readDeferral == nil, sourceLocation: sourceLocation)
        return status
    }
}

/// True if an activity line says that the limit changed outside CellKeeper.
func saysChangedOutside(_ status: ControllerStatus) -> Bool {
    status.events.contains { $0.message.contains("changed outside CellKeeper") || $0.message.contains("Released the Charge Limit: adopted") }
}

/// A restore is written and unfinished, or unwritten and waiting: never
/// both at once (D119).
func expectRestoreStateIsConsistent(_ native: NativeLimitStatus?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!(native?.isRestoreUnfinished == true && native?.isRestoreWaitingForPower == true), "a written restore is never also waiting", sourceLocation: sourceLocation)
}

@Suite("macOS's Charge Limit is judged only on power, once settled")
struct NativeLimitPowerTests {
    // MARK: - On battery power

    @Test("On battery power, macOS clearing its limit is no outside change: nothing is adopted, Manage charging stays on, nothing fails")
    func clearedOnBattery() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        #expect(rig.system.runInputs == ["85"])
        _ = await rig.read(.battery, 75, .powerSourceChanged)

        // About 300 s after the unplug macOS clears its active limit.
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 325)
        var status = await rig.read(.battery, 70)
        for _ in 0..<3 {
            #expect(status.adoptionCount == 0)
            #expect(status.adoptedChange == nil)
            #expect(status.settings.isManagementEnabled)
            #expect(status.currentMode == .nativeLimit(percent: 85), "what CellKeeper last confirmed, unconfirmed")
            #expect(status.nativeLimit?.readDeferral == .onBattery)
            #expect(status.nativeLimit?.ownerLimit == 80, "the record of the owner's own limit stands")
            #expect(status.nativeLimit?.needsNoLimitConfirmation == false)
            #expect(status.consecutiveFailures == 0)
            #expect(!status.isBackendFaulted)
            #expect(!saysChangedOutside(status))
            #expect(NativeLimitWording.deferral(status.nativeLimit)?.hasPrefix("macOS applies its Charge Limit only on power.") == true)
            #expect(NativeChargeLimitBackend.pendingAdoption(in: rig.store) == nil)
            rig.clock.advance(by: 60)
            status = await rig.read(.battery, 65)
        }
        #expect(rig.system.runInputs == ["85"], "nothing written on battery power")

        // Plugged in: macOS creates its limit again at once.
        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 65, .powerSourceChanged)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(status.nativeLimit?.readDeferral == nil, "an active limit the record accounts for is evidence at once")
        rig.clock.advance(by: 61)
        status = await rig.read(.externalPower, 66)
        #expect(status.isNativeLimitSettled)
        #expect(status.adoptionCount == 0)
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("A no-limit report at a plug-in, before macOS creates its limit again, waits out the settle window")
    func plugInBeforeLimitReturns() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)

        // The first read after the plug-in comes before macOS's limit.
        var status = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.readDeferral == .settling)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime - 0.5)
        status = await rig.read(.externalPower, 70)
        #expect(status.adoptionCount == 0, "still inside the window")
        #expect(status.nativeLimit?.readDeferral == .settling)

        rig.system.isActiveLimitCleared = false
        rig.clock.advance(by: 0.5)
        status = await rig.read(.externalPower, 71)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.readDeferral == nil)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("The settle window counts monotonic time only: a wall clock set forward does not end it, and one set back does not prolong it")
    func settleWindowIgnoresWallClock() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.changeExternally(to: 100)
        rig.clock.advance(by: 600)
        var status = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(status.nativeLimit?.readDeferral == .settling)

        // An hour forward on the wall clock, 30 s on the monotonic one.
        rig.clock.shiftWall(by: 3600)
        rig.clock.advance(by: 30)
        status = await rig.read(.externalPower, 70)
        #expect(status.nativeLimit?.readDeferral == .settling, "30 s of power, whatever the wall clock says")
        #expect(status.adoptionCount == 0)

        // Two hours back on the wall clock: 60 s of power have passed.
        rig.clock.shiftWall(by: -7200)
        rig.clock.advance(by: 30)
        status = await rig.read(.externalPower, 71)
        #expect(status.nativeLimit?.readDeferral == nil)
        #expect(status.adoptedChange?.isNoLimit == true, "judged once 60 s have passed by the monotonic clock")
    }

    @Test("On power after the settle window, a genuine no-limit report is kept as today: adopted, Manage charging off")
    func genuineNoLimitOnPower() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // Set to 100% while unplugged; on power, after the window, macOS
        // still reports no limit.
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.changeExternally(to: 100)
        rig.clock.advance(by: 600)
        var status = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(status.adoptionCount == 0, "not inside the window")
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 71)
        #expect(status.adoptionCount == 1)
        #expect(status.adoptedChange?.isNoLimit == true)
        #expect(status.adoptedChange?.previousOwnerLimit == 80)
        #expect(!status.settings.isManagementEnabled)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("changed outside CellKeeper to no limit (100%)") && $0.message.contains("your earlier limit was 80%") })
        #expect(NativeChargeLimitBackend.pendingAdoption(in: rig.store)?.isNoLimit == true)
        #expect(rig.system.runInputs == ["85"], "nothing written over it")
    }

    @Test("A change outside CellKeeper shown as an active limit on battery power is judged once on power")
    func activeChangeOnBatteryJudgedOnPower() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.changeExternally(to: 90)
        var status = await rig.read(.battery, 74)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.readDeferral == .onBattery)
        #expect(status.currentMode == .nativeLimit(percent: 85))

        _ = await rig.read(.externalPower, 74, .powerSourceChanged)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptedChange?.limit == 90)
        #expect(!status.settings.isManagementEnabled)
        #expect(rig.system.reading == .limit(90))
    }

    @Test("A wake restarts the settle window, and so does a power source that cannot be read")
    func wakeAndUnknownPower() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.externalPower, 75, .willSleep)
        rig.clock.advance(by: 3600)
        // Woken on power; macOS's limit is not shown yet.
        rig.system.isActiveLimitCleared = true
        var status = await rig.read(.externalPower, 75, .didWake)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.adoptionCount == 0)
        rig.system.isActiveLimitCleared = false
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 75)
        #expect(status.nativeLimit?.readDeferral == nil)

        await rig.telemetry.fail(with: TelemetryTestError())
        rig.system.isActiveLimitCleared = true
        status = await rig.controller.evaluate(.periodic)
        #expect(status.nativeLimit?.readDeferral == .powerUnknown)
        #expect(status.adoptionCount == 0)
        rig.system.isActiveLimitCleared = false
        // Readable again: the window starts again from that reading.
        rig.clock.advance(by: 600)
        status = await rig.read(.externalPower, 75)
        #expect(status.nativeLimit?.readDeferral == nil)
        rig.system.changeExternally(to: 95)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime - 1)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptionCount == 0, "inside the window that began at the readable reading")
        rig.clock.advance(by: 1)
        status = await rig.read(.externalPower, 75)
        #expect(status.adoptedChange?.limit == 95)
    }

    // MARK: - Recording the owner's own limit

    @Test("Turning Manage charging on, on battery power, with the owner's saved state records nothing, even with no limit confirmed; on power, once settled, 80% is recorded")
    func managementOnOnBatteryRecordsNothing() async throws {
        let store = InMemoryRecordStore()
        store.data = ownersAdoptionMarker
        let rig = PowerRig(reading: .limit(80), managed: false, power: .battery, store: store)
        rig.system.isActiveLimitCleared = true
        var status = await rig.controller.evaluate(.launch)
        #expect(!status.settings.isManagementEnabled)
        #expect(status.nativeLimit?.needsNoLimitConfirmation == false, "no question about a no limit that was not judged")
        #expect(status.nativeLimit?.readDeferral == .onBattery)
        #expect(status.capabilities.availability.acceptsRequests)

        // Even with "no limit" confirmed as the owner's (by mistake, or
        // earlier in the session), nothing is recorded on battery power.
        status = await rig.controller.confirmNoLimitIsOwnerLimit()
        status = try await rig.controller.apply(settings: rig.settings(limit: 80), adoptionsSeen: status.adoptionCount)
        #expect(status.settings.isManagementEnabled)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store) == nil, "the marker is retired")
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil, "nothing recorded")
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(status.consecutiveFailures == 0)
        #expect(!status.events.contains { $0.message.contains("Recorded your own") })
        for _ in 0..<3 {
            rig.clock.advance(by: 60)
            status = await rig.read(.battery, 60)
            #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
        }
        #expect(rig.system.runInputs.isEmpty)

        // Plugged in: macOS shows 80% at once, but it is recorded only once
        // the window has passed.
        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 60, .powerSourceChanged)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 61)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 80)
        #expect(status.events.contains { $0.message.contains("Recorded your own macOS Charge Limit of 80%") })
        #expect(status.lastExecution?.result == .unchanged)

        // Quitting writes nothing: 80% is already in effect, never 100%.
        await rig.controller.shutdown(reason: "quit")
        #expect(rig.system.runInputs.isEmpty)
        #expect(rig.system.reading == .limit(80))
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
    }

    @Test("Quitting on battery power records nothing and writes nothing for the owner's saved state")
    func quitOnBatteryWithMarker() async throws {
        let store = InMemoryRecordStore()
        store.data = ownersAdoptionMarker
        let rig = PowerRig(reading: .limit(80), managed: false, power: .battery, store: store)
        rig.system.isActiveLimitCleared = true
        var status = await rig.controller.evaluate(.launch)
        status = try await rig.controller.apply(settings: rig.settings(limit: 85), adoptionsSeen: status.adoptionCount)
        await rig.controller.shutdown(reason: "quit")
        #expect(rig.system.runInputs.isEmpty)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
        #expect(rig.system.reading == .limit(80), "the setting is still the owner's")
    }

    // MARK: - Read-backs and restores on battery power

    @Test("A change made on battery power whose read-back shows no limit waits for power without failing, then is confirmed")
    func readBackOnBatteryWaits() async throws {
        let rig = PowerRig(limit: 80)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        // Still within 300 s: macOS shows 80%. The owner picks 85%, and
        // macOS creates no limit for it on battery power.
        rig.system.scheduleRuns([.appliesWithoutActiveLimit])
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85))
        #expect(rig.system.runInputs == ["85"])
        #expect(status.lastExecution?.result == .deferred(written: true))
        #expect(status.consecutiveFailures == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(status.events.contains { $0.kind == .result && $0.message.contains("not confirmed yet") && $0.message.contains("only on power") })
        #expect(!status.events.contains { $0.message.contains("safety fallback") })
        for _ in 0..<3 {
            rig.clock.advance(by: 120)
            status = await rig.read(.battery, 70)
            #expect(status.consecutiveFailures == 0)
            #expect(status.adoptionCount == 0)
            #expect(status.calibration.session == nil)
        }
        #expect(rig.system.runInputs == ["85"], "not written again while it waits")

        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(status.events.contains { $0.message.contains("Now confirmed: a macOS Charge Limit of 85%") })
        #expect(rig.system.runInputs == ["85"])
        rig.clock.advance(by: 61)
        status = await rig.read(.externalPower, 71)
        #expect(status.isNativeLimitSettled)
    }

    @Test("A change made on battery power that did not take is found on power and made again, by the usual rules")
    func readBackOnBatteryFailsOnPower() async throws {
        let rig = PowerRig(limit: 80)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.scheduleRuns([.hasNoEffectWithoutActiveLimit])
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85))
        #expect(status.lastExecution?.result == .deferred(written: true))
        #expect(status.consecutiveFailures == 0)
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)

        // On power macOS shows 80% again: CellKeeper's own, not an outside
        // change; 85% is asked for again and confirmed.
        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(rig.system.runInputs == ["85", "85"])
        #expect(status.lastExecution?.result == .applied)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(status.adoptionCount == 0)
        #expect(status.consecutiveFailures == 0)
    }

    @Test("Manage charging turned off on battery power waits to restore the owner's limit, then restores it on power")
    func restoreWaitsForPower() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(rig.system.runInputs == ["85"], "nothing written over what cannot be judged")
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(status.nativeLimit?.ownerLimit == 80, "still owed")
        #expect(status.consecutiveFailures == 0)
        #expect(status.adoptionCount == 0)
        #expect(status.events.contains { $0.message.hasPrefix("Waiting to set your own macOS Charge Limit of 80%. macOS applies its Charge Limit only on power.") })
        rig.clock.advance(by: 60)
        status = await rig.read(.battery, 69)
        #expect(status.events.filter { $0.message.hasPrefix("Waiting to set your own") }.count == 1, "logged once")
        #expect(status.events.filter { $0.message.hasPrefix("Requesting your own") }.count == 1)

        // On power macOS shows CellKeeper's 85% again: the restore goes ahead.
        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 69, .powerSourceChanged)
        #expect(rig.system.runInputs == ["85", "80"])
        #expect(rig.system.reading == .limit(80))
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
    }

    @Test("A restore that wrote nothing waits for power in the menu's and Settings' words, without a warning")
    func deferredRestoreSaysItWaitsForPower() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(status.currentMode == .nativeLimit(percent: 85), "the record's value, unconfirmed")
        #expect(status.nativeLimit?.isRestoreWaitingForPower == true)
        #expect(status.isOwnLimitRestoreWaitingForPower)
        #expect(!status.isOwnLimitRestorePending, "no critical warning: it resolves at the next plug-in")
        #expect(NativeLimitWording.restoreProblem(status) == nil)
        #expect(NativeLimitWording.restoreWaitingForPower(80) == "CellKeeper gives back your own limit, 80%, once your Mac has been on power for a minute and it has checked macOS's Charge Limit; if you change the limit meanwhile, it keeps your change. macOS applies its Charge Limit only on power.")
        #expect(NativeLimitWording.restoreWaitingForPowerValue(80) == "80%, recorded; given back once your Mac has been on power for a minute, unless you change the limit meanwhile")
        var planner = NotificationPlanner()
        let posts = planner.plan(status, trigger: .settingsChanged, uptime: rig.clock.uptime, isDelivering: true)
        #expect(!posts.contains { $0.kind == .restoreUnconfirmed })

        // Plugged in before macOS re-creates its limit: the read still
        // cannot be judged, so the restore keeps waiting and writes nothing.
        status = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.isOwnLimitRestoreWaitingForPower)
        #expect(rig.system.runInputs == ["85"])

        // Judged once power has settled: the restore is written, confirmed
        // and the state clears.
        rig.system.isActiveLimitCleared = false
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 70)
        #expect(rig.system.runInputs == ["85", "80"])
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(status.nativeLimit?.isRestoreWaitingForPower == false)
        #expect(!status.isOwnLimitRestoreWaitingForPower)
        #expect(!status.isOwnLimitRestorePending)
    }

    @Test("Turning management on again cancels a restore that waits for power, and writes nothing")
    func managementOnCancelsWaitingRestore() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(status.isOwnLimitRestoreWaitingForPower)

        status = try await rig.controller.apply(settings: rig.settings(limit: 85))
        #expect(!status.isOwnLimitRestoreWaitingForPower)
        #expect(!status.isOwnLimitRestorePending)
        #expect(status.nativeLimit?.ownerLimit == 80, "the record still stands")
        #expect(status.nativeLimit?.isRestoreUnfinished == false)
        #expect(rig.system.runInputs == ["85"], "nothing written")

        // On power the limit CellKeeper wants is still 85%: the restore it
        // cancelled is not attempted.
        rig.system.isActiveLimitCleared = false
        _ = await rig.read(.externalPower, 70, .powerSourceChanged)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 70)
        #expect(rig.system.runInputs == ["85"])
        #expect(!status.isOwnLimitRestoreWaitingForPower)
        #expect(status.nativeLimit?.ownerLimit == 80)
    }

    @Test("A restore written when power returns is owed, not waiting for power")
    func writtenRestoreIsNotWaiting() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(status.isOwnLimitRestoreWaitingForPower)
        #expect(rig.system.runInputs == ["85"])

        // Plugged in before the settle window ends: macOS shows CellKeeper's
        // 85% again, so the restore is written, but its read-back cannot be
        // judged, so it is owed, not waiting.
        rig.system.isActiveLimitCleared = false
        rig.system.scheduleRuns([.appliesWithoutActiveLimit])
        status = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(status.lastExecution?.result == .deferred(written: true))
        #expect(status.nativeLimit?.isRestoreUnfinished == true)
        #expect(status.nativeLimit?.isRestoreWaitingForPower == false)
        #expect(!status.isOwnLimitRestoreWaitingForPower)
    }

    @Test("A judged read that shows your own limit back ends a restore's wait without writing")
    func ownerLimitBackEndsWaitingRestore() async throws {
        let rig = PowerRig(limit: 80)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 80, managed: false))
        #expect(status.isOwnLimitRestoreWaitingForPower)
        #expect(rig.system.runInputs.isEmpty, "nothing written on battery power")

        rig.system.isActiveLimitCleared = false
        rig.system.changeExternally(to: 80)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 70)
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(!status.isOwnLimitRestoreWaitingForPower)
        #expect(rig.system.runInputs.isEmpty)
    }

    @Test("A judged outside change ends a restore's wait, and nothing is written over it")
    func outsideChangeEndsWaitingRestore() async throws {
        let rig = PowerRig(limit: 80)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 80, managed: false))
        #expect(status.isOwnLimitRestoreWaitingForPower)

        rig.system.isActiveLimitCleared = false
        rig.system.changeExternally(to: 90)
        status = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(status.nativeLimit?.readDeferral == .settling, "power just returned")
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.read(.externalPower, 70)
        #expect(status.adoptionCount == 1)
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(!status.isOwnLimitRestoreWaitingForPower)
        #expect(rig.system.runInputs.isEmpty, "nothing written over the outside change")
    }

    @Test("Quitting on battery power after macOS cleared its limit writes nothing and leaves the record for the next launch")
    func quitOnBatteryLeavesRecord() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)
        let stopped = await rig.controller.shutdown(reason: "CellKeeper is quitting")
        #expect(rig.system.runInputs == ["85"])
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store)?.ownerLimit == 80, "quitting warns, and the next launch restores")
        #expect(stopped.adoptionCount == 0)
        #expect(stopped.events.contains { $0.kind == .safety && $0.message.contains("Restoring your own macOS Charge Limit of 80% (CellKeeper is quitting) waits; nothing was changed.") })
    }

    @Test("A restore made just after an unplug, while macOS still shows CellKeeper's limit, goes ahead; a read-back of no limit waits")
    func restoreJustAfterUnplug() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.scheduleRuns([.appliesWithoutActiveLimit])
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(rig.system.runInputs == ["85", "80"])
        #expect(status.lastExecution?.result == .deferred(written: true))
        #expect(status.nativeLimit?.isRestoreUnfinished == true)
        #expect(status.currentMode == nil, "either may be in effect")
        #expect(status.consecutiveFailures == 0)
        rig.clock.advance(by: 120)
        status = await rig.read(.battery, 74)
        #expect(rig.system.runInputs == ["85", "80"], "not written again while it waits")
        #expect(status.currentMode == nil, "the owner's limit may be in effect, not only CellKeeper's 85%")
        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 74, .powerSourceChanged)
        #expect(status.nativeLimit?.ownerLimit == nil, "the restore is confirmed by macOS showing the owner's 80%")
        #expect(rig.system.runInputs == ["85", "80"])
    }

    @Test("A restore written on battery power is owed until confirmed, so turning management on again finishes it first; one that wrote nothing is not owed")
    func restoreOwedOnlyWhenWritten() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.scheduleRuns([.appliesWithoutActiveLimit])
        _ = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        var status = try await rig.controller.apply(settings: rig.settings(limit: 85))
        #expect(status.decision?.reason == .releaseRequired(.restoreUnfinished))
        #expect(rig.system.runInputs == ["85", "80"])

        let other = PowerRig(limit: 85)
        await other.settledOnPower()
        _ = await other.read(.battery, 75, .powerSourceChanged)
        other.system.isActiveLimitCleared = true
        other.clock.advance(by: 600)
        _ = try await other.controller.apply(settings: other.settings(limit: 85, managed: false))
        status = try await other.controller.apply(settings: other.settings(limit: 85))
        #expect(status.decision?.state == .osEnforcedLimit)
        #expect(status.decision?.action == .noAction)
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(other.system.runInputs == ["85"])
    }

    @Test("A restore outside an evaluation, such as quitting, judges by the time it runs, not by the last evaluation's")
    func quitJudgesByItsOwnTime() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        var status = await rig.read(.externalPower, 75, .powerSourceChanged)
        #expect(status.nativeLimit?.readDeferral == nil)
        // Set to 100% on power; CellKeeper quits a minute later, with no
        // check in between.
        rig.system.changeExternally(to: 100)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        status = await rig.controller.shutdown(reason: "quit")
        #expect(status.adoptedChange?.isNoLimit == true, "judged: kept as the owner's change")
        #expect(NativeChargeLimitBackend.pendingAdoption(in: rig.store)?.isNoLimit == true)
        #expect(rig.system.runInputs == ["85"])
    }

    @Test("A request that waits for power neither counts as a failure nor clears earlier ones")
    func waitKeepsFailureCount() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        // A change whose shortcut fails: one failure; the fallback gives
        // back the owner's own limit.
        rig.system.scheduleRuns([.fails])
        rig.clock.advance(by: 61)
        var status = try await rig.controller.apply(settings: rig.settings(limit: 90))
        #expect(status.consecutiveFailures == 1)
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        status = try await rig.controller.apply(settings: rig.settings(limit: 95))
        #expect(status.lastExecution?.result == .deferred(written: false))
        #expect(status.consecutiveFailures == 1)
    }

    // MARK: - A value written and not confirmed (review of PR #110)

    /// Settled on power at CellKeeper's 85%, unplugged, plugged in again,
    /// and a full charge started inside the settle window: 100% is written
    /// and macOS's "no limit" read-back cannot confirm it yet.
    private func fullChargeAwaitingConfirmation(sourceLocation: SourceLocation = #_sourceLocation) async -> PowerRig {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.clock.advance(by: 600)
        _ = await rig.read(.externalPower, 74, .powerSourceChanged)
        let status = await rig.controller.startFullCharge()
        #expect(rig.system.runInputs == ["85", "100"], sourceLocation: sourceLocation)
        #expect(rig.system.reading == .noLimit, "macOS is at 100%", sourceLocation: sourceLocation)
        #expect(status.lastExecution?.result == .deferred(written: true), sourceLocation: sourceLocation)
        #expect(status.nativeLimit?.target == 85, sourceLocation: sourceLocation)
        #expect(status.nativeLimit?.pendingLimits == [100], sourceLocation: sourceLocation)
        return rig
    }

    @Test("A full charge that ends on an unplug before its 100% is confirmed asks for the return at once")
    func fullChargeEndsBeforeConfirmed() async throws {
        let rig = await fullChargeAwaitingConfirmation()
        rig.clock.advance(by: 61)
        let status = await rig.read(.battery, 76, .powerSourceChanged)
        #expect(status.activeOverride == nil)
        #expect(rig.system.runInputs == ["85", "100", "85"], "the return, not skipped for the limit last confirmed")
        #expect(rig.system.reading == .limit(85))
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(status.nativeLimit?.pendingLimits == [])
        #expect(status.consecutiveFailures == 0)
    }

    @Test("A full charge cancelled before its 100% is confirmed asks for the return as soon as the rate limit allows, and an unplug does not lose it")
    func fullChargeCancelledBeforeConfirmed() async throws {
        let rig = await fullChargeAwaitingConfirmation()
        rig.clock.advance(by: 20)
        var status = await rig.controller.cancelOverride()
        #expect(status.activeOverride == nil)
        #expect(status.currentMode == nil, "100% may be in effect")
        guard case .refuse(.rateLimited)? = status.decision?.action else {
            Issue.record("the return is not asked for: \(String(describing: status.decision?.action))")
            return
        }
        rig.clock.advance(by: 41)
        status = await rig.read(.battery, 75, .powerSourceChanged)
        #expect(rig.system.runInputs == ["85", "100", "85"])
        #expect(rig.system.reading == .limit(85))
    }

    @Test("Nothing takes the limit last confirmed for the one in effect while another is written and not confirmed")
    func pendingValueIsNotTakenAsConfirmed() async throws {
        let rig = await fullChargeAwaitingConfirmation()
        rig.system.isActiveLimitCleared = true
        let status = await rig.read(.externalPower, 76)
        #expect(status.nativeLimit?.readDeferral == .settling)
        #expect(status.currentMode == nil)
        #expect(!status.isNativeLimitSettled)
        #expect(CalibrationWording.limitAfter(status) == .notJudged(.settling))
        let environment = DiagnosticsEnvironment(appVersion: "0.1.0 (1)", systemVersion: "Version 27.0.1", modelIdentifier: "Mac16,1")
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: rig.clock.now)
        #expect(report.contains("Reported mode: unknown"))
        #expect(report.contains("CellKeeper's limit: 85% confirmed; 100% written, not confirmed yet"))
        #expect(rig.system.runInputs == ["85", "100"], "100% is not written again while it waits")

        #expect(ChargeController.modeInEffect(.nativeLimit(percent: 85), native: NativeLimitStatus(ownerLimit: 80, target: 85, pendingLimits: [100], readDeferral: .onBattery)) == nil)
        #expect(ChargeController.modeInEffect(.nativeLimit(percent: 85), native: NativeLimitStatus(ownerLimit: 80, target: 85, isRestoreUnfinished: true, readDeferral: .onBattery)) == nil)
        #expect(ChargeController.modeInEffect(.nativeLimit(percent: 85), native: NativeLimitStatus(ownerLimit: 80, target: 85, readDeferral: .onBattery)) == .nativeLimit(percent: 85), "nothing else of CellKeeper's may be in effect")
        #expect(ChargeController.modeInEffect(.nativeLimit(percent: 85), native: NativeLimitStatus(ownerLimit: 80, target: 85, pendingLimits: [100])) == .nativeLimit(percent: 85), "a judged read")
    }
}

/// Review round 1 of D119: the wait follows what CellKeeper still wants, a
/// restore that was written is never also waiting, and the words allow for
/// an outside change that is adopted at the plug-in instead of restored.
@Suite("D119 review round 1: the wait ends with the wish")
struct DeferredRestoreReviewTests {
    @Test("Cancelling a pending backend switch clears the restore's wait, and no restore is written later")
    func cancellingBackendSwitchClearsWaiting() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        _ = await rig.read(.battery, 70)

        // Choosing another backend asks for the restore while it waits.
        let pending = await rig.controller.switchBackend(to: ReadOnlyChargingBackend(reason: "review"))
        #expect(pending.pendingBackend?.identifier == "read-only")
        #expect(pending.isOwnLimitRestoreWaitingForPower)
        expectRestoreStateIsConsistent(pending.nativeLimit)

        // Choosing the current kind again cancels the switch: management
        // resumes and nothing is owed, so the wait must go too.
        let resumed = await rig.controller.switchBackend(to: makeNativeBackend(system: rig.system, store: rig.store, clock: rig.clock))
        #expect(resumed.pendingBackend == nil)
        #expect(resumed.settings.isManagementEnabled)
        #expect(resumed.decision?.state == .osEnforcedLimit)
        #expect(resumed.decision?.action == .noAction)
        #expect(!resumed.isOwnLimitRestoreWaitingForPower, "management resumed and no restore is scheduled")
        expectRestoreStateIsConsistent(resumed.nativeLimit)

        // On power the resumed policy keeps 85%: the cancelled 80% restore
        // is never written, and a judged read does not bring the wait back.
        rig.system.isActiveLimitCleared = false
        _ = await rig.read(.externalPower, 70, .powerSourceChanged)
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        let powered = await rig.read(.externalPower, 70)
        #expect(rig.system.runInputs == ["85"], "resumed policy never restores 80%")
        #expect(!powered.isOwnLimitRestoreWaitingForPower, "a judged read does not resurrect the stale wait")
        #expect(powered.nativeLimit?.ownerLimit == 80, "the record still stands")
    }

    @Test("A restore written just after an unplug does not turn into an unwritten wait at its retry")
    func writtenRestoreRetryStaysWritten() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.scheduleRuns([.appliesWithoutActiveLimit])
        let written = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))
        #expect(written.lastExecution?.result == .deferred(written: true))
        #expect(written.nativeLimit?.isRestoreUnfinished == true)
        #expect(!written.isOwnLimitRestoreWaitingForPower)
        expectRestoreStateIsConsistent(written.nativeLimit)

        // The next check asks for the restore again, but it was written:
        // only `isRestoreUnfinished` describes it.
        rig.clock.advance(by: 120)
        let retried = await rig.read(.battery, 74)
        #expect(rig.system.runInputs == ["85", "80"], "not written again while it awaits confirmation")
        #expect(retried.isOwnLimitRestorePending)
        #expect(retried.nativeLimit?.isRestoreUnfinished == true)
        #expect(!retried.isOwnLimitRestoreWaitingForPower, "this restore was written; it only awaits confirmation")
        expectRestoreStateIsConsistent(retried.nativeLimit)
    }

    @Test("The wait stays while a decision still wants or requests the user's own limit, and goes only when it asks for CellKeeper's")
    func waitFollowsTheDecision() {
        func decision(_ desired: ChargeControlMode, _ action: ChargingAction, _ reason: DecisionReason) -> PolicyDecision {
            PolicyDecision(state: .osEnforcedLimit, desiredMode: desired, action: action, reason: reason, notes: [], memory: PolicyMemory(), overrideEnded: nil)
        }
        // A release that is due, and the policy's other fail-safes with
        // management on: the restore is still wanted.
        #expect(ChargeController.wantsOwnLimitBack(decision(.normal, .enableCharging, .releaseRequired(.stateUnverified))))
        #expect(ChargeController.wantsOwnLimitBack(decision(.normal, .noAction, .nativeLimitUnsupported(limit: 82, steps: [80, 85, 90, 95, 100]))))
        #expect(ChargeController.wantsOwnLimitBack(decision(.normal, .enableCharging, .batteryNotPresent)))
        // A faulted backend's fail-safe requests it while wanting
        // CellKeeper's limit.
        #expect(ChargeController.wantsOwnLimitBack(decision(.nativeLimit(percent: 85), .enableCharging, .nativeLimitActive(limit: 85))))
        // CellKeeper's own limit, set, kept or refused: not wanted any more.
        #expect(!ChargeController.wantsOwnLimitBack(decision(.nativeLimit(percent: 85), .noAction, .nativeLimitActive(limit: 85))))
        #expect(!ChargeController.wantsOwnLimitBack(decision(.nativeLimit(percent: 90), .setNativeLimit(90), .nativeLimitActive(limit: 90))))
        #expect(!ChargeController.wantsOwnLimitBack(decision(.nativeLimit(percent: 100), .refuse(.backendFaulted), .nativeFullCharge)))
    }

    @Test("A failure that faults the backend keeps the wait its safety fallback set in the same evaluation")
    func failedRequestFallbackWaitSurvivesEvaluation() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.clock.advance(by: 600)
        rig.system.isActiveLimitCleared = true
        _ = await rig.read(.battery, 70)
        // In each evaluation the mode's read shows no active limit, then the
        // new limit's read fails; once the backend faults, its safety
        // fallback finds no active limit either and defers the 80% restore
        // without writing.
        rig.system.failRead(after: 1)
        var failed = try await rig.controller.apply(settings: rig.settings(limit: 90))
        for _ in 1..<ChargeController.maximumConsecutiveFailures {
            rig.clock.advance(by: ChargingPolicy.minimumRestrictingInterval + 1)
            rig.system.failRead(after: 1)
            failed = await rig.read(.battery, 70)
        }
        #expect(failed.isBackendFaulted)
        #expect(failed.nativeLimit?.ownerLimit == 80)
        #expect(failed.nativeLimit?.isRestoreUnfinished == false)
        #expect(rig.system.runInputs == ["85"], "nothing written on battery power")
        #expect(failed.isOwnLimitRestoreWaitingForPower, "the faulted backend's safety restore waits for power")
        expectRestoreStateIsConsistent(failed.nativeLimit)
        let next = await rig.read(.battery, 70)
        #expect(next.decision?.action == .enableCharging)
        #expect(next.isOwnLimitRestoreWaitingForPower)
    }

    @Test("A new limit request clears an unwritten restore even if the request itself must wait")
    func newLimitRequestClearsWait() async throws {
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let backend = makeNativeBackend(system: system, store: store)
        _ = try await backend.setMode(.nativeLimit(percent: 85))
        system.isActiveLimitCleared = true
        await backend.noteChargeLimitReadCondition(.onBattery)
        let restored = try await backend.setMode(.normal)
        #expect(restored == .deferred)
        let waiting = await backend.nativeLimitStatus()
        #expect(waiting?.isRestoreWaitingForPower == true)
        expectRestoreStateIsConsistent(waiting)

        let requested = try await backend.setMode(.nativeLimit(percent: 90))
        #expect(requested == .deferred)
        let cancelled = await backend.nativeLimitStatus()
        #expect(cancelled?.isRestoreWaitingForPower == false)
        #expect(cancelled?.ownerLimit == 80)
        #expect(system.runInputs == ["85"])
    }

    @Test("An unwritten wait is not persisted, and a new session recreates it while recovering its record")
    func relaunchRecreatesWaitFromRecovery() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.clock.advance(by: 600)
        rig.system.isActiveLimitCleared = true
        _ = await rig.read(.battery, 70)
        let quitting = await rig.controller.shutdown(reason: "review quit")
        #expect(quitting.isOwnLimitRestoreWaitingForPower)
        expectRestoreStateIsConsistent(quitting.nativeLimit)
        let stored = try #require(rig.store.data)
        let recordText = String(decoding: stored, as: UTF8.self)
        #expect(!recordText.contains("WaitingForPower"), "the wait is in memory only")

        // A new session recovers the record on battery power: the restore it
        // owes wrote nothing and waits again, while the warning stands.
        let backend = makeNativeBackend(system: rig.system, store: rig.store, clock: rig.clock)
        let initial = await backend.nativeLimitStatus()
        #expect(initial?.isRestoreWaitingForPower == false)
        let controller = ChargeController(
            telemetry: rig.telemetry,
            backend: backend,
            settings: rig.settings(limit: 85),
            adoptionMarkerStore: rig.store,
            now: { rig.clock.now },
            uptime: { rig.clock.uptime }
        )
        let relaunched = await controller.evaluate(.launch)
        #expect(relaunched.isOwnLimitRestoreWaitingForPower)
        #expect(relaunched.isOwnLimitRestorePending, "an earlier session's outstanding record remains a warning")
        expectRestoreStateIsConsistent(relaunched.nativeLimit)
        rig.system.isActiveLimitCleared = false
        await rig.telemetry.set(snapshot(percent: 70, source: .externalPower))
        let recovered = await controller.evaluate(.powerSourceChanged)
        #expect(recovered.nativeLimit?.reportedLimit == 80)
        #expect(!recovered.isOwnLimitRestoreWaitingForPower)
        #expect(recovered.nativeLimit?.isRestoreUnfinished == false, "the read-back confirmed this restore")
    }

    @Test("A pending switch clears its wait when the restore completes")
    func completedBackendSwitchClearsWait() async {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.clock.advance(by: 600)
        rig.system.isActiveLimitCleared = true
        _ = await rig.read(.battery, 70)
        let pending = await rig.controller.switchBackend(to: ReadOnlyChargingBackend(reason: "review"))
        #expect(pending.isOwnLimitRestoreWaitingForPower)
        expectRestoreStateIsConsistent(pending.nativeLimit)

        rig.system.isActiveLimitCleared = false
        let finished = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(finished.backend.identifier == "read-only")
        #expect(finished.pendingBackend == nil)
        #expect(!finished.isOwnLimitRestoreWaitingForPower)
        expectRestoreStateIsConsistent(finished.nativeLimit)
        #expect(rig.system.runInputs == ["85", "80"])
        #expect(NativeChargeLimitBackend.outstandingRecord(in: rig.store) == nil)
    }

    @Test("An outside choice after an unplug makes the waiting words promise nothing that will not happen")
    func outsideChoiceMakesRestorePromiseFalse() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.clock.advance(by: 600)
        rig.system.isActiveLimitCleared = true
        _ = await rig.read(.battery, 70)
        _ = try await rig.controller.apply(settings: rig.settings(limit: 85, managed: false))

        // The owner chooses 90% in System Settings on battery, after the
        // restore was asked for: at the plug-in it is adopted, not restored.
        rig.system.changeExternally(to: 90)
        rig.system.isActiveLimitCleared = false
        let settling = await rig.read(.externalPower, 70, .powerSourceChanged)
        #expect(settling.isOwnLimitRestoreWaitingForPower)
        #expect(settling.nativeLimit?.readDeferral == .settling)
        #expect(NativeLimitWording.restoreProblem(settling) == nil)
        let owner = try #require(settling.nativeLimit?.ownerLimit)
        let menu = NativeLimitWording.restoreWaitingForPower(owner)
        let settings = NativeLimitWording.restoreWaitingForPowerValue(owner)
        #expect(!menu.contains("is restored once"), "the waiting state promises a restore that will not happen: \(menu)")
        #expect(!settings.contains("restored once"), "the waiting state promises a restore that will not happen: \(settings)")
        #expect(menu.contains("if you change the limit meanwhile, it keeps your change"))
        #expect(settings.contains("unless you change the limit meanwhile"))

        rig.clock.advance(by: ChargeController.chargeLimitSettleTime)
        let adopted = await rig.read(.externalPower, 70)
        #expect(adopted.adoptedChange?.limit == 90)
        #expect(adopted.nativeLimit?.reportedLimit == 90)
        #expect(adopted.nativeLimit?.ownerLimit == nil)
        #expect(rig.system.runInputs == ["85"], "80% was not restored once power settled")
        expectRestoreStateIsConsistent(adopted.nativeLimit)
    }
}

/// What the menu, Settings, Diagnostics and the calibration's lines say
/// about a read that was not judged: never that the limit changed.
@Suite("macOS's Charge Limit on battery power: the words")
struct NativeLimitPowerWordingTests {
    @Test("Each reason says plainly why the limit was not judged, and when it is", arguments: [ChargeLimitReadCondition.onBattery, .settling, .powerUnknown])
    func deferralWords(condition: ChargeLimitReadCondition) {
        let text = NativeLimitWording.deferral(condition)
        #expect(text.hasPrefix(NativeLimitWording.deferralTitle(condition) + ". "))
        #expect(text.hasSuffix(NativeLimitWording.deferralDetail(condition)))
        #expect(!text.contains("changed"))
        #expect(!text.contains("no limit"))
        #expect(!NativeLimitWording.deferralValue(condition).contains("100"))
        #expect(NativeLimitWording.deferral(NativeLimitStatus(reportedLimit: 100, readDeferral: condition)) == text)
    }

    @Test("On battery power the words are those of the brief")
    func batteryWords() {
        #expect(NativeLimitWording.deferral(.onBattery) == "macOS applies its Charge Limit only on power. CellKeeper checks macOS's Charge Limit once your Mac has been on power for a minute.")
        #expect(NativeLimitWording.deferralValue(.onBattery) == "Not active on battery")
        #expect(NativeLimitWording.deferral(NativeLimitStatus(reportedLimit: 80)) == nil)
    }

    @Test("A restore that waits for power says so, in the menu's and Settings' words")
    func restoreWaitingWords() {
        #expect(NativeLimitWording.restoreWaitingForPower(80) == "CellKeeper gives back your own limit, 80%, once your Mac has been on power for a minute and it has checked macOS's Charge Limit; if you change the limit meanwhile, it keeps your change. macOS applies its Charge Limit only on power.")
        #expect(NativeLimitWording.restoreWaitingForPowerValue(80) == "80%, recorded; given back once your Mac has been on power for a minute, unless you change the limit meanwhile")
        #expect(NativeLimitWording.restoreWaitingForPower(100) == "CellKeeper gives back your own limit, 100% (no limit), once your Mac has been on power for a minute and it has checked macOS's Charge Limit; if you change the limit meanwhile, it keeps your change. macOS applies its Charge Limit only on power.")
    }

    @Test("Diagnostics and the calibration's outcome say the read was not judged, not that macOS reports 100%")
    func statusWords() async throws {
        let rig = PowerRig(limit: 85)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.isActiveLimitCleared = true
        rig.clock.advance(by: 600)
        let status = await rig.read(.battery, 70)
        let environment = DiagnosticsEnvironment(appVersion: "0.1.0 (1)", systemVersion: "Version 27.0.1", modelIdentifier: "Mac16,1")
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: rig.clock.now)
        #expect(report.contains("Reported by macOS: 100% (not judged: on battery power)"))
        #expect(!report.contains("Kept outside change"))
        #expect(CalibrationWording.limitAfter(status) == .notJudged(.onBattery))
        let sentence = CalibrationWording.limitSentence(.notJudged(.onBattery), ownerLimit: 80)
        #expect(sentence == "macOS has not confirmed CellKeeper's limit back yet. macOS applies its Charge Limit only on power. CellKeeper checks macOS's Charge Limit once your Mac has been on power for a minute.")
        #expect(status.isNativeLimitSettled, "the menu's summary, which says why, says all there is to say")
    }

    @Test("A request waiting for power, and one set but not confirmed, are described as such")
    func executionWords() async throws {
        let rig = PowerRig(limit: 80)
        await rig.settledOnPower()
        _ = await rig.read(.battery, 75, .powerSourceChanged)
        rig.system.scheduleRuns([.appliesWithoutActiveLimit])
        let status = try await rig.controller.apply(settings: rig.settings(limit: 85))
        let environment = DiagnosticsEnvironment(appVersion: "0.1.0 (1)", systemVersion: "Version 27.0.1", modelIdentifier: "Mac16,1")
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: rig.clock.now)
        #expect(report.contains("set macOS Charge Limit to 85%: set, not confirmed yet: macOS's Charge Limit not judged"))
    }
}
