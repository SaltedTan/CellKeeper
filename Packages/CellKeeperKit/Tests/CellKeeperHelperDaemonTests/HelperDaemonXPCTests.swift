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
    /// listener; its stop gives up only when `stopDeadline` opens.
    private struct Served {
        let harness: DaemonHarness
        let listener: NSXPCListener
        let stopDeadline = Gate()

        init(control: any HelperChargeControl) {
            let listener = NSXPCListener.anonymous()
            let stopDeadline = stopDeadline
            let frontend = XPCFrontend(
                listener: listener,
                requirement: { try HelperCodeSigningRequirement.currentProcessDesignatedRequirement() },
                stopDeadline: { await stopDeadline.wait() }
            )
            self.listener = listener
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

    @Test("A stop that cannot drain within its budget reports it, and the daemon exits with 75")
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

        // The frontend's stop gives up: the request is still in the engine,
        // and so is the daemon's restore behind it, so its retries run out.
        served.stopDeadline.open()
        let gaveUp = await eventually { h.log.contains(.fault, .xpc, "The frontend stopped without confirming") }
        #expect(gaveUp)
        let retrying = HelperDaemon.terminationDeadline - HelperDaemon.finalisationReserve
        let waiting = await eventually { h.clock.waits.contains(retrying - 0.001...retrying) }
        #expect(waiting)
        h.clock.advance(by: retrying)
        let exited = await eventually { !h.exits.statuses.isEmpty }
        #expect(exited)
        #expect(h.exits.statuses == [HelperDaemon.restoreNotConfirmedExitStatus])

        #expect(h.log.contains(.fault, .xpc, "The frontend could not confirm that it stopped serving"))

        control.release()
        #expect(await running.value == HelperDaemon.restoreNotConfirmedExitStatus)
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
            requirement: { try HelperCodeSigningRequirement.forClientApp(identifier: XPCFrontend.clientIdentifier) },
            stopDeadline: {}
        )
        let h = DaemonHarness(frontend: frontend)
        let daemon = h.daemon
        #expect(await daemon.run() == 0)
        #expect(h.log.contains(.fault, .xpc, "The frontend could not start (\(HelperCodeSigningRequirementError.noTeamIdentifier))"))
        #expect(!h.log.contains(.notice, .xpc, "Serving CellKeeper over NSXPC"))
        #expect(await frontend.stop())
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
