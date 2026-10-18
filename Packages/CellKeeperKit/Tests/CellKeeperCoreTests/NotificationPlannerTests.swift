import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// Which notifications the controller's statuses call for, and when none.
@Suite("Notification planner")
struct NotificationPlannerTests {
    static let simulatedNote = "CellKeeper's control is simulated: your Mac's charging is not changed."

    /// Charges from 76% to the 80% limit: one reading reaches it, the next
    /// confirms it, and the hold applies. Returns what the hold planned.
    @discardableResult
    private func chargeToLimit(_ scenario: PlannerScenario) async -> [PlannedNotification] {
        await scenario.evaluate(.launch)
        await scenario.read(80)
        await scenario.evaluate()
        return await scenario.evaluate()
    }

    // MARK: - Limit reached

    @Test("Charging up to the limit and a hold the backend reports post one notification; the hold going on posts nothing")
    func limitReached() async {
        let scenario = PlannerScenario(percent: 76)
        let held = await chargeToLimit(scenario)
        #expect(held == [PlannedNotification(
            kind: .limitReached,
            title: "Simulated: charging paused at your limit",
            body: "Charge 80% has reached the 80% limit; charging paused. \(Self.simulatedNote)"
        )])
        // The policy's own reason, as the menu shows it.
        #expect(held.first?.body.hasPrefix(DecisionReason.limitReached(percent: 80, limit: 80).description) == true)
        let planned1 = await scenario.evaluate()
        #expect(planned1.isEmpty)
        await scenario.read(79)
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)
    }

    @Test("A hold that begins above the limit, as after charging during sleep, is said to be above it")
    func limitReachedAbove() async {
        let scenario = PlannerScenario(percent: 76)
        await scenario.evaluate(.launch)
        await scenario.read(84)
        await scenario.evaluate(.didWake)
        await scenario.read(84)
        let held = await scenario.evaluate()
        #expect(held == [PlannedNotification(
            kind: .limitReached,
            title: "Simulated: charging paused above your limit",
            body: "Charge 84% has reached the 80% limit; charging paused. \(Self.simulatedNote)"
        )])
    }

    @Test("A charge already at or above the limit at launch posts nothing when the hold follows")
    func noLimitAtLaunch() async {
        let scenario = PlannerScenario(percent: 85)
        await scenario.evaluate(.launch)
        await scenario.evaluate()
        await scenario.evaluate()
        let status = await scenario.status
        #expect(status.decision?.state == .holding)
        #expect(scenario.all.isEmpty)
    }

    @Test("The latch clearing at the resume threshold and setting again posts nothing within an hour, and once after it")
    func limitHysteresis() async {
        let scenario = PlannerScenario(percent: 76)
        let planned1 = await chargeToLimit(scenario)
        #expect(planned1.map(\.kind) == [.limitReached])

        await scenario.read(75)
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)
        await scenario.read(80)
        await scenario.evaluate()
        let planned3 = await scenario.evaluate()
        #expect(planned3.isEmpty)
        let status = await scenario.status
        #expect(status.decision?.state == .holding)

        await scenario.read(75)
        await scenario.evaluate(after: NotificationKind.limitReached.minimumInterval)
        await scenario.read(80)
        await scenario.evaluate()
        let planned4 = await scenario.evaluate()
        #expect(planned4.map(\.kind) == [.limitReached])
    }

    @Test("Battery power or stale telemetry between holds posts nothing when the hold resumes")
    func limitBlips() async {
        let scenario = PlannerScenario(percent: 76)
        let planned1 = await chargeToLimit(scenario)
        #expect(planned1.map(\.kind) == [.limitReached])

        await scenario.read(80, source: .battery)
        let planned2 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned2.isEmpty)
        await scenario.read(79)
        let planned3 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned3.isEmpty)

        await scenario.telemetry.fail(with: TelemetryTestError())
        let planned4 = await scenario.evaluate()
        #expect(planned4.isEmpty)
        await scenario.read(79)
        let planned5 = await scenario.evaluate()
        #expect(planned5.isEmpty)
        let status = await scenario.status
        #expect(status.decision?.state == .holding)
        #expect(scenario.all.map(\.kind) == [.limitReached])
    }

    @Test("Lowering the limit below the charge posts nothing when the hold follows")
    func loweredLimit() async throws {
        let scenario = PlannerScenario(percent: 78)
        await scenario.evaluate(.launch)
        try await scenario.apply(ChargingSettings.default.withChargeLimit(70))
        await scenario.evaluate()
        let status = await scenario.status
        #expect(status.decision?.state == .holding)
        #expect(scenario.all.isEmpty)
    }

    @Test("A hold the backend does not confirm is not reported; the one it confirms later is, without a simulation note on hardware")
    func unconfirmedHold() async {
        let backend = HardwareLikeBackend()
        let scenario = PlannerScenario(percent: 76, backend: backend)
        await scenario.evaluate(.launch)
        await scenario.read(80)
        await scenario.evaluate()
        await backend.failNextRequests(1)
        let planned1 = await scenario.evaluate()
        #expect(planned1.isEmpty)
        let failed = await scenario.status
        #expect(failed.decision?.state == .holding)
        #expect(failed.currentMode == .normal)

        let held = await scenario.evaluate()
        #expect(held == [PlannedNotification(kind: .limitReached, title: "Charging paused at your limit", body: "Charge 80% has reached the 80% limit; charging paused.")])
    }

    @Test("The sleep precaution's hold is not the limit")
    func sleepPrecaution() async {
        let scenario = PlannerScenario(percent: 77)
        await scenario.evaluate(.launch)
        await scenario.evaluate(.willSleep)
        let asleep = await scenario.status
        #expect(asleep.decision?.reason == .sleepPrecaution(percent: 77, resumeThreshold: 75))
        #expect(asleep.currentMode == .inhibitCharging)
        await scenario.evaluate(.didWake)
        #expect(scenario.all.isEmpty)
    }

    @Test("Sleep and wake replay nothing, also with unusable telemetry right after the wake")
    func wakeReplaysNothing() async {
        let scenario = PlannerScenario(percent: 76)
        let planned1 = await chargeToLimit(scenario)
        #expect(planned1.map(\.kind) == [.limitReached])
        let planned2 = await scenario.evaluate(.willSleep)
        #expect(planned2.isEmpty)
        await scenario.telemetry.fail(with: TelemetryTestError())
        let planned3 = await scenario.evaluate(.didWake, after: 3 * 60 * 60)
        #expect(planned3.isEmpty)
        await scenario.read(80)
        let planned4 = await scenario.evaluate(.postWakeReread, after: 35)
        #expect(planned4.isEmpty)
        let status = await scenario.status
        #expect(status.decision?.state == .holding)
    }

    @Test("A hold reached by the user's own command posts nothing, then or later")
    func userCommandPostsNoProgress() async {
        let scenario = PlannerScenario(percent: 76)
        await scenario.evaluate(.launch)
        await scenario.read(80)
        await scenario.evaluate()
        let planned1 = await scenario.evaluate(.manual)
        #expect(planned1.isEmpty)
        let status = await scenario.status
        #expect(status.decision?.state == .holding)
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)
    }

    @Test("A backend switch replays nothing: a hold that continues, or one first seen on the new backend, posts nothing")
    func backendSwitch() async {
        let continuing = PlannerScenario(percent: 76)
        let planned1 = await chargeToLimit(continuing)
        #expect(planned1.map(\.kind) == [.limitReached])
        let planned2 = await continuing.command(.backendChanged) { await $0.switchBackend(to: HardwareLikeBackend()) }
        #expect(planned2.isEmpty)
        let planned3 = await continuing.evaluate()
        #expect(planned3.isEmpty)
        let switched = await continuing.status
        #expect(switched.backend.identifier == "test-hardware")
        #expect(switched.currentMode == .inhibitCharging)

        // Seen charging toward the limit on the old backend only.
        let crossing = PlannerScenario(percent: 79)
        await crossing.evaluate(.launch)
        await crossing.read(81)
        let planned4 = await crossing.command(.backendChanged) { await $0.switchBackend(to: HardwareLikeBackend()) }
        #expect(planned4.isEmpty)
        let planned5 = await crossing.evaluate()
        #expect(planned5.isEmpty)
        let held = await crossing.status
        #expect(held.backend.identifier == "test-hardware")
        #expect(held.decision?.state == .holding)
        #expect(held.currentMode == .inhibitCharging)
    }

    // MARK: - macOS's Charge Limit

    private func nativeScenario(percent: Int, clock: TestClock = TestClock()) -> (PlannerScenario, FakeChargeLimitSystem) {
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let scenario = PlannerScenario(
            clock: clock,
            percent: percent,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(85),
            adoptionMarkerStore: store
        )
        return (scenario, system)
    }

    @Test("With macOS's Charge Limit, macOS reporting the battery at CellKeeper's limit and not charging posts once, without claiming a cause")
    func nativeLimitHeld() async {
        let (scenario, _) = nativeScenario(percent: 82)
        let planned1 = await scenario.evaluate(.launch)
        #expect(planned1.isEmpty)
        let launched = await scenario.status
        #expect(launched.currentMode == .nativeLimit(percent: 85))

        await scenario.read(85, charging: false)
        let held = await scenario.evaluate()
        #expect(held == [PlannedNotification(
            kind: .limitReached,
            title: "Battery at the Charge Limit",
            body: "macOS reports the battery at 85% and not charging. Your limit in CellKeeper is 85%, and macOS reports its Charge Limit at 85%."
        )])
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)
    }

    @Test("With macOS's Charge Limit, a battery above the limit, as after macOS's occasional full charge, is said to be above it, with no cause")
    func nativeAboveLimit() async {
        let (scenario, _) = nativeScenario(percent: 82)
        await scenario.evaluate(.launch)
        await scenario.read(100, charging: false, fullyCharged: true)
        let held = await scenario.evaluate()
        #expect(held == [PlannedNotification(
            kind: .limitReached,
            title: "Battery above the Charge Limit",
            body: "macOS reports the battery at 100% and not charging. Your limit in CellKeeper is 85%, and macOS reports its Charge Limit at 85%."
        )])
        for word in ["reason", "cause", "because", "likely"] {
            #expect(held.first?.body.contains(word) == false)
        }
    }

    @Test("With macOS's Charge Limit, telemetry the policy rejects neither arms nor reports the limit")
    func nativeStaleTelemetry() async {
        let stale = ChargingPolicy.maximumSourceAge + 10 * 60
        // Charging below the limit, seen only on stale readings.
        let (unarmed, _) = nativeScenario(percent: 82)
        await unarmed.read(82, charging: true, sourceAge: stale)
        await unarmed.evaluate(.launch)
        let kept = await unarmed.status
        #expect(kept.decision?.state == .osEnforcedLimit)
        #expect(kept.decision?.notes.contains(.nativeLimitKeptWithoutTelemetry) == true)
        await unarmed.read(85, charging: false)
        let planned1 = await unarmed.evaluate()
        #expect(planned1.isEmpty)

        // Armed by a usable reading, then a stale one at the limit.
        let (armed, _) = nativeScenario(percent: 82)
        await armed.evaluate(.launch)
        await armed.read(85, charging: false, sourceAge: stale)
        let planned2 = await armed.evaluate()
        #expect(planned2.isEmpty)
        await armed.read(85, charging: false)
        let planned3 = await armed.evaluate()
        #expect(planned3.map(\.kind) == [.limitReached])
    }

    @Test("With macOS's Charge Limit, not charging at launch, or below the limit, posts nothing")
    func nativeLimitNotHeld() async {
        let (atLaunch, _) = nativeScenario(percent: 85)
        await atLaunch.read(85, charging: false)
        await atLaunch.evaluate(.launch)
        await atLaunch.evaluate()
        #expect(atLaunch.all.isEmpty)

        let (below, _) = nativeScenario(percent: 82)
        await below.evaluate(.launch)
        // macOS may pause below its limit for reasons it does not report.
        await below.read(83, charging: false)
        await below.evaluate()
        #expect(below.all.isEmpty)
    }

    // MARK: - Temperature pause

    @Test("A temperature pause the backend reports posts once, in the policy's words")
    func temperaturePause() async {
        let scenario = PlannerScenario(percent: 50)
        await scenario.evaluate(.launch)
        await scenario.read(50, temperature: 41)
        let paused = await scenario.evaluate()
        #expect(paused == [PlannedNotification(
            kind: .temperaturePause,
            title: "Simulated: charging paused because the battery is warm",
            body: "\(DecisionReason.temperatureHigh(celsius: 41, pauseAt: 40).description) \(Self.simulatedNote)"
        )])
        let planned1 = await scenario.evaluate()
        #expect(planned1.isEmpty)
    }

    @Test("A battery already hot at launch posts nothing")
    func hotAtLaunch() async {
        let scenario = PlannerScenario(percent: 50, temperature: 41)
        await scenario.evaluate(.launch)
        await scenario.evaluate()
        let status = await scenario.status
        #expect(status.decision?.state == .temperaturePause)
        #expect(scenario.all.isEmpty)
    }

    @Test("Unplugging during a pause, or cooling and heating again within an hour, posts nothing; heating again after it posts once")
    func temperatureRepeats() async {
        let scenario = PlannerScenario(percent: 50)
        await scenario.evaluate(.launch)
        await scenario.read(50, temperature: 41)
        let planned1 = await scenario.evaluate()
        #expect(planned1.map(\.kind) == [.temperaturePause])

        await scenario.read(50, source: .battery, temperature: 41)
        let planned2 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned2.isEmpty)
        await scenario.read(50, temperature: 41)
        let planned3 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned3.isEmpty)

        await scenario.read(50, temperature: 34)
        let planned4 = await scenario.evaluate(after: ChargingPolicy.minimumTemperaturePause)
        #expect(planned4.isEmpty)
        let cooled = await scenario.status
        #expect(cooled.decision?.state == .charging)
        await scenario.read(50, temperature: 41)
        let planned5 = await scenario.evaluate()
        #expect(planned5.isEmpty)

        await scenario.read(50, temperature: 34)
        await scenario.evaluate(after: ChargingPolicy.minimumTemperaturePause)
        await scenario.read(50, temperature: 41)
        let planned6 = await scenario.evaluate(after: NotificationKind.temperaturePause.minimumInterval)
        #expect(planned6.map(\.kind) == [.temperaturePause])
    }

    @Test("A reading the policy rejects, or one without a temperature, never arms the temperature notification again")
    func temperatureNotArmedByRejectedTelemetry() async {
        // Hot at launch: silent.
        let scenario = PlannerScenario(percent: 50, temperature: 41)
        let planned1 = await scenario.evaluate(.launch)
        #expect(planned1.isEmpty)
        // A reading with no battery: rejected, though it clears the latch.
        await scenario.read(50, temperature: 41, present: false)
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)
        let absent = await scenario.status
        #expect(absent.decision?.reason == .batteryNotPresent)
        #expect(absent.decision?.memory.temperatureTripped == false)
        // The same hot reading again: no cooling was seen, so silent.
        await scenario.read(50, temperature: 41)
        let planned3 = await scenario.evaluate()
        #expect(planned3.isEmpty)
        let paused = await scenario.status
        #expect(paused.decision?.state == .temperaturePause)
        #expect(paused.currentMode == .inhibitCharging)

        // An unknown temperature clears the latch too, but shows no cooling.
        await scenario.read(50, temperature: nil)
        let planned4 = await scenario.evaluate(after: ChargingPolicy.minimumTemperaturePause)
        #expect(planned4.isEmpty)
        await scenario.read(50, temperature: 41)
        let planned5 = await scenario.evaluate(after: NotificationKind.temperaturePause.minimumInterval)
        #expect(planned5.isEmpty)
        let again = await scenario.status
        #expect(again.decision?.state == .temperaturePause)

        // A usable reading that shows it cool arms it again.
        await scenario.read(50, temperature: 34)
        await scenario.evaluate(after: ChargingPolicy.minimumTemperaturePause)
        await scenario.read(50, temperature: 41)
        let planned6 = await scenario.evaluate()
        #expect(planned6.map(\.kind) == [.temperaturePause])
    }

    @Test("Turning temperature protection back on while the battery is hot posts nothing")
    func protectionReenabled() async throws {
        let scenario = PlannerScenario(percent: 50)
        await scenario.evaluate(.launch)
        var off = ChargingSettings.default
        off.temperatureProtection.isEnabled = false
        try await scenario.apply(off)
        await scenario.read(50, temperature: 41)
        await scenario.evaluate()
        let planned1 = try await scenario.apply(.default)
        #expect(planned1.isEmpty)
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)
        let status = await scenario.status
        #expect(status.decision?.state == .temperaturePause)
    }

    // MARK: - Overrides

    @Test("A temporary full charge that completes posts how it ended and what macOS reports")
    func fullChargeCompleted() async {
        let scenario = PlannerScenario(percent: 95)
        await scenario.evaluate(.launch)
        let planned1 = await scenario.command(.overrideChanged) { await $0.startFullCharge() }
        #expect(planned1.isEmpty)
        await scenario.read(100, charging: false, fullyCharged: true)
        let ended = await scenario.evaluate()
        #expect(ended == [PlannedNotification(
            kind: .overrideEnded,
            title: "Simulated: temporary full charge ended",
            body: "Temporary full charge completed. macOS reports the battery fully charged. \(Self.simulatedNote)"
        )])
    }

    @Test("A temporary full charge that expires or ends on unplugging says so")
    func fullChargeExpiredOrUnplugged() async {
        let expiring = PlannerScenario(percent: 85)
        await expiring.evaluate(.launch)
        await expiring.command(.overrideChanged) { await $0.startFullCharge() }
        let expired = await expiring.evaluate(after: ChargeOverride.defaultFullChargeDuration)
        #expect(expired.filter { $0.kind == .overrideEnded }.map(\.body) == ["Temporary full charge expired. \(Self.simulatedNote)"])

        let unplugging = PlannerScenario(percent: 85)
        await unplugging.evaluate(.launch)
        await unplugging.command(.overrideChanged) { await $0.startFullCharge() }
        await unplugging.read(85, source: .battery)
        let unplugged = await unplugging.evaluate(.powerSourceChanged)
        #expect(unplugged.map(\.body) == ["Temporary full charge ended: a battery reading showed the Mac on battery power. \(Self.simulatedNote)"])
    }

    @Test("A discharge that reaches the limit posts that it completed, and the charge macOS reports")
    func dischargeCompleted() async {
        let scenario = PlannerScenario(percent: 90)
        await scenario.evaluate(.launch)
        await scenario.command(.overrideChanged) { await $0.startDischargeToLimit() }
        let running = await scenario.status
        #expect(running.decision?.state == .discharging)
        await scenario.read(80)
        let ended = await scenario.evaluate()
        #expect(ended == [PlannedNotification(
            kind: .overrideEnded,
            title: "Simulated: discharge ended",
            body: "Discharge to limit completed. macOS reports the battery at 80%. \(Self.simulatedNote)"
        )])
    }

    @Test("A discharge a temperature pause interrupts posts both, the discharge first")
    func dischargeInterrupted() async {
        let scenario = PlannerScenario(percent: 90)
        await scenario.evaluate(.launch)
        await scenario.command(.overrideChanged) { await $0.startDischargeToLimit() }
        await scenario.read(88, temperature: 41)
        let ended = await scenario.evaluate()
        #expect(ended.map(\.kind) == [.overrideEnded, .temperaturePause])
        #expect(ended.first?.body == "Discharge to limit stopped by a safety rule. The menu shows what CellKeeper does now. \(Self.simulatedNote)")
    }

    @Test("An override the user cancels, or ends by turning management off or changing the limit, posts nothing")
    func userEndedOverride() async throws {
        let cancelled = PlannerScenario(percent: 85)
        await cancelled.evaluate(.launch)
        await cancelled.command(.overrideChanged) { await $0.startFullCharge() }
        let planned1 = await cancelled.command(.overrideChanged) { await $0.cancelOverride() }
        #expect(planned1.isEmpty)
        let planned2 = await cancelled.evaluate()
        #expect(planned2.isEmpty)

        let managementOff = PlannerScenario(percent: 85)
        await managementOff.evaluate(.launch)
        await managementOff.command(.overrideChanged) { await $0.startFullCharge() }
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        let planned3 = try await managementOff.apply(off)
        #expect(planned3.isEmpty)
        let planned4 = await managementOff.evaluate()
        #expect(planned4.isEmpty)

        let raised = PlannerScenario(percent: 85)
        await raised.evaluate(.launch)
        await raised.command(.overrideChanged) { await $0.startDischargeToLimit() }
        // The session stops at the higher of its target and the limit.
        let completed = try await raised.apply(ChargingSettings.default.withChargeLimit(85))
        #expect(completed.isEmpty)
        let status = await raised.status
        #expect(status.activeOverride == nil)
        #expect(status.decision?.overrideEnded == .completed)
        let planned5 = await raised.evaluate()
        #expect(planned5.isEmpty)
    }

    @Test("A discharge ended by a policy note says what the note says")
    func dischargeEndedByNote() async throws {
        let scenario = PlannerScenario(percent: 90)
        await scenario.evaluate(.launch)
        let running = await scenario.command(.overrideChanged) { await $0.startDischargeToLimit() }
        #expect(running.isEmpty)
        var status = await scenario.status
        var planner = scenario.planner
        let session = try #require(status.activeOverride)
        status.activeOverride = nil
        status.decision?.overrideEnded = .interrupted
        status.lastEndedOverride = EndedOverride(override: session, end: .interrupted)
        status.overridesEnded += 1
        status.decision?.notes = [.dischargeUnsupported]
        let ended = planner.plan(status, trigger: .periodic, uptime: scenario.clock.uptime + 60, isDelivering: true)
        #expect(ended.map(\.body) == ["Discharge to limit stopped by a safety rule. \(PolicyNote.dischargeUnsupported.description) \(Self.simulatedNote)"])
    }

    // MARK: - Scheduled full charge

    /// How a scheduled full charge ends by itself.
    enum ScheduledEnd: CaseIterable {
        case expired, completed, unplugged
    }

    @Test("A scheduled full charge that ends by itself posts how it ended, named as in the menu; setting it and its start post nothing", arguments: ScheduledEnd.allCases)
    func scheduledFullChargeEnds(end: ScheduledEnd) async throws {
        // Above the limit, so no hold is armed.
        let scenario = PlannerScenario(percent: 85)
        await scenario.evaluate(.launch)
        let set = try await scenario.setSchedule(startingIn: hour, window: 2 * hour)
        #expect(set.isEmpty)
        let started = await scenario.evaluate(after: hour + 60)
        #expect(started.isEmpty)
        let running = await scenario.status
        #expect(running.activeOverride?.source == .schedule)

        let ended: [PlannedNotification]
        let body: String
        switch end {
        case .expired:
            ended = await scenario.evaluate(after: 2 * hour)
            body = "Scheduled full charge expired."
        case .completed:
            await scenario.read(100, charging: false, fullyCharged: true)
            ended = await scenario.evaluate()
            body = "Scheduled full charge completed. macOS reports the battery fully charged."
        case .unplugged:
            await scenario.read(85, source: .battery)
            ended = await scenario.evaluate(.powerSourceChanged)
            body = "Scheduled full charge ended: a battery reading showed the Mac on battery power."
        }
        #expect(ended == [PlannedNotification(
            kind: .overrideEnded,
            title: "Simulated: scheduled full charge ended",
            body: "\(body) \(Self.simulatedNote)"
        )])
        let after = await scenario.evaluate()
        #expect(after.isEmpty)
    }

    @Test("A scheduled full charge the user cancels, or a schedule cancelled before it starts, posts nothing")
    func scheduledFullChargeCancelled() async throws {
        let running = PlannerScenario(percent: 85)
        await running.evaluate(.launch)
        try await running.setSchedule(startingIn: hour, window: 2 * hour)
        await running.evaluate(after: hour + 60)
        let started = await running.status
        #expect(started.activeOverride?.source == .schedule)
        await running.command(.overrideChanged) { await $0.cancelOverride() }
        await running.evaluate(after: 2 * hour)
        #expect(running.all.isEmpty)

        let armed = PlannerScenario(percent: 85)
        await armed.evaluate(.launch)
        try await armed.setSchedule(startingIn: hour, window: 2 * hour)
        await armed.command(.scheduleChanged) { await $0.cancelFullChargeSchedule() }
        await armed.evaluate(after: hour + 60)
        await armed.evaluate(after: 2 * hour)
        #expect(armed.all.isEmpty)
    }

    @Test("A temporary full charge a schedule extended is named a scheduled full charge when it ends, as in the menu and the log")
    func extendedFullChargeEnds() async throws {
        let scenario = PlannerScenario(percent: 85)
        await scenario.evaluate(.launch)
        await scenario.command(.overrideChanged) { await $0.startFullCharge() }
        // The schedule ends after the manual charge's 12 hours.
        try await scenario.setSchedule(startingIn: hour, window: 14 * hour)
        await scenario.evaluate(after: hour + 60)
        let extended = await scenario.status
        #expect(extended.activeOverride?.source == .schedule)
        // Past the manual charge's own deadline, it still runs.
        let midway = await scenario.evaluate(after: 12 * hour)
        #expect(midway.isEmpty)
        let ended = await scenario.evaluate(after: 2 * hour)
        #expect(ended.map(\.body) == ["Scheduled full charge expired. \(Self.simulatedNote)"])
    }

    @Test("A scheduled full charge that replaces a discharge and completes in the same evaluation is the one named, not the discharge")
    func scheduleReplacesDischarge() async throws {
        let scenario = PlannerScenario(percent: 90)
        await scenario.evaluate(.launch)
        await scenario.command(.overrideChanged) { await $0.startDischargeToLimit() }
        try await scenario.setSchedule(startingIn: hour, window: 2 * hour)
        // The simulated discharge changes nothing; the battery reads full
        // when the schedule starts.
        await scenario.read(100, charging: false, fullyCharged: true)
        let ended = await scenario.evaluate(after: hour + 60)
        #expect(ended == [PlannedNotification(
            kind: .overrideEnded,
            title: "Simulated: scheduled full charge ended",
            body: "Scheduled full charge completed. macOS reports the battery fully charged. \(Self.simulatedNote)"
        )])
        let status = await scenario.status
        #expect(status.events.contains { $0.message == "Discharge to limit ended: the scheduled full charge started." })
    }

    @Test("A temporary full charge whose deadline passed before the evaluation that starts a schedule posts that it expired, as the log says")
    func expiredFullChargeReplaced() async throws {
        let scenario = PlannerScenario(percent: 85)
        await scenario.evaluate(.launch)
        await scenario.command(.overrideChanged) { await $0.startFullCharge() }
        try await scenario.setSchedule(startingIn: 12.5 * hour, window: 2 * hour)
        // Asleep past the manual charge's deadline and the schedule's start.
        let woke = await scenario.evaluate(.didWake, after: 12.5 * hour + 60)
        #expect(woke.map(\.body) == ["Temporary full charge expired. \(Self.simulatedNote)"])
        let status = await scenario.status
        #expect(status.activeOverride?.source == .schedule)
        let ended = await scenario.evaluate(after: 2 * hour)
        #expect(ended.map(\.body) == ["Scheduled full charge expired. \(Self.simulatedNote)"])
    }

    @Test("A schedule that starts during a temperature pause posts nothing more: the pause wins, and no notification says the full charge runs")
    func scheduleDuringTemperaturePause() async throws {
        let scenario = PlannerScenario(percent: 70)
        await scenario.evaluate(.launch)
        try await scenario.setSchedule(startingIn: hour, window: 3 * hour)
        await scenario.read(70, temperature: 41)
        let paused = await scenario.evaluate()
        #expect(paused.map(\.kind) == [.temperaturePause])

        let started = await scenario.evaluate(after: hour)
        #expect(started.isEmpty)
        let status = await scenario.status
        #expect(status.activeOverride?.source == .schedule)
        #expect(status.decision?.state == .temperaturePause)
        #expect(status.decision?.notes.contains(.fullChargeSuppressed(by: .temperaturePause)) == true)

        // Cooled, the scheduled full charge goes on; its end is posted.
        await scenario.read(70, temperature: 30)
        let resumed = await scenario.evaluate()
        #expect(resumed.isEmpty)
        let charging = await scenario.status
        #expect(charging.decision?.state == .fullChargeOverride)
        await scenario.read(100, charging: false, fullyCharged: true)
        let ended = await scenario.evaluate()
        #expect(ended.map(\.kind) == [.overrideEnded])

        // The pause beginning in the evaluation the schedule starts in posts
        // only the pause.
        let together = PlannerScenario(percent: 70)
        await together.evaluate(.launch)
        try await together.setSchedule(startingIn: hour, window: 3 * hour)
        await together.read(70, temperature: 41)
        await together.evaluate(after: hour + 60)
        await together.evaluate()
        #expect(together.all.map(\.kind) == [.temperaturePause])
        #expect(together.all.allSatisfy { !$0.body.contains("full charge") })
    }

    @Test("Clock changes post nothing new: a hold is not reported again, a running scheduled full charge ends once on the monotonic clock, and a window a jump passes posts nothing")
    func clockChanges() async throws {
        let scenario = PlannerScenario(percent: 76)
        let held = await chargeToLimit(scenario)
        #expect(held.map(\.kind) == [.limitReached])
        for jump in [10 * hour, -10 * hour] {
            scenario.clock.shiftWall(by: jump)
            await scenario.evaluate(.clockChanged)
        }

        try await scenario.setSchedule(startingIn: hour, window: 2 * hour)
        await scenario.evaluate(after: hour + 60)
        for jump in [10 * hour, -10 * hour] {
            scenario.clock.shiftWall(by: jump)
            await scenario.evaluate(.clockChanged)
            let running = await scenario.status
            #expect(running.activeOverride?.source == .schedule)
        }
        let ended = await scenario.evaluate(after: 2 * hour)
        #expect(ended.map(\.body) == ["Scheduled full charge expired. \(Self.simulatedNote)"])
        scenario.clock.shiftWall(by: hour)
        await scenario.evaluate(.clockChanged)

        try await scenario.setSchedule(startingIn: hour, window: 2 * hour)
        scenario.clock.shiftWall(by: 10 * hour)
        await scenario.evaluate(.clockChanged)
        let passed = await scenario.status
        #expect(passed.fullChargeScheduleOutcome.map { if case .windowPassed = $0 { true } else { false } } == true)
        #expect(scenario.all.map(\.kind) == [.limitReached, .overrideEnded])
    }

    // MARK: - Faults

    @Test("A fault posts once; clearing it and faulting again within ten minutes posts nothing, and once after them")
    func backendFault() async {
        let backend = MockChargingBackend()
        let scenario = PlannerScenario(percent: 76, backend: backend)
        let planned1 = await chargeToLimit(scenario)
        #expect(planned1.map(\.kind) == [.limitReached])

        await backend.simulateExternalChange(to: .normal)
        let faulted = await scenario.evaluate()
        #expect(faulted == [PlannedNotification(
            kind: .backendFault,
            title: "Simulated backend faulted",
            body: "CellKeeper marked the backend faulted; Settings › Activity says why. Until you clear the fault in Settings › Control, CellKeeper only asks for normal charging. \(Self.simulatedNote)"
        )])
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)

        let planned3 = await scenario.command(.manual) { await $0.resetBackendFault() }
        #expect(planned3.isEmpty)
        await backend.simulateExternalChange(to: .normal)
        let planned4 = await scenario.evaluate()
        #expect(planned4.isEmpty)
        let again = await scenario.status
        #expect(again.isBackendFaulted)

        await scenario.command(.manual) { await $0.resetBackendFault() }
        await backend.simulateExternalChange(to: .normal)
        let planned5 = await scenario.evaluate(after: NotificationKind.backendFault.minimumInterval)
        #expect(planned5.map(\.kind) == [.backendFault])
    }

    @Test("A fault in the first status is reported: the controller starts every session without one")
    func faultAtLaunch() async {
        let scenario = PlannerScenario(percent: 70)
        scenario.clock.advance(by: 60)
        var status = await scenario.controller.evaluate(.launch)
        status.isBackendFaulted = true
        status.faultsRaised = 1
        #expect(scenario.feed(status, .launch).map(\.kind) == [.backendFault])
    }

    @Test("A fault on a newly selected backend is reported, whatever the old one showed")
    func faultAfterBackendSwitch() async {
        let backend = MockChargingBackend()
        let scenario = PlannerScenario(percent: 76, backend: backend)
        await chargeToLimit(scenario)
        await backend.simulateExternalChange(to: .normal)
        let planned1 = await scenario.evaluate()
        #expect(planned1.map(\.kind) == [.backendFault])

        let switched = await scenario.command(.backendChanged, after: NotificationKind.backendFault.minimumInterval) {
            await $0.switchBackend(to: AcknowledgingBackend())
        }
        let status = await scenario.status
        #expect(status.backend.displayName == "Test acknowledging")
        #expect(status.isBackendFaulted)
        #expect(switched.map(\.title) == ["Test acknowledging backend faulted"])
    }

    @Test("A fault cleared and raised again within one command is a new fault")
    func faultAgainInOneCommand() async {
        let scenario = PlannerScenario(percent: 70, backend: AcknowledgingBackend())
        let planned1 = await scenario.evaluate(.launch)
        #expect(planned1.map(\.kind) == [.backendFault])
        let again = await scenario.command(.manual, after: NotificationKind.backendFault.minimumInterval) { await $0.resetBackendFault() }
        let status = await scenario.status
        #expect(status.isBackendFaulted)
        #expect(status.faultsRaised == 2)
        #expect(again.map(\.kind) == [.backendFault])
    }

    // MARK: - Restores

    @Test("A release no read-back confirms posts a warning, once; the read-back that confirms it posts the confirmation")
    func restoreWarningAndConfirmation() async {
        let backend = HardwareLikeBackend()
        let scenario = PlannerScenario(percent: 76, backend: backend)
        let planned1 = await chargeToLimit(scenario)
        #expect(planned1.map(\.kind) == [.limitReached])

        await backend.failNextRequests(1)
        await scenario.read(80, source: .battery)
        let warned = await scenario.evaluate(.powerSourceChanged)
        #expect(warned == [PlannedNotification(
            kind: .restoreUnconfirmed,
            title: "Normal charging not confirmed",
            body: "No read-back has confirmed that CellKeeper's restriction (a charging pause) ended, so it may remain. CellKeeper keeps asking for its release until a read-back shows it ended."
        )])
        #expect(warned.first?.body == MacOSChargeLimitWording.releaseState(.unconfirmed(.inhibitCharging), isSimulated: false))

        // An automatic retry waits a minute; the restriction still shows.
        let planned2 = await scenario.evaluate(after: 30)
        #expect(planned2.isEmpty)
        let waiting = await scenario.status
        #expect(waiting.ownRestriction == .inEffect(.inhibitCharging, own: .inhibitCharging))

        let confirmed = await scenario.evaluate(after: 30)
        #expect(confirmed == [PlannedNotification(kind: .restoreResolved, title: "Normal charging confirmed", body: "A read-back after the warning showed normal charging: CellKeeper's restriction had ended.")])
        #expect(NotificationKind.restoreResolved.replacementKey == NotificationKind.restoreUnconfirmed.replacementKey)
        let planned3 = await scenario.evaluate()
        #expect(planned3.isEmpty)
    }

    @Test("A restore warning repeats only after a confirmed restore and ten minutes; a dropped one gets no confirmation")
    func restoreWarningRepeats() async {
        let backend = HardwareLikeBackend()
        let scenario = PlannerScenario(percent: 76, backend: backend)
        await chargeToLimit(scenario)
        await backend.failNextRequests(1)
        await scenario.read(80, source: .battery)
        let planned1 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned1.map(\.kind) == [.restoreUnconfirmed])
        let planned2 = await scenario.evaluate()
        #expect(planned2.map(\.kind) == [.restoreResolved])

        // Within ten minutes of the warning.
        await scenario.read(80)
        await scenario.evaluate(.powerSourceChanged)
        await backend.failNextRequests(1)
        await scenario.read(80, source: .battery)
        let planned3 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned3.isEmpty)
        let planned4 = await scenario.evaluate()
        #expect(planned4.isEmpty)

        await scenario.read(80)
        await scenario.evaluate(.powerSourceChanged, after: NotificationKind.restoreUnconfirmed.minimumInterval)
        await backend.failNextRequests(1)
        await scenario.read(80, source: .battery)
        let planned5 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned5.map(\.kind) == [.restoreUnconfirmed])
    }

    @Test("A warning about one backend is retired, without a confirmation, when the backend changes")
    func restoreWarningRetiredOnSwitch() async {
        let backend = HardwareLikeBackend()
        let scenario = PlannerScenario(percent: 76, backend: backend)
        await chargeToLimit(scenario)
        await backend.failNextRequests(1)
        await scenario.read(80, source: .battery)
        let planned1 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned1.map(\.kind) == [.restoreUnconfirmed])

        let planned2 = await scenario.command(.backendChanged) { await $0.switchBackend(to: MockChargingBackend()) }
        #expect(planned2.isEmpty)
        let switched = await scenario.status
        #expect(switched.backend.identifier == "simulated")
        #expect(switched.ownRestriction == .noneInEffect)
        let planned3 = await scenario.evaluate()
        #expect(planned3.isEmpty)
    }

    @Test("With macOS's Charge Limit, a restore an earlier session left that fails is reported at launch in the menu's words, and its confirmation once it succeeds")
    func nativeRestore() async {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(90))
        let store = InMemoryRecordStore()
        storeOwnershipRecord(owner: 80, target: 90, in: store)
        system.runBehaviour = .fails
        let scenario = PlannerScenario(
            clock: clock,
            percent: 70,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: ChargingSettings.default.withChargeLimit(90),
            adoptionMarkerStore: store
        )
        let launched = await scenario.evaluate(.launch)
        let status = await scenario.status
        #expect(status.isOwnLimitRestorePending)
        #expect(launched == [PlannedNotification(
            kind: .restoreUnconfirmed,
            title: "Your own Charge Limit is not confirmed back",
            body: "CellKeeper could not confirm yet that your own limit, 80%, is back. It keeps trying; you can also set it in System Settings › Battery › Charging."
        )])
        #expect(launched.first?.body == NativeLimitWording.restoreProblem(status))

        system.runBehaviour = .applies
        let confirmed = await scenario.evaluate()
        #expect(confirmed == [PlannedNotification(
            kind: .restoreResolved,
            title: "Restore of your Charge Limit confirmed",
            body: "macOS reported your own Charge Limit of 80% again."
        )])
    }

    /// A native backend at 85%, recorded from the user's 80%, whose restore
    /// has just failed to confirm; the warning has been posted.
    private func nativeWarned(_ run: FakeChargeLimitSystem.RunBehaviour) async throws -> (PlannerScenario, FakeChargeLimitSystem) {
        let (scenario, system) = nativeScenario(percent: 82)
        await scenario.evaluate(.launch)
        system.runBehaviour = run
        var off = ChargingSettings.default.withChargeLimit(85)
        off.isManagementEnabled = false
        let warned = try await scenario.apply(off)
        #expect(warned.map(\.kind) == [.restoreUnconfirmed])
        let status = await scenario.status
        #expect(status.isOwnLimitRestorePending)
        return (scenario, system)
    }

    @Test("A restore confirmed by read-back is reported without claiming its record was deleted, also when deleting it fails")
    func restoreResolvedWhileRecordRemains() async throws {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let scenario = PlannerScenario(clock: clock, percent: 82, backend: makeNativeBackend(system: system, store: store, clock: clock), settings: ChargingSettings.default.withChargeLimit(85), adoptionMarkerStore: store)
        await scenario.evaluate(.launch)
        system.runBehaviour = .fails
        var off = ChargingSettings.default.withChargeLimit(85)
        off.isManagementEnabled = false
        let planned1 = try await scenario.apply(off)
        #expect(planned1.map(\.kind) == [.restoreUnconfirmed])

        // The retry restores 80% and reads it back, but the record cannot be
        // deleted.
        system.runBehaviour = .applies
        store.removeFails = true
        let resolved = await scenario.evaluate()
        #expect(resolved == [PlannedNotification(kind: .restoreResolved, title: "Restore of your Charge Limit confirmed", body: "macOS reported your own Charge Limit of 80% again.")])
        #expect(store.data != nil)
        let status = await scenario.status
        #expect(status.nativeLimit?.restoresConfirmed == 1)
        for word in ["delet", "record", "remov"] {
            #expect(resolved.first?.body.lowercased().contains(word) == false)
            #expect(resolved.first?.title.lowercased().contains(word) == false)
        }
    }

    @Test("A limit set outside CellKeeper after a restore warning is reported as kept, never as the user's limit back")
    func restoreResolvedByAdoption() async throws {
        let (scenario, system) = try await nativeWarned(.fails)
        system.changeExternally(to: 90)
        let resolved = await scenario.evaluate()
        #expect(resolved == [PlannedNotification(
            kind: .restoreResolved,
            title: "Charge Limit set outside CellKeeper kept",
            body: "macOS reported a Charge Limit of 90% that CellKeeper did not set. CellKeeper kept it as your own limit, so it has nothing left to restore."
        )])
        let status = await scenario.status
        #expect(status.nativeLimit?.restoresConfirmed == 0)
    }

    @Test("Discarding an unreadable record resolves its warning as a discard, also while every read fails")
    func restoreResolvedByDiscard() async {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        store.data = Data("not a record".utf8)
        let scenario = PlannerScenario(clock: clock, percent: 82, backend: makeNativeBackend(system: system, store: store, clock: clock), settings: ChargingSettings.default.withChargeLimit(85), adoptionMarkerStore: store)
        let planned1 = await scenario.evaluate(.launch)
        #expect(planned1.map(\.kind) == [.restoreUnconfirmed])
        system.readFails = true
        let discarded = await scenario.command(.manual) { await $0.discardUnreadableOwnershipRecord() }
        #expect(discarded == [PlannedNotification(
            kind: .restoreResolved,
            title: "Record of your Charge Limit discarded",
            body: "At your request, CellKeeper discarded its unreadable record of your own Charge Limit, so it will not restore a limit from it."
        )])
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)
    }

    @Test("A restore confirmed and a limit applied again within one command still resolves the warning, and a later failure warns again")
    func nativeRestoreAndReapply() async throws {
        let (scenario, system) = try await nativeWarned(.appliesButNextReadFails)
        system.runBehaviour = .applies
        // Turning management on: the next read shows the user's 80%, and
        // CellKeeper sets 85% again before the status is published.
        let resumed = try await scenario.apply(ChargingSettings.default.withChargeLimit(85))
        let status = await scenario.status
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(status.currentMode == .nativeLimit(percent: 85))
        #expect(status.nativeLimit?.restoresConfirmed == 1)
        #expect(resumed.map(\.kind) == [.restoreResolved])
        #expect(resumed.first?.title == "Restore of your Charge Limit confirmed")

        system.runBehaviour = .fails
        var off = ChargingSettings.default.withChargeLimit(85)
        off.isManagementEnabled = false
        let again = try await scenario.apply(off, after: NotificationKind.restoreUnconfirmed.minimumInterval)
        #expect(again.map(\.kind) == [.restoreUnconfirmed])
    }

    @Test("A release confirmed and charging restricted again within one evaluation still resolves the warning, and a later failure warns again")
    func releaseAndRestrictAgain() async {
        let backend = HardwareLikeBackend()
        let scenario = PlannerScenario(percent: 76, backend: backend)
        await chargeToLimit(scenario)
        await backend.failReadAfterNextRequest()
        await scenario.read(80, source: .battery)
        let planned1 = await scenario.evaluate(.powerSourceChanged)
        #expect(planned1.map(\.kind) == [.restoreUnconfirmed])

        // Plugged in again: the read shows the release took effect, and the
        // hold is set again in the same evaluation.
        await scenario.read(80)
        let resolved = await scenario.evaluate(.powerSourceChanged)
        let status = await scenario.status
        #expect(status.currentMode == .inhibitCharging)
        #expect(status.releasesConfirmed == 1)
        #expect(resolved == [PlannedNotification(kind: .restoreResolved, title: "Normal charging confirmed", body: "A read-back after the warning showed normal charging: CellKeeper's restriction had ended.")])

        await backend.failReadAfterNextRequest()
        await scenario.read(80, source: .battery)
        let planned2 = await scenario.evaluate(.powerSourceChanged, after: NotificationKind.restoreUnconfirmed.minimumInterval)
        #expect(planned2.map(\.kind) == [.restoreUnconfirmed])
    }

    @Test("With macOS's Charge Limit, an unreadable record is reported in the menu's words")
    func nativeUnreadableRecord() async {
        let (scenario, _) = nativeScenario(percent: 82)
        scenario.clock.advance(by: 60)
        var status = await scenario.controller.evaluate(.launch)
        status.nativeLimit?.isRecordUnreadable = true
        status.nativeLimit?.ownerLimit = nil
        let warned = scenario.feed(status, .launch)
        #expect(warned.map(\.kind) == [.restoreUnconfirmed])
        #expect(warned.first?.body == "CellKeeper's record of your own limit cannot be read, so it will not change or restore the limit. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control.")
    }

    // MARK: - Delivery and determinism

    @Test("While notifications are not delivered, transitions are consumed: turning them on replays nothing, and no interval was used up")
    func notDelivering() async {
        let scenario = PlannerScenario(percent: 76)
        scenario.isDelivering = false
        let planned1 = await chargeToLimit(scenario)
        #expect(planned1.isEmpty)
        scenario.isDelivering = true
        let planned2 = await scenario.evaluate()
        #expect(planned2.isEmpty)

        await scenario.read(75)
        await scenario.evaluate()
        await scenario.read(80)
        await scenario.evaluate()
        let planned3 = await scenario.evaluate()
        #expect(planned3.map(\.kind) == [.limitReached])
    }

    @Test("The same statuses give the same notifications")
    func deterministic() async {
        func run() async -> [PlannedNotification] {
            let scenario = PlannerScenario(percent: 76)
            await chargeToLimit(scenario)
            await scenario.read(80, temperature: 41)
            await scenario.evaluate()
            await scenario.command(.overrideChanged) { await $0.startFullCharge() }
            await scenario.read(80, source: .battery, temperature: 41)
            await scenario.evaluate(.powerSourceChanged)
            return scenario.all
        }
        let first = await run()
        #expect(first.map(\.kind) == [.limitReached, .temperaturePause, .overrideEnded])
        let planned1 = await run()
        #expect(planned1 == first)
    }

    @Test("Every notification about a simulated backend says so in its title and its body")
    func simulatedAlwaysSaid() async {
        let scenario = PlannerScenario(percent: 76)
        let backend = MockChargingBackend()
        let faulting = PlannerScenario(percent: 76, backend: backend)
        await chargeToLimit(scenario)
        await scenario.read(80, temperature: 41)
        await scenario.evaluate()
        await chargeToLimit(faulting)
        await backend.simulateExternalChange(to: .normal)
        await faulting.evaluate()
        let all = scenario.all + faulting.all
        #expect(Set(all.map(\.kind)) == [.limitReached, .temperaturePause, .backendFault])
        for notification in all {
            #expect(notification.title.contains("Simulated"))
            #expect(notification.body.hasSuffix(Self.simulatedNote))
        }
    }
}
