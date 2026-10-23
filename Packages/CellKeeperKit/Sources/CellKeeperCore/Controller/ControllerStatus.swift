import Foundation
import os

/// Why an evaluation ran. Recorded for diagnostics only; the policy does not
/// depend on it. Its description says when the evaluation ran, in plain
/// words, for the activity log.
public enum EvaluationTrigger: String, Sendable, CaseIterable, CustomStringConvertible {
    case launch
    case powerSourceChanged
    case periodic
    case settingsChanged
    case overrideChanged
    case backendChanged
    case willSleep
    case didWake
    /// The re-read shortly after waking, once macOS's battery estimates are
    /// valid again. Unlike ``didWake`` it never clears a sleep announcement:
    /// the Mac may have been told to sleep again since it woke.
    case postWakeReread
    /// The system clock or time zone changed, so a scheduled full charge's
    /// window is checked again at once.
    case clockChanged
    /// The user set or cancelled a scheduled full charge.
    case scheduleChanged
    case manual

    /// True for evaluations the system started, as opposed to a user action.
    /// Only automatic evaluations wait before retrying a failed restore.
    public var isAutomatic: Bool {
        switch self {
        case .launch, .powerSourceChanged, .periodic, .willSleep, .didWake, .postWakeReread, .clockChanged: true
        case .settingsChanged, .overrideChanged, .backendChanged, .scheduleChanged, .manual: false
        }
    }

    public var description: String {
        switch self {
        case .launch: "at launch"
        case .powerSourceChanged: "after a power source change"
        case .periodic: "at a periodic check"
        case .settingsChanged: "after a settings change"
        case .overrideChanged: "after you started or cancelled a full charge or discharge"
        case .backendChanged: "after a backend change"
        case .willSleep: "before sleep"
        case .didWake: "after waking from sleep"
        case .postWakeReread: "at the re-read after waking"
        case .clockChanged: "after a clock or time zone change"
        case .scheduleChanged: "after a schedule change"
        case .manual: "at a check you asked for"
        }
    }
}

/// The result of the most recent attempt to act on a decision.
public struct ExecutionRecord: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        /// Real hardware state changed and was confirmed.
        case applied
        /// The requested state was already in effect; nothing was changed.
        case unchanged
        /// Recorded by a simulated backend; hardware unchanged.
        case simulated
        /// macOS's Charge Limit had been changed outside CellKeeper; the new
        /// value was kept as the user's own and nothing was changed.
        case adoptedOutsideChange
        /// macOS's Charge Limit could not be judged (on battery power, or
        /// before power settled), so nothing is confirmed yet and nothing
        /// failed: `written` says whether the change was made
        /// (``ControlOutcome/awaitingConfirmation``) or waits
        /// (``ControlOutcome/deferred``).
        case deferred(written: Bool)
        case failed(String)
        case refused(RefusalReason)
    }

    public var date: Date
    public var action: ChargingAction
    public var result: Result
}

/// An entry in the in-memory activity log shown to the user. Every event is
/// also written to unified logging.
public struct ControlEvent: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case telemetry
        case decision
        case request
        case result
        case failure
        case safety
        case settings
        case override
        /// A guided calibration's steps, requests and end.
        case calibration

        var logger: Logger {
            switch self {
            case .telemetry: CellKeeperLog.telemetry
            case .decision: CellKeeperLog.policy
            case .request, .result, .failure: CellKeeperLog.backend
            case .safety: CellKeeperLog.safety
            case .settings, .override, .calibration: CellKeeperLog.settings
            }
        }
    }

    public var id: Int
    public var date: Date
    public var kind: Kind
    public var message: String
}

