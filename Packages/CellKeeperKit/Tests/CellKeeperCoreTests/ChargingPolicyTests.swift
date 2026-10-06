import CellKeeperCore
import Foundation
import Testing

@Suite("Charge limit and hysteresis")
struct ChargeLimitTests {
    @Test("Below the resume threshold, charging is enabled")
    func belowResumeThreshold() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 60), currentMode: .inhibitCharging, memory: PolicyMemory(limitReached: true)))
        #expect(decision.state == .charging)
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .enableCharging)
        #expect(decision.reason == .belowResumeThreshold(percent: 60, resumeThreshold: 75))
        #expect(decision.memory.limitReached == false)
    }

    @Test("At exactly the resume threshold, charging resumes")
    func atResumeThreshold() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 75), currentMode: .inhibitCharging, memory: PolicyMemory(limitReached: true)))
        #expect(decision.state == .charging)
        #expect(decision.action == .enableCharging)
    }

    @Test("Inside the hysteresis range while charging up, charging continues")
    func insideRangeChargingUp() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 78), memory: PolicyMemory(limitReached: false)))
        #expect(decision.state == .charging)
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .noAction)
        #expect(decision.reason == .chargingTowardLimit(percent: 78, limit: 80))
    }

    @Test("Inside the hysteresis range after reaching the limit, charging stays paused")
    func insideRangeAfterLimit() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 77, charging: false), currentMode: .inhibitCharging, memory: PolicyMemory(limitReached: true)))
        #expect(decision.state == .holding)
        #expect(decision.desiredMode == .inhibitCharging)
        #expect(decision.action == .noAction)
        #expect(decision.reason == .holdingAboveResumeThreshold(percent: 77, resumeThreshold: 75))
        #expect(decision.memory.limitReached)
    }

    @Test("At or above the limit, charging is disabled", arguments: [80, 81, 95, 100])
    func atOrAboveLimit(percent: Int) {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: percent)))
        #expect(decision.state == .holding)
        #expect(decision.desiredMode == .inhibitCharging)
        #expect(decision.action == .disableCharging)
        #expect(decision.memory.limitReached)
    }

    @Test("A 100% limit means no limit")
    func noLimit() {
        let settings = ChargingSettings(chargeLimit: 100, resumeThreshold: 90)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 100), settings: settings, currentMode: .inhibitCharging, memory: PolicyMemory(limitReached: true)))
        #expect(decision.state == .charging)
        #expect(decision.action == .enableCharging)
        #expect(decision.reason == .noChargeLimit)
        #expect(decision.memory.limitReached == false)
    }

    @Test("A full hysteresis cycle transitions deterministically")
    func fullCycle() {
        var memory = PolicyMemory()
        var mode: ChargeControlMode = .normal
        var states: [PolicyState] = []
        // Charge up past the limit, then drift down to the resume threshold.
        for percent in [70, 79, 80, 79, 76, 75, 76] {
            let decision = ChargingPolicy.evaluate(input(snapshot(percent: percent), currentMode: mode, memory: memory))
            memory = decision.memory
            if let requested = decision.action.requestedMode { mode = requested }
            states.append(decision.state)
        }
        #expect(states == [.charging, .charging, .holding, .holding, .holding, .charging, .charging])
        #expect(mode == .normal)
    }

    @Test("Changing the limit recalculates the desired action")
    func limitChangeRecalculates() {
        let reading = snapshot(percent: 78)
        let before = ChargingPolicy.evaluate(input(reading, settings: ChargingSettings(chargeLimit: 80, resumeThreshold: 75)))
        #expect(before.action == .noAction)
        #expect(before.desiredMode == .normal)

        let after = ChargingPolicy.evaluate(input(reading, settings: ChargingSettings(chargeLimit: 70, resumeThreshold: 65), memory: before.memory))
        #expect(after.state == .holding)
        #expect(after.action == .disableCharging)

        let raised = ChargingPolicy.evaluate(input(reading, settings: ChargingSettings(chargeLimit: 90, resumeThreshold: 85), currentMode: .inhibitCharging, memory: after.memory))
        #expect(raised.state == .charging)
        #expect(raised.action == .enableCharging)
    }

    @Test("The same input always produces the same decision")
    func deterministic() {
        let value = input(snapshot(percent: 77), memory: PolicyMemory(limitReached: true))
        #expect(ChargingPolicy.evaluate(value) == ChargingPolicy.evaluate(value))
    }

    @Test("Charging status is derived from the power source")
    func chargingStatus() {
        #expect(snapshot(percent: 50, source: .battery).chargingStatus == .discharging)
        #expect(snapshot(percent: 50, charging: true).chargingStatus == .charging)
        #expect(snapshot(percent: 80, charging: false).chargingStatus == .notCharging)
        #expect(snapshot(percent: 100, charging: false, fullyCharged: true).chargingStatus == .fullyCharged)
        #expect(snapshot(percent: 50, source: .unknown).chargingStatus == .unknown)
    }
}

