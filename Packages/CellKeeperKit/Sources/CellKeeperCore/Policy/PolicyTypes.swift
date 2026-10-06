import Foundation

/// The policy's externally visible state. Derived on every evaluation from
/// the inputs and ``PolicyMemory``.
public enum PolicyState: String, Sendable, Equatable, Codable {
    /// Management is turned off; macOS default charging.
    case unmanaged
    /// Inputs are missing, stale, or invalid; macOS default charging.
    case failSafe
    /// Charge fell to the safety floor; charging is always allowed until it
    /// recovers five points above the floor.
    case safetyFloor
    /// Running on battery. CellKeeper clears its own restrictions so that a
    /// later plug-in charges normally even if CellKeeper is no longer running.
    case onBattery
    /// Charging paused because the battery is too warm.
    case temperaturePause
    /// A temporary full charge is in progress.
    case fullChargeOverride
    /// Charging toward the charge limit.
    case charging
    /// Limit reached; charging paused until the resume threshold.
    case holding
    /// A one-shot discharge session is running the Mac from its battery down
    /// to the limit.
    case discharging
}

/// The concrete request the policy makes of the backend for this evaluation.
public enum ChargingAction: Sendable, Equatable {
    case enableCharging
    case disableCharging
    case requestDischarge
    /// The backend is already in the desired mode.
    case noAction
    /// The desired mode cannot or must not be requested.
    case refuse(RefusalReason)

    init(requesting mode: ChargeControlMode) {
        switch mode {
        case .normal: self = .enableCharging
        case .inhibitCharging: self = .disableCharging
        case .forceDischarge: self = .requestDischarge
        }
    }

    /// The mode this action asks the backend to apply, if any.
    public var requestedMode: ChargeControlMode? {
        switch self {
        case .enableCharging: .normal
        case .disableCharging: .inhibitCharging
        case .requestDischarge: .forceDischarge
        case .noAction, .refuse: nil
        }
    }
}

public enum RefusalReason: Sendable, Equatable, CustomStringConvertible {
    /// The backend cannot perform any control.
    case controlUnavailable(String)
    /// The backend cannot perform this particular mode.
    case modeUnsupported(ChargeControlMode)
    /// Repeated backend failures or an unexpected external change; only the
    /// fail-safe mode may be requested until the fault is cleared.
    case backendFaulted
    /// Too many restricting changes recently; retry at the given time.
    case rateLimited(retryAt: Date)

    public var description: String {
        switch self {
        case .controlUnavailable(let reason): "Control unavailable: \(reason)"
        case .modeUnsupported(let mode): "Backend does not support \(mode.rawValue)"
        case .backendFaulted: "Backend faulted; only normal charging may be requested"
        case .rateLimited(let retryAt): "Rate-limited until \(retryAt.formatted(date: .omitted, time: .standard))"
        }
    }
}

