import CellKeeperCore
import CellKeeperKit
import CellKeeperHelperCore
@testable import CellKeeperHelperXPC
import Foundation
import Testing

/// How long a test lets a connection be set up and answered: far longer than
/// any healthy call takes, also on a slow CI runner whose first connection
/// checks the test binary's signature. Timeouts under test are driven by
/// ``ManualTimeouts`` instead, never by this.
let setupTimeout: Duration = .seconds(30)

/// A monotonic clock the test moves by hand. Unless `step` is set, readings
/// repeat until the test advances it, so two engines that do the same work
/// read the same times.
final class XPCTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 80_000
    private let step: TimeInterval

    /// - Parameter step: how far each reading moves the clock.
    init(step: TimeInterval = 0) {
        self.step = step
    }

    var uptime: TimeInterval {
        lock.withLock {
            now += step
            return now
        }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { now += interval }
    }
}

/// The helper's power reading: on external power with an adapter, at a safe
/// charge, cool, stamped with the clock's time when read.
struct SafePower: HelperPowerReading {
    let clock: XPCTestClock

    func latestPowerState() -> HelperPowerState? {
        HelperPowerState(stateOfCharge: 60, isOnExternalPower: true, isAdapterPresent: true, isThermalPressureHigh: false, readAtUptime: clock.uptime)
    }
}

/// Collects a helper engine's events.
final class XPCEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HelperEvent] = []

    var events: [HelperEvent] {
        lock.withLock { recorded }
    }

    func record(_ event: HelperEvent) {
        lock.withLock { recorded.append(event) }
    }

    func contains(_ event: HelperEvent) -> Bool {
        events.contains(event)
    }

    var openedSessions: [HelperSessionID] {
        events.compactMap {
            if case .sessionOpened(let id) = $0 { return id }
            return nil
        }
    }

    var invalidatedSessions: [HelperSessionID] {
        events.compactMap {
            if case .sessionInvalidated(let id) = $0 { return id }
            return nil
        }
    }

    /// The events that name `session` as the one making a request: a lease,
    /// an activation, a refusal. Anything a request of that session did.
    func requestEvents(of session: HelperSessionID) -> [HelperEvent] {
        events.filter {
            switch $0 {
            case .leaseGranted(let id, _, _), .leaseRenewed(let id, _, _), .activated(_, by: let id), .requestRejected(let id, _, _):
                id == session
            default:
                false
            }
        }
    }
}

/// Collects the server's connection events.
final class ConnectionEventLog: @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let matches: @Sendable (HelperXPCConnectionEvent) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var recorded: [HelperXPCConnectionEvent] = []
    private var waiters: [Waiter] = []
    private var nextWaiter = 0
    /// Waits whose time ran out before they were registered.
    private var expired: Set<Int> = []

    var events: [HelperXPCConnectionEvent] {
        lock.withLock { recorded }
    }

    func record(_ event: HelperXPCConnectionEvent) {
        let matched = lock.withLock { () -> [Waiter] in
            recorded.append(event)
            let matched = waiters.filter { $0.matches(event) }
            waiters.removeAll { $0.matches(event) }
            return matched
        }
        for waiter in matched {
            waiter.continuation.resume(returning: true)
        }
    }

    /// Waits until an event that `matches` has been recorded, woken by its
    /// arrival, until `seconds` after the call at most. Connection events
    /// reach the host asynchronously, so a test waits for them rather than
    /// expecting them when a call returns. The deadline is fixed on entry,
    /// and a timeout that fires before the wait is registered is remembered,
    /// so the wait is bounded whichever comes first.
    func waitFor(within seconds: Double = 10, _ matches: @escaping @Sendable (HelperXPCConnectionEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        let id = lock.withLock {
            nextWaiter += 1
            return nextWaiter
        }
        let timeout = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            self?.expire(id)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            let found = lock.withLock { () -> Bool? in
                if recorded.contains(where: matches) { return true }
                if expired.remove(id) != nil { return false }
                waiters.append(Waiter(id: id, matches: matches, continuation: continuation))
                return nil
            }
            if let found {
                continuation.resume(returning: found)
            }
        }
    }

    private func expire(_ id: Int) {
        let waiter = lock.withLock { () -> Waiter? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                expired.insert(id)
                return nil
            }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume(returning: false)
    }

    func closeReason(of session: HelperSessionID) -> HelperXPCCloseReason? {
        for event in events {
            if case .closed(session, let reason) = event { return reason }
        }
        return nil
    }

    var refusals: [HelperXPCRefusal] {
        events.compactMap {
            if case .refused(_, _, let reason) = $0 { return reason }
            return nil
        }
    }
}