@Suite("Power source and sleep")
struct PowerSourceAndSleepTests {
    @Test("On battery power, restrictions are cleared but the limit latch is kept")
    func onBatteryClearsRestrictions() {
        let unplugged = ChargingPolicy.evaluate(input(snapshot(percent: 78, source: .battery), currentMode: .inhibitCharging, memory: PolicyMemory(limitReached: true)))
        #expect(unplugged.state == .onBattery)
        #expect(unplugged.action == .enableCharging)
        #expect(unplugged.memory.limitReached)

        // Plugged back in above the resume threshold: the hold is re-applied.
        let replugged = ChargingPolicy.evaluate(input(snapshot(percent: 78), memory: unplugged.memory))
        #expect(replugged.state == .holding)
        #expect(replugged.action == .disableCharging)
    }

    @Test("An unknown power source fails safe")
    func unknownPowerSource() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90, source: .unknown), currentMode: .inhibitCharging))
        #expect(decision.state == .failSafe)
        #expect(decision.reason == .powerSourceUnknown)
        #expect(decision.action == .enableCharging)
    }

    @Test("Before sleep, charging is held at or above the resume threshold to avoid overshoot")
    func sleepPrecaution() {
        let held = ChargingPolicy.evaluate(input(snapshot(percent: 78), sleepImminent: true))
        #expect(held.state == .holding)
        #expect(held.action == .disableCharging)
        #expect(held.reason == .sleepPrecaution(percent: 78, resumeThreshold: 75))
        #expect(held.memory.limitReached == false)

        let low = ChargingPolicy.evaluate(input(snapshot(percent: 60), sleepImminent: true))
        #expect(low.state == .charging)

        // After wake, charging toward the limit continues.
        let awake = ChargingPolicy.evaluate(input(snapshot(percent: 78), currentMode: .inhibitCharging, memory: held.memory))
        #expect(awake.state == .charging)
        #expect(awake.action == .enableCharging)
    }
}

@Suite("Discharge sessions")
struct DischargeSessionTests {
    let session = ChargeOverride.dischargeToLimit(target: 80, at: referenceDate, uptime: 10_000)

