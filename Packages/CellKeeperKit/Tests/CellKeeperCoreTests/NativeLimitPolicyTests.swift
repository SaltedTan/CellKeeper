import CellKeeperCore
import Foundation
import Testing

@Suite("Native limit policy")
struct NativeLimitPolicyTests {
    private func settings(limit: Int, managed: Bool = true) -> ChargingSettings {
        var settings = ChargingSettings.default.withChargeLimit(limit)
        settings.isManagementEnabled = managed
        return settings
    }

    @Test("The configured limit becomes the desired native limit, enforced by macOS", arguments: [80, 85, 90, 95, 100])
    func desiredLimit(limit: Int) {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 60), settings: settings(limit: limit), capabilities: nativeCapabilities, currentMode: .normal))
        #expect(decision.state == .osEnforcedLimit)
        #expect(decision.desiredMode == .nativeLimit(percent: limit))
        #expect(decision.action == .setNativeLimit(limit))
        #expect(decision.reason == .nativeLimitActive(limit: limit))
    }

    @Test("Nothing is requested when the limit is already set")
    func alreadySet() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90), settings: settings(limit: 90), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 90)))
        #expect(decision.action == .noAction)
    }

    @Test("The decision does not depend on charge, power source, temperature, sleep or the floor")
    func telemetryIndependent() {
        let readings = [
            snapshot(percent: 5),
            snapshot(percent: 99),
            snapshot(percent: 70, source: .battery),
            snapshot(percent: 85, temperature: 45),
        ]
        for reading in readings {
            for sleeping in [false, true] {
                let decision = ChargingPolicy.evaluate(input(reading, settings: settings(limit: 85), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 85), sleepImminent: sleeping))
                #expect(decision.state == .osEnforcedLimit)
                #expect(decision.action == .noAction)
                #expect(decision.memory == PolicyMemory())
            }
        }
    }

    @Test("Unusable telemetry keeps the limit and says why")
    func telemetryLossKeepsLimit() {
        let stale = snapshot(percent: 90, at: referenceDate.addingTimeInterval(-ChargingPolicy.maximumTelemetryAge - 1))
        for reading in [nil, stale, snapshot(percent: nil), snapshot(percent: 90, source: .unknown)] {
            let decision = ChargingPolicy.evaluate(input(reading, settings: settings(limit: 85), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 85)))
            #expect(decision.desiredMode == .nativeLimit(percent: 85))
            #expect(decision.action == .noAction)
            #expect(decision.notes.contains(.nativeLimitKeptWithoutTelemetry))
        }
    }

    @Test("Turning management off restores the user's own limit")
    func managementOff() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), settings: settings(limit: 85, managed: false), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 85)))
        #expect(decision.state == .unmanaged)
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .enableCharging)
    }

    @Test("Invalid settings restore the user's own limit")
    func invalidSettings() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), settings: ChargingSettings(chargeLimit: 120, resumeThreshold: 75), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 90)))
        #expect(decision.state == .failSafe)
        #expect(decision.action == .enableCharging)
    }

    @Test("A limit macOS cannot express fails safe to the user's own limit", arguments: [75, 82, 50])
    func unsupportedLimit(limit: Int) {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 70), settings: settings(limit: limit), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 90)))
        #expect(decision.state == .failSafe)
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .enableCharging)
        #expect(decision.reason == .nativeLimitUnsupported(limit: limit, steps: NativeChargeLimitBackend.supportedLimits))
    }

    @Test("Without a battery there is no Charge Limit to manage")
    func noBattery() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: nil, present: false), settings: settings(limit: 85), capabilities: nativeCapabilities, currentMode: .normal))
        #expect(decision.state == .failSafe)
        #expect(decision.desiredMode == .normal)
        #expect(decision.reason == .batteryNotPresent)
    }

    @Test("A temporary full charge raises the limit to 100% until full")
    func fullCharge() {
        let override = ChargeOverride.fullCharge(at: referenceDate, uptime: 10_000)
        let running = ChargingPolicy.evaluate(input(snapshot(percent: 85), settings: settings(limit: 80), override: override, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 80)))
        #expect(running.state == .fullChargeOverride)
        #expect(running.desiredMode == .nativeLimit(percent: 100))
        #expect(running.action == .setNativeLimit(100))
        #expect(running.overrideEnded == nil)

        let full = ChargingPolicy.evaluate(input(snapshot(percent: 100, charging: false, fullyCharged: true), settings: settings(limit: 80), override: override, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 100)))
        #expect(full.overrideEnded == .completed)
        #expect(full.desiredMode == .nativeLimit(percent: 80))
    }

    @Test("A full charge ends on unplug and on expiry, but not because telemetry is missing")
    func fullChargeEndings() {
        let override = ChargeOverride.fullCharge(at: referenceDate, uptime: 10_000)
        let unplugged = ChargingPolicy.evaluate(input(snapshot(percent: 90, source: .battery), settings: settings(limit: 80), override: override, capabilities: nativeCapabilities))
        #expect(unplugged.overrideEnded == .unplugged)
        #expect(unplugged.desiredMode == .nativeLimit(percent: 80))

        let expired = ChargingPolicy.evaluate(input(nil, settings: settings(limit: 80), override: override, capabilities: nativeCapabilities, uptime: override.expiresAtUptime))
        #expect(expired.overrideEnded == .expired)

        let blind = ChargingPolicy.evaluate(input(nil, settings: settings(limit: 80), override: override, capabilities: nativeCapabilities))
        #expect(blind.overrideEnded == nil)
        #expect(blind.desiredMode == .nativeLimit(percent: 100))
    }

    @Test("A discharge session cannot run on the native limit")
    func dischargeUnsupported() {
        let session = ChargeOverride.dischargeToLimit(target: 80, at: referenceDate, uptime: 10_000)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90), settings: settings(limit: 80), override: session, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 80)))
        #expect(decision.overrideEnded == .interrupted)
        #expect(decision.notes.contains(.dischargeUnsupported))
        #expect(decision.desiredMode == .nativeLimit(percent: 80))
    }

    @Test("Changing from one native limit to another is rate-limited; restoring never is")
    func rateLimits() {
        let recent: [TimeInterval] = [10_000 - 30]
        let change = ChargingPolicy.evaluate(input(snapshot(percent: 80), settings: settings(limit: 95), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 90), recentRestrictingRequests: recent))
        #expect(change.action == .refuse(.rateLimited(retryAt: referenceDate.addingTimeInterval(30))))

        let first = ChargingPolicy.evaluate(input(snapshot(percent: 80), settings: settings(limit: 95), capabilities: nativeCapabilities, currentMode: .normal, recentRestrictingRequests: recent))
        #expect(first.action == .refuse(.rateLimited(retryAt: referenceDate.addingTimeInterval(30))))

        let release = ChargingPolicy.evaluate(input(snapshot(percent: 80), settings: settings(limit: 95, managed: false), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 90), recentRestrictingRequests: recent))
        #expect(release.action == .enableCharging)
    }

    @Test("A faulted backend is only asked to restore the user's own limit")
    func faulted() {
        let restoring = ChargingPolicy.evaluate(input(snapshot(percent: 80), settings: settings(limit: 90), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 95), faulted: true))
        #expect(restoring.action == .enableCharging)
        let restored = ChargingPolicy.evaluate(input(snapshot(percent: 80), settings: settings(limit: 90), capabilities: nativeCapabilities, currentMode: .normal, faulted: true))
        #expect(restored.action == .refuse(.backendFaulted))
    }

    @Test("When the backend is unavailable the desired limit is still computed")
    func unavailable() {
        let capabilities = ControlCapabilities.unavailable("no shortcut", style: .nativeLimit(steps: NativeChargeLimitBackend.supportedLimits))
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 80), settings: settings(limit: 90), capabilities: capabilities, currentMode: .normal))
        #expect(decision.state == .osEnforcedLimit)
        #expect(decision.desiredMode == .nativeLimit(percent: 90))
        #expect(decision.action == .refuse(.controlUnavailable("no shortcut")))
    }
}