/// A charge control whose read-back can be made to hang until the test lets
/// it go, to model a helper that does not answer. Tests release it in a
/// `defer`, and the stall ends by itself after 10 s at the latest, so a
/// failing test cannot hang the run.
final class StallingChargeControl: HelperChargeControl, @unchecked Sendable {
    let inner = SimulatedChargeControl()
    private let lock = NSLock()
    private var stallsNextReadBack = false
    private var stalled = false
    private let released = DispatchSemaphore(value: 0)

    /// The next read-back blocks until ``release()``.
    func stallNextReadBack() {
        lock.withLock { stallsNextReadBack = true }
    }

    /// True while a read-back is blocked.
    var isStalled: Bool {
        lock.withLock { stalled }
    }

    func release() {
        released.signal()
    }

    func probe() -> HelperProbe {
        inner.probe()
    }

    func apply(_ control: HelperControl, active: Bool) throws {
        try inner.apply(control, active: active)
    }

    func readBack() throws -> Set<HelperControl> {
        let stalls = lock.withLock {
            defer { stallsNextReadBack = false }
            stalled = stallsNextReadBack
            return stallsNextReadBack
        }
        if stalls {
            _ = released.wait(timeout: .now() + 10)
            lock.withLock { stalled = false }
        }
        return try inner.readBack()
    }

    func restoreDefaults() throws {
        try inner.restoreDefaults()
    }
}

/// Call timeouts that fire only when the test says so.
final class ManualTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@Sendable () -> Void] = []

    var scheduler: HelperXPCClient.TimeoutScheduler {
        { [self] _, action in
            lock.withLock { actions.append(action) }
        }
    }

    /// Fires every timeout scheduled so far; those of calls that have
    /// already ended do nothing.
    func fireAll() {
        let due = lock.withLock {
            defer { actions.removeAll() }
            return actions
        }
        for action in due {
            action()
        }
    }
}

/// A lease activity that does nothing.
struct NoLeaseActivity: LeaseActivity {
    func setHolding(_ isHolding: Bool) {}
}

/// The test process's own designated requirement, which the test process
/// itself satisfies: used on both sides of a connection inside the test, so
/// the requirement checks of NSXPC run for real against the test binary.
func ownRequirement() throws -> HelperCodeSigningRequirement {
    do {
        return try HelperCodeSigningRequirement.currentProcessDesignatedRequirement()
    } catch {
        Issue.record("The test host has no readable designated requirement (\(error)); the NSXPC requirement tests cannot run.")
        throw error
    }
}

