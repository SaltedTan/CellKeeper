import CellKeeperCore
import Foundation

/// Who made a settings change. It decides only how a refusal is presented:
/// the UI's in Settings; a Shortcuts action's to the shortcut and the log;
/// CellKeeper's own only in the log. Only the UI's changes touch the
/// Settings banner.
public enum SettingsChangeSource: Sendable, Equatable {
    case ui
    case shortcuts
    /// CellKeeper keeping Manage charging off after it kept a Charge Limit
    /// set outside it: not the user's change, whatever command found it.
    case adoption
}

/// What a step does to the Settings banner, which reports a problem with
/// the user's latest change in Settings.
public enum BannerChange: Sendable, Equatable {
    case keep
    case show(String)
    case clear

    public func applied(to banner: String?) -> String? {
        switch self {
        case .keep: banner
        case .show(let text): text
        case .clear: nil
        }
    }
}

/// What became of a settings change when it was made, before the
/// controller applied it.
public enum SettingsChangeResult: Sendable, Equatable {
    /// Saved, and queued for the controller.
    case saved(previous: ChargingSettings)
    /// The same as the settings in effect: nothing saved or queued.
    case unchanged
    /// Not saved; the text says why.
    case refused(String)

    /// What Settings and Shortcuts actions say when settings could not be
    /// saved. The error itself goes only to the unified log.
    public static let saveFailed = "CellKeeper could not save its settings."
}

/// A charge limit the user asked for, checked against the limits offered
/// for the backend in charge before anything is saved, so that a value
/// outside them is refused, never clamped.
public enum ChargeLimitRequest: Sendable, Equatable {
    /// The settings with the new limit; the resume threshold moves only as
    /// far as validity needs (``ChargingSettings/withChargeLimit(_:)``).
    case accepted(ChargingSettings)
    case refused(String)

    public init(limit: Int, choices: ChargeLimitChoices, settings: ChargingSettings) {
        guard choices.values.contains(limit) else {
            switch choices {
            case .wholePercent(let range):
                // The text Settings' validation gives.
                self = .refused(SettingsIssue.chargeLimitOutOfRange(limit, allowed: range).description)
            case .steps(let steps):
                self = .refused("\(ChargeLimitChoices.notSettableWithMacOSLimit(limit)) It accepts \(Self.list(steps)).")
            }
            return
        }
        self = .accepted(settings.withChargeLimit(limit))
    }

    /// "80, 85, 90, 95 or 100%".
    private static func list(_ steps: [Int]) -> String {
        guard let last = steps.last else { return "no value" }
        let others = steps.dropLast().map(String.init)
        return others.isEmpty ? "\(last)%" : "\(others.joined(separator: ", ")) or \(last)%"
    }
}

extension ChargeLimitChoices {
    /// The first sentence wherever a limit is not one of macOS's Charge
    /// Limit steps: the menu, Settings and Set CellKeeper Limit.
    public static func notSettableWithMacOSLimit(_ limit: Int) -> String {
        "\(limit)% cannot be set with macOS's Charge Limit."
    }
}

/// What the app does with the Settings banner and the log at each step of a
/// settings change, by source. Changes from every source are reconciled the
/// same way; only the UI's touch the banner. A Shortcuts action's are
/// reported to the shortcut and logged; CellKeeper's own (`adoption`) are
/// only logged, and the menu's notice about the kept change shows them.
public enum SettingsReconciliation {
    /// When the change is made, before the controller applies it: the UI's
    /// saved change clears the banner and its refusal shows it, as before.
    public static func banner(after result: SettingsChangeResult, source: SettingsChangeSource) -> BannerChange {
        guard source == .ui else { return .keep }
        switch result {
        case .saved: return .clear
        case .unchanged: return .keep
        case .refused(let text): return .show(text)
        }
    }

    /// What to log about a refused change of CellKeeper's own. The UI's
    /// refusals are shown in Settings, and a Shortcuts action logs its own
    /// outcome. The text is fixed (a failed save's error is logged apart,
    /// privately).
    public static func logMessage(after result: SettingsChangeResult, source: SettingsChangeSource) -> String? {
        guard case .refused(let text) = result, source == .adoption else { return nil }
        return "CellKeeper could not save Manage charging as off after keeping a Charge Limit set outside it: \(text)"
    }

    /// What the controller did with the change.
    public enum ControllerResult: Sendable, Equatable {
        /// Applied. `isManagementEnabled` is what the controller kept;
        /// `managementRefusal` says why it kept management off, if it did.
        case applied(isManagementEnabled: Bool, managementRefusal: String?)
        /// Rejected as invalid; nothing changed.
        case rejected(String)
    }

    public struct Outcome: Sendable, Equatable {
        /// Save and show Manage charging as off: the controller kept it off,
        /// and no newer change is on its way.
        public var keepsManagementOff: Bool
        public var banner: BannerChange
        /// For the unified log: for changes other than the UI's.
        public var logMessage: String?

