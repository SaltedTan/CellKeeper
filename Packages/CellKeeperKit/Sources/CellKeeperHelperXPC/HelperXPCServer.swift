import CellKeeperHelperCore
import Foundation

/// Serves one ``HelperEngine`` over an `NSXPCListener`: the helper daemon's
/// side of the connection (a Mach-service listener there, an anonymous one
/// in tests).
///
/// - **Peers.** The listener checks every connecting client against
///   `clientRequirement` (`setConnectionCodeSigningRequirement`, macOS 13);
///   a client that does not satisfy it never reaches the engine. There is no
///   way to serve without a requirement.
/// - **Sessions.** Each accepted connection gets its own
///   ``HelperSession``. When the connection ends, for any reason, the
///   session is invalidated, which clears whatever it held (R1).
/// - **Order.** NSXPC delivers each connection's messages on that
///   connection's own queue, and the engine is an actor that would interleave
///   independent tasks in no particular order. So each connection has a FIFO
///   of its requests with a single consumer: they reach the engine strictly
///   in arrival order, one at a time, and each reply is sent when the engine
///   has returned (research note 04, §3.6). Different connections still run
///   concurrently; the engine serialises them.
/// - **Revocation.** When the engine revokes a session
///   (``HelperEvent/sessionRevoked(_:)``), the server closes its connection
///   once the reply to the request that caused it has been sent; requests
///   that arrived after it are never run. The client sees that reply
///   (`rateLimited`), then the connection end.
/// - **Lifecycle.** ``start()`` starts the engine, which restores defaults
///   before anything is served (R2), and then the listener. ``stop()``
///   invalidates the listener and every connection, which invalidates their
///   sessions. Ticks, sleep and wake, and termination (SIGTERM) are the
///   host's: call them on ``engine``.
///
/// The server builds the engine itself, as `InProcessHelperTransport` does,
/// so that it sees the sessions the engine revokes.
public final class HelperXPCServer: @unchecked Sendable {
    // @unchecked Sendable: `listener` is not Sendable, but it is only
    // resumed once (guarded by `registry`) and invalidated, and NSXPC
    // listeners may be messaged from any thread; every other stored property
    // is immutable and Sendable or synchronised by its own lock.

    public let engine: HelperEngine
    private let listener: NSXPCListener
    private let delegate: ListenerDelegate
    private let registry: ConnectionRegistry

    /// - Parameters:
    ///   - listener: a Mach-service listener in the daemon, an anonymous one
    ///     in tests. The server becomes its delegate; do not resume it.
    ///   - clientRequirement: the requirement every client must meet:
    ///     ``HelperCodeSigningRequirement/forClientApp(identifier:)`` in the
    ///     daemon.
    ///   - control, power, build, uptime, activationHistory: the engine's;
    ///     see ``HelperEngine``.
    ///   - events: receives every event of the engine, as
    ///     ``HelperEngine``'s sink does, after the server has noted
    ///     revocations. It must not block (the daemon logs and persists
    ///     asynchronously).
    public init(
        listener: NSXPCListener,
        clientRequirement: HelperCodeSigningRequirement,
        control: any HelperChargeControl,
        power: any HelperPowerReading,
        build: Int,
        uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime,
        activationHistory: [HelperActivationRecord] = [],
        events: @escaping @Sendable (HelperEvent) -> Void = { _ in }
    ) {
        let registry = ConnectionRegistry()
        let engine = HelperEngine(
            control: control,
            power: power,
            build: build,
            uptime: uptime,
            activationHistory: activationHistory,
            events: { event in
                if case .sessionRevoked(let id) = event {
                    registry.sessionRevoked(id)
                }
                events(event)
            }
        )
        self.engine = engine
        self.registry = registry
        self.listener = listener
        delegate = ListenerDelegate(engine: engine, registry: registry)
        // Before the listener is resumed, so no connection is ever accepted
        // without it. The requirement was compiled when it was made, so this
        // cannot hit NSXPC's fatal error for a malformed one.
        listener.setConnectionCodeSigningRequirement(clientRequirement.text)
        listener.delegate = delegate
    }

    deinit {
        listener.invalidate()
        for handler in registry.stop() {
            handler.close()
        }
    }

    /// Starts the engine, which restores defaults and reads them back first
    /// (R2), and then accepts connections. Returns the engine's start status:
    /// `hardwareError` if that restore failed, in which case the engine
    /// serves sessions with a restore owed. Later calls start nothing.
    @discardableResult
    public func start() async -> HelperStatus {
        let status = await engine.start()
        if registry.beginListening() {
            listener.resume()
        }
        return status
    }

