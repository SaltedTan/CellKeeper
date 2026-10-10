import CellKeeperHelperCore
import Foundation

/// CellKeeper's side of one NSXPC connection to the helper: one session.
///
/// - **Peer.** The helper must satisfy `helperRequirement`
///   (`setCodeSigningRequirement`, macOS 13), set before the connection is
///   resumed. No reply from a helper that does not satisfy it is ever
///   delivered: the call throws ``HelperXPCError/requirementNotMet``.
///   (The XPC runtime checks the peer when its first message arrives, so
///   CellKeeper's first request may already have reached it; CellKeeper's
///   requests carry nothing secret.)
/// - **Calls.** Each method sends one request and waits for its reply, at
///   most `timeout`. Exactly one outcome is delivered per call: the reply,
///   the connection's error, or the timeout, whichever comes first; anything
///   later is ignored.
/// - **Failure.** Any transport failure (an interruption, an invalidation,
///   a requirement the helper does not meet, a timeout, or a reply this
///   version cannot read) makes the client unusable: it invalidates its
///   connection, the calls in flight throw, and every later call throws
///   ``HelperXPCError/invalidated``. This matters because NSXPC would
///   otherwise reconnect an interrupted connection by itself, to a new
///   session that has not said hello. After a timeout, the invalidated
///   connection also makes sure a late reply cannot resume anything.
///   The helper ends the session when the connection ends, which clears
///   what it held; the caller connects again with a new client.
public final class HelperXPCClient: @unchecked Sendable {
    // @unchecked Sendable: `connection` is not Sendable, but it is configured
    // and resumed in `init` only, and afterwards only asked for proxies and
    // invalidated, which NSXPC allows from any thread. The mutable state is
    // guarded by `lock`.

    /// Where the helper listens.
    public enum Destination: @unchecked Sendable {
        // @unchecked Sendable: an `NSXPCListenerEndpoint` is immutable once
        // made; it only names a listener.

        /// The daemon's Mach service, in the privileged bootstrap
        /// (`NSXPCConnection.Options.privileged`).
        case machService(String)
        /// An anonymous listener's endpoint (tests).
        case endpoint(NSXPCListenerEndpoint)
    }

    /// How long a call waits for its reply by default.
    public static let defaultTimeout: Duration = .seconds(10)

    private let connection: NSXPCConnection
    private let timeout: Duration
    private let lock = NSLock()
    private var failure: HelperXPCError?
    private var pending: [UInt64: any FailableCall] = [:]
    private var nextCallID: UInt64 = 0

