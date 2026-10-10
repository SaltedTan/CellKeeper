import CellKeeperCore
import Foundation

/// One line saying what controls charging, for the menu and Settings ›
/// Control, with a backend that switches charging itself. It says only what
/// the backend's availability and macOS's Charge Limit establish: an
/// unavailable backend controls nothing, whatever the policy wants; while
/// macOS's limit may be limiting, CellKeeper defers to it; and simulated
/// controls change nothing on the Mac.
public enum ControlStatement {
    /// The line for the backend in charge; nil for macOS's Charge Limit,
    /// whose own summary says who enforces the limit.
    public static func text(for status: ControllerStatus) -> String? {
        let capabilities = status.capabilities
        guard !capabilities.isEnforcedByMacOS else { return nil }
        if case .unavailable(let reason) = capabilities.availability {
            return "Unavailable: \(reason)"
        }
        if isDeferringToMacOS(status) {
            return "Deferring to macOS's Charge Limit"
        }
        let isSimulatedHelper = status.backend.identifier == HelperChargingBackend.simulatedHelperIdentifier
        switch capabilities.availability {
        case .simulated where isSimulatedHelper:
            return "Simulated helper: CellKeeper's own control, simulated; nothing on your Mac changes"
        case .simulated:
            return "\(status.backend.displayName): CellKeeper records what it would do; nothing on your Mac changes"
        case .experimental:
            return "\(status.backend.displayName): controls your Mac's charging (experimental)"
        case .available:
            return "\(status.backend.displayName): controls your Mac's charging"
        case .unavailable:
            return nil
        }
    }

    /// True while macOS's own Charge Limit may be limiting charging and a
    /// backend that switches charging itself, and accepts requests, defers
    /// to it.
    public static func isDeferringToMacOS(_ status: ControllerStatus) -> Bool {
        guard !status.capabilities.isEnforcedByMacOS, status.capabilities.availability.acceptsRequests else { return false }
        return status.decision?.state == .deferringToMacOS || status.capabilities.macOSChargeLimit?.isLimiting == true
    }

    /// Whether to offer the steps for turning macOS's Charge Limit off: only
    /// for a backend that switches charging itself and accepts requests,
    /// while macOS's limit may be limiting. A backend that is unavailable
    /// controls nothing, so turning macOS's limit off would leave nothing
    /// limiting charging.
    public static func offersMacOSLimitGuide(_ status: ControllerStatus) -> Bool {
        guard !status.capabilities.isEnforcedByMacOS, status.capabilities.availability.acceptsRequests else { return false }
        return status.capabilities.macOSChargeLimit?.isLimiting == true
    }

    /// Said next to CellKeeper's own limit while it does not apply because
    /// CellKeeper defers to macOS's Charge Limit; nil otherwise.
    public static func limitNote(for status: ControllerStatus) -> String? {
        guard status.settings.isManagementEnabled, isDeferringToMacOS(status) else { return nil }
        return "Not in effect while macOS's Charge Limit is on: CellKeeper defers to it, with no limit, temperature pause or discharge of its own."
    }

    /// Whether the policy's decision is carried out: false for a backend
    /// that accepts no requests, whose decisions are only what CellKeeper
    /// would do.
    public static func isPolicyApplied(_ status: ControllerStatus) -> Bool {
        status.capabilities.availability.acceptsRequests
    }
}

/// The charge limits the UI offers for a backend.
public enum ChargeLimitChoices: Sendable, Equatable {
    /// Every whole percentage in the range: CellKeeper's own control, the
    /// simulated and read-only backends.
    case wholePercent(ClosedRange<Int>)
    /// Only these values: macOS's Charge Limit.
    case steps([Int])

    /// What to offer for the backend in charge (`capabilities`), or, before
    /// any status, for the chosen backend (`isNativeChosen`: macOS's Charge
    /// Limit).
    public static func offered(capabilities: ControlCapabilities?, isNativeChosen: Bool) -> ChargeLimitChoices {
        guard capabilities?.isEnforcedByMacOS ?? isNativeChosen else {
            return .wholePercent(ChargingSettings.chargeLimitRange)
        }
        let steps = capabilities?.nativeLimitSteps ?? []
        return .steps(steps.isEmpty ? NativeChargeLimitBackend.supportedLimits : steps)
    }

    /// Every value offered, ascending.
    public var values: [Int] {
        switch self {
        case .wholePercent(let range): Array(range)
        case .steps(let steps): steps
        }
    }

    public var isNativeSteps: Bool {
        if case .steps = self { return true }
        return false
    }
}

/// Where System Settings shows the Battery settings.
public enum BatterySettingsLink {
    /// The Battery pane, through System Settings' URL scheme. Observed to
    /// open System Settings › Battery on macOS 27.0.1; Apple does not
    /// document this pane's identifier, so callers fall back to
    /// ``systemSettingsApp`` if opening it fails.
    public static let batteryPane = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
    /// System Settings itself, at its top level.
    public static let systemSettingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true)
}