    @Test("Above the limit on external power, an active session requests discharge")
    func dischargeRequested() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90), override: session))
        #expect(decision.state == .discharging)
        #expect(decision.desiredMode == .forceDischarge)
        #expect(decision.action == .requestDischarge)
        #expect(decision.reason == .dischargingToLimit(percent: 90, limit: 80))
        #expect(decision.overrideEnded == nil)
    }

    @Test("Without a session, above the limit only holds")
    func holdWithoutSession() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90)))
        #expect(decision.state == .holding)
        #expect(decision.action == .disableCharging)
    }

    @Test("Reaching the limit completes the session and holds")
    func completesAtLimit() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 80, charging: false), override: session, currentMode: .forceDischarge, memory: PolicyMemory(limitReached: true)))
        #expect(decision.overrideEnded == .completed)
        #expect(decision.state == .holding)
        #expect(decision.action == .disableCharging)
    }

    @Test("Unplugging ends the session, and the session never restarts by itself")
    func unplugEndsSession() {
        let unplugged = ChargingPolicy.evaluate(input(snapshot(percent: 88, source: .battery), override: session, currentMode: .forceDischarge, memory: PolicyMemory(limitReached: true)))
        #expect(unplugged.overrideEnded == .unplugged)
        #expect(unplugged.state == .onBattery)
        #expect(unplugged.action == .enableCharging)

        // Plugged in again without a session: hold, never discharge.
        let replugged = ChargingPolicy.evaluate(input(snapshot(percent: 88), memory: unplugged.memory))
        #expect(replugged.state == .holding)
        #expect(replugged.desiredMode == .inhibitCharging)
    }

    @Test("Imminent sleep interrupts the session and holds")
    func sleepInterrupts() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90), override: session, currentMode: .forceDischarge, memory: PolicyMemory(limitReached: true), sleepImminent: true))
        #expect(decision.overrideEnded == .interrupted)
        #expect(decision.state == .holding)
        #expect(decision.action == .disableCharging)
    }

    @Test("Temperature protection interrupts the session")
    func temperatureInterrupts() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90, temperature: 45), override: session, currentMode: .forceDischarge))
        #expect(decision.overrideEnded == .interrupted)
        #expect(decision.state == .temperaturePause)
        #expect(decision.desiredMode == .inhibitCharging)
    }

    @Test("Lost telemetry interrupts the session")
    func telemetryLossInterrupts() {
        let decision = ChargingPolicy.evaluate(input(nil, override: session, currentMode: .forceDischarge))
        #expect(decision.overrideEnded == .interrupted)
        #expect(decision.state == .failSafe)
        #expect(decision.action == .enableCharging)
    }

    @Test("A backend that cannot discharge interrupts the session and says why")
    func unsupportedInterrupts() {
        let capabilities = ControlCapabilities(availability: .simulated, supportedModes: [.normal, .inhibitCharging])
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90), override: session, capabilities: capabilities))
        #expect(decision.overrideEnded == .interrupted)
        #expect(decision.notes.contains(.dischargeUnsupported))
        #expect(decision.state == .holding)
    }

    @Test("A session with a target outside 20–95% is interrupted")
    func invalidTarget() {
        let settings = ChargingSettings(chargeLimit: 96, resumeThreshold: 80)
        let outOfRange = ChargeOverride.dischargeToLimit(target: 96, at: referenceDate, uptime: 10_000)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 98), settings: settings, override: outOfRange))
        #expect(decision.overrideEnded == .interrupted)
        #expect(decision.desiredMode != .forceDischarge)
    }

    @Test("Lowering the limit mid-session never discharges below the confirmed target")
    func targetIsCaptured() {
        let lowered = ChargingSettings(chargeLimit: 60, resumeThreshold: 55)
        let running = ChargingPolicy.evaluate(input(snapshot(percent: 85), settings: lowered, override: session))
        #expect(running.state == .discharging)
        #expect(running.reason == .dischargingToLimit(percent: 85, limit: 80))

        let done = ChargingPolicy.evaluate(input(snapshot(percent: 80), settings: lowered, override: session, currentMode: .forceDischarge))
        #expect(done.overrideEnded == .completed)
        #expect(done.desiredMode == .inhibitCharging)
    }

    @Test("Raising the limit mid-session stops discharging at the new limit")
    func raisedLimitStopsEarlier() {
        let raised = ChargingSettings(chargeLimit: 90, resumeThreshold: 85)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 88), settings: raised, override: session, currentMode: .forceDischarge))
        #expect(decision.overrideEnded == .completed)
    }

    @Test("A faulted backend interrupts the session")
    func faultInterrupts() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90), override: session, currentMode: .forceDischarge, faulted: true))
        #expect(decision.overrideEnded == .interrupted)
        #expect(decision.action == .enableCharging)
    }
}

