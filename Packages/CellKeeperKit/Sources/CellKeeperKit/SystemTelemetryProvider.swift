import CellKeeperCore
import Foundation
import IOKit
import IOKit.ps

public enum SystemTelemetryError: Error, Sendable, CustomStringConvertible {
    case powerSourcesUnavailable

    public var description: String {
        switch self {
        case .powerSourcesUnavailable: "The system did not return power-source information."
        }
    }
}

/// Read-only telemetry from macOS.
///
/// Sources, in order of preference:
/// 1. IOPowerSources (`IOKit.ps`) — documented public API.
/// 2. The `AppleSmartBattery` IORegistry entry — readable without privileges
///    via public IOKit registry calls, but its property names are
///    undocumented and vary across macOS versions. Only an allowlist of keys
///    is read (``BatteryTelemetryParser/registryKeys``), and of the nested
///    `BatteryData` and `PowerTelemetryData` dictionaries only their own
///    allowlists.
///
/// This type never opens an IOUserClient and never writes anything. It holds
/// no state, and every read gets its own objects from IOKit, so reads may
/// overlap (the menu's power flow and the controller both read through it).
public struct SystemTelemetryProvider: TelemetryProvider {
    public init() {}

    public func currentSnapshot() async throws -> BatterySnapshot {
        let raw = try Self.readRawPowerData()
        return BatteryTelemetryParser.snapshot(from: raw, at: Date())
    }

    /// IOPowerSources only, as ``currentSnapshot()`` derives the power
    /// source: no adapter details, and no registry read unless
    /// IOPowerSources returns nothing. Taken after every read of macOS's
    /// Charge Limit (D118).
    public func currentPowerSource() async throws -> PowerSource {
        var raw = Self.readPowerSources(includingAdapter: false)
        if raw.providingPowerSourceType == nil, raw.powerSource == nil {
            raw.registry = Self.readSmartBatteryRegistry()
            guard raw.registry != nil else { throw SystemTelemetryError.powerSourcesUnavailable }
        }
        return BatteryTelemetryParser.powerSource(from: raw)
    }

    public func powerSourceChanges() -> AsyncStream<Void> {
        PowerSourceNotifications.stream()
    }

    static func readRawPowerData() throws -> RawPowerData {
        var raw = readPowerSources()
        raw.registry = readSmartBatteryRegistry()

        if raw.providingPowerSourceType == nil, raw.powerSource == nil, raw.registry == nil {
            throw SystemTelemetryError.powerSourcesUnavailable
        }
        return raw
    }

    /// The documented IOPowerSources part of ``readRawPowerData()``: the
    /// internal battery's description, the providing power source, and the
    /// attached adapter's details (nil when `IOPSCopyExternalPowerAdapterDetails`
    /// returns nothing: no adapter is attached, or they could not be read;
    /// not asked for without `includingAdapter`). Reads no registry
    /// properties.
    static func readPowerSources(includingAdapter: Bool = true) -> RawPowerData {
        var raw = RawPowerData()

        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            raw.providingPowerSourceType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
                else { continue }
                if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                    raw.powerSource = description.filter { BatteryTelemetryParser.powerSourceKeys.contains($0.key) }
                    break
                }
            }
        }
        guard includingAdapter else { return raw }
        raw.adapter = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?
            .filter { BatteryTelemetryParser.adapterKeys.contains($0.key) }
        return raw
    }

    /// Reads allowlisted properties of the `AppleSmartBattery` registry entry.
    /// Returns nil when there is no such entry (for example on desktop Macs).
    static func readSmartBatteryRegistry() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: [String: Any] = [:]
        for key in BatteryTelemetryParser.registryKeys {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                properties[key] = value
            }
        }
        return BatteryTelemetryParser.allowlistingNestedKeys(of: properties)
    }
}