/// Why the policy chose its desired mode.
public enum DecisionReason: Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration([SettingsIssue])
    case telemetryUnavailable
    case telemetryStale(ageSeconds: Int)
    case batteryNotPresent
    case powerSourceUnknown
    case managementDisabled
    case onBatteryPower
    case belowSafetyFloor(percent: Int, floor: Int)
    case temperatureHigh(celsius: Double, pauseAt: Double)
    case temperatureCooling(celsius: Double, resumeAt: Double)
    case fullChargeRequested(percent: Int)
    case dischargingToLimit(percent: Int, limit: Int)
    case noChargeLimit
    case belowResumeThreshold(percent: Int, resumeThreshold: Int)
    case chargingTowardLimit(percent: Int, limit: Int)
    case limitReached(percent: Int, limit: Int)
    case holdingAboveResumeThreshold(percent: Int, resumeThreshold: Int)
    case sleepPrecaution(percent: Int, resumeThreshold: Int)

    public var description: String {
        switch self {
        case .invalidConfiguration(let issues):
            "Settings are invalid (\(issues.count) issue(s)); using macOS default charging."
        case .telemetryUnavailable:
            "Battery telemetry is unavailable; using macOS default charging."
        case .telemetryStale(let age) where age < 0:
            "Battery telemetry is timestamped \(-age)s in the future; using macOS default charging."
        case .telemetryStale(let age):
            "Battery telemetry is \(age)s old; using macOS default charging."
        case .batteryNotPresent:
            "No battery detected."
        case .powerSourceUnknown:
            "The power source is unknown; using macOS default charging."
        case .managementDisabled:
            "Charge management is off; macOS manages charging."
        case .onBatteryPower:
            "Running on battery; Cell Keeper's restrictions are cleared until power is reconnected."
        case .belowSafetyFloor(let percent, let floor):
            "Charge \(percent)% reached the \(floor)% safety floor; charging is always allowed until it recovers."
        case .temperatureHigh(let celsius, let pauseAt):
            "Battery at \(celsius.formatted(.number.precision(.fractionLength(1))))°C (pause at \(pauseAt.formatted())°C); charging paused."
        case .temperatureCooling(let celsius, let resumeAt):
            "Battery cooling at \(celsius.formatted(.number.precision(.fractionLength(1))))°C; charging resumes at \(resumeAt.formatted())°C."
        case .fullChargeRequested(let percent):
            "Temporary full charge requested (now \(percent)%)."
        case .dischargingToLimit(let percent, let limit):
            "Discharging from \(percent)% to the \(limit)% limit while plugged in."
        case .noChargeLimit:
            "Charge limit is 100%; charging normally."
        case .belowResumeThreshold(let percent, let resume):
            "Charge \(percent)% is at or below the resume threshold \(resume)%; charging."
        case .chargingTowardLimit(let percent, let limit):
            "Charging from \(percent)% toward the \(limit)% limit."
        case .limitReached(let percent, let limit):
            "Charge \(percent)% has reached the \(limit)% limit; charging paused."
        case .holdingAboveResumeThreshold(let percent, let resume):
            "Charge \(percent)% is above the resume threshold \(resume)%; charging stays paused."
        case .sleepPrecaution(let percent, let resume):
            "Mac is going to sleep at \(percent)% (resume threshold \(resume)%); charging paused to avoid overshooting the limit while asleep."
        }
    }
}

/// Non-fatal observations attached to a decision.
public enum PolicyNote: Sendable, Equatable, CustomStringConvertible {
    /// Temperature protection is enabled but no temperature reading exists,
    /// so it cannot trigger.
    case temperatureUnavailable
    /// A discharge session was requested but the backend cannot discharge.
    case dischargeUnsupported
    /// A temporary full charge is active but a higher-priority rule wins.
    case fullChargeSuppressed(by: PolicyState)

    public var description: String {
        switch self {
        case .temperatureUnavailable:
            "Temperature protection is enabled, but battery temperature is not available on this Mac."
        case .dischargeUnsupported:
            "The current backend cannot discharge while plugged in."
        case .fullChargeSuppressed(let state):
            "Temporary full charge is paused by \(state.rawValue)."
        }
    }
}

/// How a temporary override ended.
public enum OverrideEnd: String, Sendable, Equatable, CustomStringConvertible {
    /// Its goal was reached (100%/fully charged, or discharged to the limit).
    case completed
    /// Its maximum duration elapsed.
    case expired
    /// External power was disconnected.
    case unplugged
    /// A safety rule ended it (sleep, temperature, lost telemetry, a faulted
    /// or unsupported backend, or an invalid target).
    case interrupted

    public var description: String {
        switch self {
        case .completed: "completed"
        case .expired: "expired"
        case .unplugged: "ended because external power was disconnected"
        case .interrupted: "stopped by a safety rule"
        }
    }
}

/// A temporary, one-shot override of the normal policy. Overrides always
/// expire. Expiry is measured on a monotonic clock that keeps counting during
/// sleep, so wall-clock changes cannot extend or shorten it.
public struct ChargeOverride: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Charge to 100% once, then return to the normal policy.
        case fullCharge
        /// Run from the battery while plugged in until the charge limit is
        /// reached, then hold. Ends on unplug, sleep, or temperature pause.
        case dischargeToLimit
    }

    public var kind: Kind
    /// For a discharge session, the percentage confirmed by the user when it
    /// started. The session never discharges below it, nor below the current
    /// charge limit.
    public var targetPercent: Int?
    /// Wall-clock start, for display.
    public var startedAt: Date
    /// Wall-clock expiry estimate, for display.
    public var expiresAt: Date
    /// Monotonic expiry used by the policy (see ``PolicyInput/uptime``).
    public var expiresAtUptime: TimeInterval

    public static let defaultFullChargeDuration: TimeInterval = 12 * 60 * 60
    public static let defaultDischargeDuration: TimeInterval = 6 * 60 * 60
    public static let minimumDuration: TimeInterval = 60 * 60
    public static let maximumDuration: TimeInterval = 48 * 60 * 60

    public init(kind: Kind, targetPercent: Int? = nil, startedAt: Date, uptime: TimeInterval, duration: TimeInterval) {
        let clamped = min(max(duration.isFinite ? duration : 0, Self.minimumDuration), Self.maximumDuration)
        self.kind = kind
        self.targetPercent = targetPercent
        self.startedAt = startedAt
        self.expiresAt = startedAt.addingTimeInterval(clamped)
        self.expiresAtUptime = uptime + clamped
    }

    public static func fullCharge(at start: Date, uptime: TimeInterval, duration: TimeInterval = defaultFullChargeDuration) -> ChargeOverride {
        ChargeOverride(kind: .fullCharge, startedAt: start, uptime: uptime, duration: duration)
    }

    public static func dischargeToLimit(target: Int, at start: Date, uptime: TimeInterval, duration: TimeInterval = defaultDischargeDuration) -> ChargeOverride {
        ChargeOverride(kind: .dischargeToLimit, targetPercent: target, startedAt: start, uptime: uptime, duration: duration)
    }
}

