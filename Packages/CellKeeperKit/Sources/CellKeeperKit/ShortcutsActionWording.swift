import CellKeeperCore
import Foundation

/// What an action's backend-specific checks and qualifiers rely on. It
/// exists only once the context is settled: a first status, no backend
/// switch pending, and the backend in charge is the one selected. Until
/// then the latest status may describe another backend than the one the
/// action's command will meet.
public struct ShortcutsActionContext: Sendable {
    /// The latest status, with the app's settings as saved.
    public private(set) var status: ControllerStatus

    public init?(status: ControllerStatus?, settings: ChargingSettings, selectedBackendIdentifier: String) {
        guard var status, status.pendingBackend == nil, status.backend.identifier == selectedBackendIdentifier else { return nil }
        status.settings = settings
        self.status = status
    }

    /// The same context with the settings as an action just saved them.
    public func with(settings: ChargingSettings) -> ShortcutsActionContext {
        var copy = self
        copy.status.settings = settings
        return copy
    }
}

/// What Shortcuts actions say. A result states only what is certain when the
/// action returns, the saved setting or the queued command; what the backend
/// then does is left to the menu. Qualifiers follow from the settled context
/// alone, whichever sentence comes first.
///
/// Like ``NotificationWording``, the text is built from fixed phrases,
/// numbers, backend names and the plain words of the policy's types, never
/// from unavailability reasons, error messages, report problems or log
/// entries, so it carries no identifiers or paths.
public enum ShortcutsActionWording {
    public static let notReady = "CellKeeper is still starting or switching how it controls charging. Try again in a moment."
    public static let quitting = "CellKeeper is quitting."

    /// A sentence added after an action's result, from the settled context.
    public enum Qualifier: Sendable, CaseIterable {
        case managementOff
        case simulated
        case noRequests
        case fault
        case deferringToMacOS
        case fullChargeRunning
        case belowHalf
    }

    static let limitQualifiers: [Qualifier] = [.managementOff, .simulated, .noRequests, .fault, .deferringToMacOS, .fullChargeRunning, .belowHalf]
    static let controlQualifiers: [Qualifier] = [.simulated, .noRequests, .fault, .deferringToMacOS]
    static let releaseQualifiers: [Qualifier] = [.simulated, .noRequests]

    static let showsWhatItDoesWithIt = "The menu shows what CellKeeper does with it."
    static let showsWhatItDoesNow = "The menu shows what CellKeeper does now."

    /// The qualifier's sentence, or nil where it does not apply.
    public static func qualifier(_ qualifier: Qualifier, in context: ShortcutsActionContext) -> String? {
        let status = context.status
        let capabilities = status.capabilities
        switch qualifier {
        case .managementOff:
            return status.settings.isManagementEnabled ? nil : "Manage charging is off, so the limit is not applied until you turn it on."
        case .simulated:
            return status.isControlSimulated ? "Simulated: nothing on your Mac changes." : nil
        case .noRequests:
            guard !capabilities.availability.acceptsRequests else { return nil }
            if status.backend.identifier == ReadOnlyChargingBackend().descriptor.identifier {
                return "Read-only is selected, so CellKeeper changes nothing."
            }
            return "\(status.backend.displayName) is unavailable right now, so CellKeeper changes nothing; the menu says why."
        case .fault:
            guard status.isBackendFaulted else { return nil }
            return capabilities.isEnforcedByMacOS
                ? "The control backend is faulted: until you clear the fault in Settings › Control, CellKeeper only gives back your own Charge Limit."
                : "The control backend is faulted: until you clear the fault in Settings › Control, CellKeeper only asks for normal charging."
        case .deferringToMacOS:
            // The menu's own note, with the caveat that a restriction of
            // CellKeeper's may remain (the menu leaves that to its notice).
            return ControlStatement.limitNote(for: status)
        case .fullChargeRunning:
            return status.activeOverride?.kind == .fullCharge ? "A temporary full charge is running, which takes precedence over the limit until it ends." : nil
        case .belowHalf:
            return status.settings.chargeLimit < 50 ? "Limits below 50% leave little charge for unplugged use." : nil
        }
    }

    static func qualifiers(_ list: [Qualifier], in context: ShortcutsActionContext?) -> [String] {
        guard let context else { return [] }
        return list.compactMap { qualifier($0, in: context) }
    }

    /// Where the menu shows the outcome; none for a backend that accepts no
    /// requests, which changes nothing.
    static func closing(_ text: String, in context: ShortcutsActionContext?) -> [String] {
        context?.status.capabilities.availability.acceptsRequests == false ? [] : [text]
    }

    // MARK: - Results

    /// Set CellKeeper Limit, saved. `context` carries the saved settings.
    public static func limitSaved(in context: ShortcutsActionContext) -> String {
        let settings = context.status.settings
        var parts = ["CellKeeper saved its limit as \(settings.chargeLimit)%."]
        // The saved setting, not a promise: whether charging resumes there
        // is up to the backend, Manage charging and the safety rules.
        if !context.status.capabilities.isEnforcedByMacOS {
            parts.append("Its saved resume threshold is \(settings.resumeThreshold)%.")
        }
        parts += qualifiers(limitQualifiers, in: context)
        if settings.isManagementEnabled {
            parts += closing(showsWhatItDoesWithIt, in: context)
        }
        return parts.joined(separator: " ")
    }

