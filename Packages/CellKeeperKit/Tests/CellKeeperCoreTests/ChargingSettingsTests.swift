import CellKeeperCore
import Foundation
import Testing

@Suite("Settings validation")
struct ChargingSettingsTests {
    @Test("Defaults are valid")
    func defaultsValid() {
        #expect(ChargingSettings.default.isValid)
        #expect(ChargingSettings.default.chargeLimit == 80)
        #expect(ChargingSettings.default.resumeThreshold == 75)
    }

    @Test("Charge limits outside the allowed range are rejected", arguments: [-1, 0, 19, 101, 1_000, Int.min, Int.max])
    func chargeLimitOutOfRange(limit: Int) {
        let settings = ChargingSettings(chargeLimit: limit, resumeThreshold: 16)
        #expect(settings.validationIssues.contains { if case .chargeLimitOutOfRange = $0 { true } else { false } })
    }

    @Test("Charge limits at the range bounds are accepted", arguments: [20, 100])
    func chargeLimitBounds(limit: Int) {
        #expect(ChargingSettings(chargeLimit: limit, resumeThreshold: limit - 5).isValid)
    }

    @Test("Extreme values are rejected without trapping", arguments: [Int.min, Int.max])
    func extremeValues(value: Int) {
        #expect(!ChargingSettings(chargeLimit: value, resumeThreshold: value).isValid)
        #expect(!ChargingSettings(chargeLimit: 80, resumeThreshold: value).isValid)
        #expect(ChargingSettings.default.withChargeLimit(value).isValid)
    }

    @Test("Resume thresholds below the minimum are rejected", arguments: [-5, 0, 9, 14])
    func resumeTooLow(resume: Int) {
        let issues = ChargingSettings(chargeLimit: 30, resumeThreshold: resume).validationIssues
        #expect(issues == [.resumeThresholdOutOfRange(resume, minimum: 15)])
    }

    @Test("The resume threshold stays at least five points above the safety floor")
    func resumeAboveFloor() {
        #expect(ChargingSettings.minimumResumeThreshold >= ChargingPolicy.safetyFloorPercent + 5)
    }

    @Test("Resume thresholds too close to (or above) the limit are rejected", arguments: [78, 79, 80, 81, 150])
    func hysteresisTooSmall(resume: Int) {
        let issues = ChargingSettings(chargeLimit: 80, resumeThreshold: resume).validationIssues
        #expect(issues.count == 1)
    }

    @Test("Resume thresholds too far below the limit are rejected", arguments: [20, 50, 59])
    func hysteresisTooLarge(resume: Int) {
        let issues = ChargingSettings(chargeLimit: 80, resumeThreshold: resume).validationIssues
        #expect(issues == [.hysteresisTooLarge(chargeLimit: 80, resumeThreshold: resume, maximum: 20)])
    }

    @Test("Resume thresholds at the hysteresis bounds are accepted", arguments: [60, 77])
    func hysteresisBoundsAccepted(resume: Int) {
        #expect(ChargingSettings(chargeLimit: 80, resumeThreshold: resume).isValid)
    }

