import CellKeeperHelperCore
import Foundation
import IOKit
import IOKit.ps

/// The daemon's own power state, read from public, read-only IOPowerSources
/// data, so the helper never takes a client's word for it (R9, R17, D45).
///
/// This deliberately repeats the rules of the app's
/// `SystemHelperPowerReading` (CellKeeperKit) instead of sharing them: the
/// daemon depends on `CellKeeperHelperCore` only, never on the app's
/// modules (D27). A change to one must be made to the other.
///
/// - Charge: the internal battery's `kIOPSCurrentCapacityKey` over
///   `kIOPSMaxCapacityKey`, rounded, 0–100%; unknown if `kIOPSIsPresentKey`
///   says the battery is absent or a value is missing or implausible.
/// - External power: `IOPSGetProvidingPowerSourceType`: AC power is
///   external, battery power is not, anything else (or nothing) unknown.
///   (The app's reading consults the battery's own power source state
///   first and falls back to this; the daemon asks only which source
///   provides power, which is what that function is documented to report.)
/// - Adapter presence (D45): present when
///   `IOPSCopyExternalPowerAdapterDetails` returns details; absent when it
///   returns none while the Mac runs on battery; unknown when it returns
///   none while the Mac reports external power. Whether it still describes
///   an adapter that a control has disabled is unverified (`safety.md`
///   precondition 12); an adapter wrongly read as absent only makes the
///   helper clear the adapter-disable.
/// - Thermal pressure: `ProcessInfo.thermalState` serious or critical.
///
/// Each reading is stamped with the uptime taken just before it is read.
/// No identifiers are read: only the three battery keys above are kept, and
/// of the adapter details only whether there are any.
public struct DaemonPowerReading: HelperPowerReading {
    /// The internal battery's description keys the reading keeps.
    static let batteryKeys: Set<String> = [kIOPSIsPresentKey, kIOPSCurrentCapacityKey, kIOPSMaxCapacityKey]

    private let uptime: @Sendable () -> TimeInterval

    public init(uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime) {
        self.uptime = uptime
    }

    public func latestPowerState() -> HelperPowerState? {
        let readAt = uptime()
        let sources = Self.readPowerSources()
        return Self.powerState(
            battery: sources.battery,
            providingPowerSourceType: sources.providingPowerSourceType,
            hasAdapterDetails: sources.hasAdapterDetails,
            thermalState: ProcessInfo.processInfo.thermalState,
            readAtUptime: readAt
        )
    }

    /// What IOPowerSources reports, reduced to what the reading needs.
    struct PowerSources {
        /// The internal battery's description, only ``batteryKeys``; nil if
        /// there is no internal battery.
        var battery: [String: Any]?
        var providingPowerSourceType: String?
        var hasAdapterDetails: Bool
    }

    static func readPowerSources() -> PowerSources {
        var sources = PowerSources(battery: nil, providingPowerSourceType: nil, hasAdapterDetails: false)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            sources.providingPowerSourceType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                else { continue }
                sources.battery = description.filter { batteryKeys.contains($0.key) }
                break
            }
        }
        sources.hasAdapterDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil
        return sources
    }

    /// The power state from what IOPowerSources reported; nil if it reported
    /// neither a battery nor a providing power source.
    static func powerState(
        battery: [String: Any]?,
        providingPowerSourceType: String?,
        hasAdapterDetails: Bool,
        thermalState: ProcessInfo.ThermalState,
        readAtUptime: TimeInterval
    ) -> HelperPowerState? {
        guard battery != nil || providingPowerSourceType != nil else { return nil }
        let isOnExternalPower: Bool? = switch providingPowerSourceType {
        case kIOPSACPowerValue: true
        case kIOPSBatteryPowerValue: false
        default: nil
        }
        let isAdapterPresent: Bool? = if hasAdapterDetails {
            true
        } else if isOnExternalPower == false {
            false
        } else {
            nil
        }
        return HelperPowerState(
            stateOfCharge: battery.flatMap(stateOfCharge),
            isOnExternalPower: isOnExternalPower,
            isAdapterPresent: isAdapterPresent,
            isThermalPressureHigh: thermalState == .serious || thermalState == .critical,
            readAtUptime: readAtUptime
        )
    }

    /// The charge in percent, or nil if the battery is absent or a value is
    /// missing or implausible.
    static func stateOfCharge(_ battery: [String: Any]) -> Int? {
        guard bool(battery[kIOPSIsPresentKey]) ?? true,
              let current = int(battery[kIOPSCurrentCapacityKey]),
              let maximum = int(battery[kIOPSMaxCapacityKey]),
              current >= 0, maximum > 0
        else { return nil }
        let percent = (Double(current) / Double(maximum) * 100).rounded()
        // Range-check before converting, so absurd values cannot trap.
        guard (0...100).contains(percent) else { return nil }
        return Int(percent)
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        return Int(exactly: number.int64Value)
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if CFGetTypeID(number) == CFNumberGetTypeID() { return number.intValue != 0 }
        return nil
    }
}
