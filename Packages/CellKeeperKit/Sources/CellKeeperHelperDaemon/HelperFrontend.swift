import CellKeeperHelperCore
import Foundation

/// What serves the daemon's clients: the NSXPC listener on the Mach service
/// ``HelperServiceName/machService`` in a later phase, ``NoFrontend`` today.
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
public protocol HelperFrontend: Sendable {
    /// Starts serving clients on `engine`. The daemon calls it once, only
    /// after `engine.start()` has returned (defaults restored and read back,
    /// R2), and never once shutdown has begun. Throws if it cannot serve
    /// safely.
    func start(serving engine: HelperEngine) throws

    /// Stops serving, and confirms that it has. In this order:
    /// 1. Stops accepting connections, and refuses every request that
    ///    arrives from now on, on any connection.
    /// 2. Waits until every request it has already accepted has been
    ///    answered by the engine and the reply delivered to its client. The
    ///    reply to a `restoreDefaultsAndExit` is delivered before that
    ///    client's session is invalidated.
    /// 3. Invalidates every session it opened (``HelperSession/invalidate()``)
    ///    and closes every connection.
    ///
    /// It returns true only once all of that is done, so that nothing it
    /// accepted can change the engine's state afterwards; false if it could
    /// not do all of it. A frontend that never started has nothing to stop
    /// and returns true. The daemon calls it once, when shutdown begins
    /// (SIGTERM, a client's `restoreDefaultsAndExit`, or a seam that could
    /// not start), and waits for it only within its shutdown budget: it
    /// exits with 0 only after a stop that returned true, followed by a
    /// check that defaults are confirmed.
    func stop() async -> Bool
}

/// The frontend of a build without a client listener: it serves nobody and
/// says so. The daemon still restores defaults at start and on SIGTERM,
/// handles sleep and keeps its audit log.
public struct NoFrontend: HelperFrontend {
    private let log: any HelperDaemonLog

    public init(log: any HelperDaemonLog) {
        self.log = log
    }

    public func start(serving engine: HelperEngine) throws {
        log.write(.notice, .xpc, "No client listener is available in this build: serving nobody.")
    }

    /// Nothing was accepted, so there is nothing to wait for.
    public func stop() async -> Bool {
        true
    }
}
