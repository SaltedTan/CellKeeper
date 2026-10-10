import CellKeeperCore
import CellKeeperKit
import CellKeeperHelperCore
@testable import CellKeeperHelperXPC
import Foundation
import Testing

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
}

/// A charge control whose read-back can be made to hang until the test lets
/// it go, to model a helper that does not answer.
final class StallingChargeControl: HelperChargeControl, @unchecked Sendable {
    let inner = SimulatedChargeControl()
    private let lock = NSLock()
    private var stallsNextReadBack = false
    private let released = DispatchSemaphore(value: 0)

    /// The next read-back blocks until ``release()`` (at most 10 s, so a
    /// failing test cannot hang the run).
    func stallNextReadBack() {
        lock.withLock { stallsNextReadBack = true }
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
            return stallsNextReadBack
        }
        if stalls {
            _ = released.wait(timeout: .now() + 10)
        }
        return try inner.readBack()
    }

    func restoreDefaults() throws {
        try inner.restoreDefaults()
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

/// A started ``HelperXPCServer`` on its own anonymous listener.
struct XPCRig {
    let listener: NSXPCListener
    let server: HelperXPCServer
    let events: XPCEventLog
    let clock: XPCTestClock

    init(
        control: any HelperChargeControl = SimulatedChargeControl(),
        clock: XPCTestClock = XPCTestClock(),
        clientRequirement: HelperCodeSigningRequirement? = nil
    ) async throws {
        let events = XPCEventLog()
        let listener = NSXPCListener.anonymous()
        let server = HelperXPCServer(
            listener: listener,
            clientRequirement: try clientRequirement ?? ownRequirement(),
            control: control,
            power: SafePower(clock: clock),
            build: 42,
            uptime: { clock.uptime },
            events: { events.record($0) }
        )
        #expect(await server.start() == .ok)
        self.listener = listener
        self.server = server
        self.events = events
        self.clock = clock
    }

    var destination: HelperXPCClient.Destination {
        .endpoint(listener.endpoint)
    }

    func client(requirement: HelperCodeSigningRequirement? = nil, timeout: Duration = HelperXPCClient.defaultTimeout) throws -> HelperXPCClient {
        HelperXPCClient(destination: destination, helperRequirement: try requirement ?? ownRequirement(), timeout: timeout)
    }

    func transport() throws -> XPCHelperTransport {
        XPCHelperTransport(destination: destination, helperRequirement: try ownRequirement())
    }
}

/// Waits until `condition` holds, at most `seconds`; returns whether it did.
@discardableResult
func eventually(within seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
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
