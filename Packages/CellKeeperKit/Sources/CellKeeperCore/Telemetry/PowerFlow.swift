import Foundation

/// The values the menu's power flow is drawn from, as one source reported
/// them at one moment (``PowerFlowReading``). Display only, like
/// ``PowerFlow``.
public struct PowerFlowSample: Sendable, Equatable {
    /// When the source last updated these values, so that two reads of one
    /// update count once in the history; nil if the source does not say.
    public var updatedAt: Date?
    /// When the read that gave them began, on the continuous clock, which
    /// the wall clock's changes do not move; nil if unknown. Readings can
    /// arrive out of order (a controller's read delivered after its backend
    /// work, behind a later display read of the same update), so the flow
    /// shown follows this, not the order of arrival (``PowerFlowState``).
    public var readBegan: ContinuousClock.Instant?
    public var powerSource: PowerSource
    /// The adapter's negotiated power ("68 W adapter").
    public var adapterRatingWatts: Int?
    public var chargePercent: Int?
    /// The power into the Mac from the adapter.
    public var systemPowerInWatts: Double?
    /// The power the Mac uses.
    public var systemLoadWatts: Double?
    /// The battery's power, signed: positive while it charges, negative
    /// while it supplies the Mac.
    public var batteryWatts: Double?

    public init(
        updatedAt: Date?,
        readBegan: ContinuousClock.Instant? = nil,
        powerSource: PowerSource,
        adapterRatingWatts: Int? = nil,
        chargePercent: Int? = nil,
        systemPowerInWatts: Double? = nil,
        systemLoadWatts: Double? = nil,
        batteryWatts: Double? = nil
    ) {
        self.updatedAt = updatedAt
        self.readBegan = readBegan
        self.powerSource = powerSource
        self.adapterRatingWatts = adapterRatingWatts
        self.chargePercent = chargePercent
        self.systemPowerInWatts = systemPowerInWatts
        self.systemLoadWatts = systemLoadWatts
        self.batteryWatts = batteryWatts
    }

    /// The values of a battery reading, from macOS's undocumented registry
    /// data (research note 01): `SystemPowerIn` and `SystemLoad` (mW), and
    /// the battery's `Voltage` × `Amperage`, negative while it supplies the
    /// Mac. The driver's update time dedupes them; when the read began is
    /// left for the reader to set.
    public init(_ snapshot: BatterySnapshot) {
        updatedAt = snapshot.sourceTimestamp
        powerSource = snapshot.powerSource
        adapterRatingWatts = snapshot.adapterWatts
        chargePercent = snapshot.isBatteryPresent ? snapshot.chargePercent : nil
        systemPowerInWatts = snapshot.systemPowerInMilliwatts.map { Double($0) / 1000 }
        systemLoadWatts = snapshot.systemLoadMilliwatts.map { Double($0) / 1000 }
        if let voltage = snapshot.voltageMillivolts, let current = snapshot.amperageMilliamps {
            batteryWatts = Double(voltage) * Double(current) / 1_000_000
        } else {
            batteryWatts = nil
        }
    }
}

/// Where the Mac's power comes from and goes, from one sample, for the
/// menu's power flow (D114). Display only: the charging policy, the
/// controller and the safety rules never use it.
///
/// Every value is one the source reports; from macOS's registry data
/// (``PowerFlowSample/init(_:)``) those are the adapter's input
/// (`SystemPowerIn`), the Mac's use (`SystemLoad`), and the battery's power.
/// Nothing is made to add up: conversion losses and values updated at
/// slightly different moments mean they may not, and each is shown as
/// reported, with no "other" flow for a difference.
public struct PowerFlow: Sendable, Equatable {
    /// What the battery is doing.
    public enum Battery: Sendable, Equatable {
        /// Charging at `watts`, a positive number.
        case charging(watts: Double)
        /// Supplying the Mac with `watts`, a positive number.
        case supplying(watts: Double)
        /// Less than ``PowerFlow/idleThresholdWatts`` either way.
        case idle
    }

    /// Below this, in either direction, the battery is idle and a flow is
    /// not active: the diagram draws no arrow for it.
    public static let idleThresholdWatts = 0.3

    public let powerSource: PowerSource
    /// The adapter's negotiated power ("68 W adapter"), while on external
    /// power.
    public let adapterRatingWatts: Int?
    /// The power into the Mac from the adapter: nil unless the Mac is on
    /// external power and macOS reports it.
    public let adapterInputWatts: Double?
    public let chargePercent: Int?
    /// The battery's power, signed: positive while it charges, negative
    /// while it supplies the Mac. Nil without both its voltage and current.
    public let batteryWatts: Double?
    /// The power the Mac uses.
    public let macUseWatts: Double

    /// The flow of `sample`, or nil if it has no power use for the Mac
    /// (macOS's registry data lacks it on older macOS versions, Intel Macs
    /// and desktops): without it there is no flow to show, and none is
    /// guessed.
    public init?(_ sample: PowerFlowSample) {
        guard let load = sample.systemLoadWatts else { return nil }
        let isOnExternalPower = sample.powerSource == .externalPower
        powerSource = sample.powerSource
        adapterRatingWatts = isOnExternalPower ? sample.adapterRatingWatts : nil
        adapterInputWatts = isOnExternalPower ? sample.systemPowerInWatts : nil
        chargePercent = sample.chargePercent
        batteryWatts = sample.batteryWatts
        macUseWatts = load
    }

    /// The flow of a battery reading's registry values.
    public init?(_ snapshot: BatterySnapshot) {
        self.init(PowerFlowSample(snapshot))
    }

    /// What the battery is doing, or nil without its power.
    public var battery: Battery? {
        guard let batteryWatts else { return nil }
        if batteryWatts >= Self.idleThresholdWatts { return .charging(watts: batteryWatts) }
        if batteryWatts <= -Self.idleThresholdWatts { return .supplying(watts: -batteryWatts) }
        return .idle
    }

    /// What the adapter gives the Mac: the Mac's use, or the adapter's input
    /// when that is less (the battery then supplies the rest). Always one of
    /// the two reported values, never a difference of them. Nil unless both
    /// are known.
    public var adapterToMacWatts: Double? {
        guard let adapterInputWatts else { return nil }
        return min(adapterInputWatts, macUseWatts)
    }

    /// What the adapter gives the battery: the battery's charging power,
    /// while it charges on external power.
    public var adapterToBatteryWatts: Double? {
        guard powerSource == .externalPower, case .charging(let watts) = battery else { return nil }
        return watts
    }

    /// What the battery gives the Mac while it supplies it, also on external
    /// power (an adapter too weak for the Mac's use, or a discharge).
    public var batteryToMacWatts: Double? {
        guard case .supplying(let watts) = battery else { return nil }
        return watts
    }

    /// Whether a flow of `watts` is active, and gets an arrow: known, and at
    /// least ``idleThresholdWatts``.
    public static func isActive(_ watts: Double?) -> Bool {
        guard let watts else { return false }
        return watts >= idleThresholdWatts
    }
}