    /// Stops serving: invalidates the listener and every connection, and
    /// returns once each connection's request in progress has ended and its
    /// session is invalidated (which clears what it held). Requests that had
    /// not started are dropped. The engine itself keeps running for the
    /// host (for example to restore defaults at exit).
    public func stop() async {
        let handlers = registry.stop()
        listener.invalidate()
        for handler in handlers {
            handler.close()
        }
        for handler in handlers {
            await handler.finished()
        }
    }

    /// The number of client connections being served, for the host's
    /// diagnostics and for tests.
    public var connectionCount: Int {
        registry.connectionCount
    }

    /// Closes every client connection, as a lost connection would, and
    /// waits until their sessions are invalidated; the listener keeps
    /// accepting new ones. For tests of a client that must reconnect.
    func closeConnections() async {
        let handlers = registry.handlers
        for handler in handlers {
            handler.close()
        }
        for handler in handlers {
            await handler.finished()
        }
    }
}

// MARK: - Listener

/// The listener's delegate: configures and accepts each connection.
private final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    let engine: HelperEngine
    let registry: ConnectionRegistry

    init(engine: HelperEngine, registry: ConnectionRegistry) {
        self.engine = engine
        self.registry = registry
    }

    /// Called on the listener's queue for a client that met the requirement.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let handler = HelperXPCConnectionHandler(connection: connection, engine: engine, registry: registry)
        guard registry.add(handler) else { return false }
        connection.exportedInterface = HelperXPCInterface.make()
        connection.exportedObject = HelperXPCExportedObject(handler: handler)
        connection.invalidationHandler = { [weak handler] in handler?.close() }
        // Not expected on an accepted connection; treated as its end.
        connection.interruptionHandler = { [weak handler] in handler?.close() }
        handler.begin()
        connection.resume()
        return true
    }
}

