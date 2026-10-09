import Foundation

/// The power state as the helper reads it itself. The helper never takes a
/// client's word for the charge, the power source or the temperature.
public struct HelperPowerState: Sendable, Equatable {
    /// State of charge in percent, or nil if unknown.
    public var stateOfCharge: Int?
    /// Whether the Mac runs on external power, or nil if unknown. An adapter
    /// that the helper disabled makes the Mac report battery power.
    public var isOnExternalPower: Bool?
    /// Whether an adapter is physically connected, or nil if unknown.
    /// Distinct from ``isOnExternalPower``: it stays true while the adapter
    /// is disabled.
    public var isAdapterPresent: Bool?
    /// True if macOS reports high thermal pressure.
    public var isThermalPressureHigh: Bool
    /// When the state was read, on the engine's monotonic clock.
    public var readAtUptime: TimeInterval

    public init(
        stateOfCharge: Int?,
        isOnExternalPower: Bool?,
        isAdapterPresent: Bool?,
        isThermalPressureHigh: Bool,
        readAtUptime: TimeInterval
    ) {
        self.stateOfCharge = stateOfCharge
        self.isOnExternalPower = isOnExternalPower
        self.isAdapterPresent = isAdapterPresent
        self.isThermalPressureHigh = isThermalPressureHigh
        self.readAtUptime = readAtUptime
    }
}

/// The source of the helper's power state. It may return a cached reading;
/// the engine checks its age.
public protocol HelperPowerReading: Sendable {
    /// The latest power state, or nil if it cannot be read.
    func latestPowerState() -> HelperPowerState?
}
