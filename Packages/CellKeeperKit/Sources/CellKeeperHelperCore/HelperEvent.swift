/// Why the engine cleared a control or restored defaults.
public enum HelperChangeReason: Sendable, Equatable {
    /// The engine started (rule R2).
    case start
    /// A client deactivated the control or asked for defaults.
    case clientRequest
    case leaseReleased
    case leaseExpired
    /// The lease holder's connection ended (rules R1, R3).
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

/// Something the engine did or refused, for the helper's audit log. The
/// host writes each event to unified logging.
public enum HelperEvent: Sendable, Equatable {
    case started(capabilities: HelperCapabilities, isSimulated: Bool)
    case sessionOpened(HelperSessionID)
    case sessionInvalidated(HelperSessionID)
    case leaseGranted(HelperSessionID, HelperControl, seconds: Int)
    case leaseRenewed(HelperSessionID, HelperControl, seconds: Int)
    case leaseEnded(HelperSessionID, HelperControl, HelperLeaseEndReason)
    /// The control was set and confirmed by read-back.
    case activated(HelperControl, by: HelperSessionID)
    /// The control was cleared and confirmed by read-back.
    case deactivated(HelperControl, HelperChangeReason)
    /// Defaults were restored, or found already in effect, and confirmed by
    /// read-back.
    case restored(HelperChangeReason)
    /// Defaults could not be restored or confirmed; the engine is faulted.
    case restoreFailed(HelperChangeReason)
    /// A control call failed or read back the wrong state. See
    /// ``HelperHardwareError``.
    case hardwareError(code: Int)
    case interlocksRaised(HelperInterlocks)
    case interlocksCleared(HelperInterlocks)
    /// A request was refused. A session that exceeds its request budget is
    /// reported once, until it makes a request within its budget again.
    case requestRejected(HelperSessionID, HelperRequestKind, HelperStatus)
    /// The engine serves nothing more and the host may exit. `restored`
    /// says whether defaults were confirmed first.
    case shuttingDown(HelperChangeReason, restored: Bool)
}
