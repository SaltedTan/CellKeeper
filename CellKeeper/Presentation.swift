import CellKeeperCore
import SwiftUI

/// User-facing wording for core types. Kept in the app so the core stays free
/// of UI concerns.
extension ControlAvailability {
    var badgeTitle: String {
        switch self {
        case .available: "Available"
        case .experimental: "Experimental"
        case .simulated: "Simulated"
        case .unavailable: "Unavailable"
        }
    }

    var badgeColor: Color {
        switch self {
        case .available: .green
        case .experimental: .orange
        case .simulated: .purple
        case .unavailable: .secondary
        }
    }

    var explanation: String {
        switch self {
        case .available:
            "CellKeeper can change charging on this Mac."
        case .experimental:
            "Hardware control is experimental on this Mac."
        case .simulated:
            "Simulated: decisions are recorded, but your Mac's charging is not changed."
        case .unavailable(let reason):
            "Hardware control is unavailable. \(reason)"
        }
    }
}

extension PolicyState {
    var title: String {
        switch self {
        case .unmanaged: "Not managing charging"
        case .failSafe: "Fail-safe: macOS default charging"
        case .safetyFloor: "Low battery: charging allowed"
        case .onBattery: "On battery: restrictions cleared"
        case .temperaturePause: "Paused: battery temperature"
        case .fullChargeOverride: "Charging to 100% (temporary)"
        case .charging: "Charging to limit"
        case .holding: "Holding at limit"
        case .discharging: "Discharging to limit"
        }
    }
}

extension ChargeControlMode {
    var intentTitle: String {
        switch self {
        case .normal: "Allow charging"
        case .inhibitCharging: "Pause charging"
        case .forceDischarge: "Run from battery"
        }
    }
}

extension ChargingAction {
    var title: String {
        switch self {
        case .enableCharging: "Enable charging"
        case .disableCharging: "Disable charging"
        case .requestDischarge: "Request discharge"
        case .noAction: "No change needed"
        case .refuse(let reason): "Not requested — \(reason)"
        }
    }
}

extension ExecutionRecord.Result {
    var title: String {
        switch self {
        case .applied: "Applied to hardware"
        case .simulated: "Simulated — hardware unchanged"
        case .failed(let message): "Failed: \(message)"
        case .refused(let reason): "Refused: \(reason)"
        }
    }
}

extension PowerSource {
    var title: String {
        switch self {
        case .externalPower: "Power adapter"
        case .battery: "Battery"
        case .unknown: "Unknown"
        }
    }
}

extension ChargingStatus {
    var title: String {
        switch self {
        case .charging: "Charging"
        case .notCharging: "Not charging"
        case .fullyCharged: "Fully charged"
        case .discharging: "Discharging"
        case .unknown: "Unknown"
        }
    }
}

enum Format {
    static let unavailable = "Not available"

    static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? unavailable
    }

    static func celsius(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) °C" } ?? unavailable
    }

    static func volts(fromMillivolts value: Int?) -> String {
        value.map { "\((Double($0) / 1000).formatted(.number.precision(.fractionLength(2)))) V" } ?? unavailable
    }

    static func milliamps(_ value: Int?) -> String {
        value.map { "\($0) mA" } ?? unavailable
    }

    static func milliampHours(_ value: Int?) -> String {
        value.map { "\($0) mAh" } ?? unavailable
    }

    static func minutes(_ value: Int?) -> String? {
        guard let value else { return nil }
        return Duration.seconds(value * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func capacity(_ health: BatteryHealth) -> String {
        guard let full = health.fullChargeCapacityMilliampHours else { return unavailable }
        guard let design = health.designCapacityMilliampHours, let ratio = health.fullChargeCapacityPercentOfDesign else {
            return "\(full) mAh"
        }
        return "\(full) of \(design) mAh (\(ratio.formatted(.number.precision(.fractionLength(0))))%)"
    }
}

/// A small coloured capsule label.
struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}
