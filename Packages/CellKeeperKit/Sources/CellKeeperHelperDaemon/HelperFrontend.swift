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
    /// R2), and never during shutdown. Throws if it cannot serve safely.
    func start(serving engine: HelperEngine) throws

    /// Stops accepting connections and ends the existing ones, so that each
    /// ends its session; replies already being sent may complete. The
    /// daemon calls it when shutdown begins (SIGTERM, or a client's
    /// `restoreDefaultsAndExit`), possibly more than once, also without a
    /// prior ``start(serving:)``. It must return promptly: the daemon waits
    /// at most ``HelperDaemon/frontendStopTimeout`` before it carries on.
    func stop() async
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

    public func stop() async {}
}
