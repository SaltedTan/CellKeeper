import CellKeeperHelperCore
import CellKeeperHelperXPC
import Foundation

/// The daemon's frontend over NSXPC: it serves the daemon's engine on the
/// Mach service ``HelperServiceName/machService``, to CellKeeper only,
/// through a ``HelperXPCServer``.
///
/// - **Requirement.** Every client must be CellKeeper
///   (``clientIdentifier``), signed with an Apple-issued certificate of this
///   process's own team (``HelperCodeSigningRequirement/forClientApp(identifier:)``,
///   research note 04, §2.4). An ad-hoc or unsigned build has no team, so
///   ``start(serving:log:)`` throws before any listener exists: the daemon
///   then serves nobody and shuts down (exit 0 once defaults are
///   confirmed). It never listens without a requirement.
/// - **Revocations.** The daemon passes the engine's events to
///   ``handle(_:)``, so the server closes the connection of a session the
///   engine revokes.
/// - **Stop.** ``stop(by:)`` is ``HelperXPCServer/stop(by:)`` on the
///   daemon's deadline and clock: it returns true only if every connection
///   it drained can prove that every request it admitted ran and its reply
///   was sent (a send barrier confirms the send, not receipt) before the
///   connection and its session were invalidated, and only before the
///   deadline; at the deadline it cuts off what remains and returns false.
/// - **Audit.** Accepted, refused and closed connections go to the daemon's
///   log. The process and user IDs in them are informational only (note 04,
///   §2.3).
public final class XPCFrontend: HelperFrontend, @unchecked Sendable {
    // @unchecked Sendable: `server` is guarded by `lock`; `listenerSource`
    // holds a listener only in tests, which is used once, in `start`.

    /// CellKeeper's signing identifier, required of every client.
    public static let clientIdentifier = "io.github.saltedtan.CellKeeper"

    private enum ListenerSource {
        case machService
        case given(NSXPCListener)
    }

    private let listenerSource: ListenerSource
    private let makeRequirement: @Sendable () throws -> HelperCodeSigningRequirement
    private let lock = NSLock()
    private var server: HelperXPCServer?

    /// The daemon's frontend: the Mach service, and CellKeeper with this
    /// process's own team.
    public convenience init() {
        self.init(
            listenerSource: .machService,
            requirement: { try HelperCodeSigningRequirement.forClientApp(identifier: XPCFrontend.clientIdentifier) }
        )
    }

    /// For tests: an anonymous listener, and the requirement to place on
    /// clients.
    convenience init(
        listener: NSXPCListener,
        requirement: @escaping @Sendable () throws -> HelperCodeSigningRequirement
    ) {
        self.init(listenerSource: .given(listener), requirement: requirement)
    }

    private init(
        listenerSource: ListenerSource,
        requirement: @escaping @Sendable () throws -> HelperCodeSigningRequirement
    ) {
        self.listenerSource = listenerSource
        makeRequirement = requirement
    }

    /// Builds the client requirement first, and only then the listener, so a
    /// build that cannot require anything never listens. Then serves
    /// `engine` (already started by the daemon) and starts listening.
    public func start(serving engine: HelperEngine, log: any HelperDaemonLog) throws {
        let requirement = try makeRequirement()
        let listener = switch listenerSource {
        case .machService: NSXPCListener(machServiceName: HelperServiceName.machService)
        case .given(let listener): listener
        }
        let server = HelperXPCServer(
            serving: engine,
            listener: listener,
            clientRequirement: requirement,
            connectionEvents: { Self.log($0, to: log) }
        )
        // Before listening, so a revocation always finds the server.
        lock.withLock { self.server = server }
        server.startListening()
        log.write(.notice, .xpc, "Serving CellKeeper over NSXPC (\(HelperServiceName.machService)); every client must satisfy: \(requirement).")
    }

    public func handle(_ event: HelperEvent) {
        let server = lock.withLock { self.server }
        server?.handle(event)
    }

    public func stop(by deadline: HelperDaemonDeadline) async -> Bool {
        guard let server = lock.withLock({ self.server }) else { return true }
        return await server.stop(by: HelperXPCServer.Deadline(
            hasPassed: { deadline.hasPassed },
            wait: { await deadline.wait() }
        ))
    }

    static func log(_ event: HelperXPCConnectionEvent, to log: any HelperDaemonLog) {
        switch event {
        case .accepted(let session, let processID, let userID):
            log.write(.info, .xpc, "Accepted a connection: \(session) (process \(processID), user \(userID); for the log only).")
        case .refused(let processID, let userID, let reason):
            log.write(.notice, .xpc, "Refused a connection from process \(processID), user \(userID): \(reason).")
        case .closed(let session, let reason):
            log.write(reason == .clientDisconnected ? .info : .notice, .xpc, "Connection of \(session) closed: \(reason).")
        }
    }
}
