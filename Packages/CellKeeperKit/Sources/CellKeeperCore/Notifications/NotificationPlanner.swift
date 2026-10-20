import Foundation

/// What a notification is about. Each kind is planned and rate-limited on
/// its own (``NotificationPlanner``).
public enum NotificationKind: String, Sendable, CaseIterable {
    /// CellKeeper's own control holds charging at the limit, as a read-back
    /// shows; or, with macOS's Charge Limit, macOS reports the battery at or
    /// above the limit CellKeeper chose and not charging.
    case limitReached
    /// A temperature pause is in effect, as a read-back shows.
    case temperaturePause
    /// A temporary full charge (also one a schedule started) or a discharge
    /// session ended by itself (``ControllerStatus/lastEndedOverride``).
    case overrideEnded
    /// The control backend became faulted.
    case backendFault
    /// CellKeeper's own restriction may remain although it asked for its
    /// release, or the user's own Charge Limit is not confirmed back.
    case restoreUnconfirmed
    /// After a ``restoreUnconfirmed`` notification, positive evidence that
    /// nothing is owed any more: a read-back showed the release or the
    /// restore, a limit set outside CellKeeper was kept as the user's own,
    /// or the user discarded an unreadable record.
    case restoreResolved
    /// A guided calibration asks the owner to unplug (step 3).
    case calibrationUnplug
    /// A guided calibration asks the owner to rest the Mac unplugged, with
    /// the time to plug in again (step 5), or once to rest it again.
    case calibrationRest
    /// A guided calibration asks the owner to plug in (step 6).
    case calibrationPlugIn
    /// A guided calibration finished.
    case calibrationFinished
    /// A guided calibration ended by itself before it finished.
    case calibrationEndedEarly

    /// The shortest time between two notifications of this kind, on the
    /// monotonic clock. A transition within it is dropped, not delayed.
    public var minimumInterval: TimeInterval {
        switch self {
        case .limitReached, .temperaturePause: 60 * 60
        // A fault lasts until the user clears it and a restore warning
        // until the restore is resolved, so these repeat only after that;
        // the interval absorbs a clear that faults again at once or a
        // backend that keeps failing and recovering.
        case .backendFault, .restoreUnconfirmed: 10 * 60
        // One per override, which the user started; and one per posted
        // restore warning.
        case .overrideEnded, .restoreResolved: 0
        // One per request of a session, and one per session's end.
        case .calibrationUnplug, .calibrationRest, .calibrationPlugIn, .calibrationFinished, .calibrationEndedEarly: 0
        }
    }

    /// Kinds that report a problem with CellKeeper's control, or its end.
    /// They are posted whatever caused the status, also at launch: the
    /// controller starts every session without a fault and with nothing
    /// owed, apart from a restore an earlier session left, which it attempts
    /// at once.
    public var isSafety: Bool {
        switch self {
        case .backendFault, .restoreUnconfirmed, .restoreResolved: true
        case .limitReached, .temperaturePause, .overrideEnded: false
        case .calibrationUnplug, .calibrationRest, .calibrationPlugIn, .calibrationFinished, .calibrationEndedEarly: false
        }
    }

    /// Identifies the notification to the system, so a newer one of the
    /// same kind replaces an older one in Notification Center. A restore's
    /// resolution replaces its warning, and a calibration's latest request
    /// or end replaces the one before. Not shown to the user.
    public var replacementKey: String {
        switch self {
        case .restoreUnconfirmed, .restoreResolved: "restore"
        case .calibrationUnplug, .calibrationRest, .calibrationPlugIn, .calibrationFinished, .calibrationEndedEarly: "calibration"
        default: rawValue
        }
    }

    /// The kind that posts `request`.
    static func calibration(_ request: CalibrationRequest) -> NotificationKind {
        switch request {
        case .unplug: .calibrationUnplug
        case .rest, .restAgain: .calibrationRest
        case .plugIn: .calibrationPlugIn
        }
    }
}

