@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import CellKeeperHelperXPC
import Foundation
import Testing

/// The daemon serving its engine over NSXPC, end to end: an anonymous
/// listener in the test process, with the test binary's own designated
/// requirement on both sides, so NSXPC checks a real code signature on
/// every connection. The daemon's time is the manual clock; NSXPC's is
/// real, but every wait here waits for a condition, never for time. Stalls
/// block the engine's own queue, never a thread of Swift's cooperative pool;
/// the tests run one at a time to keep their choreography simple.
@Suite("Helper daemon over NSXPC", .serialized)
struct HelperDaemonXPCTests {
    /// A daemon whose frontend is an ``XPCFrontend`` on an anonymous
    /// listener; what its stops return is recorded.
    private struct Served {
        let harness: DaemonHarness
        let listener: NSXPCListener
        let frontend: StopRecordingFrontend

        init(control: any HelperChargeControl) {
            let listener = NSXPCListener.anonymous()
            let frontend = StopRecordingFrontend(XPCFrontend(
                listener: listener,
                requirement: { try HelperCodeSigningRequirement.currentProcessDesignatedRequirement() }
            ))
            self.listener = listener
            self.frontend = frontend
            harness = DaemonHarness(control: control, frontend: frontend)
        }

        /// Runs the daemon until it serves and its first tick is scheduled.
        func run() async -> Task<Int32, Never> {
            let daemon = harness.daemon
            let running = Task { await daemon.run() }
            let harness = harness
            _ = await eventually {
                harness.log.contains(.notice, .xpc, "Serving CellKeeper over NSXPC")
                    && harness.clock.waits.contains(HelperDaemon.tickInterval - 0.001...HelperDaemon.tickInterval)
            }
            return running
        }

        func client() throws -> HelperXPCClient {
            HelperXPCClient(
                destination: .endpoint(listener.endpoint),
                helperRequirement: try HelperCodeSigningRequirement.currentProcessDesignatedRequirement(),
                timeout: .seconds(30)
            )
        }
    }

    @Test("Through the daemon, a client's hello shows no capabilities and no simulation, and every activation is unsupported (R12a)")
    func monitorOnly() async throws {
        let served = Served(control: UnknownHardwareChargeControl())
        let h = served.harness
        let running = await served.run()
        let client = try served.client()

        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(hello.status == .ok)
        #expect(hello.capabilities.isEmpty)
        #expect(hello.isSimulated == false)
        for control in HelperControl.allCases {
            #expect(try await client.setControl(control: control.rawValue, active: true) == .unsupportedControl)
        }
        let accepted = await eventually { h.log.contains(.info, .xpc, "Accepted a connection") }
        #expect(accepted)

        #expect(await h.terminate(running) == 0)
        #expect(connectionFailures.contains(await clientFailure { _ = try await client.readState() }))
    }

    @Test("A client's restoreDefaultsAndExit gets its reply, and the daemon then exits with 0")
    func restoreAndExit() async throws {
        let control = SimulatedChargeControl()
        let served = Served(control: control)
        let h = served.harness
        let running = await served.run()
        let client = try served.client()
        #expect(try await client.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        #expect(try await client.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900).status == .ok)
        #expect(try await client.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)

        // The reply arrives: it was sent before the connection ended.
        #expect(try await client.restoreDefaultsAndExit() == .ok)
        #expect(await running.value == 0)
        #expect(h.exits.statuses == [0])
        #expect(control.activeControls.isEmpty)
        #expect(h.log.contains(.notice, .lifecycle, "Exit requested by a client"))
    }

    @Test("SIGTERM while a request is in the engine: its reply is sent before its session ends, and the daemon exits with 0")
    func sigtermDuringRequest() async throws {
        let control = BlockingControl()
        let served = Served(control: control)
        let h = served.harness
        let running = await served.run()
        let client = try served.client()
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(hello.status == .ok)

        control.holdNextReadBack()
        let inFlight = Task { try? await client.readState().status }
        let held = await eventually { control.isHolding }
        #expect(held)
        h.signals.sendSIGTERM()
        let stopping = await eventually { h.log.contains(.notice, .lifecycle, "SIGTERM: stopping the frontend") }
        #expect(stopping)

        control.release()
        // The client gets the reply, not a closed connection.
        #expect(await inFlight.value == .ok)
        #expect(await running.value == 0)
        // The session ended during the stop, before the daemon exited. (The
        // connection's own close is reported to the log asynchronously, and
        // may come after the daemon has finished its log.)
        let session = HelperSessionID(rawValue: Int(hello.sessionID))
        #expect(h.log.lines.contains { $0.message == "engine: \(HelperEvent.sessionInvalidated(session))" })
    }

    @Test("A stop that cannot drain by the shutdown's deadline cuts the connection off and returns false, and the daemon exits with 75")
    func stopCannotDrain() async throws {
        let control = BlockingControl()
        let served = Served(control: control)
        let h = served.harness
        let running = await served.run()
        let client = try served.client()
        #expect(try await client.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)

        control.holdNextReadBack()
        let inFlight = Task { await clientFailure { _ = try await client.readState() } }
        let held = await eventually { control.isHolding }
        #expect(held)
        h.signals.sendSIGTERM()
        let stopping = await eventually { h.log.contains(.notice, .lifecycle, "SIGTERM: stopping the frontend") }
        #expect(stopping)

        // The request is still in the engine, and so is the daemon's restore
        // behind it. The frontend's deadline and the end of the retries are
        // the same instant: 7 s into the shutdown, on the daemon's clock.
        let retrying = HelperDaemon.terminationDeadline - HelperDaemon.finalisationReserve
        let waiting = await eventually { h.clock.waits.filter { (retrying - 0.001...retrying).contains($0) }.count == 2 }
        #expect(waiting)
        h.clock.advance(by: retrying)
        // The stop returns false without waiting for the engine.
        let frontend = served.frontend
        let gaveUp = await eventually { frontend.stopResults == [false] }
        #expect(gaveUp)
        #expect(control.isHolding)
        let exited = await eventually { !h.exits.statuses.isEmpty }
        #expect(exited)
        #expect(h.exits.statuses == [HelperDaemon.restoreNotConfirmedExitStatus])

        control.release()
        #expect(await running.value == HelperDaemon.restoreNotConfirmedExitStatus)
        #expect(connectionFailures.contains(await inFlight.value))
    }

