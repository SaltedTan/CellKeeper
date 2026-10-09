import CellKeeperCore
import Foundation
import Testing

/// Evaluates a reading taken `seconds` after `referenceDate`, at that time:
/// wall time, read time and uptime advance together.
private func evaluate(
    at seconds: TimeInterval,
    _ percent: Int,
    source: PowerSource = .externalPower,
    temperature: Double? = 30,
    sourceTimestamp: Date? = nil,
    settings: ChargingSettings = .default,
    override: ChargeOverride? = nil,
    currentMode: ChargeControlMode? = .normal,
    memory: PolicyMemory,
    sleepImminent: Bool = false
) -> PolicyDecision {
    let time = referenceDate.addingTimeInterval(seconds)
    let reading = snapshot(percent: percent, source: source, temperature: temperature, at: time, sourceTimestamp: sourceTimestamp)
    return ChargingPolicy.evaluate(input(
        reading,
        settings: settings,
        override: override,
        currentMode: currentMode,
        memory: memory,
        sleepImminent: sleepImminent,
        now: time,
        uptime: 10_000 + seconds
    ))
}

@Suite("Limit debounce")
struct LimitDebounceTests {
    @Test("A first reading at or above the limit keeps charging and says it is confirming", arguments: [80, 85, 100])
    func firstReadingWaits(percent: Int) {
        let decision = evaluate(at: 0, percent, memory: PolicyMemory())
        #expect(decision.state == .charging)
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .noAction)
        #expect(decision.reason == .confirmingLimit(percent: percent, limit: 80))
        #expect(decision.notes.contains(.confirmingLimit))
        #expect(!decision.memory.limitReached)
        #expect(decision.memory.pendingLimitCrossing == PolicyMemory.LimitCrossing(sampleTime: referenceDate, percent: percent))
    }

    @Test("A second, distinct reading at or above the limit sets the latch and pauses charging")
    func secondReadingConfirms() {
        let first = evaluate(at: 0, 81, memory: PolicyMemory())
        let second = evaluate(at: 60, 80, memory: first.memory)
        #expect(second.state == .holding)
        #expect(second.action == .disableCharging)
        #expect(second.reason == .limitReached(percent: 80, limit: 80))
        #expect(!second.notes.contains(.confirmingLimit))
        #expect(second.memory.limitReached)
        #expect(second.memory.latchedLimit == 80)
        #expect(second.memory.pendingLimitCrossing == nil)
    }

    @Test("Evaluating the same reading again does not confirm it")
    func sameReadingDoesNotConfirm() {
        // Without a driver update time, the read time identifies the reading:
        // a power event and the timer evaluating one read do not confirm.
        let reading = snapshot(percent: 85)
        let first = ChargingPolicy.evaluate(input(reading))
        let again = ChargingPolicy.evaluate(input(reading, memory: first.memory))
        #expect(again.state == .charging)
        #expect(again.reason == .confirmingLimit(percent: 85, limit: 80))
        #expect(again.memory == first.memory)
    }

    @Test("Where the driver reports its update time, that time identifies the reading")
    func driverTimeIdentifiesReading() {
        // Two reads 30 s apart within one driver refresh are the same reading.
        let refresh = referenceDate.addingTimeInterval(-20)
        let first = evaluate(at: 0, 85, sourceTimestamp: refresh, memory: PolicyMemory())
        let reread = evaluate(at: 30, 85, sourceTimestamp: refresh, memory: first.memory)
        #expect(reread.state == .charging)
        #expect(reread.memory.pendingLimitCrossing == PolicyMemory.LimitCrossing(sampleTime: refresh, percent: 85))

        // The driver's next refresh is a second reading.
        let refreshed = evaluate(at: 60, 85, sourceTimestamp: refresh.addingTimeInterval(60), memory: reread.memory)
        #expect(refreshed.state == .holding)
        #expect(refreshed.action == .disableCharging)
    }

    @Test("A reading below the limit in between drops the pending crossing")
    func lowerReadingDropsPending() {
        let first = evaluate(at: 0, 81, memory: PolicyMemory())
        let dipped = evaluate(at: 60, 79, memory: first.memory)
        #expect(dipped.state == .charging)
        #expect(dipped.reason == .chargingTowardLimit(percent: 79, limit: 80))
        #expect(dipped.memory.pendingLimitCrossing == nil)

        // The next reading at the limit is a first reading again.
        let again = evaluate(at: 120, 81, memory: dipped.memory)
        #expect(again.state == .charging)
        #expect(again.reason == .confirmingLimit(percent: 81, limit: 80))

        let confirmed = evaluate(at: 180, 81, memory: again.memory)
        #expect(confirmed.state == .holding)
    }

    @Test("An evaluation that does not look at the charge drops the pending crossing")
    func unusableReadingDropsPending() {
        let first = evaluate(at: 0, 85, memory: PolicyMemory())
        #expect(first.memory.pendingLimitCrossing != nil)

        let later = referenceDate.addingTimeInterval(60)
        let blind = ChargingPolicy.evaluate(input(nil, memory: first.memory, now: later, uptime: 10_060))
        #expect(blind.state == .failSafe)
        #expect(blind.memory.pendingLimitCrossing == nil)

        var releasing = input(snapshot(percent: 85, at: later), memory: first.memory, now: later, uptime: 10_060)
        releasing.releaseReason = .backendSwitch
        let released = ChargingPolicy.evaluate(releasing)
        #expect(released.state == .failSafe)
        #expect(released.memory.pendingLimitCrossing == nil)

        let afterBlind = evaluate(at: 120, 85, memory: blind.memory)
        #expect(afterBlind.state == .charging)
        #expect(afterBlind.reason == .confirmingLimit(percent: 85, limit: 80))
    }

    @Test("A pending reading counts against the current limit")
    func pendingJudgedAgainstCurrentLimit() {
        let first = evaluate(at: 0, 82, memory: PolicyMemory())

        // Raised to 84%: the pending 82% reading has not reached it, so the
        // next reading at 84% is only the first for the new limit.
        let raised = ChargingSettings(chargeLimit: 84, resumeThreshold: 79)
        let atRaised = evaluate(at: 60, 84, settings: raised, memory: first.memory)
        #expect(atRaised.state == .charging)
        #expect(atRaised.reason == .confirmingLimit(percent: 84, limit: 84))
        #expect(atRaised.memory.pendingLimitCrossing == PolicyMemory.LimitCrossing(sampleTime: referenceDate.addingTimeInterval(60), percent: 84))
        #expect(evaluate(at: 120, 84, settings: raised, memory: atRaised.memory).state == .holding)

        // Lowered to 70%: the pending 82% reading has reached it too.
        let lowered = ChargingSettings(chargeLimit: 70, resumeThreshold: 65)
        #expect(evaluate(at: 60, 81, settings: lowered, memory: first.memory).state == .holding)
    }

    @Test("Readings on battery power confirm the limit, so plugging in holds at once")
    func confirmedOnBattery() {
        let first = evaluate(at: 0, 85, source: .battery, memory: PolicyMemory())
        #expect(first.state == .onBattery)
        #expect(!first.notes.contains(.confirmingLimit))
        let second = evaluate(at: 60, 84, source: .battery, memory: first.memory)
        #expect(second.state == .onBattery)
        #expect(second.memory.limitReached)

        let pluggedIn = evaluate(at: 120, 84, memory: second.memory)
        #expect(pluggedIn.state == .holding)
        #expect(pluggedIn.action == .disableCharging)
    }

    @Test("Readings during a temporary full charge confirm the limit, so it holds as soon as the override ends")
    func confirmedDuringFullCharge() {
        let override = ChargeOverride.fullCharge(at: referenceDate, uptime: 10_000)
        let first = evaluate(at: 0, 85, override: override, memory: PolicyMemory())
        let second = evaluate(at: 60, 86, override: override, memory: first.memory)
        #expect(second.state == .fullChargeOverride)
        #expect(second.memory.limitReached)

        let cancelled = evaluate(at: 120, 87, memory: second.memory)
        #expect(cancelled.state == .holding)
        #expect(cancelled.action == .disableCharging)
    }

    @Test("A 100% limit never starts a crossing")
    func noLimitNoCrossing() {
        let settings = ChargingSettings(chargeLimit: 100, resumeThreshold: 90)
        let decision = evaluate(at: 0, 100, settings: settings, memory: PolicyMemory())
        #expect(decision.reason == .noChargeLimit)
        #expect(decision.memory.pendingLimitCrossing == nil)
        #expect(decision.notes.isEmpty)
    }
}