    /// Connects to the helper at `destination`. Nothing is sent until the
    /// first call; a helper that cannot be reached makes that call throw.
    ///
    /// - Parameters:
    ///   - helperRequirement: what the helper's code signature must satisfy:
    ///     ``HelperCodeSigningRequirement/forHelper(identifier:)`` in the app.
    ///   - timeout: how long each call waits for its reply; must be positive.
    public init(destination: Destination, helperRequirement: HelperCodeSigningRequirement, timeout: Duration = defaultTimeout) {
        precondition(timeout > .zero, "a helper call needs a positive timeout")
        self.timeout = timeout
        switch destination {
        case .machService(let name):
            connection = NSXPCConnection(machServiceName: name, options: .privileged)
        case .endpoint(let endpoint):
            connection = NSXPCConnection(listenerEndpoint: endpoint)
        }
        connection.remoteObjectInterface = HelperXPCInterface.make()
        // Before resume, as NSXPC requires. The requirement was compiled when
        // it was made, so this cannot hit NSXPC's fatal error for a
        // malformed one.
        connection.setCodeSigningRequirement(helperRequirement.text)
        connection.interruptionHandler = { [weak self] in self?.fail(.interrupted) }
        connection.invalidationHandler = { [weak self] in self?.fail(.invalidated) }
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// The transport failure that made this client unusable, if any.
    public var transportFailure: HelperXPCError? {
        lock.withLock { failure }
    }

    /// Ends the connection; the helper invalidates the session, which clears
    /// what it held. Calls in flight and every later call throw
    /// ``HelperXPCError/invalidated``. Calling it twice is harmless.
    public func invalidate() {
        fail(.invalidated)
    }

    // MARK: - Requests

    public func hello(clientProtocolVersion: Int) async throws -> HelperHelloReply {
        try await call { proxy, call in
            proxy.hello(clientProtocolVersion: clientProtocolVersion) { status, version, build, capabilities, isSimulated, session, instance in
                call.complete {
                    try HelperXPCWire.helloReply(
                        status: status,
                        helperProtocolVersion: version,
                        build: build,
                        capabilities: capabilities,
                        isSimulated: isSimulated,
                        sessionID: session,
                        helperInstance: instance
                    )
                }
            }
        }
    }

    public func readState() async throws -> HelperStateReply {
        try await call { proxy, call in
            proxy.readState { status, active, inhibitLease, adapterLease, isHolder, interlocks, lastError, errorCount,
                inhibitGeneration, inhibitCause, inhibitInterlocks, inhibitSession,
                adapterGeneration, adapterCause, adapterInterlocks, adapterSession in
                call.complete {
                    try HelperXPCWire.stateReply(
                        status: status,
                        activeControls: active,
                        chargingInhibitedLeaseSeconds: inhibitLease,
                        adapterDisabledLeaseSeconds: adapterLease,
                        isLeaseHolder: isHolder,
                        interlocks: interlocks,
                        lastHardwareError: lastError,
                        hardwareErrorCount: errorCount,
                        chargingInhibitedGeneration: inhibitGeneration,
                        chargingInhibitedChangeCause: inhibitCause,
                        chargingInhibitedChangeInterlocks: inhibitInterlocks,
                        chargingInhibitedChangeSession: inhibitSession,
                        adapterDisabledGeneration: adapterGeneration,
                        adapterDisabledChangeCause: adapterCause,
                        adapterDisabledChangeInterlocks: adapterInterlocks,
                        adapterDisabledChangeSession: adapterSession
                    )
                }
            }
        }
    }

    public func acquireOrRenewLease(control: Int, seconds: Int) async throws -> HelperLeaseReply {
        try await call { proxy, call in
            proxy.acquireOrRenewLease(control: control, seconds: seconds) { status, granted in
                call.complete { try HelperXPCWire.leaseReply(status: status, grantedSeconds: granted) }
            }
        }
    }

    public func releaseLease(control: Int) async throws -> HelperStatus {
        try await statusCall { proxy, reply in proxy.releaseLease(control: control, reply: reply) }
    }

    public func setControl(control: Int, active: Bool) async throws -> HelperStatus {
        try await statusCall { proxy, reply in proxy.setControl(control: control, active: active, reply: reply) }
    }

    public func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64) async throws -> HelperStatus {
        try await statusCall { proxy, reply in
            proxy.clearControlIfUnchanged(control: control, generation: generation, helperInstance: helperInstance, reply: reply)
        }
    }

    public func restoreDefaults() async throws -> HelperStatus {
        try await statusCall { proxy, reply in proxy.restoreDefaults(reply: reply) }
    }

    public func restoreDefaultsAndExit() async throws -> HelperStatus {
        try await statusCall { proxy, reply in proxy.restoreDefaultsAndExit(reply: reply) }
    }

    // MARK: - Calls

    private func statusCall(
        _ send: (CellKeeperHelperXPCProtocol, @escaping HelperXPCStatusReplyBlock) -> Void
    ) async throws -> HelperStatus {
        try await call { proxy, call in
            send(proxy) { status in
                call.complete { try HelperXPCWire.status(status) }
            }
        }
    }

