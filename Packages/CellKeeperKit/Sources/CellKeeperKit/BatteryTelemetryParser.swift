import CellKeeperCore
import Foundation

/// Raw, unparsed power information as returned by the system.
///
/// - `powerSource`: the internal battery's description from the public
///   IOPowerSources API (`IOPSGetPowerSourceDescription`).
/// - `providingPowerSourceType`: `IOPSGetProvidingPowerSourceType` result.
/// - `registry`: an allowlisted subset of the `AppleSmartBattery` IORegistry
///   entry's properties (undocumented keys; see docs/research).
/// - `adapter`: `IOPSCopyExternalPowerAdapterDetails` result.
public struct RawPowerData {
    public var powerSource: [String: Any]?
    public var providingPowerSourceType: String?
    public var registry: [String: Any]?
    public var adapter: [String: Any]?

    public init(
        powerSource: [String: Any]? = nil,
        providingPowerSourceType: String? = nil,
        registry: [String: Any]? = nil,
        adapter: [String: Any]? = nil
    ) {
        self.powerSource = powerSource
        self.providingPowerSourceType = providingPowerSourceType
        self.registry = registry
        self.adapter = adapter
    }
}

/// Converts raw system dictionaries into a ``BatterySnapshot``.
///
/// Public IOPowerSources values are preferred; IORegistry values fill gaps.
/// Values outside plausible ranges are discarded rather than passed on.
public enum BatteryTelemetryParser {
    /// `AppleSmartBattery` property keys CellKeeper reads. Anything not listed
    /// here (including serial numbers) is never read.
    ///
    /// The registry `Temperature` key (present on some older macOS versions)
    /// is deliberately excluded: its units are unverified, and a wrong unit
    /// assumption would make temperature protection under-trigger.
    public static let registryKeys: [String] = [
        "BatteryInstalled", "ExternalConnected", "IsCharging", "FullyCharged",
        "CurrentCapacity", "MaxCapacity", "AppleRawMaxCapacity", "DesignCapacity",
        "NominalChargeCapacity", "CycleCount", "DesignCycleCount9C", "DesignCycleCount70",
        "Voltage", "Amperage", "BatteryData", "UpdateTime",
    ]

    /// IOPowerSources description keys CellKeeper keeps. Others (including
    /// the hardware serial number and power source ID) are dropped on read.
    public static let powerSourceKeys: Set<String> = [
        "Type", "Is Present", "Power Source State", "Current Capacity", "Max Capacity",
        "Is Charging", "Is Charged", "Time to Empty", "Time to Full Charge",
        "Temperature", "BatteryHealth", "BatteryHealthCondition",
    ]

    /// External adapter keys CellKeeper keeps.
    public static let adapterKeys: Set<String> = ["Watts"]

    /// Keys read from the nested `BatteryData` dictionary, which carries the
    /// capacity values on recent macOS versions.
    static let batteryDataKeys: Set<String> = ["FullChargeCapacity", "NominalChargeCapacity", "DesignCapacity"]

