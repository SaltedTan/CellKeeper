import AppKit
import CellKeeperCore
import CellKeeperKit
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
    /// With a native-limit backend the fail-safe is the user's own macOS
    /// limit, never a default such as 100%. The titles name intent (M9):
    /// using macOS's Charge Limit is what the policy wants, not evidence
    /// that macOS enforces it, which only a judged read establishes.
    func title(nativeLimit: Bool) -> String {
        switch self {
        case .unmanaged: "Not managing charging"
        case .failSafe: nativeLimit ? "Fail-safe: your own macOS limit" : "Fail-safe: macOS default charging"
        case .safetyFloor: "Low battery: charging allowed"
        case .onBattery: "On battery: restrictions cleared"
        case .temperaturePause: "Paused: battery temperature"
        case .fullChargeOverride: "Charging to 100% (temporary)"
        case .charging: "Charging to limit"
        case .holding: "Holding at limit"
        case .discharging: "Discharging to limit"
        case .osEnforcedLimit: "Use macOS Charge Limit"
        case .deferringToMacOS: "Deferring to macOS's Charge Limit"
        case .calibrating: "Calibration: macOS's limit at 100%"
        }
    }
}

/// macOS's own Charge Limit as a backend that switches charging itself
/// reads it: what macOS reports, what CellKeeper does about it as far as
/// read-backs establish (``MacOSChargeLimitWording``), and a way to check
/// again after changing it in System Settings.
struct MacOSChargeLimitNotice: View {
    let macOSLimit: MacOSChargeLimitStatus
    let status: ControllerStatus
    let recheck: () -> Void
    /// Shows the steps for turning macOS's limit off; nil shows no button
    /// (Settings shows the steps below the notice). With it, the notice is
    /// the menu's short version; Settings has the full explanation.
    var showGuide: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("macOS's Charge Limit", value: MacOSChargeLimitWording.summary(macOSLimit))
            Text(showGuide == nil
                 ? MacOSChargeLimitWording.guidance(macOSLimit, ownRestriction: status.ownRestriction, isSimulated: status.isControlSimulated)
                 : MacOSChargeLimitWording.menuSummary(macOSLimit, ownRestriction: status.ownRestriction, isSimulated: status.isControlSimulated))
                .font(.caption)
                .foregroundStyle(macOSLimit.isLimiting ? Color.warningText : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Read at \(macOSLimit.readAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let showGuide, macOSLimit.isLimiting {
                    Button("How to Turn It Off", action: showGuide)
                        .help("Opens Settings › Control with the steps for turning off macOS's Charge Limit in System Settings.")
                }
                Button("Check Again", action: recheck)
                    .help("Reads macOS's Charge Limit again now. CellKeeper also reads it about once a minute.")
            }
        }
    }
}