        public init(keepsManagementOff: Bool = false, banner: BannerChange = .keep, logMessage: String? = nil) {
            self.keepsManagementOff = keepsManagementOff
            self.banner = banner
            self.logMessage = logMessage
        }
    }

    /// After the controller applied the change. The banner is set only when
    /// a change made in the UI asked for Manage charging on (on in the
    /// settings it carried, whatever else it changed) and the controller
    /// kept it off, as when it found a Charge Limit set outside CellKeeper:
    /// the banner then explains the change the user just made. Every other
    /// reconciliation leaves the banner as it is.
    /// - Parameters:
    ///   - sent: the settings the command carried.
    ///   - current: the app's settings now; a newer change may differ.
    public static func outcome(sent: ChargingSettings, current: ChargingSettings, controller: ControllerResult, source: SettingsChangeSource) -> Outcome {
        switch controller {
        case .applied(let isManagementEnabled, let refusal):
            guard sent.isManagementEnabled, !isManagementEnabled, current == sent else { return Outcome() }
            let reason = refusal ?? "Manage charging stays off; Settings › Activity says why."
            switch source {
            case .ui: return Outcome(keepsManagementOff: true, banner: .show(reason))
            case .shortcuts: return Outcome(keepsManagementOff: true, logMessage: "CellKeeper kept Manage charging off after a Shortcuts settings change. \(reason)")
            case .adoption: return Outcome(keepsManagementOff: true, logMessage: "CellKeeper kept Manage charging off. \(reason)")
            }
        case .rejected(let error):
            switch source {
            case .ui: return Outcome(banner: .show("Settings were rejected: \(error)"))
            case .shortcuts, .adoption: return Outcome(logMessage: "CellKeeper's controller rejected settings that were saved; Settings › Activity says why.")
            }
        }
    }
}

/// Whether "Charge to 100% once" can start a temporary full charge now. The
/// menu's button and Start CellKeeper Full Charge share it; nil means it
/// can. It needs a reading that shows a battery and external power.
/// Otherwise it gives one reason, the first that applies: the menu shows it
/// under the disabled button, and the action refuses with it (D97, D110).
public enum FullChargeStart {
    public static func refusal(settings: ChargingSettings, status: ControllerStatus) -> String? {
        if let running = status.activeOverride {
            return running.kind == .fullCharge
                ? "A temporary full charge is already running."
                : "A discharge to the limit is running. Stop it first."
        }
        guard settings.isManagementEnabled else { return "Manage charging is off. Turn it on to charge to 100% once." }
        guard settings.chargeLimit < 100 else { return "CellKeeper's limit is already 100%." }
        guard let snapshot = status.snapshot, snapshot.isBatteryPresent, snapshot.isOnExternalPower else {
            if let snapshot = status.snapshot, snapshot.isBatteryPresent, snapshot.powerSource == .battery {
                return "The Mac is on battery. Connect power first."
            }
            return "CellKeeper has no battery reading that shows the Mac plugged in."
        }
        return nil
    }
}

/// Whether Settings › Charging's "Discharge Now…" can start a discharge to
/// the limit now; nil means it can, and the button is enabled exactly then.
/// Otherwise one reason, the first that applies in this order: Manage
/// charging, the limit's range (``ChargingPolicy/dischargeTargetRange``),
/// the backend, a reading of the charge, external power, a charge above the
/// limit, an override already running. Settings shows it under the disabled
/// button (D110). The controller checks Manage charging, the range and a
/// live override again when the command arrives (D108).
public enum DischargeStart {
    /// - Parameter status: the latest status; nil before the first, which
    ///   reads as no reading.
    public static func refusal(settings: ChargingSettings, status: ControllerStatus?) -> String? {
        guard settings.isManagementEnabled else { return "Manage charging is off. Turn it on to discharge to the limit." }
        let range = ChargingPolicy.dischargeTargetRange
        guard range.contains(settings.chargeLimit) else { return "Discharging needs a limit of \(range.lowerBound)–\(range.upperBound)%." }
        guard let status else { return noReading }
        guard status.capabilities.supports(.forceDischarge) else { return "Discharging while plugged in is not available with the current backend." }
        guard let snapshot = status.snapshot, let percent = snapshot.chargePercent else { return noReading }
        guard snapshot.isOnExternalPower else {
            return snapshot.powerSource == .battery
                ? "The Mac is on battery. Connect power first."
                : "CellKeeper has no battery reading that shows the Mac plugged in."
        }
        guard percent > settings.chargeLimit else { return "The battery is already at or below the limit." }
        if let running = status.activeOverride {
            return running.kind == .fullCharge
                ? "A temporary full charge is running."
                : "A discharge to the limit is already running."
        }
        return nil
    }

    private static let noReading = "CellKeeper has no reading of the battery's charge."
}