@Suite("Temporary full charge")
struct FullChargeOverrideTests {
    let override = ChargeOverride.fullCharge(at: referenceDate, uptime: 10_000)

    @Test("An active override enables charging above the limit")
    func overrideEnablesCharging() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), override: override, currentMode: .inhibitCharging, memory: PolicyMemory(limitReached: true)))
        #expect(decision.state == .fullChargeOverride)
        #expect(decision.action == .enableCharging)
        #expect(decision.overrideEnded == nil)
    }

    @Test("The override completes at 100% and the limit applies again")
    func overrideCompletes() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 100), override: override))
        #expect(decision.overrideEnded == .completed)
        #expect(decision.state == .holding)
        #expect(decision.action == .disableCharging)
    }

    @Test("The override completes when the system reports fully charged")
    func overrideCompletesWhenFull() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 99, charging: false, fullyCharged: true), override: override))
        #expect(decision.overrideEnded == .completed)
    }

    @Test("The override expires on the monotonic clock, regardless of wall-clock time")
    func overrideExpires() {
        let expiredUptime = override.expiresAtUptime
        // The wall clock was moved back a day; the override still expires.
        let earlier = referenceDate.addingTimeInterval(-86_400)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90, at: earlier), override: override, now: earlier, uptime: expiredUptime))
        #expect(decision.overrideEnded == .expired)
        #expect(decision.state == .holding)

        let notYet = ChargingPolicy.evaluate(input(snapshot(percent: 90), override: override, uptime: expiredUptime - 1))
        #expect(notYet.overrideEnded == nil)
    }

    @Test("The override ends when external power is disconnected")
    func overrideEndsOnUnplug() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90, source: .battery), override: override))
        #expect(decision.overrideEnded == .unplugged)
        #expect(decision.state == .onBattery)
    }

    @Test("Unplugging ends the override even when the charge reading is unusable")
    func unplugWithUnknownPercent() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: nil, source: .battery), override: override))
        #expect(decision.state == .failSafe)
        #expect(decision.overrideEnded == .unplugged)
    }

    @Test("Expiry is processed even when telemetry is missing")
    func expiryWithoutTelemetry() {
        let decision = ChargingPolicy.evaluate(input(nil, override: override, uptime: override.expiresAtUptime + 1))
        #expect(decision.overrideEnded == .expired)
    }

    @Test("Override durations are clamped to 1–48 hours")
    func durationClamped() {
        let long = ChargeOverride.fullCharge(at: referenceDate, uptime: 0, duration: 1_000_000)
        #expect(long.expiresAtUptime == ChargeOverride.maximumDuration)
        #expect(long.expiresAt == referenceDate.addingTimeInterval(ChargeOverride.maximumDuration))
        let negative = ChargeOverride.fullCharge(at: referenceDate, uptime: 0, duration: -5)
        #expect(negative.expiresAtUptime == ChargeOverride.minimumDuration)
        let nonFinite = ChargeOverride.fullCharge(at: referenceDate, uptime: 0, duration: .nan)
        #expect(nonFinite.expiresAtUptime == ChargeOverride.minimumDuration)
    }
}