/// A consistent, read-only view of the controller's state for the UI.
public struct ControllerStatus: Sendable, Equatable {
    public var snapshot: BatterySnapshot?
    public var telemetryError: String?
    public var settings: ChargingSettings
    public var activeOverride: ChargeOverride?
    public var backend: BackendDescriptor
    public var capabilities: ControlCapabilities
    /// The backend's reported mode, or nil if unknown.
    public var currentMode: ChargeControlMode?
    /// The non-normal mode CellKeeper may have put into effect on this
    /// backend and has not seen end; nil if none. Set before a non-normal
    /// request is sent; cleared only by a read taken after it showing normal
    /// charging, or by the backend's records showing positively that nothing
    /// in effect is CellKeeper's. Asking for `.normal`, a fault, an attempted
    /// restore, a restarted helper or losing track of ownership does not
    /// clear it.
    public var ownRestrictionMode: ChargeControlMode?
    /// Whether what the last read reported is CellKeeper's by the backend's
    /// records (``ChargingBackend/isReportedModeOwn()``): false only on
    /// positive evidence that nothing in effect is CellKeeper's; nil if
    /// unknown.
    public var isReportedModeOwn: Bool?
    /// macOS's Charge Limit as seen by a native-limit backend; nil otherwise.
    public var nativeLimit: NativeLimitStatus?
    /// The latest change to macOS's Charge Limit made outside CellKeeper and
    /// adopted as the user's own limit; cleared when management is turned
    /// on again.
    public var adoptedChange: AdoptedLimitChange?
    /// How many outside changes have been adopted in this session, so the
    /// app can react to each one exactly once.
    public var adoptionCount: Int
    /// Why the latest settings change that turned management on was refused,
    /// for the user; nil if it was not refused, or the latest change did not
    /// turn management on.
    public var managementRefusal: String?
    /// A backend the user switched to, waiting until `.normal` is confirmed
    /// on the current one.
    public var pendingBackend: BackendDescriptor?
    public var decision: PolicyDecision?
    public var lastExecution: ExecutionRecord?
    public var consecutiveFailures: Int
    public var isBackendFaulted: Bool
    /// How many times a backend became faulted in this session, counting
    /// faults that began and were cleared between two statuses. Only grows.
    public var faultsRaised: Int
    /// With a backend that switches charging itself: how many reads in this
    /// session showed normal charging after a restriction of CellKeeper's
    /// own may have been in effect, each ending ``ownRestrictionMode``. A
    /// release confirmed by read-back, counted even if a later request in
    /// the same command restricted charging again. Only grows; not counted
    /// for macOS's Charge Limit (see ``NativeLimitStatus/restoresConfirmed``).
    public var releasesConfirmed: Int
    public var events: [ControlEvent]
    public var lastEvaluation: Date?
    /// The scheduled full charge that is armed, if any. It is removed when
    /// it starts, when its window passes, and when the user cancels it.
    public var fullChargeSchedule: FullChargeSchedule? = nil
    /// Why the armed schedule, now due, cannot start yet; nil if it is not
    /// due or no reason was seen in this run.
    public var fullChargeScheduleWait: FullChargeScheduleWait? = nil
    /// What became of the latest schedule, until the user dismisses it or
    /// sets a new one.
    public var fullChargeScheduleOutcome: FullChargeScheduleOutcome? = nil
    /// The weekly full charge in use and the record of the latest occurrence
    /// handled, if one is in use.
    public var weeklyFullCharge: WeeklyFullChargeSchedule? = nil
    /// The weekly occurrence that is due but cannot start yet, and why.
    /// Never the next one.
    public var weeklyFullChargeDue: WeeklyFullChargeDue? = nil
    /// The first weekly occurrence that starts after the latest evaluation,
    /// computed in the time zone of that evaluation.
    public var weeklyFullChargeNext: WeeklyFullChargeOccurrence? = nil
    /// What became of the latest weekly occurrence handled, until the user
    /// dismisses it or saves a weekly schedule; kept after removal.
    public var weeklyFullChargeOutcome: WeeklyFullChargeOutcome? = nil
    /// Set while the stored weekly full charge could not be brought in line
    /// with the one in use (or its removal); CellKeeper keeps using what is
    /// in memory and tries again at every check. Until it succeeds, a
    /// relaunch may lose the latest change, or start an occurrence handled
    /// in this run once more inside its window.
    public var weeklyFullChargeStoreProblem: WeeklyFullChargeStoreProblem? = nil
    /// The override that most recently ended by itself in this session, as
    /// it was when it ended, with how: the policy ended it (also a full
    /// charge a schedule started in the same evaluation, in place of the
    /// override shown before), or its monotonic deadline had passed when a
    /// schedule replaced it. A cancellation, turning management off, a kept
    /// outside change, or a schedule replacing a live override ends one
    /// without that, and is not recorded here.
    public var lastEndedOverride: EndedOverride? = nil
    /// How many overrides have ended by themselves in this session
    /// (``lastEndedOverride``), counting ones that began and ended between
    /// two statuses. Only grows.
    public var overridesEnded: Int = 0
    /// The guided calibration: the session in progress, if any, and the
    /// latest one that ended.
    public var calibration: CalibrationStatus = CalibrationStatus()
}

/// An override that ended by itself, and how.
public struct EndedOverride: Sendable, Equatable {
    public var override: ChargeOverride
    public var end: OverrideEnd

    public init(override: ChargeOverride, end: OverrideEnd) {
        self.override = override
        self.end = end
    }
}

extension ControllerStatus {
    /// True while CellKeeper owes the user's own Charge Limit back and has not
    /// confirmed it: a restore failed or could not be checked yet, possibly in
    /// an earlier session.
    public var isOwnLimitRestorePending: Bool {
        guard nativeLimit?.ownerLimit != nil else { return false }
        return nativeLimit?.isRestoreUnfinished == true || decision?.reason == .releaseRequired(.restoreUnfinished)
    }

    /// True while CellKeeper was asked to give the user's own Charge Limit
    /// back and wrote nothing, because macOS's report could not be judged:
    /// the restore waits for power. Unlike ``isOwnLimitRestorePending`` this
    /// is not a warning: it ends at the next judged read on power, when the
    /// restore is written, or when it is no longer wanted.
    public var isOwnLimitRestoreWaitingForPower: Bool {
        nativeLimit?.isRestoreWaitingForPower == true
    }

    /// With macOS's Charge Limit: CellKeeper's limit is in effect and
    /// confirmed, and nothing failed, was refused, or is pending, so a
    /// summary of the Charge Limit says all there is to say. On battery
    /// power that is the limit last confirmed, which the summary says
    /// macOS applies only on power (``NativeLimitStatus/readDeferral``).
    public var isNativeLimitSettled: Bool {
        guard capabilities.isEnforcedByMacOS, capabilities.availability.acceptsRequests,
              !isBackendFaulted, pendingBackend == nil,
              let decision, decision.state == .osEnforcedLimit, decision.notes.isEmpty,
              currentMode == decision.desiredMode
        else { return false }
        switch lastExecution?.result {
        case .failed?, .refused?: return false
        default: return true
        }
    }
}
