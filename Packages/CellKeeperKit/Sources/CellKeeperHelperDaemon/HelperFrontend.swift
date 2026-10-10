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

    /// Stops serving, by `deadline`, and says whether it can prove that it
    /// did so with everything it accepted answered.
    ///
    /// A request is *accepted* once the frontend has admitted it to be
    /// served (for ``XPCFrontend``: put it on its connection's queue). A
    /// request that arrives after the stop began is not admitted and gets no
    /// reply; its client sees the connection end. A reply is *sent* once the
    /// transport has confirmed that the send completed: for NSXPC, a send
    /// barrier (`NSXPCConnection.scheduleSendBarrierBlock(_:)`) scheduled
    /// after the reply has run while the connection was valid. That confirms
    /// the send, not that the client received it; receipt would need an
    /// acknowledgement, which the protocol does not have. In this order, it:
    /// 1. Stops accepting connections and requests.
    /// 2. Waits until every accepted request has been answered by the engine
    ///    and its reply sent. The reply to a `restoreDefaultsAndExit` is sent
    ///    before that client's session is invalidated.
    /// 3. Invalidates every session it opened (``HelperSession/invalidate()``)
    ///    and closes every connection.
    ///
    /// It returns true only if it can prove all of that for every
    /// connection it was still serving when the stop began: every request
    /// that connection ever accepted answered, every reply's send confirmed,
    /// the connection closed only after that, and its session invalidated.
    /// That a connection's work has ended is not that proof. So it returns
    /// false, never true, if an accepted request was discarded (one queued
    /// behind a revocation, which never runs; one queued when its client
    /// went away; one cut off at the deadline), if a reply's send was never
    /// confirmed, or if it is done only after `deadline`. A frontend that
    /// never started has nothing to stop and returns true.
    ///
    /// `deadline` is absolute, on the daemon's clock, and fixed when
    /// shutdown began: time spent before the stop starts (a slow start, a
    /// task scheduled late) is taken from it, never added. At the deadline
    /// the frontend cuts off whatever remains and returns false promptly,
    /// without waiting for a request still in the engine.
    ///
    /// The daemon calls it once, when shutdown begins (SIGTERM, a client's
    /// `restoreDefaultsAndExit`, or a seam that could not start), after any
    /// `start(serving:log:)` in progress has returned, with the shutdown's
    /// deadline less ``HelperDaemon/finalisationReserve``. It counts the stop
    /// as confirmed only if it returned true before that deadline, and exits
    /// with 0 only after a confirmed stop, followed by a check that defaults
    /// are confirmed.
    func stop(by deadline: HelperDaemonDeadline) async -> Bool
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
    public func stop(by deadline: HelperDaemonDeadline) async -> Bool {
        true
    }
}
