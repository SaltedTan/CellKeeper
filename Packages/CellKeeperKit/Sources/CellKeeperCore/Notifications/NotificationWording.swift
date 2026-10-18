import Foundation

/// What CellKeeper's notifications say. Each one states only what the status
/// establishes, as observations: what read-backs confirmed, what macOS
/// reports, and that simulated controls change nothing on the Mac; never a
/// likely cause. Where the menu, Settings or the activity log already word a
/// fact, the same words are used.
///
/// The text is built from fixed phrases, percentages, temperatures and
/// backend names only, never from error messages, unavailability reasons,
/// macOS's report problems or log entries, so it carries no identifiers or
/// paths.
public enum NotificationWording {
    /// Ends every notification about a simulated backend; the title says
    /// "Simulated" too, because a banner may cut the body short.
    static let simulatedNote = "CellKeeper's control is simulated: your Mac's charging is not changed."

    /// What Settings says notifications are about.
    public static let settingsSummary = "CellKeeper notifies you when it holds charging at your limit or pauses it because the battery is warm, when a temporary full charge or a discharge ends without you stopping it, when its control backend faults, and when it cannot confirm that its own restriction ended or that your own Charge Limit is back, and once that is resolved. With macOS's Charge Limit, it notifies you when macOS reports the battery at or above the limit CellKeeper chose and not charging. Notifications say only what CellKeeper observed, and say so when its control is simulated."

    /// `percent`: the charge usable telemetry showed with the hold.
    static func limitReached(_ status: ControllerStatus, limit: Int, percent: Int) -> PlannedNotification {
        if status.capabilities.isEnforcedByMacOS {
            // Observations only: macOS does not report why it is not
            // charging, and may charge past its limit now and then.
            return PlannedNotification(
                kind: .limitReached,
                title: percent > limit ? "Battery above the Charge Limit" : "Battery at the Charge Limit",
                body: "macOS reports the battery at \(percent)% and not charging. Your limit in CellKeeper is \(limit)%, and macOS reports its Charge Limit at \(limit)%."
            )
        }
        // The policy's reason, as the menu shows it; only these reasons,
        // which carry nothing but numbers.
        let reason: String = switch status.decision?.reason {
        case let reason? where reason.isLimitHold: reason.description
        default: "Charging is paused at your \(limit)% limit."
        }
        let title = percent > limit ? "Charging paused above your limit" : "Charging paused at your limit"
        return PlannedNotification(kind: .limitReached, title: titled(title, status), body: noted(reason, status))
    }

    static func temperaturePause(_ status: ControllerStatus) -> PlannedNotification {
        let reason: String = switch status.decision?.reason {
        case let reason? where reason.isTemperaturePause: reason.description
        default: "Charging is paused because the battery is warm."
        }
        return PlannedNotification(kind: .temperaturePause, title: titled("Charging paused because the battery is warm", status), body: noted(reason, status))
    }

    static func overrideEnded(_ kind: ChargeOverride.Kind, _ ended: OverrideEnd, override: ChargeOverride, status: ControllerStatus) -> PlannedNotification {
        let name = ChargeController.describe(kind)
        var sentences: [String]
        switch ended {
        case .completed:
            // Completion is judged only on telemetry the policy accepted.
            sentences = ["\(name) \(ended)."]
            let snapshot = NotificationPlanner.usableSnapshot(status)
            if kind == .fullCharge, snapshot?.isFullyCharged == true {
                sentences.append("macOS reports the battery fully charged.")
            } else if let percent = snapshot?.chargePercent {
                sentences.append("macOS reports the battery at \(percent)%.")
            }
        case .expired:
            let hours = max(1, Int((override.expiresAt.timeIntervalSince(override.startedAt) / 3600).rounded()))
            sentences = ["\(name) \(ended) after \(hours) \(hours == 1 ? "hour" : "hours")."]
        case .unplugged:
            // The policy ends an override on any reading of battery power,
            // even one too old to act on otherwise; say what it saw.
            sentences = ["\(name) ended: a battery reading showed the Mac on battery power."]
        case .interrupted:
            sentences = ["\(name) \(ended)."]
            if let note = status.decision?.notes.first(where: { $0 == .dischargeEndedForMacOSChargeLimit || $0 == .dischargeUnsupported }) {
                sentences.append(note.description)
            } else {
                sentences.append("The menu shows what CellKeeper does now.")
            }
        }
        let title = kind == .fullCharge ? "Temporary full charge ended" : "Discharge ended"
        return PlannedNotification(kind: .overrideEnded, title: titled(title, status), body: noted(sentences.joined(separator: " "), status))
    }