/// A requirement that is valid but that nothing in the test satisfies.
func unmatchableRequirement() throws -> HelperCodeSigningRequirement {
    try HelperCodeSigningRequirement(validating: #"identifier "io.github.saltedtan.cellkeeper.tests.nomatch""#)
}

/// The failures that show a connection was refused or ended. A timeout is
/// not among them: it would also be what a test sees if nothing happened.
let connectionFailures: [HelperXPCError?] = [.interrupted, .invalidated, .requirementNotMet]
let appConnectionFailures: [HelperTransportError?] = [.interrupted, .invalidated, .requirementNotMet]

/// The client failure `body` threw; nil if it returned or threw another
/// error.
func clientFailure(_ body: () async throws -> Void) async -> HelperXPCError? {
    do {
        try await body()
        return nil
    } catch {
        return error as? HelperXPCError
    }
}

/// The transport error `body` threw; nil if it returned or threw another
/// error.
func transportFailure(_ body: () async throws -> Void) async -> HelperTransportError? {
    do {
        try await body()
        return nil
    } catch {
        return error as? HelperTransportError
    }
}

/// A ``HelperXPCServer`` on its own anonymous listener, started unless the
/// test says otherwise.
struct XPCRig {
    let listener: NSXPCListener
    let server: HelperXPCServer
    let events: XPCEventLog
    let connections: ConnectionEventLog
    let clock: XPCTestClock

    init(
        control: any HelperChargeControl = SimulatedChargeControl(),
        clock: XPCTestClock = XPCTestClock(),
        clientRequirement: HelperCodeSigningRequirement? = nil,
        start: Bool = true
    ) async throws {
        let events = XPCEventLog()
        let connections = ConnectionEventLog()
        let listener = NSXPCListener.anonymous()
        let server = HelperXPCServer(
            listener: listener,
            clientRequirement: try clientRequirement ?? ownRequirement(),
            control: control,
            power: SafePower(clock: clock),
            build: 42,
            uptime: { clock.uptime },
            events: { events.record($0) },
            connectionEvents: { connections.record($0) }
        )
        if start {
            #expect(await server.start() == .ok)
        }
        self.listener = listener
        self.server = server
        self.events = events
        self.connections = connections
        self.clock = clock
    }

    var destination: HelperXPCClient.Destination {
        .endpoint(listener.endpoint)
    }

    /// A client with a generous timeout, or with timeouts the test fires.
    func client(requirement: HelperCodeSigningRequirement? = nil, timeouts: ManualTimeouts? = nil) throws -> HelperXPCClient {
        HelperXPCClient(
            destination: destination,
            helperRequirement: try requirement ?? ownRequirement(),
            timeout: setupTimeout,
            scheduler: timeouts?.scheduler ?? HelperXPCClient.dispatchScheduler
        )
    }

    func transport() throws -> XPCHelperTransport {
        XPCHelperTransport(destination: destination, helperRequirement: try ownRequirement(), timeout: setupTimeout)
    }

    func raw() throws -> RawHelperConnection {
        try RawHelperConnection(endpoint: listener.endpoint)
    }
}

/// A bare NSXPC connection to a server, with none of the client's logic: it
/// neither closes itself after a failure nor guards against a second
/// outcome, so tests see what NSXPC itself delivers, and can send without
/// waiting. Each call is numbered; its outcomes are recorded.
final class RawHelperConnection: @unchecked Sendable {
    // @unchecked Sendable: `connection` is configured in `init` only;
    // the outcomes are guarded by `lock`.

    enum Outcome: Equatable, Sendable {
        case reply(status: Int)
        case error(HelperXPCError)
    }

    let connection: NSXPCConnection
    private let lock = NSLock()
    private var recorded: [Int: [Outcome]] = [:]

    init(endpoint: NSXPCListenerEndpoint) throws {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = HelperXPCInterface.make()
        connection.setCodeSigningRequirement(try ownRequirement().text)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// The proxy for call `id`: an error NSXPC reports for it is recorded.
    func proxy(_ id: Int) -> CellKeeperHelperXPCProtocol {
        // The interface is the protocol's, so the cast cannot fail.
        connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.record(id, .error(HelperXPCError(error)))
        } as! CellKeeperHelperXPCProtocol
    }

    func record(_ id: Int, _ outcome: Outcome) {
        lock.withLock { recorded[id, default: []].append(outcome) }
    }

    func outcomes(_ id: Int) -> [Outcome] {
        lock.withLock { recorded[id] ?? [] }
    }

    /// Sends `hello` as call `id`.
    func hello(_ id: Int) {
        proxy(id).hello(clientProtocolVersion: HelperProtocolVersion.current) { [weak self] status, _, _, _, _, _, _ in
            self?.record(id, .reply(status: status))
        }
    }

    func readState(_ id: Int) {
        proxy(id).readState { [weak self] status, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
            self?.record(id, .reply(status: status))
        }
    }

    func lease(_ id: Int, seconds: Int) {
        proxy(id).acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: seconds) { [weak self] status, _ in
            self?.record(id, .reply(status: status))
        }
    }

    func activate(_ id: Int) {
        proxy(id).setControl(control: HelperControl.chargingInhibited.rawValue, active: true) { [weak self] status in
            self?.record(id, .reply(status: status))
        }
    }
}

/// An NSXPC proxy that reply blocks can use to send the next request.
final class SendableProxy: @unchecked Sendable {
    // @unchecked Sendable: NSXPC proxies may be messaged from any thread.
    let helper: CellKeeperHelperXPCProtocol

    init(_ helper: CellKeeperHelperXPCProtocol) {
        self.helper = helper
    }
}

/// Numbers requests and sends them on one serial queue, so a request's
/// number is its place on the wire.
final class OrderedProducer: @unchecked Sendable {
    // @unchecked Sendable: `nextIndex` is only touched on `queue`.
    private let queue = DispatchQueue(label: "io.github.saltedtan.CellKeeper.tests.ordered-producer")
    private let count: Int
    private var nextIndex = 0

    init(count: Int) {
        self.count = count
    }

    /// Takes the next number, while there is one, and sends with it, both
    /// on the producer's queue.
    func next(_ send: @escaping @Sendable (Int) -> Void) {
        queue.async {
            guard self.nextIndex < self.count else { return }
            let index = self.nextIndex
            self.nextIndex += 1
            send(index)
        }
    }

