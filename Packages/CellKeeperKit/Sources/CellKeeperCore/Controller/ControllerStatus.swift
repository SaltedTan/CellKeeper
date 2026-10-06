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
    case manual
}

/// The result of the most recent attempt to act on a decision.
public struct ExecutionRecord: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        /// Real hardware state changed and was confirmed.
        case applied
        /// Recorded by a simulated backend; hardware unchanged.
        case simulated
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
    public var decision: PolicyDecision?
    public var lastExecution: ExecutionRecord?
    public var consecutiveFailures: Int
    public var isBackendFaulted: Bool
    public var events: [ControlEvent]
    public var lastEvaluation: Date?
}