@Suite("Restore retries")
struct RestoreRetryTests {
    @Test("An automatic retry of a failed restore waits; without the wait it runs at once")
    func retryWaits() {
        let waiting = ChargingPolicy.evaluate(input(snapshot(percent: 50), currentMode: nil, restoreRetryNotBefore: 10_040))
        #expect(waiting.desiredMode == .normal)
        #expect(waiting.action == .refuse(.rateLimited(retryAt: referenceDate.addingTimeInterval(40))))

        let due = ChargingPolicy.evaluate(input(snapshot(percent: 50), currentMode: nil, restoreRetryNotBefore: 10_000))
        #expect(due.action == .enableCharging)

        let userInitiated = ChargingPolicy.evaluate(input(snapshot(percent: 50), currentMode: nil))
        #expect(userInitiated.action == .enableCharging)
    }

    @Test("A faulted backend's recovery also waits between automatic retries")
    func faultedRetryWaits() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), currentMode: .inhibitCharging, faulted: true, restoreRetryNotBefore: 10_030))
        #expect(decision.action == .refuse(.rateLimited(retryAt: referenceDate.addingTimeInterval(30))))
    }

    @Test("Restricting changes are classified consistently")
    func restrictingClassification() {
        #expect(ChargeControlMode.inhibitCharging.isRestricting(from: .normal))
        #expect(ChargeControlMode.inhibitCharging.isRestricting(from: nil))
        #expect(ChargeControlMode.forceDischarge.isRestricting(from: .inhibitCharging))
        #expect(!ChargeControlMode.inhibitCharging.isRestricting(from: .forceDischarge))
        #expect(!ChargeControlMode.normal.isRestricting(from: .forceDischarge))
        #expect(!ChargeControlMode.inhibitCharging.isRestricting(from: .inhibitCharging))
        #expect(ChargeControlMode.nativeLimit(percent: 85).isRestricting(from: .normal))
        #expect(ChargeControlMode.nativeLimit(percent: 85).isRestricting(from: .nativeLimit(percent: 90)))
        #expect(!ChargeControlMode.nativeLimit(percent: 85).isRestricting(from: .nativeLimit(percent: 85)))
    }
}
