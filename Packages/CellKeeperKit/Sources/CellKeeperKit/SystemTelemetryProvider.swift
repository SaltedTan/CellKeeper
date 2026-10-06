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
///    is read (``BatteryTelemetryParser/registryKeys``).
///
/// This type never opens an IOUserClient and never writes anything.
public struct SystemTelemetryProvider: TelemetryProvider {
    public init() {}

    public func currentSnapshot() async throws -> BatterySnapshot {
        let raw = try Self.readRawPowerData()
        return BatteryTelemetryParser.snapshot(from: raw, at: Date())
    }

    public func powerSourceChanges() -> AsyncStream<Void> {
        PowerSourceNotifications.stream()
    }

    static func readRawPowerData() throws -> RawPowerData {
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
        raw.adapter = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?
            .filter { BatteryTelemetryParser.adapterKeys.contains($0.key) }
        raw.registry = readSmartBatteryRegistry()

        if raw.providingPowerSourceType == nil, raw.powerSource == nil, raw.registry == nil {
            throw SystemTelemetryError.powerSourcesUnavailable
        }
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
        if let batteryData = properties["BatteryData"] as? [String: Any] {
            properties["BatteryData"] = batteryData.filter { BatteryTelemetryParser.batteryDataKeys.contains($0.key) }
        }
        return properties
    }
}