@Suite("Temperature protection")
struct TemperatureProtectionTests {
    @Test("At the pause threshold, charging pauses")
    func pausesWhenHot() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50, temperature: 40)))
        #expect(decision.state == .temperaturePause)
        #expect(decision.action == .disableCharging)
        #expect(decision.reason == .temperatureHigh(celsius: 40, pauseAt: 40))
        #expect(decision.memory.temperatureTripped)
    }

    @Test("Between thresholds after tripping, charging stays paused")
    func staysPausedWhileCooling() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50, temperature: 37), currentMode: .inhibitCharging, memory: PolicyMemory(temperatureTripped: true)))
        #expect(decision.state == .temperaturePause)
        #expect(decision.action == .noAction)
        #expect(decision.reason == .temperatureCooling(celsius: 37, resumeAt: 35))
    }

    @Test("Between thresholds without tripping, charging is unaffected")
    func unaffectedBelowPause() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50, temperature: 37)))
        #expect(decision.state == .charging)
    }

    @Test("At the resume threshold, charging resumes")
    func resumesWhenCool() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50, temperature: 35), currentMode: .inhibitCharging, memory: PolicyMemory(temperatureTripped: true)))
        #expect(decision.state == .charging)
        #expect(decision.action == .enableCharging)
        #expect(decision.memory.temperatureTripped == false)
    }

    @Test("Unknown temperature cannot pause charging, and is reported")
    func unknownTemperature() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50, temperature: nil), currentMode: .inhibitCharging, memory: PolicyMemory(temperatureTripped: true)))
        #expect(decision.state == .charging)
        #expect(decision.memory.temperatureTripped == false)
        #expect(decision.notes.contains(.temperatureUnavailable))
    }

    @Test("Non-finite temperatures are treated as unknown")
    func nonFiniteTemperature() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50, temperature: .infinity)))
        #expect(decision.state == .charging)
        #expect(decision.notes.contains(.temperatureUnavailable))
    }

    @Test("Disabled protection ignores temperature")
    func disabledProtection() {
        var settings = ChargingSettings.default
        settings.temperatureProtection.isEnabled = false
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50, temperature: 45), settings: settings))
        #expect(decision.state == .charging)
        #expect(decision.notes.isEmpty)
    }
}

@Suite("Unavailable or faulted backend")
struct BackendAvailabilityTests {
    let unavailable = ControlCapabilities.unavailable("read-only")

    @Test("When control is unavailable, a pause is refused but still computed")
    func refusesWhenUnavailable() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), capabilities: unavailable, currentMode: nil))
        #expect(decision.state == .holding)
        #expect(decision.desiredMode == .inhibitCharging)
        #expect(decision.action == .refuse(.controlUnavailable("read-only")))
    }

    @Test("When control is unavailable and defaults are wanted, nothing is needed")
    func noActionForNormalWhenUnavailable() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50), capabilities: unavailable, currentMode: nil))
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .noAction)
    }

    @Test("When control is lost while charging is inhibited, restoring is refused, not ignored")
    func refusesRestoreWhenUnavailable() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50), capabilities: unavailable, currentMode: .inhibitCharging))
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .refuse(.controlUnavailable("read-only")))
    }

    @Test("Unsupported modes are refused")
    func unsupportedMode() {
        let capabilities = ControlCapabilities(availability: .simulated, supportedModes: [.normal])
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), capabilities: capabilities))
        #expect(decision.action == .refuse(.modeUnsupported(.inhibitCharging)))
    }

    @Test("A faulted backend in normal mode is never asked to restrict")
    func faultedRefusesRestriction() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), faulted: true))
        #expect(decision.action == .refuse(.backendFaulted))
    }

    @Test("A faulted backend that is not confirmed normal is actively restored", arguments: [ChargeControlMode?.some(.forceDischarge), .some(.inhibitCharging), nil])
    func faultedRestores(current: ChargeControlMode?) {
        // Even when the policy itself wants to hold, recovery takes priority.
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), currentMode: current, faulted: true))
        #expect(decision.desiredMode == .inhibitCharging)
        #expect(decision.action == .enableCharging)
    }

    @Test("Capabilities always include normal when requests are accepted")
    func capabilitiesIncludeNormal() {
        let capabilities = ControlCapabilities(availability: .experimental, supportedModes: [.inhibitCharging])
        #expect(capabilities.supports(.normal))
        #expect(ControlCapabilities.unavailable("x").supports(.normal) == false)
    }
}