@Suite("Rules that act on the first reading")
struct UndebouncedRuleTests {
    @Test("The safety floor acts on the first reading")
    func safetyFloor() {
        let decision = evaluate(at: 0, 9, currentMode: .inhibitCharging, memory: PolicyMemory())
        #expect(decision.state == .safetyFloor)
        #expect(decision.action == .enableCharging)
    }

    @Test("The sleep precaution holds on the first reading at the limit")
    func sleepPrecaution() {
        let decision = evaluate(at: 0, 85, memory: PolicyMemory(), sleepImminent: true)
        #expect(decision.state == .holding)
        #expect(decision.action == .disableCharging)
        #expect(decision.reason == .sleepPrecaution(percent: 85, resumeThreshold: 75))
        #expect(!decision.memory.limitReached)
    }

    @Test("Temperature protection trips on the first hot reading", arguments: [50, 85])
    func temperatureTrips(percent: Int) {
        let decision = evaluate(at: 0, percent, temperature: 40, memory: PolicyMemory())
        #expect(decision.state == .temperaturePause)
        #expect(decision.action == .disableCharging)
        #expect(decision.memory.temperatureTripped)
    }

    @Test("Falling to the resume threshold releases the hold on the first reading")
    func resumeThreshold() {
        let latched = evaluate(at: 0, 85, memory: memoryAfterReading(85))
        let held = evaluate(at: 60, 77, currentMode: .inhibitCharging, memory: latched.memory)
        #expect(held.state == .holding)
        let resumed = evaluate(at: 120, 75, currentMode: .inhibitCharging, memory: held.memory)
        #expect(resumed.state == .charging)
        #expect(resumed.action == .enableCharging)
        #expect(!resumed.memory.limitReached)
    }