    /// Runs `work` on the producer's queue, in order with the sends.
    func run(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}

/// Waits until `condition` holds, at most `seconds`; returns whether it did.
@discardableResult
func eventually(within seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Every reply of a helper connection, comparable across transports.
enum RecordedReply: Equatable {
    case hello(HelperHelloReply)
    case state(HelperStateReply)
    case lease(HelperLeaseReply)
    case status(HelperStatus)
}

/// A stand-in helper on an anonymous listener that answers every request
/// with the same raw status, to see what the client makes of replies the
/// real engine never sends.
final class RawStatusHelper: NSObject, NSXPCListenerDelegate, CellKeeperHelperXPCProtocol, @unchecked Sendable {
    // @unchecked Sendable: `listener` is only resumed in `init` and
    // invalidated in `deinit`; `status` never changes.

    let listener = NSXPCListener.anonymous()
    private let status: Int

    init(status: Int) throws {
        self.status = status
        super.init()
        listener.setConnectionCodeSigningRequirement(try ownRequirement().text)
        listener.delegate = self
        listener.resume()
    }

    deinit {
        listener.invalidate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = HelperXPCInterface.make()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func hello(clientProtocolVersion: Int, reply: @escaping HelperXPCHelloReplyBlock) {
        reply(status, HelperProtocolVersion.current, 1, 3, true, 1, 1)
    }

    func readState(reply: @escaping HelperXPCStateReplyBlock) {
        reply(status, 0, 0, 0, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    func acquireOrRenewLease(control: Int, seconds: Int, reply: @escaping HelperXPCLeaseReplyBlock) {
        reply(status, seconds)
    }

    func releaseLease(control: Int, reply: @escaping HelperXPCStatusReplyBlock) {
        reply(status)
    }

    func setControl(control: Int, active: Bool, reply: @escaping HelperXPCStatusReplyBlock) {
        reply(status)
    }

    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64, reply: @escaping HelperXPCStatusReplyBlock) {
        reply(status)
    }

    func restoreDefaults(reply: @escaping HelperXPCStatusReplyBlock) {
        reply(status)
    }

    func restoreDefaultsAndExit(reply: @escaping HelperXPCStatusReplyBlock) {
        reply(status)
    }
}

/// Opened by the test; until then, `wait()` suspends (never blocks a thread).
final class XPCGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let openNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if openNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting {
            waiter.resume()
        }
    }
}

/// Lets an engine's event sink reach a server made after the engine, as a
/// host's sink does.
final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: HelperXPCServer?

    var server: HelperXPCServer? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/// A stop's deadline the test moves by hand: it passes when the test says
/// so, and its timer can be woken with it, or left asleep as if it ran late.
final class TestDeadline: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`.

    private let lock = NSLock()
    private var passed = false
    private var isExpired = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    var deadline: HelperXPCServer.Deadline {
        HelperXPCServer.Deadline(hasPassed: { [self] in hasPassed }, wait: { [self] in await wait() })
    }

    var hasPassed: Bool {
        lock.withLock { passed }
    }

    /// True while the stop's timer waits for the deadline.
    var isAwaited: Bool {
        lock.withLock { !waiters.isEmpty }
    }

    /// The deadline passes, but its timer is not woken: a timer that runs
    /// late.
    func pass() {
        lock.withLock { passed = true }
    }

    /// The deadline passes and its timer is woken.
    func expire() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            passed = true
            isExpired = true
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// Returns once ``expire()`` has been called, or when the task is
    /// cancelled.
    private func wait() async {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if isExpired || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
}

/// Holds the server's send barriers of the given kinds when they run, as a
/// slow transport would, until the test releases them; others take effect
/// at once.
final class HeldBarriers: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`.

    private let lock = NSLock()
    private let kinds: Set<SendBarrierKind>
    private var held: [@Sendable () -> Void] = []

    init(holding kinds: Set<SendBarrierKind> = [.closing]) {
        self.kinds = kinds
    }

    /// Installs the hold on `server`.
    func install(on server: HelperXPCServer) {
        server.onSendBarrier { [self] kind, run in
            intercept(kind, run)
        }
    }

    private func intercept(_ kind: SendBarrierKind, _ run: @escaping @Sendable () -> Void) {
        let isHeld = lock.withLock { () -> Bool in
            guard kinds.contains(kind) else { return false }
            held.append(run)
            return true
        }
        if !isHeld {
            run()
        }
    }

    /// Barriers that have run and are being held.
    var heldCount: Int {
        lock.withLock { held.count }
    }

    /// Lets every held barrier take effect, and stops holding new ones.
    func releaseAll() {
        let released = lock.withLock { () -> [@Sendable () -> Void] in
            defer { held = [] }
            return held
        }
        for run in released {
            run()
        }
    }
}

/// Set once, read by the test: whether an asynchronous step has finished.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool {
        lock.withLock { isSet }
    }

    func set() {
        lock.withLock { isSet = true }
    }
}