    @Test("Non-finite temperatures are rejected", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteTemperature(value: Double) {
        let pause = ChargingSettings(temperatureProtection: TemperatureProtection(isEnabled: true, pauseAtCelsius: value, resumeAtCelsius: 35))
        #expect(pause.validationIssues == [.temperatureNotFinite])
        let resume = ChargingSettings(temperatureProtection: TemperatureProtection(isEnabled: true, pauseAtCelsius: 40, resumeAtCelsius: value))
        #expect(resume.validationIssues == [.temperatureNotFinite])
    }

    @Test("Temperature pause thresholds outside the allowed range are rejected", arguments: [0.0, 34.9, 45.1, 90])
    func pauseOutOfRange(value: Double) {
        let settings = ChargingSettings(temperatureProtection: TemperatureProtection(isEnabled: true, pauseAtCelsius: value, resumeAtCelsius: 25))
        #expect(settings.validationIssues.contains { if case .temperaturePauseOutOfRange = $0 { true } else { false } })
    }

    @Test("Temperature thresholds are validated even when protection is disabled")
    func validatedWhenDisabled() {
        let settings = ChargingSettings(temperatureProtection: TemperatureProtection(isEnabled: false, pauseAtCelsius: 99, resumeAtCelsius: 35))
        #expect(!settings.isValid)
    }

    @Test("Temperature resume must be below pause by the minimum gap")
    func temperatureHysteresis() {
        let tooClose = ChargingSettings(temperatureProtection: TemperatureProtection(isEnabled: true, pauseAtCelsius: 40, resumeAtCelsius: 38))
        #expect(tooClose.validationIssues == [.temperatureHysteresisTooSmall(minimum: 3)])
        let exact = ChargingSettings(temperatureProtection: TemperatureProtection(isEnabled: true, pauseAtCelsius: 40, resumeAtCelsius: 37))
        #expect(exact.isValid)
        let tooLow = ChargingSettings(temperatureProtection: TemperatureProtection(isEnabled: true, pauseAtCelsius: 40, resumeAtCelsius: 25))
        #expect(tooLow.validationIssues == [.temperatureResumeTooLow(25, minimum: 30)])
    }

    @Test("validated() throws every issue")
    func validatedThrows() {
        let settings = ChargingSettings(chargeLimit: 500, resumeThreshold: 1)
        #expect(throws: SettingsValidationError.self) { try settings.validated() }
        #expect(settings.validationIssues.count == 2)
    }

    @Test("Changing the limit keeps the resume threshold valid")
    func withChargeLimit() {
        let lowered = ChargingSettings.default.withChargeLimit(60)
        #expect(lowered.chargeLimit == 60)
        #expect(lowered.resumeThreshold == 57)
        #expect(lowered.isValid)

        let raised = ChargingSettings.default.withChargeLimit(95)
        #expect(raised.resumeThreshold == 75)
        #expect(raised.isValid)

        let full = ChargingSettings.default.withChargeLimit(100)
        #expect(full.resumeThreshold == 80)
        #expect(full.isValid)

        let clamped = ChargingSettings.default.withChargeLimit(5)
        #expect(clamped.chargeLimit == 20)
        #expect(clamped.resumeThreshold == 17)
        #expect(clamped.isValid)
    }

    @Test("Resume threshold range follows the limit")
    func resumeRange() {
        #expect(ChargingSettings.resumeThresholdRange(forChargeLimit: 80) == 60...77)
        #expect(ChargingSettings.resumeThresholdRange(forChargeLimit: 20) == 15...17)
        #expect(ChargingSettings.resumeThresholdRange(forChargeLimit: Int.min) == 15...17)
        #expect(ChargingSettings.resumeThresholdRange(forChargeLimit: Int.max) == 80...97)
        for limit in ChargingSettings.chargeLimitRange {
            for resume in ChargingSettings.resumeThresholdRange(forChargeLimit: limit) {
                #expect(ChargingSettings(chargeLimit: limit, resumeThreshold: resume).isValid)
            }
        }
    }

    @Test("Decoding ignores keys from other versions")
    func decodesUnknownKeys() throws {
        let data = Data(#"{"chargeLimit": 70, "resumeThreshold": 60, "dischargeAboveLimit": true, "future": 1}"#.utf8)
        let decoded = try JSONDecoder().decode(ChargingSettings.self, from: data)
        #expect(decoded.chargeLimit == 70)
        #expect(decoded.isValid)
    }

    @Test("Decoding tolerates missing keys")
    func decodesPartialData() throws {
        let data = Data(#"{"chargeLimit": 70, "resumeThreshold": 60}"#.utf8)
        let decoded = try JSONDecoder().decode(ChargingSettings.self, from: data)
        #expect(decoded.chargeLimit == 70)
        #expect(decoded.resumeThreshold == 60)
        #expect(decoded.isManagementEnabled == ChargingSettings.default.isManagementEnabled)
        #expect(decoded.temperatureProtection == .default)
    }
}

@Suite("Settings persistence")
struct SettingsStoreTests {
    private func makeStore() -> (SettingsStore, InMemoryStorage) {
        let storage = InMemoryStorage()
        return (SettingsStore(defaults: storage), storage)
    }

    @Test("Nothing stored yields defaults")
    func emptyStore() {
        let (store, _) = makeStore()
        let result = store.loadChargingSettings()
        #expect(result.settings == .default)
        #expect(result.recoveryReason == nil)
    }

    @Test("Valid settings round-trip")
    func roundTrip() throws {
        let (store, _) = makeStore()
        let settings = ChargingSettings(chargeLimit: 65, resumeThreshold: 55)
        try store.save(settings)
        #expect(store.loadChargingSettings().settings == settings)
    }

    @Test("Invalid settings are not saved")
    func invalidNotSaved() {
        let (store, defaults) = makeStore()
        #expect(throws: SettingsValidationError.self) {
            try store.save(ChargingSettings(chargeLimit: 10, resumeThreshold: 50))
        }
        #expect(defaults.data(forKey: SettingsStore.chargingSettingsKey) == nil)
    }

    @Test("Invalid stored settings fall back to defaults")
    func invalidStored() {
        let (store, defaults) = makeStore()
        defaults.set(Data(#"{"chargeLimit": 5, "resumeThreshold": 90}"#.utf8), forKey: SettingsStore.chargingSettingsKey)
        let result = store.loadChargingSettings()
        #expect(result.settings == .default)
        #expect(result.recoveryReason != nil)
    }

    @Test("Corrupt stored data falls back to defaults")
    func corruptStored() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not json".utf8), forKey: SettingsStore.chargingSettingsKey)
        let result = store.loadChargingSettings()
        #expect(result.settings == .default)
        #expect(result.recoveryReason != nil)
    }
}

/// In-memory ``KeyValueStorage`` so tests never write to ~/Library/Preferences.
final class InMemoryStorage: KeyValueStorage {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
