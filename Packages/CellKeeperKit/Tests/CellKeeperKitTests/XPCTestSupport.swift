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
    private let lock = NSLock()
    private var recorded: [HelperXPCConnectionEvent] = []

    var events: [HelperXPCConnectionEvent] {
        lock.withLock { recorded }
    }

    func record(_ event: HelperXPCConnectionEvent) {
        lock.withLock { recorded.append(event) }
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