/// The policy's only memory between evaluations: three hysteresis latches.
public struct PolicyMemory: Sendable, Equatable {
    /// Set when the charge reaches the limit; cleared when it falls to the
    /// resume threshold. While set, charging stays paused.
    public var limitReached: Bool
    /// Set when the temperature reaches the pause threshold; cleared when it
    /// falls to the resume threshold or becomes unknown.
    public var temperatureTripped: Bool
    /// Set when the charge falls to the safety floor; cleared once it is five
    /// points above the floor.
    public var belowSafetyFloor: Bool

    public init(limitReached: Bool = false, temperatureTripped: Bool = false, belowSafetyFloor: Bool = false) {
        self.limitReached = limitReached
        self.temperatureTripped = temperatureTripped
        self.belowSafetyFloor = belowSafetyFloor
    }
}

/// Everything the policy needs to make a decision. No hidden inputs.
public struct PolicyInput: Sendable, Equatable {
    /// Wall-clock time, used for telemetry age and display.
    public var now: Date
    /// Monotonic seconds that keep counting during sleep, used for override
    /// expiry and rate limiting so that clock changes cannot affect them.
    public var uptime: TimeInterval
    public var settings: ChargingSettings
    /// Latest telemetry, or nil if it could not be read.
    public var snapshot: BatterySnapshot?
    public var activeOverride: ChargeOverride?
    public var capabilities: ControlCapabilities
    /// The backend's current mode, or nil if unknown.
    public var currentMode: ChargeControlMode?
    public var memory: PolicyMemory
    /// True after repeated backend failures or an unexpected external change.
    public var isBackendFaulted: Bool
    /// Uptime values of recent restricting requests, for rate limiting.
    public var recentRestrictingRequests: [TimeInterval]
    /// True when the Mac has announced that it is about to sleep.
    public var isSleepImminent: Bool

    public init(
        now: Date,
        uptime: TimeInterval,
        settings: ChargingSettings,
        snapshot: BatterySnapshot?,
        activeOverride: ChargeOverride? = nil,
        capabilities: ControlCapabilities,
        currentMode: ChargeControlMode?,
        memory: PolicyMemory = PolicyMemory(),
        isBackendFaulted: Bool = false,
        recentRestrictingRequests: [TimeInterval] = [],
        isSleepImminent: Bool = false
    ) {
        self.now = now
        self.uptime = uptime
        self.settings = settings
        self.snapshot = snapshot
        self.activeOverride = activeOverride
        self.capabilities = capabilities
        self.currentMode = currentMode
        self.memory = memory
        self.isBackendFaulted = isBackendFaulted
        self.recentRestrictingRequests = recentRestrictingRequests
        self.isSleepImminent = isSleepImminent
    }
}

/// The result of one policy evaluation.
public struct PolicyDecision: Sendable, Equatable {
    public var state: PolicyState
    /// The mode CellKeeper wants, whether or not it can be applied.
    public var desiredMode: ChargeControlMode
    /// What to ask of the backend now.
    public var action: ChargingAction
    public var reason: DecisionReason
    public var notes: [PolicyNote]
    /// Memory to pass into the next evaluation.
    public var memory: PolicyMemory
    /// Set when the active override ended during this evaluation; the caller
    /// should clear it.
    public var overrideEnded: OverrideEnd?
}
