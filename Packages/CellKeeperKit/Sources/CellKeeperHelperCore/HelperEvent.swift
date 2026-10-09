/// Why the engine cleared a control or restored defaults.
public enum HelperChangeReason: Sendable, Equatable {
    /// The engine started (rule R2).
    case start
    /// A client deactivated the control or asked for defaults.
    case clientRequest
    case leaseReleased
    case leaseExpired
    /// The lease holder's connection ended, or the engine revoked the
    /// session (rules R1, R3).
    case sessionInvalidated
    /// These interlocks require the control cleared.
    case interlock(HelperInterlocks)
    /// A write or the read-back after it failed.
    case writeFailed
    /// After a write, the read-back did not show the state written.
    case readBackMismatch
    /// The state could not be read back, so it is unknown (rule R1).
    case readBackFailed
    /// The read-back differed from what the engine had set (rule R27).
    case externalModification
    /// An earlier restore failed and is being retried.
    case faultRetry
    /// An activation was refused by the activation limits (rule R13).
    case activationLimited
    /// A client asked the helper to restore defaults and exit.
    case exitRequested
    /// The host is terminating the helper (rule R4).
    case terminate
}

/// Why a lease ended.
public enum HelperLeaseEndReason: Sendable, Equatable {
    case released
    case expired
    case restoredDefaults
    /// The session's connection ended, or the engine revoked it.
    case sessionInvalidated
    case shutdown
}

/// The requests a session can make, for audit.
public enum HelperRequestKind: Sendable, Equatable {
    case hello
    case readState
    case acquireOrRenewLease
    case releaseLease
    case setControl
    case restoreDefaults
    case restoreDefaultsAndExit
}

/// One write to the hardware and what came of it (research note 04, §3.7).
public struct HelperWriteRecord: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case control(HelperControl, active: Bool)
        case restoreDefaults
    }

    public enum Outcome: Sendable, Equatable {
        /// The read-back showed the state written.
        case confirmed
        /// The write threw. It is not read back; recovery is the restore of
        /// defaults that follows.
        case threw(code: Int)
        /// The write returned, but the read-back after it failed.
        case readBackFailed(code: Int)
        /// The write returned, but the read-back showed another state.
        case readBackMismatch
    }

    public var target: Target
    public var outcome: Outcome
    /// The controls read back after the write; nil if not read or unknown.
    public var readBack: Set<HelperControl>?

    public init(target: Target, outcome: Outcome, readBack: Set<HelperControl>?) {
        self.target = target
        self.outcome = outcome
        self.readBack = readBack
    }
}

/// An activation write, for the activation limits (rule R13). The host
/// persists these so that a relaunched helper keeps enforcing the limits.
public struct HelperActivationRecord: Sendable, Equatable, Codable {
    public var control: HelperControl
    /// When the write was attempted, on the engine's monotonic clock.
    public var uptime: Double

    public init(control: HelperControl, uptime: Double) {
        self.control = control
        self.uptime = uptime
    }
}

/// Something the engine did or refused, for the helper's audit log. The
/// host writes each event to unified logging.
public enum HelperEvent: Sendable, Equatable {
    case started(capabilities: HelperCapabilities, isSimulated: Bool)
    case sessionOpened(HelperSessionID)
    case sessionInvalidated(HelperSessionID)
    /// The session kept exceeding its request budget and has been ended:
    /// its controls are cleared and its leases ended. The transport should
    /// close the connection.
    case sessionRevoked(HelperSessionID)
    case leaseGranted(HelperSessionID, HelperControl, seconds: Int)
    case leaseRenewed(HelperSessionID, HelperControl, seconds: Int)
    case leaseEnded(HelperSessionID, HelperControl, HelperLeaseEndReason)
    /// Every hardware write attempt, client-driven or internal.
    case write(HelperWriteRecord)
    /// An activation write is about to be attempted; it counts toward the
    /// activation limits. The host persists it (see
    /// ``HelperEngine/activationHistory``).
    case activationRecorded(HelperActivationRecord)
    /// The control was set and confirmed by read-back.
    case activated(HelperControl, by: HelperSessionID)
    /// The control was cleared and confirmed by read-back.
    case deactivated(HelperControl, HelperChangeReason)
    /// Defaults were restored, or found already in effect, and confirmed by
    /// read-back.
    case restored(HelperChangeReason)
    /// Defaults could not be restored or confirmed; a restore is owed.
    case restoreFailed(HelperChangeReason)
    /// A control call failed or read back the wrong state. See
    /// ``HelperHardwareError``.
    case hardwareError(code: Int)
    case interlocksRaised(HelperInterlocks)
    case interlocksCleared(HelperInterlocks)
    /// A request was refused. A session that exceeds its request budget is
    /// reported once, until it makes a request within its budget again.
    case requestRejected(HelperSessionID, HelperRequestKind, HelperStatus)
    /// Shutdown was requested: the engine serves only restores from now on.
    /// `restored` says whether defaults were confirmed at once.
    case shuttingDown(HelperChangeReason, restored: Bool)
    /// Defaults are confirmed during shutdown: the host may exit now.
    case safeToExit
}