    /// Sends one request through `send`, which must hand the reply to the
    /// call, and returns the first outcome: the reply, an error from NSXPC,
    /// or the timeout. A failure makes the client unusable before the
    /// caller resumes, so its next call throws.
    private func call<Reply: Sendable>(
        _ send: (CellKeeperHelperXPCProtocol, PendingCall<Reply>) -> Void
    ) async throws -> Reply {
        let result: Result<Reply, HelperXPCError> = await withCheckedContinuation { continuation in
            let call = PendingCall<Reply>(continuation: continuation, client: self)
            guard register(call) else {
                call.take()?.resume(returning: .failure(.invalidated))
                return
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                // NSXPC may report an error for a call after its reply (for
                // example when the connection ends later); only the first
                // outcome counts, but the connection has failed either way.
                let failure = HelperXPCError(error)
                let continuation = call.take()
                self?.fail(failure)
                continuation?.resume(returning: .failure(failure))
            }
            guard let helper = proxy as? CellKeeperHelperXPCProtocol else {
                let continuation = call.take()
                fail(.invalidated)
                continuation?.resume(returning: .failure(.invalidated))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.dispatchInterval(timeout)) { [weak self] in
                guard let continuation = call.take() else { return }
                // The connection is invalidated before the caller resumes, so
                // a late reply can never be delivered to anything.
                self?.fail(.timedOut)
                continuation.resume(returning: .failure(.timedOut))
            }
            send(helper, call)
        }
        return try result.get()
    }

    /// Records the client's first failure, invalidates the connection and
    /// fails every call still in flight with ``HelperXPCError/invalidated``.
    /// A call that met the failure itself takes its continuation first and
    /// resumes it with that failure afterwards.
    fileprivate func fail(_ error: HelperXPCError) {
        let calls: [any FailableCall] = lock.withLock {
            if failure == nil {
                failure = error
            }
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        connection.invalidate()
        for call in calls {
            call.fail(.invalidated)
        }
    }

    /// Adds a call to those in flight; false if the client has already
    /// failed.
    private func register(_ call: any FailableCall) -> Bool {
        lock.withLock {
            guard failure == nil else { return false }
            nextCallID += 1
            call.id = nextCallID
            pending[nextCallID] = call
            return true
        }
    }

    fileprivate func unregister(_ id: UInt64) {
        _ = lock.withLock { pending.removeValue(forKey: id) }
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        let nanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanoseconds.overflow else { return .never }
        let total = nanoseconds.partialValue.addingReportingOverflow(attoseconds / 1_000_000_000)
        guard !total.overflow, total.partialValue <= Int64(Int.max) else { return .never }
        return .nanoseconds(Int(total.partialValue))
    }
}

/// A call in flight that the client can fail.
private protocol FailableCall: AnyObject, Sendable {
    var id: UInt64 { get set }
    func fail(_ error: HelperXPCError)
}

/// One call's outcome, delivered exactly once: the reply block, the error
/// handler, the timeout and the client's failure race, and whichever takes
/// the continuation first resumes the caller.
private final class PendingCall<Reply: Sendable>: FailableCall, @unchecked Sendable {
    // @unchecked Sendable: all mutable state is guarded by `lock`.

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Reply, HelperXPCError>, Never>?
    private weak var client: HelperXPCClient?
    private var callID: UInt64 = 0

    init(continuation: CheckedContinuation<Result<Reply, HelperXPCError>, Never>, client: HelperXPCClient) {
        self.continuation = continuation
        self.client = client
    }

    var id: UInt64 {
        get { lock.withLock { callID } }
        set { lock.withLock { callID = newValue } }
    }

    /// Takes the continuation if no outcome has been delivered yet; nil
    /// otherwise. The call is no longer in flight.
    func take() -> CheckedContinuation<Result<Reply, HelperXPCError>, Never>? {
        let (continuation, id) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, callID)
        }
        if continuation != nil {
            client?.unregister(id)
        }
        return continuation
    }

    /// Delivers the reply. A reply that cannot be read is
    /// ``HelperXPCError/malformedReply``, which also makes the client
    /// unusable.
    func complete(_ decode: () throws -> Reply) {
        guard let continuation = take() else { return }
        do {
            continuation.resume(returning: .success(try decode()))
        } catch {
            client?.fail(.malformedReply)
            continuation.resume(returning: .failure(.malformedReply))
        }
    }

    func fail(_ error: HelperXPCError) {
        take()?.resume(returning: .failure(error))
    }
}