@Suite("Rate limiting")
struct RateLimitTests {
    @Test("A restricting change soon after another is refused until the interval passes")
    func minimumInterval() {
        let recent: [TimeInterval] = [10_000 - 30]
        let limited = ChargingPolicy.evaluate(input(snapshot(percent: 85), recentRestrictingRequests: recent))
        #expect(limited.desiredMode == .inhibitCharging)
        #expect(limited.action == .refuse(.rateLimited(retryAt: referenceDate.addingTimeInterval(30))))

        let later = referenceDate.addingTimeInterval(31)
        let allowed = ChargingPolicy.evaluate(input(snapshot(percent: 85, at: later), recentRestrictingRequests: recent, now: later, uptime: 10_031))
        #expect(allowed.action == .disableCharging)
    }

    @Test("Restricting changes are capped per hour")
    func hourlyCap() {
        let history = (0..<ChargingPolicy.maximumRestrictingRequestsPerHour).map { 10_000 - 3_000 + TimeInterval($0) * 120 }
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), recentRestrictingRequests: history))
        #expect(decision.action == .refuse(.rateLimited(retryAt: referenceDate.addingTimeInterval(history[0] + 3_600 - 10_000))))
    }

    @Test("Relaxing changes toward normal charging are never rate-limited")
    func relaxingNeverLimited() {
        let recent: [TimeInterval] = [10_000]
        let toNormal = ChargingPolicy.evaluate(input(snapshot(percent: 50), currentMode: .inhibitCharging, recentRestrictingRequests: recent))
        #expect(toNormal.action == .enableCharging)

        let session = ChargeOverride.dischargeToLimit(target: 80, at: referenceDate, uptime: 10_000)
        let dischargeToHold = ChargingPolicy.evaluate(input(snapshot(percent: 80), override: session, currentMode: .forceDischarge, memory: PolicyMemory(limitReached: true), recentRestrictingRequests: recent))
        #expect(dischargeToHold.action == .disableCharging)
    }

    @Test("Wall-clock changes do not affect rate limiting")
    func wallClockIndependent() {
        let recent: [TimeInterval] = [10_000 - 30]
        let earlier = referenceDate.addingTimeInterval(-7_200)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85, at: earlier), recentRestrictingRequests: recent, now: earlier))
        #expect(decision.action == .refuse(.rateLimited(retryAt: earlier.addingTimeInterval(30))))
    }
}

@Suite("Conflicting policy states")
struct ConflictTests {
    @Test("Temperature protection beats a temporary full charge")
    func temperatureBeatsFullCharge() {
        let override = ChargeOverride.fullCharge(at: referenceDate, uptime: 10_000)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85, temperature: 45), override: override))
        #expect(decision.state == .temperaturePause)
        #expect(decision.desiredMode == .inhibitCharging)
        #expect(decision.notes.contains(.fullChargeSuppressed(by: .temperaturePause)))
        #expect(decision.overrideEnded == nil)
    }

    @Test("The safety floor beats temperature protection")
    func safetyFloorBeatsTemperature() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 8, temperature: 45), currentMode: .inhibitCharging))
        #expect(decision.state == .safetyFloor)
        #expect(decision.action == .enableCharging)
    }

    @Test("Disabled management beats every other rule")
    func managementDisabledWins() {
        var settings = ChargingSettings.default
        settings.isManagementEnabled = false
        let override = ChargeOverride.fullCharge(at: referenceDate, uptime: 10_000)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90, temperature: 45), settings: settings, override: override, currentMode: .inhibitCharging, memory: PolicyMemory(limitReached: true, temperatureTripped: true)))
        #expect(decision.state == .unmanaged)
        #expect(decision.action == .enableCharging)
        #expect(decision.memory == PolicyMemory())
    }
}

