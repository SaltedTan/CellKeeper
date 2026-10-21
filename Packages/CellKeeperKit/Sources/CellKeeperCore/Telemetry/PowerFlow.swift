import Foundation

/// Where the Mac's power comes from and goes, from one battery reading, for
/// the menu's power flow (D114). Display only: the charging policy, the
/// controller and the safety rules never use it.
///
/// Every value is one macOS reports, from undocumented registry data
/// (research note 01): the adapter's input (`SystemPowerIn`), the Mac's use
/// (`SystemLoad`), and the battery's power (`Voltage` × `Amperage`, negative
/// while it supplies the Mac). Nothing is made to add up: conversion losses
/// and values updated at slightly different moments mean they may not, and
/// each is shown as reported, with no "other" flow for a difference.
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

    /// The flow of `snapshot`, or nil if macOS reports no power use for the
    /// Mac (older macOS versions, Intel Macs, desktops): without it there is
    /// no flow to show, and none is guessed.
    public init?(_ snapshot: BatterySnapshot) {
        guard let load = snapshot.systemLoadMilliwatts else { return nil }
        let isOnExternalPower = snapshot.powerSource == .externalPower
        powerSource = snapshot.powerSource
        adapterRatingWatts = isOnExternalPower ? snapshot.adapterWatts : nil
        adapterInputWatts = isOnExternalPower ? snapshot.systemPowerInMilliwatts.map(Self.watts(fromMilliwatts:)) : nil
        chargePercent = snapshot.isBatteryPresent ? snapshot.chargePercent : nil
        if let voltage = snapshot.voltageMillivolts, let current = snapshot.amperageMilliamps {
            batteryWatts = Double(voltage) * Double(current) / 1_000_000
        } else {
            batteryWatts = nil
        }
        macUseWatts = Self.watts(fromMilliwatts: load)
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

    static func watts(fromMilliwatts value: Int) -> Double {
        Double(value) / 1000
    }
}
