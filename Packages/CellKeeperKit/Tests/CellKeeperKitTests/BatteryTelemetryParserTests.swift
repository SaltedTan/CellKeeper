@testable import CellKeeperKit
import CellKeeperCore
import Foundation
import Testing

/// Fixtures mirror the shapes observed via `ioreg`/IOPowerSources (see
/// docs/research/01-battery-telemetry.md), with identifiers removed.
@Suite("Telemetry parsing")
struct BatteryTelemetryParserTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Apple silicon on macOS 27: capacities nested in `BatteryData`, no temperature.
    let appleSiliconCurrent = RawPowerData(
        powerSource: [
            "Type": "InternalBattery", "Is Present": true, "Power Source State": "AC Power",
            "Current Capacity": 80, "Max Capacity": 100, "Is Charging": false, "Is Charged": false,
            "Time to Empty": 0, "Time to Full Charge": 0,
        ],
        providingPowerSourceType: "AC Power",
        registry: [
            "BatteryInstalled": true, "ExternalConnected": true, "IsCharging": false, "FullyCharged": false,
            "CurrentCapacity": 80, "MaxCapacity": 100, "CycleCount": 54, "DesignCycleCount9C": 1000,
            "Voltage": 12_427, "Amperage": 0, "UpdateTime": 1_799_999_970,
            "BatteryData": ["FullChargeCapacity": 6131, "NominalChargeCapacity": 6283, "DesignCapacity": 6249],
        ],
        adapter: ["Watts": 70]
    )

    @Test("Current Apple silicon shape")
    func appleSilicon() {
        let snapshot = BatteryTelemetryParser.snapshot(from: appleSiliconCurrent, at: now)
        #expect(snapshot.isBatteryPresent)
        #expect(snapshot.chargePercent == 80)
        #expect(snapshot.powerSource == .externalPower)
        #expect(snapshot.chargingStatus == .notCharging)
        #expect(snapshot.temperatureCelsius == nil)
        #expect(snapshot.voltageMillivolts == 12_427)
        #expect(snapshot.sourceTimestamp == Date(timeIntervalSince1970: 1_799_999_970))
        #expect(snapshot.adapterWatts == 70)
        #expect(snapshot.timeToEmptyMinutes == nil)
        #expect(snapshot.health.cycleCount == 54)
        #expect(snapshot.health.designCycleCount == 1000)
        #expect(snapshot.health.fullChargeCapacityMilliampHours == 6131)
        #expect(snapshot.health.designCapacityMilliampHours == 6249)
        #expect(snapshot.health.nominalChargeCapacityMilliampHours == 6283)
        let percentOfDesign = snapshot.health.fullChargeCapacityPercentOfDesign ?? 0
        #expect(abs(percentOfDesign - 98.11) < 0.01)
    }

    @Test("Older shape with top-level capacity keys")
    func legacyShape() {
        let raw = RawPowerData(
            powerSource: ["Type": "InternalBattery", "Current Capacity": 64, "Max Capacity": 100, "Is Charging": true, "Power Source State": "AC Power", "Time to Full Charge": 42],
            registry: ["AppleRawMaxCapacity": 4300, "DesignCapacity": 4382, "Temperature": 3012, "CycleCount": 210, "Amperage": -1520, "DesignCycleCount70": 1000]
        )
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.chargePercent == 64)
        #expect(snapshot.chargingStatus == .charging)
        #expect(snapshot.timeToFullMinutes == 42)
        #expect(snapshot.health.designCycleCount == 1000)
        #expect(snapshot.amperageMilliamps == -1520)
        #expect(snapshot.health.fullChargeCapacityMilliampHours == 4300)
        #expect(snapshot.health.designCapacityMilliampHours == 4382)
    }

    @Test("Temperature comes only from the documented power-source key, in °C")
    func temperatureSource() {
        let documented = RawPowerData(powerSource: ["Type": "InternalBattery", "Current Capacity": 50, "Max Capacity": 100, "Temperature": 31])
        #expect(BatteryTelemetryParser.snapshot(from: documented, at: now).temperatureCelsius == 31)

        // The registry key's units are unverified, so it is never used.
        let registryOnly = RawPowerData(powerSource: ["Type": "InternalBattery", "Current Capacity": 50, "Max Capacity": 100], registry: ["Temperature": 3012])
        #expect(BatteryTelemetryParser.snapshot(from: registryOnly, at: now).temperatureCelsius == nil)
        #expect(!BatteryTelemetryParser.registryKeys.contains("Temperature"))
    }

    @Test("mAh-based capacities compute the percentage")
    func milliampHourCapacities() {
        let raw = RawPowerData(registry: ["CurrentCapacity": 4000, "MaxCapacity": 5000, "ExternalConnected": false, "BatteryInstalled": true])
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.chargePercent == 80)
        #expect(snapshot.powerSource == .battery)
        #expect(snapshot.health.fullChargeCapacityMilliampHours == 5000)
    }

    @Test("On battery power")
    func onBattery() {
        let raw = RawPowerData(
            powerSource: ["Type": "InternalBattery", "Current Capacity": 55, "Max Capacity": 100, "Is Charging": false, "Power Source State": "Battery Power", "Time to Empty": 312],
            providingPowerSourceType: "Battery Power",
            adapter: ["Watts": 70]
        )
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.powerSource == .battery)
        #expect(snapshot.chargingStatus == .discharging)
        #expect(snapshot.timeToEmptyMinutes == 312)
        #expect(snapshot.adapterWatts == nil)
    }

    @Test("A Mac without a battery")
    func noBattery() {
        let raw = RawPowerData(providingPowerSourceType: "AC Power")
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.isBatteryPresent == false)
        #expect(snapshot.chargePercent == nil)
        #expect(snapshot.powerSource == .externalPower)
    }

    @Test("Implausible values are discarded")
    func implausibleValues() {
        let raw = RawPowerData(
            powerSource: ["Type": "InternalBattery", "Current Capacity": 250, "Max Capacity": 100, "Temperature": 400, "Time to Empty": -1, "Power Source State": "Battery Power"],
            registry: ["Voltage": 0, "Amperage": 900_000, "CycleCount": -3, "Temperature": 99_999]
        )
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.chargePercent == nil)
        #expect(snapshot.temperatureCelsius == nil)
        #expect(snapshot.voltageMillivolts == nil)
        #expect(snapshot.amperageMilliamps == nil)
        #expect(snapshot.timeToEmptyMinutes == nil)
        #expect(snapshot.health.cycleCount == nil)
    }

    @Test("Extreme integers cannot trap")
    func extremeIntegers() {
        let raw = RawPowerData(
            powerSource: ["Type": "InternalBattery", "Current Capacity": Int.max, "Max Capacity": 1, "Time to Empty": Int.max],
            registry: ["Amperage": Int.min, "Voltage": Int.max, "CurrentCapacity": Int.max, "MaxCapacity": 1]
        )
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.chargePercent == nil)
        #expect(snapshot.amperageMilliamps == nil)
        #expect(snapshot.voltageMillivolts == nil)
        #expect(snapshot.timeToEmptyMinutes == nil)
    }

    @Test("Implausible driver update times are ignored", arguments: [0, -5, 978_307_200])
    func implausibleUpdateTime(value: Int) {
        let raw = RawPowerData(registry: ["CurrentCapacity": 50, "MaxCapacity": 100, "UpdateTime": value])
        #expect(BatteryTelemetryParser.snapshot(from: raw, at: now).sourceTimestamp == nil)
    }

    @Test("Values of the wrong type are ignored")
    func wrongTypes() {
        let raw = RawPowerData(
            powerSource: ["Type": "InternalBattery", "Current Capacity": "80", "Max Capacity": 100, "Is Charging": "yes"],
            registry: ["CycleCount": "54", "BatteryData": "not a dictionary"]
        )
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.chargePercent == nil)
        #expect(snapshot.isCharging == nil)
        #expect(snapshot.health.cycleCount == nil)
    }

    @Test("The system power values come from PowerTelemetryData, in mW, as reported")
    func systemPower() {
        var raw = appleSiliconCurrent
        raw.registry?["PowerTelemetryData"] = ["SystemPowerIn": 37_304, "SystemLoad": 17_363]
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.systemPowerInMilliwatts == 37_304)
        #expect(snapshot.systemLoadMilliwatts == 17_363)

        // Kept on battery power too: the power flow decides what they mean.
        raw.powerSource?["Power Source State"] = "Battery Power"
        raw.providingPowerSourceType = "Battery Power"
        let onBattery = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(onBattery.powerSource == .battery)
        #expect(onBattery.systemPowerInMilliwatts == 37_304)
        #expect(onBattery.systemLoadMilliwatts == 17_363)
    }

    @Test("Without PowerTelemetryData the system power values are absent")
    func systemPowerMissing() {
        let snapshot = BatteryTelemetryParser.snapshot(from: appleSiliconCurrent, at: now)
        #expect(snapshot.systemPowerInMilliwatts == nil)
        #expect(snapshot.systemLoadMilliwatts == nil)

        // Not a dictionary, or the values only at the top level.
        var raw = appleSiliconCurrent
        raw.registry?["PowerTelemetryData"] = "not a dictionary"
        raw.registry?["SystemPowerIn"] = 30_000
        raw.registry?["SystemLoad"] = 30_000
        let misplaced = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(misplaced.systemPowerInMilliwatts == nil)
        #expect(misplaced.systemLoadMilliwatts == nil)
    }

    @Test(
        "System power values outside 0–500 W, or of the wrong type, are discarded",
        arguments: [
            (-1, nil), (0, 0), (500_000, 500_000), (500_001, nil),
            (Int.max, nil), (Int.min, nil), ("30000", nil), (true, nil), (30_000.5, 30_000),
        ] as [(any Sendable, Int?)]
    )
    func systemPowerRange(value: any Sendable, expected: Int?) {
        var raw = appleSiliconCurrent
        raw.registry?["PowerTelemetryData"] = ["SystemPowerIn": value, "SystemLoad": value]
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: now)
        #expect(snapshot.systemPowerInMilliwatts == expected)
        #expect(snapshot.systemLoadMilliwatts == expected)
    }

    @Test("Only SystemPowerIn and SystemLoad are kept from PowerTelemetryData")
    func powerTelemetryAllowlist() throws {
        #expect(BatteryTelemetryParser.registryKeys.contains("PowerTelemetryData"))
        #expect(BatteryTelemetryParser.powerTelemetryDataKeys == ["SystemPowerIn", "SystemLoad"])
        let read: [String: Any] = [
            "Voltage": 12_427,
            "PowerTelemetryData": [
                "SystemPowerIn": 34_848, "SystemLoad": 34_848, "BatteryPower": 0,
                "AccumulatedSystemLoad": 8_426_200_041, "SystemPowerInAccumulatorCount": 822_508,
                "WallEnergyEstimate": 10_572, "SystemVoltageIn": 20_289, "SystemCurrentIn": 1_717,
            ] as [String: Any],
            "BatteryData": ["FullChargeCapacity": 6131, "BatteryPower": 0, "RemainingCapacity": 6131] as [String: Any],
        ]
        let kept = BatteryTelemetryParser.allowlistingNestedKeys(of: read)
        let telemetry = try #require(kept["PowerTelemetryData"] as? [String: Any])
        #expect(Set(telemetry.keys) == ["SystemPowerIn", "SystemLoad"])
        let batteryData = try #require(kept["BatteryData"] as? [String: Any])
        #expect(Set(batteryData.keys) == ["FullChargeCapacity"])
        #expect(kept["Voltage"] as? Int == 12_427)
        // A nested value that is not a dictionary is left for the parser to
        // ignore.
        let odd = BatteryTelemetryParser.allowlistingNestedKeys(of: ["PowerTelemetryData": 5])
        #expect(odd["PowerTelemetryData"] as? Int == 5)
    }

    @Test("Allowlists exclude identifiers")
    func allowlistsExcludeIdentifiers() {
        let keys = BatteryTelemetryParser.registryKeys
            + BatteryTelemetryParser.powerSourceKeys
            + BatteryTelemetryParser.adapterKeys
            + BatteryTelemetryParser.batteryDataKeys
            + BatteryTelemetryParser.powerTelemetryDataKeys
        let lowered = keys.map { $0.lowercased() }
        #expect(!lowered.contains { $0.contains("serial") || $0.contains("lot") || $0.contains("manufacturerdata") || $0.contains("source id") })
    }
}

@Suite("System telemetry (read-only smoke test)")
struct SystemTelemetrySmokeTests {
    @Test("Reading the real system returns a coherent snapshot or a clean error")
    func readsWithoutCrashing() async {
        do {
            let snapshot = try await SystemTelemetryProvider().currentSnapshot()
            if let percent = snapshot.chargePercent {
                #expect((0...100).contains(percent))
            }
            if !snapshot.isBatteryPresent {
                #expect(snapshot.chargePercent == nil)
            }
        } catch {
            #expect(error is SystemTelemetryError)
        }
    }

    @Test("The real registry read keeps only the allowlisted nested keys")
    func registryReadIsAllowlisted() {
        guard let registry = SystemTelemetryProvider.readSmartBatteryRegistry() else { return }
        #expect(Set(registry.keys).isSubset(of: BatteryTelemetryParser.registryKeys))
        if let telemetry = registry["PowerTelemetryData"] as? [String: Any] {
            #expect(Set(telemetry.keys).isSubset(of: BatteryTelemetryParser.powerTelemetryDataKeys))
        }
        if let batteryData = registry["BatteryData"] as? [String: Any] {
            #expect(Set(batteryData.keys).isSubset(of: BatteryTelemetryParser.batteryDataKeys))
        }
    }
}