/// A notification to post: its kind and its text, built only from fixed
/// phrases, percentages, temperatures and backend names
/// (``NotificationWording``). No identifiers, paths, error messages or
/// activity-log entries.
public struct PlannedNotification: Sendable, Equatable {
    public var kind: NotificationKind
    public var title: String
    public var body: String

    public init(kind: NotificationKind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Decides which notifications to post from the controller's statuses, one
/// status at a time, in the order the commands that produced them ran. Pure
/// and deterministic: the result depends only on the statuses, triggers and
/// uptimes given so far.
///
/// Rules:
/// - **Evidence.** A notification that says something happened needs
///   positive evidence of it: a read-back (``ControllerStatus/currentMode``)
///   for a hold or a pause; for a restore, a read-back of normal charging
///   (``ControllerStatus/releasesConfirmed``) or of the user's own Charge
///   Limit (``NativeLimitStatus/restoresConfirmed``). The absence of a
///   record, or of a restriction in the final status, is not evidence.
///   Telemetry the policy rejects (``ChargingPolicy/usableSnapshot(_:now:)``)
///   is neither evidence nor arming input. The wording states observations,
///   never a likely cause.
/// - **Episodes.** A kind is posted when an episode of its condition
///   begins, never because it still holds. Faults, restores and overrides'
///   ends are followed through monotonic counters in the status, so an
///   episode that began or ended between two statuses (inside one command)
///   is not lost; of several overrides that ended between two statuses,
///   only the latest is posted, as it would replace the others in
///   Notification Center anyway.
///   A hold or a pause is armed again only once the opposite has been seen
///   on telemetry the policy accepts: charging toward that limit from below
///   it, or a known temperature with the latch clear and protection on. So
///   a hysteresis or debounce that sets the same condition again, a blip of
///   battery power, rejected telemetry or an unknown temperature, sleep and
///   wake, and a hold that resumes after a temperature pause post nothing.
/// - **Minimum interval.** At most one notification of a kind per
///   ``NotificationKind/minimumInterval`` of monotonic time, across
///   backends; a transition within it is dropped, not delayed.
/// - **Calibration requests** (note 12 §7.5) are posted once each, when a
///   session's request begins: a request is identified by the session and
///   what it asks (a rest asked again is a new one), and a session's end
///   by ``CalibrationStatus/endedCount``. They follow the same rules as an
///   override's end: only from automatic evaluations, never replayed. The
///   menu shows every request whether or not one is posted.
/// - **No replay.** Nothing true in the first status is reported, except
///   the safety kinds (``NotificationKind/isSafety``). Statuses of the
///   user's own commands (settings, overrides, a schedule, backend switch,
///   refresh) and a change of backend post only safety kinds, never a hold,
///   a pause or an override's end. A change of backend resets all arming and retires a
///   restore warning without a claim about how it ended. The limit is armed
///   only for the limit in force when charging toward it was seen, so
///   lowering it below the charge posts nothing.
///   While a calibration session exists, running or paused, the limit is
///   not armed at all: its 100% steps and returns are its own doing.
///
/// When notifications are not delivered (off, or macOS does not show
/// them), statuses still update the arming, so turning them on later
/// replays nothing; nothing counts as posted.
public struct NotificationPlanner: Sendable {
    /// What ends a restore episode, counted; a change in any of them since
    /// an episode began means it ended.
    private struct RestoreEvidence: Equatable {
        var releasesConfirmed: Int
        var restoresConfirmed: Int
        var recordsDiscarded: Int
        var adoptions: Int

        init(_ status: ControllerStatus) {
            releasesConfirmed = status.releasesConfirmed
            restoresConfirmed = status.nativeLimit?.restoresConfirmed ?? 0
            recordsDiscarded = status.nativeLimit?.recordsDiscarded ?? 0
            adoptions = status.adoptionCount
        }
    }

    private var previous: ControllerStatus?
    /// The limit at which charging toward it, from below, was seen since the
    /// last limit notification on this backend.
    private var limitArmedAt: Int?
    private var isTemperaturePauseArmed = false
    /// ``ControllerStatus/faultsRaised`` when last seen.
    private var faultsSeen = 0
    /// ``ControllerStatus/overridesEnded`` when last seen; nil before the
    /// first status, which only sets it.
    private var overridesEndedSeen: Int?
    /// The evidence when the restore episode in progress was first seen; nil
    /// while none is.
    private var restoreEpisode: RestoreEvidence?
    /// The evidence when a restore warning was posted on this backend, until
    /// positive evidence resolves it.
    private var restoreWarning: RestoreEvidence?
    private var lastPostedAt: [NotificationKind: TimeInterval] = [:]
    /// The calibration request shown by the last status, with its session.
    private var calibrationRequestSeen: CalibrationRequestSeen?
    /// ``CalibrationStatus/endedCount`` when last seen; nil before the
    /// first status, which only sets it.
    private var calibrationsEndedSeen: Int?

    private struct CalibrationRequestSeen: Equatable {
        var session: UUID
        var request: CalibrationRequest
    }

    public init() {}

    /// The notifications `status` calls for.
    ///
    /// - Parameters:
    ///   - trigger: what produced the status; for a command that is not an
    ///     evaluation, the trigger of the evaluation it runs
    ///     (`settingsChanged`, `overrideChanged`, `backendChanged`,
    ///     `manual`). Only automatic triggers post a hold, a pause or an
    ///     override's end.
    ///   - uptime: monotonic seconds, for the minimum intervals.
    ///   - isDelivering: false while notifications are off or macOS does not
    ///     show them; the arming is updated and nothing is returned.
    public mutating func plan(_ status: ControllerStatus, trigger: EvaluationTrigger, uptime: TimeInterval, isDelivering: Bool) -> [PlannedNotification] {
        defer { previous = status }
        let isBackendChanged = previous.map { $0.backend.identifier != status.backend.identifier } ?? false
        if isBackendChanged {
            // Nothing on the old backend is observed any more; a warning
            // about it is retired without a claim about how it ended.
            limitArmedAt = nil
            isTemperaturePauseArmed = false
            restoreEpisode = nil
            restoreWarning = nil
        }
        let mayPostProgress = trigger.isAutomatic && !isBackendChanged
        var planned: [PlannedNotification] = []
        // Posts `kind` if it may be posted now; true if it was.
        func offer(_ kind: NotificationKind, _ content: @autoclosure () -> PlannedNotification) -> Bool {
            guard isDelivering, kind.isSafety || mayPostProgress, isOutsideInterval(kind, uptime: uptime) else { return false }
            lastPostedAt[kind] = uptime
            planned.append(content())
            return true
        }

        // The override that ended, as the controller recorded it: so a full
        // charge a schedule started in place of the override shown before,
        // and ended in the same evaluation, is the one named.
        if let seen = overridesEndedSeen, status.overridesEnded != seen, let ended = status.lastEndedOverride {
            _ = offer(.overrideEnded, NotificationWording.overrideEnded(ended.override, ended.end, status: status))
        }
        overridesEndedSeen = status.overridesEnded

        if status.calibration.isInProgress {
            // A calibration takes the battery to 100% and back on purpose:
            // a hold at the limit is not news until charging toward it is
            // seen again after the session.
            limitArmedAt = nil
        } else if let held = Self.heldLimit(status) {
            if limitArmedAt == held.limit {
                _ = offer(.limitReached, NotificationWording.limitReached(status, limit: held.limit, percent: held.percent))
            }
            limitArmedAt = nil
        } else if let limit = Self.chargingTowardLimit(status) {
            limitArmedAt = limit
        }

        if Self.isTemperaturePauseInEffect(status) {
            if isTemperaturePauseArmed {
                _ = offer(.temperaturePause, NotificationWording.temperaturePause(status))
            }
            isTemperaturePauseArmed = false
        } else if Self.isTemperatureClearSeen(status) {
            isTemperaturePauseArmed = true
        }

        // One notification per fault episode, on whichever backend; a fault
        // that began and was cleared between two statuses is not reported.
        if status.faultsRaised != faultsSeen {
            faultsSeen = status.faultsRaised
            if status.isBackendFaulted {
                _ = offer(.backendFault, NotificationWording.backendFault(status))
            }
        }

        // A calibration's new request, and its end, as recorded.
        let request = CalibrationWording.request(for: status)
        var requestSeen: CalibrationRequestSeen?
        if let session = status.calibration.session, let request {
            requestSeen = CalibrationRequestSeen(session: session.id, request: request)
        }
        if previous != nil, let requestSeen, let request, requestSeen != calibrationRequestSeen {
            _ = offer(NotificationKind.calibration(request), NotificationWording.calibrationRequest(request, status: status))
        }
        calibrationRequestSeen = requestSeen
        if let seen = calibrationsEndedSeen, status.calibration.endedCount != seen, let report = status.calibration.outcome {
            _ = offer(report.end.isCompleted ? .calibrationFinished : .calibrationEndedEarly, NotificationWording.calibrationEnded(report, status: status))
        }
        calibrationsEndedSeen = status.calibration.endedCount

        let evidence = RestoreEvidence(status)
        if let warned = restoreWarning, let resolution = Self.resolution(since: warned, now: evidence, status: status) {
            _ = offer(.restoreResolved, NotificationWording.restoreResolved(resolution, status))
            restoreWarning = nil
        }
        if Self.isRestoreUnconfirmed(status) {
            // A new episode, unless the one seen before is still going on:
            // any evidence since means that one ended.
            if restoreEpisode != evidence {
                restoreEpisode = evidence
                if offer(.restoreUnconfirmed, NotificationWording.restoreUnconfirmed(status)) {
                    restoreWarning = evidence
                }
            }
        } else {
            restoreEpisode = nil
        }
        return planned
    }

    private func isOutsideInterval(_ kind: NotificationKind, uptime: TimeInterval) -> Bool {
        guard let last = lastPostedAt[kind] else { return true }
        // A time later than now (a clock that went backwards) counts as now,
        // so it can delay a notification by at most the interval.
        return uptime - min(last, uptime) >= kind.minimumInterval
    }

    // MARK: - Conditions

    /// The telemetry of the status's latest evaluation, if the policy acted
    /// on it; nil if it rejected it.
    static func usableSnapshot(_ status: ControllerStatus) -> BatterySnapshot? {
        guard let evaluatedAt = status.lastEvaluation else { return nil }
        return ChargingPolicy.usableSnapshot(status.snapshot, now: evaluatedAt)
    }

    /// The limit at which charging is held, as a read-back shows, with the
    /// charge then: CellKeeper holds charging at its limit
    /// (``PolicyState/holding``, not the sleep precaution); or, with macOS's
    /// Charge Limit set by CellKeeper below 100%, usable telemetry shows the
    /// battery at or above it, on external power and not charging. Nil
    /// otherwise.
    static func heldLimit(_ status: ControllerStatus) -> (limit: Int, percent: Int)? {
        guard let decision = status.decision, status.capabilities.availability.acceptsRequests,
              status.currentMode == decision.desiredMode
        else { return nil }
        if status.capabilities.isEnforcedByMacOS {
            guard decision.state == .osEnforcedLimit, case .nativeLimit(let limit) = decision.desiredMode, limit < 100,
                  let snapshot = usableSnapshot(status), snapshot.isOnExternalPower, snapshot.isCharging == false,
                  let percent = snapshot.chargePercent, percent >= limit
            else { return nil }
            return (limit, percent)
        }
        guard decision.state == .holding, decision.desiredMode == .inhibitCharging else { return nil }
        switch decision.reason {
        case .limitReached(let percent, _), .holdingAboveResumeThreshold(let percent, _):
            return (status.settings.chargeLimit, percent)
        default:
            return nil
        }
    }

    /// The limit the battery is seen charging toward from below, on external
    /// power, by usable telemetry: CellKeeper allows charging below its
    /// limit, or, with macOS's Charge Limit set by CellKeeper below 100%,
    /// the battery is below it and charging. Nil otherwise.
    static func chargingTowardLimit(_ status: ControllerStatus) -> Int? {
        guard let decision = status.decision, let snapshot = usableSnapshot(status), snapshot.isOnExternalPower,
              let percent = snapshot.chargePercent
        else { return nil }
        if status.capabilities.isEnforcedByMacOS {
            guard decision.state == .osEnforcedLimit, case .nativeLimit(let limit) = decision.desiredMode, limit < 100,
                  status.currentMode == decision.desiredMode, snapshot.isCharging == true, percent < limit
            else { return nil }
            return limit
        }
        let limit = status.settings.chargeLimit
        guard decision.state == .charging, limit < 100, percent < limit else { return nil }
        return limit
    }

    /// The opposite of a temperature pause, seen: a reading the policy
    /// accepts shows the temperature, temperature protection is on, and the
    /// latch is clear. A rejected reading (no battery, stale, incomplete), an
    /// unknown temperature or protection turned off also clear the latch,
    /// but show nothing about the temperature, so they leave the arming as
    /// it is.
    static func isTemperatureClearSeen(_ status: ControllerStatus) -> Bool {
        guard let snapshot = usableSnapshot(status), snapshot.temperatureCelsius?.isFinite == true,
              status.settings.temperatureProtection.isEnabled
        else { return false }
        return status.decision?.memory.temperatureTripped == false
    }

    /// A temperature pause the backend reports in effect.
    static func isTemperaturePauseInEffect(_ status: ControllerStatus) -> Bool {
        status.decision?.state == .temperaturePause
            && status.capabilities.availability.acceptsRequests
            && status.currentMode == .inhibitCharging
    }

    /// With macOS's Charge Limit: CellKeeper owes the user's own limit back
    /// and has not confirmed it, or cannot read its record of it. Otherwise:
    /// a restriction of CellKeeper's own may remain as far as read-backs
    /// establish, and either no read shows what is in effect, or CellKeeper
    /// wants normal charging and the read still shows the restriction.
    static func isRestoreUnconfirmed(_ status: ControllerStatus) -> Bool {
        if status.capabilities.isEnforcedByMacOS {
            return status.isOwnLimitRestorePending || status.nativeLimit?.isRecordUnreadable == true
        }
        switch status.ownRestriction {
        case .unconfirmed: return true
        case .inEffect: return status.decision?.desiredMode == .normal
        case .noneInEffect, .unknown, .noneKnown, .notCellKeepers, .unexplained: return false
        }
    }

    /// What resolved a restore warning, by positive evidence since it was
    /// posted; nil if nothing has. A read-back comes first.
    private static func resolution(since warned: RestoreEvidence, now evidence: RestoreEvidence, status: ControllerStatus) -> RestoreResolution? {
        if evidence.restoresConfirmed > warned.restoresConfirmed {
            return .restored(limit: status.nativeLimit?.lastRestoredLimit)
        }
        if evidence.releasesConfirmed > warned.releasesConfirmed {
            return .released
        }
        if evidence.adoptions > warned.adoptions {
            return .keptOutsideChange(status.adoptedChange)
        }
        if evidence.recordsDiscarded > warned.recordsDiscarded {
            return .recordDiscarded
        }
        return nil
    }
}

/// What resolved a restore warning (``NotificationKind/restoreResolved``).
enum RestoreResolution: Equatable {
    /// A read of macOS's Charge Limit showed the user's recorded limit.
    /// Whether deleting the record then succeeded is not claimed.
    case restored(limit: Int?)
    /// A read showed normal charging after CellKeeper's restriction.
    case released
    /// macOS reported a Charge Limit CellKeeper did not set, kept as the
    /// user's own (the change, if the status still holds it).
    case keptOutsideChange(AdoptedLimitChange?)
    /// The user discarded an unreadable record.
    case recordDiscarded
}
