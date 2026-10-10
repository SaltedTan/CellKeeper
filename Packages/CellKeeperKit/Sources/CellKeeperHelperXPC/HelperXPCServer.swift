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
/// - **Lifecycle.** The host starts the engine, which restores defaults
///   before anything is served (R2), and only then the listener
///   (``startListening()``; ``start()`` does both). ``stop()`` drains and
///   confirms (below). Starting and stopping the listener and accepting each
///   connection are serialised with each other, so a stop can never be
///   undone by a start or an acceptance in progress; each connection's close
///   is recorded atomically with the decision to close it. Ticks, sleep and
///   wake, and termination (SIGTERM) are the host's: call them on
///   ``engine``.
/// - **Stop.** ``stop(drainingUntil:)`` admits no new connection and no new
///   request; lets every request already admitted run, in order, and sends
///   its reply; then, once a send barrier has confirmed that those replies
///   were sent, invalidates each connection and its session. It returns
///   true only if it cut nothing off (see there).
/// - **Audit.** Connection events (``HelperXPCConnectionEvent``) go to the
///   host asynchronously, in order, on a queue of their own, so the host's
///   logging never delays a request.
///
/// The server serves an engine the host made (the daemon's), or builds one
/// itself (``init(listener:clientRequirement:control:power:build:uptime:activationHistory:events:connectionEvents:)``,
/// for tests). Either way it must see the sessions the engine revokes: the
/// host's event sink passes every event to ``handle(_:)``.
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

    /// Serves `engine`, which the host made, started and keeps: the daemon's.
    /// The host's event sink must pass every event to ``handle(_:)``, so the
    /// server closes the connections of the sessions the engine revokes.
    ///
    /// - Parameters:
    ///   - listener: a Mach-service listener in the daemon, an anonymous one
    ///     in tests. The server becomes its delegate; do not resume it.
    ///   - clientRequirement: the requirement every client must meet:
    ///     ``HelperCodeSigningRequirement/forClientApp(identifier:)`` in the
    ///     daemon.
    ///   - connectionEvents: receives every connection event, asynchronously
    ///     and in order, for the host's log.
    public convenience init(
        serving engine: HelperEngine,
        listener: NSXPCListener,
        clientRequirement: HelperCodeSigningRequirement,
        connectionEvents: @escaping @Sendable (HelperXPCConnectionEvent) -> Void = { _ in }
    ) {
        self.init(
            engine: engine,
            registry: ConnectionRegistry(audit: AuditChannel(sink: connectionEvents)),
            listener: listener,
            clientRequirement: clientRequirement
        )
    }

    /// Builds the engine as well, so that it sees the sessions the engine
    /// revokes without help from a host (tests).
    ///
    /// - Parameters:
    ///   - listener, clientRequirement, connectionEvents: as for
    ///     ``init(serving:listener:clientRequirement:connectionEvents:)``.
    ///   - control, power, build, uptime, activationHistory: the engine's;
    ///     see ``HelperEngine``.
    ///   - events: receives every event of the engine, as
    ///     ``HelperEngine``'s sink does, after the server has noted
    ///     revocations. It must not block (the daemon logs and persists
    ///     asynchronously).
    public convenience init(
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
                registry.handle(event)
                events(event)
            }
        )
        self.init(engine: engine, registry: registry, listener: listener, clientRequirement: clientRequirement)
    }

    private init(
        engine: HelperEngine,
        registry: ConnectionRegistry,
        listener: NSXPCListener,
        clientRequirement: HelperCodeSigningRequirement
    ) {
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

    /// An event of the engine, from the host's event sink: the server closes
    /// the connection of a session the engine revokes, once the reply to the
    /// request that caused it has been sent. Returns at once; it never calls
    /// into the engine.
    public func handle(_ event: HelperEvent) {
        registry.handle(event)
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
        startListening()
        return status
    }

    /// Accepts connections, unless the server was stopped meanwhile. The host
    /// calls it only once the engine has started (R2). Later calls do
    /// nothing.
    public func startListening() {
        registry.startListening(listener)
    }

    /// How long ``stop()`` lets the requests already admitted finish.
    public static let defaultStopTimeout: Duration = .seconds(5)

    /// ``stop(drainingUntil:)``, cut off after `timeout`.
    @discardableResult
    public func stop(timeout: Duration = HelperXPCServer.defaultStopTimeout) async -> Bool {
        await stop(drainingUntil: { try? await Task.sleep(for: timeout) })
    }

    /// Stops serving, and says whether it could do so without cutting
    /// anything off. In order:
    /// 1. Admits nothing more: a connection that arrives is refused, and no
    ///    connection admits another request. The listener itself is
    ///    invalidated only at the end, because invalidating it would also end
    ///    the connections still draining.
    /// 2. Lets every request already admitted run, in arrival order, and
    ///    sends its reply, a `restoreDefaultsAndExit`'s included.
    /// 3. On each connection, once a send barrier has confirmed that every
    ///    reply sent before it was sent, invalidates the connection, then its
    ///    session (which clears what it held).
    ///
    /// A request is *admitted* once it is on its connection's queue; one that
    /// arrives after the stop began is not, gets no reply, and its client
    /// sees the connection end. A *sent* reply is one the transport confirmed
    /// sending; that the client received it is not confirmed, because the
    /// protocol has no acknowledgement. A connection that ends on its own
    /// meanwhile (its client goes away, the engine revokes its session)
    /// ends as it always does.
    ///
    /// Returns true once all of that is done for every connection, every
    /// session is invalidated, and the stop cut nothing off. If `deadline`
    /// returns first, it closes what remains at once, so admitted requests
    /// may never run and a reply may be cut off, and returns false without
    /// waiting for a request still in the engine. The engine keeps running
    /// for the host (for example to restore defaults at exit).
    public func stop(drainingUntil deadline: @escaping @Sendable () async -> Void) async -> Bool {
        let handlers = registry.beginDrain(listener)
        let drained = await StopRace.run(deadline: deadline) {
            for handler in handlers {
                await handler.finished()
            }
        }
        if !drained {
            for handler in handlers {
                handler.close(.serverStopped)
            }
        }
        registry.invalidateListener(listener)
        return drained
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

    /// True once a stop has begun: nothing more is admitted. For tests.
    var hasStopped: Bool {
        registry.isStopped
    }

    /// Connections not yet closed (a closed one may still finish its request
    /// in progress). For tests.
    var openConnectionCount: Int {
        registry.handlers.filter(\.isOpen).count
    }

    /// For tests: runs on the connection's queue between the decision to
    /// close a connection for overflow and the close itself.
    func onOverflowDecided(_ hook: @escaping @Sendable () -> Void) {
        registry.onOverflowDecided = hook
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

/// The server's lifecycle and connections. The listener's lifecycle
/// (resuming, invalidating), the acceptance of each connection
/// (configuring, resuming, publishing) and closing every connection at a
/// stop happen under this registry's lock, each together with the decision
/// to make it, so none can interleave with a transition that would undo it.
/// A single connection's close is recorded under that connection's own lock
/// instead (see ``HelperXPCConnectionHandler``), and its side effects follow
/// outside any lock.
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
    private var isListenerInvalidated = false
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

    /// Stops for good: invalidates the listener and closes every connection
    /// at once (queued requests never run). Returns them, so the caller can
    /// wait for their sessions to end.
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
            case .listening:
                state = .stopped
            case .stopped:
                break
            }
            if !isListenerInvalidated {
                isListenerInvalidated = true
                listener.invalidate()
            }
            return closeAllLocked(reason: reason)
        }
    }

    /// Closes every connection; the listener keeps accepting.
    func closeAll(reason: HelperXPCCloseReason) -> [HelperXPCConnectionHandler] {
        lock.withLock { closeAllLocked(reason: reason) }
    }

    /// Stops for good, draining: from now on every connection that arrives
    /// is refused (a listener never resumed is resumed for that, as in
    /// ``stop(_:reason:)``), and every connection admits nothing more while
    /// it finishes the requests it has. The listener stays valid, because
    /// invalidating it would end those connections too; the caller
    /// invalidates it once they have drained (``invalidateListener(_:)``).
    /// Under the lock, so a connection accepted meanwhile is either among
    /// those returned or refused.
    func beginDrain(_ listener: NSXPCListener) -> [HelperXPCConnectionHandler] {
        lock.withLock {
            switch state {
            case .idle:
                state = .stopped
                listener.resume()
            case .listening:
                state = .stopped
            case .stopped:
                break
            }
            let handlers = Array(connections.values)
            for handler in handlers {
                handler.beginDrain()
            }
            return handlers
        }
    }

    /// Invalidates the listener of a stopped server, once.
    func invalidateListener(_ listener: NSXPCListener) {
        lock.withLock {
            guard state == .stopped, !isListenerInvalidated else { return }
            isListenerInvalidated = true
            listener.invalidate()
        }
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

    var isStopped: Bool {
        lock.withLock { state == .stopped }
    }

    /// For tests: runs on the connection's queue after a handler has decided
    /// (and recorded) an overflow close, before it carries the close out.
    var onOverflowDecided: (@Sendable () -> Void)? {
        get { lock.withLock { overflowHook } }
        set { lock.withLock { overflowHook = newValue } }
    }

    private var overflowHook: (@Sendable () -> Void)?

    func overflowDecided() {
        onOverflowDecided?()
    }

    /// From the engine's event sink, before the call that caused the event
    /// returns.
    func handle(_ event: HelperEvent) {
        guard case .sessionRevoked(let session) = event else { return }
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
    /// A stop is draining: no request is admitted, the queued ones run.
    private var isDraining = false
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
    /// the connection: the client broke the protocol. The overflow is
    /// recorded as the close in the same lock that detects it, so the
    /// consumer cannot start another request after the violation. While a
    /// stop drains, nothing is admitted. An admitted request is put on the
    /// queue under the same lock, so a drain that begins meanwhile either
    /// finds it on the queue or refuses it.
    func enqueue(_ request: @escaping Request) {
        enum Admission {
            case accepted, refused
            case overflow(Closing)
        }
        let admission: Admission = lock.withLock {
            guard closeReason == nil, !isDraining else { return .refused }
            guard queued < HelperXPCServer.maximumQueuedRequests else {
                return .overflow(closeLocked(.requestQueueFull))
            }
            queued += 1
            continuation.yield(request)
            return .accepted
        }
        switch admission {
        case .accepted, .refused:
            break
        case .overflow(let closing):
            registry.overflowDecided()
            finishClosing(closing, afterSentReplies: false)
        }
    }

    var queuedCount: Int {
        lock.withLock { queued }
    }

    var isOpen: Bool {
        lock.withLock { closeReason == nil }
    }

    /// The engine revoked the session. A request in progress (the one that
    /// caused it) gets its reply first: the consumer closes the connection
    /// when it ends. Otherwise the connection closes now.
    func noteRevocation() {
        let closing: Closing? = lock.withLock {
            guard closeReason == nil else { return nil }
            if isRunning {
                isRevocationPending = true
                return nil
            }
            return closeLocked(.revoked)
        }
        if let closing {
            finishClosing(closing, afterSentReplies: true)
        }
    }

    /// A stop begins: nothing more is admitted, and the consumer ends once it
    /// has run every request already queued.
    func beginDrain() {
        lock.withLock {
            guard closeReason == nil, !isDraining else { return }
            isDraining = true
            continuation.finish()
        }
    }

    /// Closes the connection now. The request in progress finishes, nothing
    /// queued runs, and the session is invalidated at once.
    func close(_ reason: HelperXPCCloseReason) {
        let closing: Closing? = lock.withLock {
            closeReason == nil ? closeLocked(reason) : nil
        }
        if let closing {
            finishClosing(closing, afterSentReplies: false)
        }
    }

    /// Waits until the consumer has ended and the session is invalidated.
    func finished() async {
        let task = lock.withLock { consumer }
        await task?.value
    }

    /// What closing still has to do outside the lock.
    private struct Closing {
        var connection: NSXPCConnection?
        var session: HelperSession?
    }

    /// Ends admission: records why, which stops the consumer from starting
    /// any further request, and takes the connection and the session to
    /// close. Must be called with `lock` held, in the same critical section
    /// that decided to close, and only while the connection is open.
    private func closeLocked(_ reason: HelperXPCCloseReason) -> Closing {
        closeReason = reason
        defer { connection = nil }
        return Closing(connection: connection, session: session)
    }

    /// The side effects of a close, outside the lock: ends the FIFO,
    /// invalidates the connection (after the replies already sent, for a
    /// revocation) and the session.
    private func finishClosing(_ closing: Closing, afterSentReplies: Bool) {
        continuation.finish()
        if let connection = closing.connection {
            if afterSentReplies {
                // The barrier runs once the messages enqueued before it have
                // been sent. `NSXPCConnection` is not Sendable; the block
                // only invalidates it, which NSXPC allows from any thread.
                nonisolated(unsafe) let closed = connection
                connection.scheduleSendBarrierBlock {
                    closed.invalidate()
                }
            } else {
                connection.invalidate()
            }
        }
        // Without waiting for the request in progress: the engine runs one
        // call at a time anyway.
        if let session = closing.session {
            Task { await session.invalidate() }
        }
    }

    /// Takes the next request to run; false once admission has ended.
    private func startRequest() -> Bool {
        lock.withLock {
            queued -= 1
            guard closeReason == nil else { return false }
            isRunning = true
            return true
        }
    }

    /// Ends the request. If the engine revoked the session meanwhile, the
    /// close is recorded here, before the consumer can take another request,
    /// and returned for the consumer to carry out.
    private func finishRequest() -> Closing? {
        lock.withLock {
            isRunning = false
            guard isRevocationPending, closeReason == nil else { return nil }
            return closeLocked(.revoked)
        }
    }

    /// After a drain has run every queued request: records the close, so
    /// nothing else can close the connection meanwhile, and returns the
    /// connection to invalidate once its replies are sent. Nil if the
    /// connection was closed otherwise.
    private func finishDrain() -> NSXPCConnection? {
        lock.withLock {
            guard isDraining, closeReason == nil else { return nil }
            closeReason = .serverStopped
            defer { connection = nil }
            return connection
        }
    }

    /// Invalidates `connection` once a send barrier has confirmed that the
    /// replies sent before it were sent, and returns then.
    private static func invalidateAfterSentReplies(_ connection: NSXPCConnection) async {
        // `NSXPCConnection` is not Sendable; the block only invalidates it,
        // which NSXPC allows from any thread.
        nonisolated(unsafe) let closed = connection
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closed.scheduleSendBarrierBlock {
                closed.invalidate()
                continuation.resume()
            }
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
                if let closing = finishRequest() {
                    finishClosing(closing, afterSentReplies: true)
                    break
                }
            }
        }
        // A drain: every queued request has run and replied. The connection
        // ends once those replies are sent, and the session after it.
        if let connection = finishDrain() {
            await Self.invalidateAfterSentReplies(connection)
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

// MARK: - Stop

/// Races a stop's drain against its deadline.
enum StopRace {
    /// Runs `operation` and `deadline` in tasks of their own; true if
    /// `operation` returned first. The loser is cancelled, but an operation
    /// waiting for the engine may keep running.
    static func run(
        deadline: @escaping @Sendable () async -> Void,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.begin(continuation)
            let work = Task {
                await operation()
                race.finish(true)
            }
            let timer = Task {
                await deadline()
                race.finish(false)
            }
            race.adopt([work, timer])
        }
    }

    /// The first side to finish resumes the caller; both tasks are then
    /// cancelled.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var isFinished = false
        private var tasks: [Task<Void, Never>] = []

        func begin(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func adopt(_ tasks: [Task<Void, Never>]) {
            let cancelNow = lock.withLock {
                self.tasks = tasks
                return isFinished
            }
            if cancelNow {
                for task in tasks {
                    task.cancel()
                }
            }
        }

        func finish(_ outcome: Bool) {
            let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, [Task<Void, Never>]) in
                guard !isFinished else { return (nil, []) }
                isFinished = true
                defer { self.continuation = nil }
                return (self.continuation, self.tasks)
            }
            continuation?.resume(returning: outcome)
            for task in tasks {
                task.cancel()
            }
        }
    }
}