    @Test("A stop whose timer starts only after its deadline has passed returns false as soon as it starts: the deadline is absolute")
    func lateTimer() async throws {
        let clock = ManualClock()
        let control = BlockingControl()
        let engine = HelperEngine(control: control, power: StubPower(clock: clock), build: 1, uptime: { clock.uptime() }, events: { _ in })
        #expect(await engine.start() == .ok)
        let listener = NSXPCListener.anonymous()
        let frontend = XPCFrontend(listener: listener, requirement: { try HelperCodeSigningRequirement.currentProcessDesignatedRequirement() })
        try frontend.start(serving: engine, log: RecordingLog())
        let client = HelperXPCClient(
            destination: .endpoint(listener.endpoint),
            helperRequirement: try HelperCodeSigningRequirement.currentProcessDesignatedRequirement(),
            timeout: .seconds(30)
        )
        #expect(try await client.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        control.holdNextReadBack()
        let inFlight = Task { await clientFailure { _ = try await client.readState() } }
        let held = await eventually { control.isHolding }
        #expect(held)

        // The stop's timer is scheduled late: it starts only once `late`
        // opens, after the clock has passed the deadline.
        let late = Gate()
        let timerStarting = Flag()
        clock.beforeNextSleep { timerStarting.set(true) }
        clock.holdNextSleep(until: late)
        let deadline = HelperDaemonDeadline(uptime: clock.uptime() + 5, on: clock)
        let stopping = Task { await frontend.stop(by: deadline) }
        let starting = await eventually { timerStarting.value }
        #expect(starting)
        clock.advance(by: 6)
        late.open()
        // No further time passes: the timer finds its deadline gone.
        #expect(await stopping.value == false)
        #expect(control.isHolding)

        control.release()
        #expect(connectionFailures.contains(await inFlight.value))
    }

    @Test(
        "A build without a team identifier cannot build the client requirement: the daemon never listens, and exits with 0",
        .enabled(if: HelperCodeSigningRequirement.currentProcessTeamIdentifier() == nil, "the test binary is signed with a team")
    )
    func adHocRefusesToListen() async {
        let listener = NSXPCListener.anonymous()
        let frontend = XPCFrontend(
            listener: listener,
            requirement: { try HelperCodeSigningRequirement.forClientApp(identifier: XPCFrontend.clientIdentifier) }
        )
        let h = DaemonHarness(frontend: frontend)
        let daemon = h.daemon
        #expect(await daemon.run() == 0)
        #expect(h.log.contains(.fault, .xpc, "The frontend could not start (\(HelperCodeSigningRequirementError.noTeamIdentifier))"))
        #expect(!h.log.contains(.notice, .xpc, "Serving CellKeeper over NSXPC"))
        #expect(await frontend.stop(by: HelperDaemonDeadline(uptime: h.clock.uptime() + 1, on: h.clock)))
    }

    @Test(
        "The shipped frontend refuses to start in a build without a team identifier, before any Mach-service listener exists",
        .enabled(if: HelperCodeSigningRequirement.currentProcessTeamIdentifier() == nil, "the test binary is signed with a team")
    )
    func shippedFrontendRefuses() {
        let clock = ManualClock()
        let engine = HelperEngine(control: UnknownHardwareChargeControl(), power: StubPower(clock: clock), build: 1, uptime: { clock.uptime() }, events: { _ in })
        #expect(throws: HelperCodeSigningRequirementError.noTeamIdentifier) {
            try XPCFrontend().start(serving: engine, log: RecordingLog())
        }
    }
}

/// Passes everything to another frontend, and records what its stops
/// returned.
private final class StopRecordingFrontend: HelperFrontend, @unchecked Sendable {
    private let inner: any HelperFrontend
    private let lock = NSLock()
    private var results: [Bool] = []

    init(_ inner: any HelperFrontend) {
        self.inner = inner
    }

    var stopResults: [Bool] {
        lock.withLock { results }
    }

    func start(serving engine: HelperEngine, log: any HelperDaemonLog) throws {
        try inner.start(serving: engine, log: log)
    }

    func handle(_ event: HelperEvent) {
        inner.handle(event)
    }

    func stop(by deadline: HelperDaemonDeadline) async -> Bool {
        let result = await inner.stop(by: deadline)
        lock.withLock { results.append(result) }
        return result
    }
}

/// The client failures that mean the connection ended.
private let connectionFailures: [HelperXPCError?] = [.interrupted, .invalidated, .requirementNotMet]

/// The client failure `body` threw; nil if it returned or threw another
/// error.
private func clientFailure(_ body: () async throws -> Void) async -> HelperXPCError? {
    do {
        try await body()
        return nil
    } catch {
        return error as? HelperXPCError
    }
}