/// The server's connections, its listening state, and the sessions the
/// engine revoked.
final class ConnectionRegistry: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`.

    private enum State {
        case idle, listening, stopped
    }

    private let lock = NSLock()
    private var state = State.idle
    private var connections: [ObjectIdentifier: HelperXPCConnectionHandler] = [:]
    private var bySession: [HelperSessionID: HelperXPCConnectionHandler] = [:]
    private var revoked: Set<HelperSessionID> = []

    /// True the first time, if the server has not been stopped: the caller
    /// resumes the listener.
    func beginListening() -> Bool {
        lock.withLock {
            guard state == .idle else { return false }
            state = .listening
            return true
        }
    }

    /// Marks the server stopped and returns every connection to close.
    func stop() -> [HelperXPCConnectionHandler] {
        lock.withLock {
            state = .stopped
            return Array(connections.values)
        }
    }

    /// Adds a new connection; false once the server is stopped.
    func add(_ handler: HelperXPCConnectionHandler) -> Bool {
        lock.withLock {
            guard state != .stopped else { return false }
            connections[ObjectIdentifier(handler)] = handler
            return true
        }
    }

    func register(_ handler: HelperXPCConnectionHandler, for session: HelperSessionID) {
        lock.withLock { bySession[session] = handler }
    }

    func remove(_ handler: HelperXPCConnectionHandler, session: HelperSessionID?) {
        lock.withLock {
            connections[ObjectIdentifier(handler)] = nil
            if let session {
                bySession[session] = nil
                revoked.remove(session)
            }
        }
    }

    var handlers: [HelperXPCConnectionHandler] {
        lock.withLock { Array(connections.values) }
    }

    var connectionCount: Int {
        lock.withLock { connections.count }
    }

    /// From the engine's event sink, before the revoking request returns.
    func sessionRevoked(_ session: HelperSessionID) {
        let handler = lock.withLock {
            revoked.insert(session)
            return bySession[session]
        }
        handler?.noteRevocation()
    }

    func isRevoked(_ session: HelperSessionID) -> Bool {
        lock.withLock { revoked.contains(session) }
    }
}

// MARK: - One connection

/// One client connection: its session, and the FIFO that runs its requests
/// in arrival order, one at a time.
final class HelperXPCConnectionHandler: @unchecked Sendable {
    // @unchecked Sendable: `connection` (not Sendable) and the other mutable
    // state are guarded by `lock`; NSXPC connections may be invalidated from
    // any thread. The stream's continuation is thread-safe.

    private enum Job: Sendable {
        /// Runs one request on the session and sends its reply.
        case request(@Sendable (HelperSession) async -> Void)
        /// The engine revoked the session.
        case revocation
    }

    private let engine: HelperEngine
    private let registry: ConnectionRegistry
    private let jobs: AsyncStream<Job>
    private let continuation: AsyncStream<Job>.Continuation
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var isClosed = false
    private var consumer: Task<Void, Never>?

    init(connection: NSXPCConnection, engine: HelperEngine, registry: ConnectionRegistry) {
        self.connection = connection
        self.engine = engine
        self.registry = registry
        (jobs, continuation) = AsyncStream.makeStream(of: Job.self)
    }

    /// Starts the consumer: opens the session, then runs the requests.
    func begin() {
        let task = Task { await self.run() }
        lock.withLock { consumer = task }
    }

    /// Queues a request. Called on the connection's queue, in arrival order.
    func enqueue(_ request: @escaping @Sendable (HelperSession) async -> Void) {
        continuation.yield(.request(request))
    }

    func noteRevocation() {
        continuation.yield(.revocation)
    }

    /// Closes the connection now (the client went away, or the server is
    /// stopping). The request in progress finishes; the rest are dropped,
    /// and then the session is invalidated.
    func close() {
        let connection = markClosed()
        connection?.invalidate()
    }

    /// Waits until the session has been invalidated.
    func finished() async {
        let task = lock.withLock { consumer }
        await task?.value
    }

    private var isOpen: Bool {
        lock.withLock { !isClosed }
    }

    /// Marks the connection closed and ends the FIFO; returns the connection
    /// the first time.
    private func markClosed() -> NSXPCConnection? {
        let connection: NSXPCConnection? = lock.withLock {
            guard !isClosed else { return nil }
            isClosed = true
            defer { self.connection = nil }
            return self.connection
        }
        continuation.finish()
        return connection
    }

    /// Closes the connection after every reply already sent, so the request
    /// that caused a revocation still gets its reply.
    private func closeAfterSentReplies() {
        guard let connection = markClosed() else { return }
        // The barrier runs once the messages enqueued before it have been
        // sent. `NSXPCConnection` is not Sendable; the block only
        // invalidates it, which NSXPC allows from any thread.
        nonisolated(unsafe) let closing = connection
        connection.scheduleSendBarrierBlock {
            closing.invalidate()
        }
    }

    private func run() async {
        let session = await engine.openSession()
        registry.register(self, for: session.id)
        for await job in jobs {
            // Nothing more runs for a connection that has ended.
            guard isOpen else { continue }
            switch job {
            case .request(let request):
                await request(session)
            case .revocation:
                break
            }
            if registry.isRevoked(session.id) {
                closeAfterSentReplies()
            }
        }
        await session.invalidate()
        registry.remove(self, session: session.id)
    }
}

// MARK: - Exported object

/// The object NSXPC calls for each message: queues the request on its
/// connection's FIFO. Arguments are passed on unchanged; the engine
/// validates them.
private final class HelperXPCExportedObject: NSObject, CellKeeperHelperXPCProtocol {
    // Weak: the registry keeps the handler while its connection is served,
    // and the connection keeps this object; a strong reference would form a
    // cycle through the connection.
    private weak var handler: HelperXPCConnectionHandler?

    init(handler: HelperXPCConnectionHandler) {
        self.handler = handler
    }

    func hello(clientProtocolVersion: Int, reply: @escaping HelperXPCHelloReplyBlock) {
        handler?.enqueue { HelperXPCWire.send(await $0.hello(clientProtocolVersion: clientProtocolVersion), to: reply) }
    }

    func readState(reply: @escaping HelperXPCStateReplyBlock) {
        handler?.enqueue { HelperXPCWire.send(await $0.readState(), to: reply) }
    }

    func acquireOrRenewLease(control: Int, seconds: Int, reply: @escaping HelperXPCLeaseReplyBlock) {
        handler?.enqueue { HelperXPCWire.send(await $0.acquireOrRenewLease(control: control, seconds: seconds), to: reply) }
    }

    func releaseLease(control: Int, reply: @escaping HelperXPCStatusReplyBlock) {
        handler?.enqueue { HelperXPCWire.send(await $0.releaseLease(control: control), to: reply) }
    }

    func setControl(control: Int, active: Bool, reply: @escaping HelperXPCStatusReplyBlock) {
        handler?.enqueue { HelperXPCWire.send(await $0.setControl(control: control, active: active), to: reply) }
    }

    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64, reply: @escaping HelperXPCStatusReplyBlock) {
        handler?.enqueue {
            HelperXPCWire.send(
                await $0.clearControlIfUnchanged(control: control, generation: generation, helperInstance: helperInstance),
                to: reply
            )
        }
    }

    func restoreDefaults(reply: @escaping HelperXPCStatusReplyBlock) {
        handler?.enqueue { HelperXPCWire.send(await $0.restoreDefaults(), to: reply) }
    }

    func restoreDefaultsAndExit(reply: @escaping HelperXPCStatusReplyBlock) {
        handler?.enqueue { HelperXPCWire.send(await $0.restoreDefaultsAndExit(), to: reply) }
    }
}