/// The steps for turning macOS's Charge Limit off (``MacOSChargeLimitGuide``),
/// with a way to open System Settings › Battery and to check again.
struct MacOSChargeLimitGuideView: View {
    let isSimulated: Bool
    let openBatterySettings: () -> Void
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MacOSChargeLimitGuide.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                    Text(step)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The number and its step read as one.
                .accessibilityElement(children: .combine)
            }
            ForEach(Array(MacOSChargeLimitGuide.notes(isSimulated: isSimulated).enumerated()), id: \.offset) { index, note in
                Label(note, systemImage: isSimulated && index == 0 ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(isSimulated && index == 0 ? Color.warningText : Color.secondary)
            }
            HStack {
                Button("Open Battery Settings", action: openBatterySettings)
                    .help("Opens System Settings › Battery. CellKeeper changes nothing there.")
                Button("Check Again", action: recheck)
                    .help("Reads macOS's Charge Limit again now.")
            }
            .padding(.top, 2)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One line saying what controls charging (``ControlStatement``), or the
/// availability's explanation for macOS's Charge Limit.
struct ControlStatementText: View {
    let status: ControllerStatus

    var body: some View {
        if let statement = ControlStatement.text(for: status) {
            Text(statement)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(status.capabilities.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    /// A deferred result names the written and unwritten cases without
    /// promising a confirmation (M10): the native deferral beside it says
    /// what the check waits for.
    var title: String {
        switch self {
        case .applied: "Applied and confirmed"
        case .unchanged: "Already in effect — nothing changed"
        case .simulated: "Simulated — hardware unchanged"
        case .adoptedOutsideChange: "Kept your change made outside CellKeeper — nothing changed"
        case .deferred(let written): written ? "Set; confirmation pending." : "Waiting for a check after a minute on power."
        case .failed(let message): "Failed: \(message)"
        case .refused(let reason): "Refused: \(reason)"
        }
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
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

extension ControlEvent.Kind {
    /// The label of an event in Settings › Activity. The diagnostics report
    /// keeps the kind's identifier.
    var title: String {
        switch self {
        case .telemetry: "Battery reading"
        case .decision: "Decision"
        case .request: "Request"
        case .result: "Result"
        case .failure: "Failure"
        case .safety: "Safety"
        case .settings: "Settings"
        case .override: "Override"
        case .calibration: "Calibration"
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
        NativeLimitWording.limit(value)
    }

    /// Why a backend switch is still waiting: the backend still in charge,
    /// the one asked for, and what the switch waits for. Only macOS's Charge
    /// Limit speaks of the user's own limit.
    static func pendingSwitch(from active: BackendDescriptor, to requested: BackendDescriptor, nativeLimit: NativeLimitStatus?, isNative: Bool) -> String {
        let switching = "\(active.displayName) is still in charge. CellKeeper switches to \(requested.displayName) once"
        if nativeLimit?.isAdoptionUnsaved == true {
            return "\(switching) it has stored its record of the limit it kept; it could not write to its storage yet."
        }
        if isNative {
            return "\(switching) your own limit is confirmed restored, and keeps trying until then."
        }
        if ControlBackendChoice(backendIdentifier: active.identifier) == .simulatedHelper {
            return "\(switching) the simulated helper confirms that nothing CellKeeper set there is still in effect; until then it keeps asking for normal charging. Your Mac's charging is not affected."
        }
        return "\(switching) \(active.displayName) confirms normal charging; until then it keeps asking for it."
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

    /// What VoiceOver reads for the readings above: units in words
    /// (``AccessibilityWording``), not abbreviations.
    enum Spoken {
        static func celsius(_ value: Double?) -> String {
            value.map { AccessibilityWording.celsius($0) } ?? Format.unavailable
        }

        static func volts(fromMillivolts value: Int?) -> String {
            value.map { AccessibilityWording.volts(fromMillivolts: $0) } ?? Format.unavailable
        }

        static func milliamps(_ value: Int?) -> String {
            value.map { AccessibilityWording.milliamps($0) } ?? Format.unavailable
        }

        static func capacity(_ health: BatteryHealth) -> String {
            guard let full = health.fullChargeCapacityMilliampHours else { return Format.unavailable }
            return AccessibilityWording.capacity(fullChargeMilliampHours: full, designMilliampHours: health.designCapacityMilliampHours, percentOfDesign: health.fullChargeCapacityPercentOfDesign)
        }

        static func minutes(_ value: Int?) -> String? {
            guard let value else { return nil }
            return Duration.seconds(value * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        }
    }

    /// A moment in Settings › Diagnostics, in local time: the time, with
    /// the date unless it is today. The diagnostics report writes the same
    /// moment in ISO 8601.
    static func moment(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .standard)
    }
}

extension ControllerStatus {
    /// The policy's reason as shown for the backend in charge: macOS's
    /// Charge Limit restores the user's own limit, and the Simulated
    /// helper's controls are simulated.
    var displayedReason: String? {
        guard let reason = decision?.reason else { return nil }
        if capabilities.isEnforcedByMacOS {
            return reason.description(restoring: "your own macOS Charge Limit")
        }
        if ControlBackendChoice(backendIdentifier: backend.identifier) == .simulatedHelper {
            return reason.description(restoring: "normal charging on the simulated helper's controls (simulated; your Mac's charging is not changed)")
        }
        return reason.description
    }
}

/// A backend switch that waits for the backend in charge, with the way to
/// cancel it: choosing that backend again.
struct PendingSwitchNotice: View {
    let status: ControllerStatus
    /// Selects a backend; nil shows no cancel button.
    let select: ((ControlBackendChoice) -> Void)?

    var body: some View {
        if let requested = status.pendingBackend {
            let active = status.backend
            let activeChoice = ControlBackendChoice(backendIdentifier: active.identifier)
            VStack(alignment: .leading, spacing: 6) {
                Label(Format.pendingSwitch(from: active, to: requested, nativeLimit: status.nativeLimit, isNative: status.capabilities.isEnforcedByMacOS),
                      systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                if let select, let activeChoice {
                    Button("Stay with \(active.displayName)") { select(activeChoice) }
                        .help("Cancels the switch to \(requested.displayName); the same as choosing \(active.displayName) again.")
                }
            }
            .font(.caption)
        }
    }
}

/// Why a button is disabled (``FullChargeStart``, ``DischargeStart``),
/// shown only while it is: under the button in the menu, under its row's
/// label in Settings. Secondary text, not a warning tone: nothing is wrong.
/// The button carries the same text as its accessibility hint
/// (`disabledReasonHint(_:help:)`); the line stays readable on its own for
/// VoiceOver users who turn hints off.
struct DisabledReason: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// The accessibility hint of a button that may be disabled: the reason
    /// while it is (nil when enabled), otherwise `help`, its help tag, as
    /// before. On macOS both are the element's AXHelp and the outer modifier
    /// wins (verified), so this goes after `.help(_:)`; an empty hint would
    /// remove the help tag's.
    func disabledReasonHint(_ reason: String?, help: String = "") -> some View {
        accessibilityHint(reason ?? help)
    }
}

/// A small capsule label, tinted and outlined in `color`. The text keeps
/// the label colour: coloured text on a tint of its own colour is too faint
/// to read (2.2:1 to 4:1 against white).
struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.primary)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }
}

/// Asks VoiceOver, or another assistive app, to read a short text now. Only
/// for the outcome of something the user just did that would otherwise go
/// unnoticed; status updates are not announced. Without an assistive app,
/// nothing happens.
@MainActor
enum Announcement {
    static func post(_ text: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: priority.rawValue]
        )
    }
}

extension TextTone {
    /// The tone as a colour that follows the appearance, including the
    /// high-contrast appearances macOS uses while Increase Contrast is on.
    var nsColor: NSColor {
        let tone = self
        return NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let color = tone.color(
                isDark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
                isIncreasedContrast: match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            )
            return NSColor(srgbRed: color.red / 255, green: color.green / 255, blue: color.blue / 255, alpha: 1)
        }
    }
}

extension ShapeStyle where Self == Color {
    /// Warning text: something to be aware of (``TextTone/warning``). Use
    /// it instead of `.orange`, which is too light for text on a light
    /// background.
    static var warningText: Color { Color(nsColor: TextTone.warning.nsColor) }

    /// Error text: something wrong (``TextTone/critical``). Use it instead
    /// of `.red`.
    static var criticalText: Color { Color(nsColor: TextTone.critical.nsColor) }
}