    /// Set CellKeeper Limit with the limit already in effect.
    public static func limitUnchanged(in context: ShortcutsActionContext) -> String {
        (["CellKeeper's limit is already \(context.status.settings.chargeLimit)%."] + qualifiers(limitQualifiers, in: context)).joined(separator: " ")
    }

    /// Start CellKeeper Full Charge, queued.
    public static func fullChargeQueued(in context: ShortcutsActionContext) -> String {
        (["CellKeeper received the request for a temporary full charge."]
            + qualifiers(controlQualifiers, in: context)
            + closing(showsWhatItDoesWithIt, in: context)).joined(separator: " ")
    }

    /// Stop CellKeeper Full Charge or Discharge, queued. `context` is nil
    /// while unsettled.
    public static func stopQueued(in context: ShortcutsActionContext?) -> String {
        (["CellKeeper will end any temporary full charge or discharge in progress."]
            + qualifiers(releaseQualifiers, in: context)
            + closing(showsWhatItDoesNow, in: context)).joined(separator: " ")
    }

    /// Set CellKeeper Manage Charging. `changed` is false when it was
    /// already in that state; `context` carries the saved settings, and is
    /// nil while unsettled (possible only when turning it off).
    public static func management(isOn: Bool, changed: Bool, in context: ShortcutsActionContext?) -> String {
        let state = isOn ? "on" : "off"
        var parts = [changed ? "CellKeeper saved Manage charging as \(state)." : "Manage charging is already \(state)."]
        parts += qualifiers(isOn ? controlQualifiers : releaseQualifiers, in: context)
        if changed {
            parts += closing(isOn ? showsWhatItDoesWithIt : showsWhatItDoesNow, in: context)
        }
        return parts.joined(separator: " ")
    }
}

/// The value Get CellKeeper Status returns: the latest status as it is,
/// with the app's settings. Backend-specific values are given only in a
/// settled context.
public struct ShortcutsStatus: Sendable, Equatable {
    /// macOS's percentage; nil with no battery or an unknown charge.
    public var batteryCharge: Int?
    /// What macOS reports, in plain words.
    public var chargingStatus: String
    /// CellKeeper's state in plain words.
    public var state: String
    /// The backend in charge.
    public var control: String
    /// Whether control is simulated; nil while unsettled.
    public var isSimulated: Bool?
    public var chargeLimit: Int
    public var isManagingCharging: Bool
    /// When CellKeeper last checked.
    public var checkedAt: Date?
    /// The short title and subtitle Shortcuts shows for the value.
    public var title: String
    public var dialog: String

    static let unsettled = "still starting or switching"

    public init(status: ControllerStatus, settings: ChargingSettings, selectedBackendIdentifier: String, timeZone: TimeZone = .current, locale: Locale = .current) {
        let context = ShortcutsActionContext(status: status, settings: settings, selectedBackendIdentifier: selectedBackendIdentifier)
        let snapshot = status.snapshot
        let battery: String
        if let snapshot, snapshot.isBatteryPresent {
            batteryCharge = snapshot.chargePercent
            chargingStatus = snapshot.chargingStatus.description
            battery = "\(snapshot.chargePercent.map { "Battery \($0)%" } ?? "Battery charge unknown"), \(chargingStatus)."
            title = snapshot.chargePercent.map { "Battery \($0)%" } ?? "Battery charge unknown"
        } else if snapshot != nil {
            batteryCharge = nil
            chargingStatus = "no battery"
            battery = "No battery detected."
            title = "No battery"
        } else {
            batteryCharge = nil
            chargingStatus = ChargingStatus.unknown.description
            battery = "No battery reading."
            title = "No battery reading"
        }
        chargeLimit = settings.chargeLimit
        isManagingCharging = settings.isManagementEnabled
        checkedAt = status.lastEvaluation

        var parts = [battery]
        if let context {
            let capabilities = context.status.capabilities
            control = context.status.backend.displayName
            isSimulated = context.status.isControlSimulated
            if context.status.isBackendFaulted {
                state = "control backend faulted"
            } else {
                let policyState = context.status.decision?.state.description ?? "no decision yet"
                state = capabilities.availability.acceptsRequests ? policyState : "\(policyState), not applied"
            }
            parts.append("CellKeeper (\(control)): \(state); its limit is \(settings.chargeLimit)%.")
            parts += ShortcutsActionWording.qualifiers(ShortcutsActionWording.controlQualifiers, in: context)
            if capabilities.isEnforcedByMacOS, capabilities.availability.acceptsRequests {
                parts.append(context.status.nativeLimit?.reportedLimit.map { "macOS reports its Charge Limit at \(NativeLimitWording.limit($0))." }
                    ?? "macOS's Charge Limit could not be read.")
            }
        } else {
            control = Self.unsettled
            isSimulated = nil
            state = Self.unsettled
            parts.append("CellKeeper is still starting or switching how it controls charging.")
        }
        if let checkedAt {
            parts.append("Checked at \(checkedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))).")
        }
        dialog = parts.joined(separator: " ")
    }
}
