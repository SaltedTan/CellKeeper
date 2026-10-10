import CellKeeperHelperCore
import Foundation

/// Serves one ``HelperEngine`` over an `NSXPCListener`: the helper daemon's
/// side of the connection (a Mach-service listener there, an anonymous one
/// in tests).
///
/// - **Peers.** The listener checks every connecting client against
///   `clientRequirement` (`setConnectionCodeSigningRequirement`, macOS 13);
///   a client that does not satisfy it never reaches the server or the
///   engine. There is no way to serve without a requirement. At most
///   ``maximumConnections`` clients are served at once.
/// - **Sessions.** Each accepted connection gets its own
///   ``HelperSession``. When the connection ends, for any reason, its
///   session is invalidated at once, which clears whatever it held (R1).
/// - **Order and bounds.** NSXPC delivers each connection's messages on that
///   connection's own queue, and the engine is an actor that would not order
///   independent calls. So each connection has a FIFO with a single
///   consumer: requests reach the engine strictly in arrival order, one at a
///   time, and each reply is sent when the engine has returned (research
///   note 04, §3.6). At most ``maximumQueuedRequests`` may wait behind the
///   one in progress; one more is a protocol violation that closes the
///   connection, never a silent drop. A closed connection runs nothing more.
/// - **Revocation.** When the engine revokes a session
///   (``HelperEvent/sessionRevoked(_:)``), the server closes its connection
///   once the reply to the request that caused it has been sent; requests
///   behind it never run.
/// - **Lifecycle.** ``start()`` starts the engine, which restores defaults
///   before anything is served (R2), and then the listener. ``stop()``
///   invalidates the listener and every connection, which invalidates their
///   sessions. Starting and stopping the listener, and setting up, starting
///   and closing each connection, are serialised with each other, so a stop
///   can never be undone by a start or an acceptance in progress. Ticks,
///   sleep and wake, and termination (SIGTERM) are the host's: call them on
///   ``engine``.
/// - **Audit.** Connection events (``HelperXPCConnectionEvent``) go to the
///   host asynchronously, in order, on a queue of their own, so the host's
///   logging never delays a request.
///
/// The server builds the engine itself, as `InProcessHelperTransport` does,
/// so that it sees the sessions the engine revokes.
public final class HelperXPCServer: @unchecked Sendable {
    // @unchecked Sendable: `listener` is not Sendable; it is resumed and
    // invalidated only by `registry`, under its lock. Every other stored
    // property is immutable and Sendable.

    /// Requests that may wait behind the one in progress on one connection.
    /// Far above what a well-behaved client sends (CellKeeper waits for each
    /// reply, and the engine's budget allows 10 at once).
    public static let maximumQueuedRequests = 32

    /// Connections served at once. CellKeeper uses one at a time; a few more
    /// cover a reconnect that overlaps the end of the old connection.
    public static let maximumConnections = 8

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
    ///   - connectionEvents: receives every connection event, asynchronously
    ///     and in order, for the host's log.
    public init(
        listener: NSXPCListener,
        clientRequirement: HelperCodeSigningRequirement,
        control: any HelperChargeControl,
        power: any HelperPowerReading,
        build: Int,
        uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime,
        activationHistory: [HelperActivationRecord] = [],
        events: @escaping @Sendable (HelperEvent) -> Void = { _ in },
        connectionEvents: @escaping @Sendable (HelperXPCConnectionEvent) -> Void = { _ in }
    ) {
        let registry = ConnectionRegistry(audit: AuditChannel(sink: connectionEvents))
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
        _ = registry.stop(listener, reason: .serverStopped)
    }

    /// Starts the engine, which restores defaults and reads them back first
    /// (R2), and then accepts connections, unless the server was stopped
    /// meanwhile. Returns the engine's start status: `hardwareError` if that
    /// restore failed, in which case the engine serves sessions with a
    /// restore owed. Later calls start nothing.
    @discardableResult
    public func start() async -> HelperStatus {
        let status = await engine.start()
        registry.startListening(listener)
        return status
    }

    /// Stops serving: invalidates the listener and every connection, and
    /// returns once each connection's request in progress has ended and its
    /// session is invalidated (which clears what it held). Queued requests
    /// never run. A connection that arrives meanwhile is refused. The engine
    /// itself keeps running for the host (for example to restore defaults at
    /// exit).
    public func stop() async {
        for handler in registry.stop(listener, reason: .serverStopped) {
            await handler.finished()
        }
    }

