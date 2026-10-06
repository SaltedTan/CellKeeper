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

extension ControlCapabilities {
    /// What the availability means for this kind of backend.
    var explanation: String {
        guard isEnforcedByMacOS else { return availability.explanation }
        switch availability {
        case .available:
            return "CellKeeper sets macOS's Charge Limit through your shortcut, and macOS enforces it."
        case .experimental:
            return "CellKeeper sets macOS's Charge Limit through your shortcut, and macOS enforces it. Experimental: so far verified on one Mac."
        case .simulated:
            return availability.explanation
        case .unavailable(let reason):
            return "CellKeeper cannot change macOS's Charge Limit right now. \(reason)"
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
        case .osEnforcedLimit: "Limit enforced by macOS"
        }
    }
}

extension ChargeControlMode {
    /// What the mode means to the user. With a native-limit backend `.normal`
    /// is the user's own macOS limit rather than unrestricted charging.
    func intentTitle(nativeLimit: Bool) -> String {
        switch self {
        case .normal: nativeLimit ? "Your own macOS limit" : "Allow charging"
        case .inhibitCharging: "Pause charging"
        case .forceDischarge: "Run from battery"
        case .nativeLimit(let percent): percent >= 100 ? "macOS limit off (100%)" : "macOS limit \(percent)%"
        }
    }
}

extension ExecutionRecord.Result {
    var title: String {
        switch self {
        case .applied: "Applied and confirmed"
        case .unchanged: "Already in effect — nothing changed"
        case .simulated: "Simulated — hardware unchanged"
        case .adoptedOutsideChange: "Kept your change made outside CellKeeper — nothing changed"
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

    /// A Charge Limit value, where 100% means no limit.
    static func chargeLimit(_ value: Int) -> String {
        value >= 100 ? "100% (no limit)" : "\(value)%"
    }

    /// Why a backend switch is still waiting.
    static func pendingSwitch(to name: String, nativeLimit: NativeLimitStatus?) -> String {
        if nativeLimit?.isAdoptionUnsaved == true {
            return "Switching to \(name) once CellKeeper has stored its record of the limit it kept; it could not write to its storage yet."
        }
        return "Switching to \(name) once your own limit is confirmed restored."
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
