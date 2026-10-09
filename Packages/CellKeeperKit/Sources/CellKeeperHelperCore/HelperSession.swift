/// Identifies one client connection to the engine.
public struct HelperSessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public var description: String { "session \(rawValue)" }
}

/// One client connection's requests to a ``HelperEngine``.
///
/// A transport opens one session per connection with
/// ``HelperEngine/openSession()``, forwards each request with its arguments
/// unchanged, and calls ``invalidate()`` when the connection ends for any
/// reason. Leases belong to the session, so invalidating it clears what it
/// set. Arguments arrive as raw wire values and are validated by the engine.
///
/// `hello` must succeed before any other request is served, except
/// ``restoreDefaults()`` and ``restoreDefaultsAndExit()``: they only move
/// toward safety, so any live session may call them, also before the engine
/// has started and during shutdown, and the request budget does not refuse
/// them. A session that keeps exceeding its request budget is revoked
/// (``HelperEvent/sessionRevoked(_:)``); the request that revokes it gets
/// `rateLimited`, even a restore, and the transport should then close the
/// connection. A session that was invalidated or revoked gets
/// `notIntroduced` for its restores, and for everything else `notReady`,
/// `shuttingDown` or `notIntroduced`, depending on the engine's phase.
public struct HelperSession: Sendable {
    public let id: HelperSessionID
    private let engine: HelperEngine

    init(id: HelperSessionID, engine: HelperEngine) {
        self.id = id
        self.engine = engine
    }

    /// Introduces the client. A version outside
    /// ``HelperProtocolVersion/minimumSupportedClient`` through
    /// ``HelperProtocolVersion/current`` gets `incompatibleProtocol`. Any
    /// hello that does not return `ok` withdraws the introduction. No other
    /// side effects.
    public func hello(clientProtocolVersion: Int) async -> HelperHelloReply {
        await engine.hello(id, clientProtocolVersion: clientProtocolVersion)
    }

    /// The controls read back from the hardware, the leases, the interlocks,
    /// each control's latest change (generation, cause, interlocks and
    /// session), and the last hardware error with the number of errors so
    /// far. Runs the engine's checks
    /// first, as every request except `hello` and the restores does.
    public func readState() async -> HelperStateReply {
        await engine.readState(id)
    }

    /// Grants or renews this session's lease on `control` (a raw
    /// ``HelperControl``) for `seconds`, clamped to the control's
    /// ``HelperControl/maximumLeaseSeconds``. Refused while another session
    /// holds any lease.
    public func acquireOrRenewLease(control: Int, seconds: Int) async -> HelperLeaseReply {
        await engine.acquireOrRenewLease(id, control: control, seconds: seconds)
    }

    /// Ends this session's lease on `control` and clears the control. Not
    /// refused by the request budget, unless the request revokes the
    /// session.
    public func releaseLease(control: Int) async -> HelperStatus {
        await engine.releaseLease(id, control: control)
    }

    /// Activates or deactivates `control`. Activation needs this session's
    /// lease (still valid when the write is made), the capability, no
    /// blocking interlock, and the activation limits; refused by those
    /// limits, it restores defaults. Deactivation needs no lease, is not
    /// refused by the activation limits or the request budget (unless the
    /// request revokes the session), and clears only what the engine set. A
    /// request for the state already in effect writes nothing.
    public func setControl(control: Int, active: Bool) async -> HelperStatus {
        await engine.setControl(id, control: control, active: active)
    }

    /// Deactivates `control` (a raw ``HelperControl``) only if its latest
    /// change is still the one the caller names: `generation`
    /// (``HelperControlChange/generation``) on the helper process
    /// `helperInstance` (``HelperHelloReply/helperInstance``). The engine
    /// compares them after its checks and right before it clears, with
    /// nothing in between; on a mismatch it writes nothing and returns
    /// `controlChanged`. Otherwise it is a deactivation like
    /// `setControl(control, false)`: no lease needed, not refused by the
    /// request budget (unless the request revokes the session), and it
    /// clears only what the engine set. A client releasing a control it set
    /// uses this, so it never clears a control that has changed hands since
    /// it last looked.
    public func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64) async -> HelperStatus {
        await engine.clearControlIfUnchanged(id, control: control, generation: generation, helperInstance: helperInstance)
    }

    /// Ends every lease and returns every control to macOS's default,
    /// confirmed by read-back. It reads the hardware afresh and writes
    /// nothing if the read-back shows defaults and no restore is owed; an
    /// owed restore is written even if defaults may already be in effect. A
    /// clean result also clears the `externalModification`, `hardwareFault`
    /// and `writeFailed` interlocks.
    public func restoreDefaults() async -> HelperStatus {
        await engine.restoreDefaults(id)
    }

    /// Restores defaults, then shuts the engine down so the host can exit
    /// (for an update or an uninstall). From then on, every request except
    /// a restore gets `shuttingDown`. Returns `hardwareError` if defaults
    /// were not confirmed; the engine keeps retrying, and the host waits for
    /// ``HelperEngine/isSafeToExit``. During shutdown it acts like
    /// ``restoreDefaults()``.
    public func restoreDefaultsAndExit() async -> HelperStatus {
        await engine.restoreDefaultsAndExit(id)
    }

    /// Ends the session: the client disconnected, crashed or quit. Every
    /// control it holds is cleared at once and its leases end. Later
    /// requests on it get `notIntroduced`.
    public func invalidate() async {
        await engine.invalidate(id)
    }
}
