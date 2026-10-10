import CellKeeperHelperCore
import Foundation

/// What serves the daemon's clients: ``XPCFrontend``, the NSXPC listener on
/// the Mach service ``HelperServiceName/machService``, or ``NoFrontend``.
///
/// A frontend that accepts connections from other processes must check
/// every connection against a code-signing requirement for CellKeeper's app
/// (`NSXPCListener.setConnectionCodeSigningRequirement(_:)`, macOS 13+)
/// before it opens a session for it, and must refuse to start (throw) when
/// it has no requirement to check. It must never serve a connection it has
/// not checked, in any build: an ad-hoc or development build checks a
/// requirement of its own, never none (research note 04, §2; `safety.md`
/// precondition 4). The daemon starts no frontend that throws.
///
/// The frontend opens one ``HelperSession`` per connection, forwards each
/// connection's requests in order with their raw wire values, invalidates
/// the session when the connection ends for any reason, and closes the
/// connection when the engine revokes its session
/// (``HelperEvent/sessionRevoked(_:)``). See ``HelperEngine``.
///
/// The daemon calls the frontend from a task of its own, never on the
/// daemon's actor, so a frontend that blocks cannot keep the daemon from
/// shutting down; it still has to return promptly.
public protocol HelperFrontend: Sendable {
    /// Starts serving clients on `engine`. The daemon calls it once, only
    /// after `engine.start()` has returned (defaults restored and read back,
    /// R2), and never once shutdown has begun. Throws if it cannot serve
    /// safely. `log` is the daemon's audit log: writing to it never blocks.
    func start(serving engine: HelperEngine, log: any HelperDaemonLog) throws

    /// An event of the engine, passed on by the daemon's event sink, so the
    /// frontend can close the connection of a session the engine revokes.
    /// Called synchronously, on the engine's executor: it must return at
    /// once and never call into the engine. The default does nothing.
    func handle(_ event: HelperEvent)

    /// Stops serving, and confirms that it has.
    ///
    /// A request is *accepted* once the frontend has admitted it to be
    /// served (for ``XPCFrontend``: put it on its connection's queue). A
    /// request that arrives after the stop began is not admitted and gets no
    /// reply; its client sees the connection end. A reply is *sent* once the
    /// transport has confirmed that the send completed: for NSXPC, a send
    /// barrier (`NSXPCConnection.scheduleSendBarrierBlock(_:)`) scheduled
    /// after the reply has run. That confirms the send, not that the client
    /// received it; receipt would need an acknowledgement, which the
    /// protocol does not have. In this order, `stop()`:
    /// 1. Stops accepting connections and requests.
    /// 2. Waits until every accepted request has been answered by the engine
    ///    and its reply sent. The reply to a `restoreDefaultsAndExit` is sent
    ///    before that client's session is invalidated.
    /// 3. Invalidates every session it opened (``HelperSession/invalidate()``)
    ///    and closes every connection.
    ///
    /// A connection that ends on its own meanwhile (its client goes away,
    /// the engine revokes its session) ends as it always does; whatever of it
    /// had not run never runs.
    ///
    /// It returns true only once all of that is done and the stop itself cut
    /// nothing off, so that nothing it accepted can change the engine's state
    /// afterwards. Otherwise it returns false, never true: an implementation
    /// that discards accepted requests, or invalidates a connection before
    /// its replies are sent (at a deadline, for example), returns false. A
    /// frontend that never started has nothing to stop and returns true.
    ///
    /// The daemon calls it once, when shutdown begins (SIGTERM, a client's
    /// `restoreDefaultsAndExit`, or a seam that could not start), after any
    /// `start(serving:log:)` in progress has returned, and waits for it
    /// only within its shutdown budget: it exits with 0 only after a stop
    /// that returned true, followed by a check that defaults are confirmed.
    func stop() async -> Bool
}

extension HelperFrontend {
    public func handle(_ event: HelperEvent) {}
}

/// The frontend of a build without a client listener: it serves nobody and
/// says so. The daemon still restores defaults at start and on SIGTERM,
/// handles sleep and keeps its audit log.
public struct NoFrontend: HelperFrontend {
    public init() {}

    public func start(serving engine: HelperEngine, log: any HelperDaemonLog) throws {
        log.write(.notice, .xpc, "No client listener is available in this build: serving nobody.")
    }

    /// Nothing was accepted, so there is nothing to wait for.
    public func stop() async -> Bool {
        true
    }
}
