import Foundation
import os

/// Why an evaluation ran. Recorded for diagnostics only; the policy does not
/// depend on it.
public enum EvaluationTrigger: String, Sendable {
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
    case manual

    /// True for evaluations the system started, as opposed to a user action.
    /// Only automatic evaluations wait before retrying a failed restore.
    public var isAutomatic: Bool {
        switch self {
        case .launch, .powerSourceChanged, .periodic, .willSleep, .didWake, .postWakeReread: true
        case .settingsChanged, .overrideChanged, .backendChanged, .manual: false
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

        var logger: Logger {
            switch self {
            case .telemetry: CellKeeperLog.telemetry
            case .decision: CellKeeperLog.policy
            case .request, .result, .failure: CellKeeperLog.backend
            case .safety: CellKeeperLog.safety
            case .settings, .override: CellKeeperLog.settings
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
    public var events: [ControlEvent]
    public var lastEvaluation: Date?
}