    public static func snapshot(from raw: RawPowerData, at timestamp: Date) -> BatterySnapshot {
        let ps = raw.powerSource ?? [:]
        let reg = raw.registry ?? [:]
        let batteryData = reg["BatteryData"] as? [String: Any] ?? [:]

        let isPresent = bool(ps["Is Present"]) ?? bool(reg["BatteryInstalled"]) ?? (raw.powerSource != nil)

        let powerSource: PowerSource = {
            let state = (ps["Power Source State"] as? String) ?? raw.providingPowerSourceType
            switch state {
            case "AC Power": return .externalPower
            case "Battery Power": return .battery
            default:
                if let external = bool(reg["ExternalConnected"]) { return external ? .externalPower : .battery }
                return .unknown
            }
        }()

        let percent: Int? = {
            if let current = int(ps["Current Capacity"]), let max = int(ps["Max Capacity"]), max > 0 {
                return percentage(current, of: max)
            }
            if let current = int(reg["CurrentCapacity"]), let max = int(reg["MaxCapacity"]), max > 0 {
                return percentage(current, of: max)
            }
            return nil
        }()

        // On Apple silicon, MaxCapacity is a percentage (100) and mAh values
        // live elsewhere; on older Intel Macs MaxCapacity was in mAh.
        let fullChargeCapacity = positive(int(batteryData["FullChargeCapacity"]))
            ?? positive(int(reg["AppleRawMaxCapacity"]))
            ?? int(reg["MaxCapacity"]).flatMap { $0 > 100 ? $0 : nil }
        let designCapacity = positive(int(batteryData["DesignCapacity"])) ?? positive(int(reg["DesignCapacity"]))
        let nominalCapacity = positive(int(batteryData["NominalChargeCapacity"])) ?? positive(int(reg["NominalChargeCapacity"]))

        let health = BatteryHealth(
            cycleCount: nonNegative(int(reg["CycleCount"])),
            designCycleCount: positive(int(reg["DesignCycleCount9C"])) ?? positive(int(reg["DesignCycleCount70"])),
            fullChargeCapacityMilliampHours: fullChargeCapacity,
            nominalChargeCapacityMilliampHours: nominalCapacity,
            designCapacityMilliampHours: designCapacity,
            condition: (ps["BatteryHealthCondition"] as? String) ?? (ps["BatteryHealth"] as? String)
        )

        return BatterySnapshot(
            timestamp: timestamp,
            sourceTimestamp: updateTime(reg["UpdateTime"]),
            isBatteryPresent: isPresent,
            chargePercent: isPresent ? percent : nil,
            powerSource: powerSource,
            isCharging: bool(ps["Is Charging"]) ?? bool(reg["IsCharging"]),
            isFullyCharged: bool(ps["Is Charged"]) ?? bool(reg["FullyCharged"]),
            temperatureCelsius: temperature(powerSource: ps),
            voltageMillivolts: int(reg["Voltage"]).flatMap { (1_000...30_000).contains($0) ? $0 : nil },
            amperageMilliamps: int(reg["Amperage"]).flatMap { (-20_000...20_000).contains($0) ? $0 : nil },
            timeToEmptyMinutes: powerSource == .battery ? minutes(ps["Time to Empty"]) : nil,
            timeToFullMinutes: bool(ps["Is Charging"]) == true ? minutes(ps["Time to Full Charge"]) : nil,
            adapterWatts: powerSource == .externalPower ? positive(int(raw.adapter?["Watts"])) : nil,
            health: health
        )
    }

    // MARK: - Field helpers

    /// Temperature in °C from the documented IOPowerSources key
    /// (`kIOPSTemperatureKey`, specified in degrees Celsius). Implausible
    /// values are discarded. Not published on macOS 27.
    static func temperature(powerSource: [String: Any]) -> Double? {
        guard let value = double(powerSource["Temperature"]), (-20...80).contains(value) else { return nil }
        return value
    }

    /// The driver's last-update time (UNIX seconds). Values before 2001 are
    /// treated as absent; the policy judges future or old values.
    static func updateTime(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 978_307_200 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func percentage(_ current: Int, of max: Int) -> Int? {
        guard current >= 0, max > 0 else { return nil }
        let value = (Double(current) / Double(max) * 100).rounded()
        // Range-check before converting so absurd inputs cannot trap.
        guard (0...100).contains(value) else { return nil }
        return Int(value)
    }

    /// IOPowerSources reports -1 while estimating and 0 when not applicable.
    static func minutes(_ value: Any?) -> Int? {
        guard let minutes = int(value), minutes > 0, minutes < 65_535 else { return nil }
        return minutes
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        // Registry values are stored as signed 64-bit; negative currents may
        // appear as large unsigned values in `ioreg` text output only.
        return Int(exactly: number.int64Value)
    }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if CFGetTypeID(number) == CFNumberGetTypeID() { return number.intValue != 0 }
        return nil
    }

    static func positive(_ value: Int?) -> Int? {
        value.flatMap { $0 > 0 ? $0 : nil }
    }

    static func nonNegative(_ value: Int?) -> Int? {
        value.flatMap { $0 >= 0 ? $0 : nil }
    }
}