@Suite("Fail-safe inputs")
struct FailSafeTests {
    @Test("Invalid settings fail safe to macOS default charging", arguments: [
        ChargingSettings(chargeLimit: 120, resumeThreshold: 75),
        ChargingSettings(chargeLimit: 5, resumeThreshold: 3),
        ChargingSettings(chargeLimit: 80, resumeThreshold: 80),
        ChargingSettings(temperatureProtection: TemperatureProtection(isEnabled: true, pauseAtCelsius: .nan, resumeAtCelsius: 35)),
    ])
    func invalidSettings(settings: ChargingSettings) {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90), settings: settings, currentMode: .inhibitCharging))
        #expect(decision.state == .failSafe)
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .enableCharging)
        guard case .invalidConfiguration(let issues) = decision.reason else {
            Issue.record("expected invalidConfiguration, got \(decision.reason)")
            return
        }
        #expect(!issues.isEmpty)
    }

    @Test("Missing telemetry fails safe")
    func missingTelemetry() {
        let decision = ChargingPolicy.evaluate(input(nil, currentMode: .inhibitCharging))
        #expect(decision.state == .failSafe)
        #expect(decision.action == .enableCharging)
        #expect(decision.reason == .telemetryUnavailable)
    }

    @Test("Unknown charge percentage fails safe")
    func unknownPercent() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: nil), currentMode: .inhibitCharging))
        #expect(decision.state == .failSafe)
        #expect(decision.reason == .telemetryUnavailable)
    }

    @Test("Stale telemetry fails safe")
    func staleTelemetry() {
        let old = snapshot(percent: 90, at: referenceDate.addingTimeInterval(-ChargingPolicy.maximumTelemetryAge - 1))
        let decision = ChargingPolicy.evaluate(input(old))
        #expect(decision.state == .failSafe)
        #expect(decision.desiredMode == .normal)
    }

    @Test("A frozen data source fails safe even when freshly read")
    func frozenSource() {
        let frozen = snapshot(percent: 90, sourceTimestamp: referenceDate.addingTimeInterval(-ChargingPolicy.maximumSourceAge - 1))
        let decision = ChargingPolicy.evaluate(input(frozen))
        #expect(decision.state == .failSafe)
        guard case .telemetryStale = decision.reason else {
            Issue.record("expected telemetryStale, got \(decision.reason)")
            return
        }

        let recent = snapshot(percent: 90, sourceTimestamp: referenceDate.addingTimeInterval(-59))
        #expect(ChargingPolicy.evaluate(input(recent)).state == .holding)
    }

    @Test("Absurd telemetry timestamps fail safe without trapping", arguments: [Date.distantPast, .distantFuture])
    func absurdTimestamps(timestamp: Date) {
        #expect(ChargingPolicy.evaluate(input(snapshot(percent: 90, at: timestamp))).state == .failSafe)
        #expect(ChargingPolicy.evaluate(input(snapshot(percent: 90, sourceTimestamp: timestamp))).state == .failSafe)
    }

    @Test("Telemetry from the future fails safe")
    func futureTelemetry() {
        let future = snapshot(percent: 90, at: referenceDate.addingTimeInterval(ChargingPolicy.maximumClockSkew + 1))
        let decision = ChargingPolicy.evaluate(input(future))
        #expect(decision.state == .failSafe)
    }

    @Test("No battery fails safe")
    func noBattery() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: nil, present: false)))
        #expect(decision.state == .failSafe)
        #expect(decision.reason == .batteryNotPresent)
    }

    @Test("At or below the safety floor, charging is always allowed", arguments: [0, 5, 10])
    func safetyFloor(percent: Int) {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: percent), currentMode: .inhibitCharging))
        #expect(decision.state == .safetyFloor)
        #expect(decision.action == .enableCharging)
        #expect(decision.memory.belowSafetyFloor)
    }

    @Test("The safety floor holds until five points above it")
    func safetyFloorHysteresis() {
        let latched = PolicyMemory(belowSafetyFloor: true)
        let stillLatched = ChargingPolicy.evaluate(input(snapshot(percent: 14, temperature: 45), memory: latched))
        #expect(stillLatched.state == .safetyFloor)

        let released = ChargingPolicy.evaluate(input(snapshot(percent: 15, temperature: 30), memory: latched))
        #expect(released.state == .charging)
        #expect(released.memory.belowSafetyFloor == false)

        // Without having reached the floor, 12% is ordinary charging.
        #expect(ChargingPolicy.evaluate(input(snapshot(percent: 12))).state == .charging)
    }
}
