import CellKeeperCore
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
        rig.clock.advance(by: ChargeController.chargeLimitSettleTime - 1)
        status = await rig.read(.externalPower, 70)
        #expect(status.adoptionCount == 0, "still inside the window")
        #expect(status.nativeLimit?.readDeferral == .settling)

        rig.system.isActiveLimitCleared = false
        rig.clock.advance(by: 1)
        status = await rig.read(.externalPower, 71)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.readDeferral == nil)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(rig.system.runInputs == ["85"])
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
        #expect(status.consecutiveFailures == 0)
        rig.clock.advance(by: 120)
        status = await rig.read(.battery, 74)
        #expect(rig.system.runInputs == ["85", "80"], "not written again while it waits")
        rig.system.isActiveLimitCleared = false
        status = await rig.read(.externalPower, 74, .powerSourceChanged)
        #expect(status.nativeLimit?.ownerLimit == nil, "the restore is confirmed by macOS showing the owner's 80%")
        #expect(rig.system.runInputs == ["85", "80"])
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
        #expect(!status.isNativeLimitSettled)
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
