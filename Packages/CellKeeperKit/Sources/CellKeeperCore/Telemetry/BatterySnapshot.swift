import Foundation

/// The source currently powering the Mac.
public enum PowerSource: String, Sendable, Codable, Equatable {
    case externalPower
    case battery
    case unknown
}

/// High-level charging status, derived only from what the system reports.
///
/// This describes what macOS says is happening, not what CellKeeper wants to
/// happen. The two can legitimately differ (for example when control is
/// simulated or unavailable).
public enum ChargingStatus: String, Sendable, Equatable {
    /// On external power and the battery is charging.
    case charging
    /// On external power but the battery is not charging and is not reported
    /// as full (held by macOS, firmware, or another tool).
    case notCharging
    /// On external power and the system reports the battery as fully charged.
    case fullyCharged
    /// Running from the battery.
    case discharging
    case unknown
}

/// Battery health and capacity information. Every field is optional because
/// availability differs between Mac models and macOS versions.
public struct BatteryHealth: Sendable, Equatable {
    public var cycleCount: Int?
    /// The design cycle count published by the battery, if any.
    public var designCycleCount: Int?
    public var fullChargeCapacityMilliampHours: Int?
    public var nominalChargeCapacityMilliampHours: Int?
    public var designCapacityMilliampHours: Int?
    /// A coarse condition string published by the system, if any
    /// (for example "Good", or a service recommendation).
    public var condition: String?

    public init(
        cycleCount: Int? = nil,
        designCycleCount: Int? = nil,
        fullChargeCapacityMilliampHours: Int? = nil,
        nominalChargeCapacityMilliampHours: Int? = nil,
        designCapacityMilliampHours: Int? = nil,
        condition: String? = nil
    ) {
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.fullChargeCapacityMilliampHours = fullChargeCapacityMilliampHours
        self.nominalChargeCapacityMilliampHours = nominalChargeCapacityMilliampHours
        self.designCapacityMilliampHours = designCapacityMilliampHours
        self.condition = condition
    }

    /// Full-charge capacity as a percentage of design capacity, computed by
    /// CellKeeper. This is not necessarily the "Maximum Capacity" figure shown
    /// by macOS, whose exact derivation is not documented.
    public var fullChargeCapacityPercentOfDesign: Double? {
        guard let full = fullChargeCapacityMilliampHours,
              let design = designCapacityMilliampHours,
              design > 0, full >= 0
        else { return nil }
        return Double(full) / Double(design) * 100
    }
}

/// A point-in-time reading of battery and power state.
public struct BatterySnapshot: Sendable, Equatable {
    /// When CellKeeper read the values.
    public var timestamp: Date
    /// When the system last refreshed the battery data, if it reports this.
    /// Lets the policy detect a frozen data source that keeps returning old
    /// values.
    public var sourceTimestamp: Date?
    public var isBatteryPresent: Bool
    /// State of charge in percent (0...100), or nil if unknown.
    public var chargePercent: Int?
    public var powerSource: PowerSource
    public var isCharging: Bool?
    public var isFullyCharged: Bool?
    /// Battery temperature in degrees Celsius, or nil if no safe source exists.
    public var temperatureCelsius: Double?
    public var voltageMillivolts: Int?
    /// Battery current in milliamps. Negative while discharging.
    public var amperageMilliamps: Int?
    public var timeToEmptyMinutes: Int?
    public var timeToFullMinutes: Int?
    public var adapterWatts: Int?
    public var health: BatteryHealth

    public init(
        timestamp: Date,
        sourceTimestamp: Date? = nil,
        isBatteryPresent: Bool = true,
        chargePercent: Int?,
        powerSource: PowerSource,
        isCharging: Bool? = nil,
        isFullyCharged: Bool? = nil,
        temperatureCelsius: Double? = nil,
        voltageMillivolts: Int? = nil,
        amperageMilliamps: Int? = nil,
        timeToEmptyMinutes: Int? = nil,
        timeToFullMinutes: Int? = nil,
        adapterWatts: Int? = nil,
        health: BatteryHealth = BatteryHealth()
    ) {
        self.timestamp = timestamp
        self.sourceTimestamp = sourceTimestamp
        self.isBatteryPresent = isBatteryPresent
        self.chargePercent = chargePercent
        self.powerSource = powerSource
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.temperatureCelsius = temperatureCelsius
        self.voltageMillivolts = voltageMillivolts
        self.amperageMilliamps = amperageMilliamps
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.adapterWatts = adapterWatts
        self.health = health
    }

    public var isOnExternalPower: Bool { powerSource == .externalPower }

    public var chargingStatus: ChargingStatus {
        switch powerSource {
        case .battery:
            return .discharging
        case .unknown:
            return .unknown
        case .externalPower:
            if isCharging == true { return .charging }
            if isFullyCharged == true { return .fullyCharged }
            if isCharging == false { return .notCharging }
            return .unknown
        }
    }
}
