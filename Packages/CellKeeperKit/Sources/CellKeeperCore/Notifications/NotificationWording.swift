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
    public static let settingsSummary = "CellKeeper notifies you when it holds charging at your limit or pauses it because the battery is warm, when a temporary full charge or a discharge ends without you stopping it, when its control backend faults, and when it cannot confirm that its own restriction ended or that your own Charge Limit is back, and once that is resolved. With macOS's Charge Limit, it notifies you when macOS reports the battery at or above the limit CellKeeper chose and not charging, and during a calibration when it asks you to unplug, rest or plug in your Mac, and when the calibration finishes or ends early. Notifications say only what CellKeeper observed, and say so when its control is simulated."

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

    /// `override` is the one the policy ended; a full charge a schedule
    /// started or extended is named so, as in the menu and the log.
    static func overrideEnded(_ override: ChargeOverride, _ ended: OverrideEnd, status: ControllerStatus) -> PlannedNotification {
        let kind = override.kind
        let name = ChargeController.describe(override)
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
            // Its monotonic deadline passed; how long it ran is not said,
            // since the wall-clock times it carries are estimates a clock
            // change can move.
            sentences = ["\(name) \(ended)."]
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
        let title = kind == .fullCharge ? "\(name) ended" : "Discharge ended"
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

    /// A calibration's request, worded as the menu words it but "from now",
    /// since it is posted when the request begins (note 12 §7.5).
    static func calibrationRequest(_ request: CalibrationRequest, status: ControllerStatus) -> PlannedNotification {
        PlannedNotification(
            kind: NotificationKind.calibration(request),
            title: CalibrationWording.title(request),
            body: CalibrationWording.text(request, atRequest: true, now: status.lastEvaluation ?? Date()),
            identifier: status.calibration.session.map { calibrationIdentifier(session: $0.id, request: request) }
        )
    }

    /// What every calibration request's identifier begins with, and only
    /// theirs: after a relaunch, a request an earlier run posted is found in
    /// Notification Center by it. A session's end report has another.
    public static let calibrationRequestPrefix = "calibration.request."

    /// What a session's end report's identifier begins with.
    public static let calibrationReportPrefix = "calibration.report."

    /// The identifier of the calibration request that holds for `status`,
    /// also a paused session's, if any: what reconciliation keeps.
    static func standingCalibrationRequest(_ status: ControllerStatus) -> String? {
        guard let session = status.calibration.session,
              let request = CalibrationWording.request(status.calibration, reading: NotificationPlanner.usableSnapshot(status), includingPaused: true)
        else { return nil }
        return calibrationIdentifier(session: session.id, request: request)
    }

    /// A calibration request's own identifier: its session and what it
    /// asks, a rest asked again being a new one.
    static func calibrationIdentifier(session: UUID, request: CalibrationRequest) -> String {
        let what = switch request {
        case .unplug: "unplug"
        case .rest: "rest"
        case .restAgain: "restAgain"
        case .plugIn: "plugIn"
        }
        return "\(calibrationRequestPrefix)\(session.uuidString).\(what)"
    }

    /// A calibration that finished or ended by itself.
    static func calibrationEnded(_ report: CalibrationReport, status: ControllerStatus) -> PlannedNotification {
        let words = CalibrationWording.endNotification(report, status: status)
        return PlannedNotification(kind: report.end.isCompleted ? .calibrationFinished : .calibrationEndedEarly, title: words.title, body: words.body, identifier: "\(calibrationReportPrefix)\(report.id.uuidString)")
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

    /// Why CellKeeper has not judged macOS's latest report of its Charge
    /// Limit (``NativeLimitStatus/readDeferral``), as sentences. Never that
    /// the limit changed: macOS clears its active limit on battery power and
    /// creates it again on power (research note 08, O20).
    public static func deferral(_ condition: ChargeLimitReadCondition) -> String {
        "\(deferralTitle(condition)). \(deferralDetail(condition))"
    }

    /// The first part of ``deferral(_:)``, without a full stop, for the
    /// menu's line about macOS's Charge Limit.
    public static func deferralTitle(_ condition: ChargeLimitReadCondition) -> String {
        switch condition {
        case .onBattery, .settled: "macOS applies its Charge Limit only on power"
        case .settling: "Waiting for power to settle"
        case .powerUnknown: "CellKeeper cannot tell whether your Mac is on power"
        }
    }

    /// The rest of ``deferral(_:)``: when CellKeeper checks again.
    public static func deferralDetail(_ condition: ChargeLimitReadCondition) -> String {
        switch condition {
        case .onBattery, .settled, .settling: "Checks the Charge Limit after a minute on power."
        case .powerUnknown: "CellKeeper checks macOS's Charge Limit once it can."
        }
    }

    /// ``deferral(_:)`` for the last read in `native`, or nil if it was
    /// judged.
    public static func deferral(_ native: NativeLimitStatus?) -> String? {
        native?.readDeferral.map(deferral)
    }

    /// What Settings and Diagnostics show for the limit macOS reports,
    /// shortly, when its report was not judged.
    public static func deferralValue(_ condition: ChargeLimitReadCondition) -> String {
        switch condition {
        case .onBattery, .settled: "Not active on battery"
        case .settling: "Checked a minute after power returns"
        case .powerUnknown: "Not checked: power source unknown"
        }
    }

    /// What the menu says about the user's own limit while CellKeeper's
    /// restore waits for power, in place of saying when management stops:
    /// nothing was written, macOS applies its Charge Limit only on power
    /// (research note 08, O20), and a change made meanwhile is kept, since
    /// an outside change is adopted at the plug-in (D116, O15).
    public static func restoreWaitingForPower(_ owner: Int) -> String {
        "CellKeeper gives back your own limit, \(limit(owner)), once your Mac has been on power for a minute and it has checked macOS's Charge Limit; if you change the limit meanwhile, it keeps your change. macOS applies its Charge Limit only on power."
    }

    /// Settings › Control's short value for the same state.
    public static func restoreWaitingForPowerValue(_ owner: Int) -> String {
        "\(limit(owner)), recorded; given back once your Mac has been on power for a minute, unless you change the limit meanwhile"
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
            ? "Restoring your \(limit(owner)) limit is not confirmed. CellKeeper keeps trying; you can also set it in System Settings › Battery › Charging."
            : "CellKeeper cannot restore your \(limit(owner)) limit now. Set it in System Settings › Battery › Charging."
    }
}