    @Test("Unplugging clears restrictions on the first reading")
    func onBattery() {
        let held = evaluate(at: 0, 85, currentMode: .inhibitCharging, memory: memoryAfterReading(85))
        #expect(held.state == .holding)
        let unplugged = evaluate(at: 1, 85, source: .battery, currentMode: .inhibitCharging, memory: held.memory)
        #expect(unplugged.state == .onBattery)
        #expect(unplugged.action == .enableCharging)
    }
}

@Suite("Temperature minimum pause")
struct TemperatureMinimumPauseTests {
    /// Memory after temperature protection tripped at uptime 10 000.
    let tripped = evaluate(at: 0, 50, temperature: 41, memory: PolicyMemory()).memory

    @Test("A trip records when it began, on the monotonic clock")
    func recordsTripTime() {
        #expect(tripped.temperatureTripped)
        #expect(tripped.temperatureTrippedAtUptime == 10_000)
    }

    @Test("Cooled to the resume threshold, charging stays paused until 5 minutes after the trip")
    func holdsForMinimum() {
        let early = evaluate(at: 299, 50, temperature: 34, currentMode: .inhibitCharging, memory: tripped)
        #expect(early.state == .temperaturePause)
        #expect(early.action == .noAction)
        #expect(early.reason == .temperatureMinimumPause(celsius: 34, resumesAt: referenceDate.addingTimeInterval(300)))
        #expect(early.memory.temperatureTripped)
        #expect(early.memory.temperatureTrippedAtUptime == 10_000)

        let done = evaluate(at: 300, 50, temperature: 34, currentMode: .inhibitCharging, memory: early.memory)
        #expect(done.state == .charging)
        #expect(done.action == .enableCharging)
        #expect(!done.memory.temperatureTripped)
        #expect(done.memory.temperatureTrippedAtUptime == nil)
    }

    @Test("The minimum is timed from the trip, not from the last hot reading")
    func timedFromTrip() {
        let stillHot = evaluate(at: 200, 50, temperature: 42, currentMode: .inhibitCharging, memory: tripped)
        #expect(stillHot.memory.temperatureTrippedAtUptime == 10_000)
        let cooled = evaluate(at: 300, 50, temperature: 35, currentMode: .inhibitCharging, memory: stillHot.memory)
        #expect(cooled.state == .charging)
    }