    /// The number of client connections being served (accepted, and not yet
    /// ended with their session invalidated), for the host's diagnostics.
    public var connectionCount: Int {
        registry.connectionCount
    }

    /// Closes every client connection and waits until their sessions are
    /// invalidated; the listener keeps accepting new ones. For tests of a
    /// client that must reconnect.
    func closeConnections() async {
        for handler in registry.closeAll(reason: .serverStopped) {
            await handler.finished()
        }
    }

    /// Requests waiting behind the one in progress, over every connection.
    /// For tests.
    var queuedRequestCount: Int {
        registry.handlers.reduce(0) { $0 + $1.queuedCount }
    }

    /// Connections not yet closed (a closed one may still finish its request
    /// in progress). For tests.
    var openConnectionCount: Int {
        registry.handlers.filter(\.isOpen).count
    }
}

// MARK: - Connection events

/// A connection event, for the host's audit log. The process and user IDs are
/// informational only: process IDs are reused, so they are never used to
/// decide anything (research note 04, §2.3). Clients that fail the
/// requirement never reach the server, so they do not appear here.
public enum HelperXPCConnectionEvent: Sendable, Equatable {
    /// A client that met the requirement connected and was given a session.
    case accepted(HelperSessionID, processID: Int32, effectiveUserID: UInt32)
    /// A client that met the requirement was turned away.
    case refused(processID: Int32, effectiveUserID: UInt32, reason: HelperXPCRefusal)
    /// The connection ended; its session has been invalidated.
    case closed(HelperSessionID, reason: HelperXPCCloseReason)
}

public enum HelperXPCRefusal: Sendable, Equatable {
    /// ``HelperXPCServer/maximumConnections`` clients are already served.
    case tooManyConnections
    /// The server has been stopped.
    case notServing
}

public enum HelperXPCCloseReason: Sendable, Equatable {
    /// The client went away: it quit, crashed or invalidated the connection.
    case clientDisconnected
    /// The engine revoked the session for exceeding its request budget.
    case revoked
    /// More than ``HelperXPCServer/maximumQueuedRequests`` requests waited
    /// behind the one in progress.
    case requestQueueFull
    /// The server stopped.
    case serverStopped
}

/// Delivers connection events to the host on a serial queue of their own.
final class AuditChannel: Sendable {
    private let queue = DispatchQueue(label: "io.github.saltedtan.CellKeeper.helper-xpc.audit")
    private let sink: @Sendable (HelperXPCConnectionEvent) -> Void

    init(sink: @escaping @Sendable (HelperXPCConnectionEvent) -> Void) {
        self.sink = sink
    }

    func send(_ event: HelperXPCConnectionEvent) {
        queue.async { [sink] in sink(event) }
    }
}

// MARK: - Listener

/// The listener's delegate: hands each connection to the registry.
private final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    let engine: HelperEngine
    let registry: ConnectionRegistry

    init(engine: HelperEngine, registry: ConnectionRegistry) {
        self.engine = engine
        self.registry = registry
    }

    /// Called on the listener's queue for a client that met the requirement.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        registry.accept(connection, engine: engine)
    }
}

