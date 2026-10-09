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
/// ``restoreDefaults()`` and ``restoreDefaultsAndExit()``, which any session
/// may call at any time because they only move toward safety.
public struct HelperSession: Sendable {
    public let id: HelperSessionID
    private let engine: HelperEngine

    init(id: HelperSessionID, engine: HelperEngine) {
        self.id = id
        self.engine = engine
    }

    /// Introduces the client. A version outside
    /// ``HelperProtocolVersion/minimumSupportedClient`` through
    /// ``HelperProtocolVersion/current`` gets `incompatibleProtocol`. No side
    /// effects.
    public func hello(clientProtocolVersion: Int) async -> HelperHelloReply {
        await engine.hello(id, clientProtocolVersion: clientProtocolVersion)
    }

    /// The controls read back from the hardware, the leases, the
    /// interlocks and the last hardware error. Runs the engine's checks
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

    /// Ends this session's lease on `control` and clears the control.
    public func releaseLease(control: Int) async -> HelperStatus {
        await engine.releaseLease(id, control: control)
    }

    /// Activates or deactivates `control`. Activation needs this session's
    /// lease, the capability, no blocking interlock, and the rate limits.
    /// Deactivation needs no lease and is never rate-limited. A request for
    /// the state already in effect writes nothing.
    public func setControl(control: Int, active: Bool) async -> HelperStatus {
        await engine.setControl(id, control: control, active: active)
    }

    /// Ends every lease and returns every control to macOS's default,
    /// confirmed by read-back. A clean restore also clears the
    /// `externalModification` and `hardwareFault` interlocks.
    public func restoreDefaults() async -> HelperStatus {
        await engine.restoreDefaults(id)
    }

    /// Restores defaults, then shuts the engine down so the host can exit
    /// (for an update or an uninstall). Every later request gets
    /// `shuttingDown`.
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