    @Test("Above the resume threshold, the pause continues after the minimum")
    func hysteresisStillApplies() {
        let decision = evaluate(at: 600, 50, temperature: 36, currentMode: .inhibitCharging, memory: tripped)
        #expect(decision.state == .temperaturePause)
        #expect(decision.reason == .temperatureCooling(celsius: 36, resumeAt: 35))
    }

    @Test("An unknown temperature ends the pause at once, even within the minimum")
    func unknownTemperatureEndsPause() {
        for temperature in [nil, .nan, .infinity] as [Double?] {
            let decision = evaluate(at: 10, 50, temperature: temperature, currentMode: .inhibitCharging, memory: tripped)
            #expect(decision.state == .charging)
            #expect(decision.action == .enableCharging)
            #expect(!decision.memory.temperatureTripped)
            #expect(decision.memory.temperatureTrippedAtUptime == nil)
            #expect(decision.notes.contains(.temperatureUnavailable))
        }
    }

    @Test("Turning temperature protection off ends the pause at once")
    func disablingEndsPause() {
        var settings = ChargingSettings.default
        settings.temperatureProtection.isEnabled = false
        let decision = evaluate(at: 10, 50, temperature: 41, settings: settings, currentMode: .inhibitCharging, memory: tripped)
        #expect(decision.state == .charging)
        #expect(decision.action == .enableCharging)
        #expect(decision.memory.temperatureTrippedAtUptime == nil)
    }

    @Test("Once the pause has ended, a hot reading pauses again at once")
    func retripsWithoutMinimum() {
        let ended = evaluate(at: 300, 50, temperature: 34, currentMode: .inhibitCharging, memory: tripped)
        #expect(ended.state == .charging)
        let hotAgain = evaluate(at: 301, 50, temperature: 40, memory: ended.memory)
        #expect(hotAgain.state == .temperaturePause)
        #expect(hotAgain.action == .disableCharging)
        #expect(hotAgain.memory.temperatureTrippedAtUptime == 10_301)
    }

    @Test("The safety floor overrides a pause within the minimum")
    func floorOverridesPause() {
        let decision = evaluate(at: 10, 9, temperature: 41, currentMode: .inhibitCharging, memory: tripped)
        #expect(decision.state == .safetyFloor)
        #expect(decision.action == .enableCharging)
    }

    @Test("A trip time later than now restarts the minimum from now, never longer")
    func futureTripTimeIsClamped() {
        let future = PolicyMemory(temperatureTripped: true, temperatureTrippedAtUptime: 50_000)
        let now = evaluate(at: 0, 50, temperature: 34, currentMode: .inhibitCharging, memory: future)
        #expect(now.state == .temperaturePause)
        #expect(now.memory.temperatureTrippedAtUptime == 10_000)
        let later = evaluate(at: 300, 50, temperature: 34, currentMode: .inhibitCharging, memory: now.memory)
        #expect(later.state == .charging)
    }

    @Test("A trip without a recorded time has no minimum")
    func unknownTripTime() {
        let decision = evaluate(at: 0, 50, temperature: 35, currentMode: .inhibitCharging, memory: PolicyMemory(temperatureTripped: true))
        #expect(decision.state == .charging)
        #expect(!decision.memory.temperatureTripped)
    }
}

@Suite("Native limit and the debounce")
struct NativeLimitDebounceTests {
    @Test("Native-limit decisions ignore and clear the debounce and pause memory")
    func nativeLimitUnaffected() {
        let settings = ChargingSettings.default.withChargeLimit(85)
        let memory = PolicyMemory(
            limitReached: true,
            temperatureTripped: true,
            latchedLimit: 85,
            pendingLimitCrossing: PolicyMemory.LimitCrossing(sampleTime: referenceDate.addingTimeInterval(-60), percent: 90),
            temperatureTrippedAtUptime: 9_990
        )
        for reading in [snapshot(percent: 90), snapshot(percent: 90, temperature: 34), snapshot(percent: 50, temperature: 41)] {
            let fresh = ChargingPolicy.evaluate(input(reading, settings: settings, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 85)))
            let remembered = ChargingPolicy.evaluate(input(reading, settings: settings, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 85), memory: memory))
            #expect(remembered == fresh)
            #expect(remembered.state == .osEnforcedLimit)
            #expect(remembered.desiredMode == .nativeLimit(percent: 85))
            #expect(remembered.notes.isEmpty)
            #expect(remembered.memory == PolicyMemory())
        }
    }
}