/// The server's lifecycle and connections. Every transition that touches an
/// NSXPC object (resuming or invalidating the listener; configuring,
/// resuming and publishing a connection; closing them all) happens under
/// one lock, together with the decision to make it, so none can interleave
/// with a transition that would undo it.
final class ConnectionRegistry: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`. NSXPC objects are
    // only messaged under it here; their handlers run later, on NSXPC's
    // queues, and never wait for this lock while NSXPC waits for them.

    private enum State {
        case idle, listening, stopped
    }

    let audit: AuditChannel
    private let lock = NSLock()
    private var state = State.idle
    private var connections: [ObjectIdentifier: HelperXPCConnectionHandler] = [:]
    private var bySession: [HelperSessionID: HelperXPCConnectionHandler] = [:]

    init(audit: AuditChannel) {
        self.audit = audit
    }

    /// Resumes the listener, once, unless the server has been stopped.
    func startListening(_ listener: NSXPCListener) {
        lock.withLock {
            guard state == .idle else { return }
            state = .listening
            listener.resume()
        }
    }

    /// Stops for good: invalidates the listener and closes every connection.
    /// Returns them, so the caller can wait for their sessions to end.
    ///
    /// A listener that was never resumed is resumed first, with the state
    /// already stopped, so it refuses every client and then ends: invalidated
    /// while still suspended, it would leave clients that are connecting
    /// waiting for an answer that never comes, and resuming it after the
    /// invalidation is not a supported order.
    func stop(_ listener: NSXPCListener, reason: HelperXPCCloseReason) -> [HelperXPCConnectionHandler] {
        lock.withLock {
            switch state {
            case .idle:
                state = .stopped
                listener.resume()
                listener.invalidate()
            case .listening:
                state = .stopped
                listener.invalidate()
            case .stopped:
                break
            }
            return closeAllLocked(reason: reason)
        }
    }

    /// Closes every connection; the listener keeps accepting.
    func closeAll(reason: HelperXPCCloseReason) -> [HelperXPCConnectionHandler] {
        lock.withLock { closeAllLocked(reason: reason) }
    }

    private func closeAllLocked(reason: HelperXPCCloseReason) -> [HelperXPCConnectionHandler] {
        let handlers = Array(connections.values)
        for handler in handlers {
            handler.close(reason)
        }
        return handlers
    }

    /// Sets up, publishes and starts a new connection, all under the lock;
    /// or refuses it, also under the lock, so a connection accepted while
    /// the server stops is either closed by the stop or never served.
    func accept(_ connection: NSXPCConnection, engine: HelperEngine) -> Bool {
        lock.withLock {
            let refusal: HelperXPCRefusal? = if state != .listening {
                .notServing
            } else if connections.count >= HelperXPCServer.maximumConnections {
                .tooManyConnections
            } else {
                nil
            }
            if let refusal {
                audit.send(.refused(processID: connection.processIdentifier, effectiveUserID: connection.effectiveUserIdentifier, reason: refusal))
                connection.invalidate()
                return false
            }
            let handler = HelperXPCConnectionHandler(connection: connection, engine: engine, registry: self)
            connection.exportedInterface = HelperXPCInterface.make()
            connection.exportedObject = HelperXPCExportedObject(handler: handler)
            connection.invalidationHandler = { [weak handler] in handler?.close(.clientDisconnected) }
            // Not expected on an accepted connection; treated as its end.
            connection.interruptionHandler = { [weak handler] in handler?.close(.clientDisconnected) }
            connections[ObjectIdentifier(handler)] = handler
            handler.begin()
            connection.resume()
            return true
        }
    }

    func register(_ handler: HelperXPCConnectionHandler, for session: HelperSessionID) {
        lock.withLock { bySession[session] = handler }
    }

    func remove(_ handler: HelperXPCConnectionHandler, session: HelperSessionID) {
        lock.withLock {
            connections[ObjectIdentifier(handler)] = nil
            bySession[session] = nil
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
        let handler = lock.withLock { bySession[session] }
        handler?.noteRevocation()
    }
}

// MARK: - One connection

/// One client connection: its session, and the bounded FIFO that runs its
/// requests in arrival order, one at a time.
final class HelperXPCConnectionHandler: @unchecked Sendable {
    // @unchecked Sendable: `connection` (not Sendable) and the other mutable
    // state are guarded by `lock`; NSXPC connections may be invalidated from
    // any thread. The stream's continuation is thread-safe.

    typealias Request = @Sendable (HelperSession) async -> Void

    private let engine: HelperEngine
    private let registry: ConnectionRegistry
    private let processID: Int32
    private let effectiveUserID: UInt32
    private let jobs: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var session: HelperSession?
    private var closeReason: HelperXPCCloseReason?
    /// Requests accepted and not yet taken by the consumer.
    private var queued = 0
    /// The consumer is running a request.
    private var isRunning = false
    /// The engine revoked the session while a request was running.
    private var isRevocationPending = false
    private var consumer: Task<Void, Never>?

    init(connection: NSXPCConnection, engine: HelperEngine, registry: ConnectionRegistry) {
        self.connection = connection
        self.engine = engine
        self.registry = registry
        processID = connection.processIdentifier
        effectiveUserID = connection.effectiveUserIdentifier
        (jobs, continuation) = AsyncStream.makeStream(of: Request.self)
    }

    /// Starts the consumer: opens the session, then runs the requests.
    func begin() {
        let task = Task { await self.run() }
        lock.withLock { consumer = task }
    }

    /// Queues a request. Called on the connection's queue, in arrival order.
    /// One more than ``HelperXPCServer/maximumQueuedRequests`` waiting closes
    /// the connection: the client broke the protocol.
    func enqueue(_ request: @escaping Request) {
        let accepted = lock.withLock {
            guard closeReason == nil, queued < HelperXPCServer.maximumQueuedRequests else { return false }
            queued += 1
            return true
        }
        if accepted {
            continuation.yield(request)
        } else {
            close(.requestQueueFull)
        }
    }

    var queuedCount: Int {
        lock.withLock { queued }
    }

    var isOpen: Bool {
        lock.withLock { closeReason == nil }
    }

    /// The engine revoked the session. A request in progress (the one that
    /// caused it) gets its reply first.
    func noteRevocation() {
        let closesNow = lock.withLock {
            guard closeReason == nil else { return false }
            if isRunning {
                isRevocationPending = true
                return false
            }
            return true
        }
        if closesNow {
            closeAfterSentReplies(.revoked)
        }
    }

    /// Closes the connection now. The request in progress finishes, nothing
    /// queued runs, and the session is invalidated at once.
    func close(_ reason: HelperXPCCloseReason) {
        guard let (connection, session) = markClosed(reason) else { return }
        connection?.invalidate()
        invalidate(session)
    }

    /// Waits until the consumer has ended and the session is invalidated.
    func finished() async {
        let task = lock.withLock { consumer }
        await task?.value
    }

    /// Marks the connection closed and ends the FIFO. Returns the connection
    /// and the session the first time, nil afterwards.
    private func markClosed(_ reason: HelperXPCCloseReason) -> (NSXPCConnection?, HelperSession?)? {
        let taken: (NSXPCConnection?, HelperSession?)? = lock.withLock {
            guard closeReason == nil else { return nil }
            closeReason = reason
            defer { connection = nil }
            return (connection, session)
        }
        if taken != nil {
            continuation.finish()
        }
        return taken
    }

    /// Closes the connection after every reply already sent, so the request
    /// that caused a revocation still gets its reply.
    private func closeAfterSentReplies(_ reason: HelperXPCCloseReason) {
        guard let (connection, session) = markClosed(reason) else { return }
        if let connection {
            // The barrier runs once the messages enqueued before it have been
            // sent. `NSXPCConnection` is not Sendable; the block only
            // invalidates it, which NSXPC allows from any thread.
            nonisolated(unsafe) let closing = connection
            connection.scheduleSendBarrierBlock {
                closing.invalidate()
            }
        }
        invalidate(session)
    }

    /// Invalidates the session now, without waiting for the request in
    /// progress (the engine runs one call at a time anyway).
    private func invalidate(_ session: HelperSession?) {
        guard let session else { return }
        Task { await session.invalidate() }
    }

    /// Takes the next request to run, or nil once the connection is closed.
    private func startRequest() -> Bool {
        lock.withLock {
            queued -= 1
            guard closeReason == nil else { return false }
            isRunning = true
            return true
        }
    }

    /// Ends the request; true if the session was revoked meanwhile.
    private func finishRequest() -> Bool {
        lock.withLock {
            isRunning = false
            return isRevocationPending
        }
    }

    private func run() async {
        let session = await engine.openSession()
        let isOpen = lock.withLock {
            self.session = session
            return closeReason == nil
        }
        registry.register(self, for: session.id)
        registry.audit.send(.accepted(session.id, processID: processID, effectiveUserID: effectiveUserID))
        if isOpen {
            for await request in jobs {
                // Nothing more runs once the connection is closed.
                guard startRequest() else { break }
                await request(session)
                if finishRequest() {
                    closeAfterSentReplies(.revoked)
                    break
                }
            }
        }
        // Already done by `close` if the session was open then; harmless
        // twice.
        await session.invalidate()
        let reason = lock.withLock { closeReason ?? .clientDisconnected }
        registry.remove(self, session: session.id)
        registry.audit.send(.closed(session.id, reason: reason))
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