    static func backendFault(_ status: ControllerStatus) -> PlannedNotification {
        let until = status.capabilities.isEnforcedByMacOS
            ? "Until you clear the fault in Settings › Control, CellKeeper only gives back your own Charge Limit."
            : "Until you clear the fault in Settings › Control, CellKeeper only asks for normal charging."
        return PlannedNotification(
            kind: .backendFault,
            title: "\(status.backend.displayName) backend faulted",
            body: noted("CellKeeper marked the backend faulted; Settings › Activity says why. \(until)", status)
        )
    }

    static func restoreUnconfirmed(_ status: ControllerStatus) -> PlannedNotification {
        if status.capabilities.isEnforcedByMacOS {
            return PlannedNotification(
                kind: .restoreUnconfirmed,
                title: "Your own Charge Limit is not confirmed back",
                body: NativeLimitWording.restoreProblem(status) ?? "CellKeeper could not confirm yet that your own limit is back. You can set it in System Settings › Battery › Charging."
            )
        }
        let own = status.ownRestriction
        let body: String
        if status.capabilities.availability.acceptsRequests {
            body = MacOSChargeLimitWording.releaseState(own, isSimulated: false)
        } else {
            let caveat = MacOSChargeLimitWording.ownRestrictionCaveat(own, isSimulated: false) ?? "CellKeeper cannot confirm that nothing it set remains"
            body = "\(caveat). \(status.backend.displayName) accepts no requests right now, so CellKeeper cannot ask for its release."
        }
        return PlannedNotification(kind: .restoreUnconfirmed, title: titled("Normal charging not confirmed", status), body: noted(body, status))
    }

    /// In the past tense: what happened since the warning, which later
    /// changes (CellKeeper applying its limit again, say) do not undo.
    static func restoreResolved(_ resolution: RestoreResolution, _ status: ControllerStatus) -> PlannedNotification {
        switch resolution {
        case .restored(let limit):
            let value = limit.map { " of \(NativeLimitWording.limit($0))" } ?? ""
            return PlannedNotification(
                kind: .restoreResolved,
                title: "Restore of your Charge Limit confirmed",
                body: "macOS reported your own Charge Limit\(value) again."
            )
        case .released:
            return PlannedNotification(
                kind: .restoreResolved,
                title: titled("Normal charging confirmed", status),
                body: noted("A read-back after the warning showed normal charging: CellKeeper's restriction had ended.", status)
            )
        case .keptOutsideChange(let change):
            let value = change.map { " of \(NativeLimitWording.limit($0.limit))" } ?? ""
            return PlannedNotification(
                kind: .restoreResolved,
                title: "Charge Limit set outside CellKeeper kept",
                body: "macOS reported a Charge Limit\(value) that CellKeeper did not set. CellKeeper kept it as your own limit, so it has nothing left to restore."
            )
        case .recordDiscarded:
            return PlannedNotification(
                kind: .restoreResolved,
                title: "Record of your Charge Limit discarded",
                body: "At your request, CellKeeper discarded its unreadable record of your own Charge Limit, so it will not restore a limit from it."
            )
        }
    }

    private static func titled(_ title: String, _ status: ControllerStatus) -> String {
        guard status.isControlSimulated else { return title }
        return "Simulated: \(title.prefix(1).lowercased())\(title.dropFirst())"
    }

    private static func noted(_ body: String, _ status: ControllerStatus) -> String {
        status.isControlSimulated ? "\(body) \(simulatedNote)" : body
    }
}

private extension DecisionReason {
    var isLimitHold: Bool {
        switch self {
        case .limitReached, .holdingAboveResumeThreshold: true
        default: false
        }
    }

    var isTemperaturePause: Bool {
        switch self {
        case .temperatureHigh, .temperatureCooling, .temperatureMinimumPause: true
        default: false
        }
    }
}

/// What CellKeeper says about the user's own macOS Charge Limit and giving
/// it back. Shared by the menu and notifications.
public enum NativeLimitWording {
    /// A Charge Limit value, where 100% means no limit.
    public static func limit(_ value: Int) -> String {
        value >= 100 ? "100% (no limit)" : "\(value)%"
    }

    /// Why the user's own Charge Limit is not confirmed back, and what to do;
    /// nil if CellKeeper owes nothing, or nothing it cannot confirm.
    public static func restoreProblem(_ status: ControllerStatus) -> String? {
        let native = status.nativeLimit
        if native?.isRecordUnreadable == true {
            return "CellKeeper's record of your own limit cannot be read, so it will not change or restore the limit. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control."
        }
        guard let owner = native?.ownerLimit, status.isOwnLimitRestorePending else { return nil }
        // A backend that accepts no requests is never asked to restore.
        return status.capabilities.availability.acceptsRequests
            ? "CellKeeper could not confirm yet that your own limit, \(limit(owner)), is back. It keeps trying; you can also set it in System Settings › Battery › Charging."
            : "CellKeeper cannot give back your own limit, \(limit(owner)), right now. Set it in System Settings › Battery › Charging."
    }
}
