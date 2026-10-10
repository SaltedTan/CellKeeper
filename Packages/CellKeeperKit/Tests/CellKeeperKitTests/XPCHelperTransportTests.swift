@testable import CellKeeperKit
import CellKeeperCore
import CellKeeperHelperCore
@testable import CellKeeperHelperXPC
import Foundation
import Testing

/// The NSXPC transport, over an anonymous listener in this process. Each
/// test makes its own listener, server and engine. Unless a test says
/// otherwise, both sides require the test process's own designated
/// requirement, so NSXPC checks the code signature of the test binary on
/// every connection.
@Suite("Helper NSXPC transport")
struct XPCHelperTransportTests {
    // MARK: - Round trip

    /// Runs every request once, in a fixed order, and records the replies.
    /// The helper instance is random per engine, so it is zeroed.
    private func exercise(_ connection: any HelperConnection, clock: XPCTestClock) async throws -> [RecordedReply] {
        var replies: [RecordedReply] = []
        var hello = try await connection.hello(clientProtocolVersion: HelperProtocolVersion.current)
        let instance = hello.helperInstance
        #expect(instance != 0)
        hello.helperInstance = 0
        replies.append(.hello(hello))
        replies.append(.state(try await connection.readState()))
        replies.append(.lease(try await connection.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)))
        replies.append(.status(try await connection.setControl(control: HelperControl.chargingInhibited.rawValue, active: true)))
        let held = try await connection.readState()
        replies.append(.state(held))
        // Raw values cross unchanged: the largest generation is simply not
        // the control's.
        replies.append(.status(try await connection.clearControlIfUnchanged(control: 1, generation: UInt64.max, helperInstance: instance)))
        replies.append(.status(try await connection.clearControlIfUnchanged(
            control: 1, generation: held.change(for: .chargingInhibited).generation, helperInstance: instance
        )))
        clock.advance(by: HelperEngine.minimumActivationInterval + 1)
        replies.append(.lease(try await connection.acquireOrRenewLease(control: 1, seconds: 900)))
        replies.append(.status(try await connection.setControl(control: 1, active: true)))
        replies.append(.status(try await connection.releaseLease(control: 1)))
        replies.append(.status(try await connection.setControl(control: 2, active: false)))
        replies.append(.status(try await connection.setControl(control: 7, active: true)))
        replies.append(.lease(try await connection.acquireOrRenewLease(control: 99, seconds: 60)))
        replies.append(.lease(try await connection.acquireOrRenewLease(control: 1, seconds: -5)))
        replies.append(.status(try await connection.restoreDefaults()))
        replies.append(.state(try await connection.readState()))
        replies.append(.status(try await connection.restoreDefaultsAndExit()))
        replies.append(.state(try await connection.readState()))
        var late = try await connection.hello(clientProtocolVersion: HelperProtocolVersion.current)
        late.helperInstance = 0
        replies.append(.hello(late))
        return replies
    }

    @Test("Every request round-trips over NSXPC with the same replies as the in-process transport, with the test binary's own requirement on both sides")
    func roundTrip() async throws {
        let inProcessClock = XPCTestClock()
        let inProcess = InProcessHelperTransport(
            control: SimulatedChargeControl(),
            power: SafePower(clock: inProcessClock),
            build: 42,
            uptime: { inProcessClock.uptime },
            tickInterval: .seconds(3_600)
        )
        let expected = try await exercise(try await inProcess.connect(), clock: inProcessClock)

        let control = SimulatedChargeControl()
        let rig = try await XPCRig(control: control)
        let connection = try await rig.transport().connect()
        let replies = try await exercise(connection, clock: rig.clock)

        #expect(replies == expected)
        #expect(replies.count == 19)
        // Spot checks, so the comparison cannot pass on two broken transports.
        #expect(replies.first == .hello(HelperHelloReply(
            status: .ok, helperProtocolVersion: HelperProtocolVersion.current, build: 42,
            capabilities: [.chargingInhibit, .adapterDisable], isSimulated: true, sessionID: 1, helperInstance: 0
        )))
        #expect(replies[3] == .status(.ok))
        #expect(replies[5] == .status(.controlChanged))
        #expect(replies[11] == .status(.invalidArgument))
        if case .state(let final) = replies[17] {
            #expect(final.status == .shuttingDown)
        } else {
            Issue.record("expected a state reply, got \(replies[17])")
        }
        #expect(replies.last == .hello(HelperHelloReply(
            status: .shuttingDown, helperProtocolVersion: HelperProtocolVersion.current, build: 42,
            capabilities: [.chargingInhibit, .adapterDisable], isSimulated: true, sessionID: 1, helperInstance: 0
        )))
        #expect(control.writes.contains(.apply(.chargingInhibited, active: true)))
        #expect(control.activeControls.isEmpty)
        #expect(await rig.server.engine.isShuttingDown)
        await connection.invalidate()
    }

    // MARK: - Code-signing requirements

    @Test("A client that does not meet the listener's requirement never reaches the engine")
    func listenerRefusesClient() async throws {
        let rig = try await XPCRig(clientRequirement: try unmatchableRequirement())
        let client = try rig.client()
        await #expect(throws: HelperXPCError.self) {
            try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        }
        #expect(client.transportFailure != nil)
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.restoreDefaults()
        }
        #expect(rig.events.openedSessions.isEmpty)
        #expect(rig.server.connectionCount == 0)

        // Through the app's transport, the failure is a transport error.
        let connection = try await rig.transport().connect()
        await #expect(throws: HelperTransportError.self) {
            try await connection.hello(clientProtocolVersion: HelperProtocolVersion.current)
        }
        #expect(rig.events.openedSessions.isEmpty)
    }

    @Test("A helper that does not meet the client's requirement gets no reply delivered, and the client is closed")
    func clientRefusesHelper() async throws {
        let rig = try await XPCRig()
        let client = try rig.client(requirement: try unmatchableRequirement())
        await #expect(throws: HelperXPCError.requirementNotMet) {
            try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        }
        #expect(client.transportFailure == .requirementNotMet)
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.readState()
        }
        // The first message may reach the helper before the client checks
        // it (research note 04, §2.2); the session it opened ends with the
        // connection.
        #expect(await eventually { rig.server.connectionCount == 0 })
    }

    // MARK: - Order

    @Test("One connection's requests reach the engine strictly in arrival order, and are answered in that order")
    func arrivalOrder() async throws {
        // Each clock reading is a second later, so the request budget never
        // runs out; leases are renewed long before they could end. Each
        // request asks for a different duration, all within the 900 s the
        // helper grants, so the engine's events show the order it saw.
        let rig = try await XPCRig(clock: XPCTestClock(step: 1))
        let connection = NSXPCConnection(listenerEndpoint: rig.listener.endpoint)
        connection.remoteObjectInterface = HelperXPCInterface.make()
        connection.setCodeSigningRequirement(try ownRequirement().text)
        connection.resume()
        defer { connection.invalidate() }
        let proxy = try #require(connection.remoteObjectProxy as? CellKeeperHelperXPCProtocol)

        let count = 300
        let replies = Captured<[Int]>()
        replies.set([])
        let introduced = Captured<Int>()
        // Sent one after another without waiting for any reply.
        proxy.hello(clientProtocolVersion: HelperProtocolVersion.current) { status, _, _, _, _, _, _ in introduced.set(status) }
        for index in 0..<count {
            proxy.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 600 + index) { status, granted in
                #expect(status == HelperStatus.ok.rawValue)
                replies.mutate { $0.append(granted) }
            }
        }
        #expect(await eventually(within: 10) { replies.value?.count == count })
        #expect(introduced.value == HelperStatus.ok.rawValue)

        let reached = rig.events.events.compactMap { event -> Int? in
            switch event {
            case .leaseGranted(_, .chargingInhibited, let seconds), .leaseRenewed(_, .chargingInhibited, let seconds): seconds
            default: nil
            }
        }
        #expect(reached == Array(600..<(600 + count)))
        #expect(replies.value == Array(600..<(600 + count)))
    }

    // MARK: - Revocation

    @Test("A session revoked for exceeding its budget gets its reply, then its connection is closed, its control cleared, and later calls throw")
    func revocation() async throws {
        let control = SimulatedChargeControl()
        let rig = try await XPCRig(control: control)
        let client = try rig.client()
        #expect(try await client.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        #expect(try await client.acquireOrRenewLease(control: 1, seconds: 900).status == .ok)
        #expect(try await client.setControl(control: 1, active: true) == .ok)
        #expect(control.activeControls == [.chargingInhibited])

        // The clock stands still, so the budget never refills: 10 requests
        // at once, then more than 20 in a row beyond it revoke the session.
        var requests = 3
        var lastStatus: HelperStatus?
        while !rig.events.events.contains(where: { if case .sessionRevoked = $0 { true } else { false } }), requests < 40 {
            lastStatus = try await client.readState().status
            requests += 1
        }
        #expect(requests == HelperEngine.requestBurst + HelperEngine.maximumOverBudgetRequests + 1)
        // The request that caused it got its reply.
        #expect(lastStatus == .rateLimited)
        #expect(control.activeControls.isEmpty)

        // The server closed the connection; the client noticed and is closed.
        #expect(await eventually { client.transportFailure != nil })
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.restoreDefaults()
        }
        #expect(await eventually { rig.server.connectionCount == 0 })
    }

    // MARK: - Disconnect

    @Test("Invalidating the client ends the session, and the engine clears the control it held")
    func disconnect() async throws {
        let control = SimulatedChargeControl()
        let rig = try await XPCRig(control: control)
        let client = try rig.client()
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(try await client.acquireOrRenewLease(control: 1, seconds: 900).status == .ok)
        #expect(try await client.setControl(control: 1, active: true) == .ok)
        #expect(control.activeControls == [.chargingInhibited])

        client.invalidate()
        let session = HelperSessionID(rawValue: Int(hello.sessionID))
        #expect(await eventually { rig.events.contains(.sessionInvalidated(session)) })
        #expect(control.activeControls.isEmpty)
        #expect(rig.events.contains(.deactivated(.chargingInhibited, .sessionInvalidated)))
        #expect(await eventually { rig.server.connectionCount == 0 })
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.readState()
        }
    }

    @Test("Stopping the server ends every session and refuses new connections")
    func stop() async throws {
        let control = SimulatedChargeControl()
        let rig = try await XPCRig(control: control)
        let client = try rig.client()
        #expect(try await client.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
        #expect(try await client.acquireOrRenewLease(control: 1, seconds: 900).status == .ok)
        #expect(try await client.setControl(control: 1, active: true) == .ok)

        await rig.server.stop()
        #expect(control.activeControls.isEmpty)
        #expect(rig.server.connectionCount == 0)
        #expect(await eventually { client.transportFailure != nil })

        let late = try rig.client()
        await #expect(throws: HelperXPCError.self) {
            try await late.hello(clientProtocolVersion: HelperProtocolVersion.current)
        }
        #expect(rig.events.openedSessions.count == 1)
    }

    // MARK: - Timeout

    @Test("A call the helper does not answer in time throws, and the connection is invalidated so a late reply goes nowhere")
    func timeout() async throws {
        let control = StallingChargeControl()
        let rig = try await XPCRig(control: control)
        let client = try rig.client(timeout: .milliseconds(300))
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(hello.status == .ok)

        control.stallNextReadBack()
        let started = ContinuousClock.now
        await #expect(throws: HelperXPCError.timedOut) {
            try await client.readState()
        }
        #expect(ContinuousClock.now - started >= .milliseconds(300))
        #expect(client.transportFailure == .timedOut)
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.restoreDefaults()
        }

        // The engine finishes the request; its reply has nowhere to go, and
        // the session ends with the connection.
        control.release()
        let session = HelperSessionID(rawValue: Int(hello.sessionID))
        #expect(await eventually { rig.events.contains(.sessionInvalidated(session)) })
        #expect(await eventually { rig.server.connectionCount == 0 })
    }

    // MARK: - The app's backend

    @Test("The helper backend reconnects through the XPC transport after the helper closes its connection, and reads the state afresh")
    func backendReconnects() async throws {
        let control = SimulatedChargeControl()
        let rig = try await XPCRig(control: control)
        let clock = rig.clock
        let backend = HelperChargingBackend(
            descriptor: BackendDescriptor(identifier: "xpc-test", displayName: "XPC test", summary: "Test"),
            transport: try rig.transport(),
            uptime: { clock.uptime },
            pause: { clock.advance(by: $0) },
            activity: NoLeaseActivity()
        )
        #expect(try await backend.setMode(.inhibitCharging) == .simulated)
        #expect(control.activeControls == [.chargingInhibited])

        // The helper drops the connection; its session ends and the control
        // is cleared (R1).
        await rig.server.closeConnections()
        #expect(control.activeControls.isEmpty)

        // The first request after that either fails (the client saw the
        // connection end) or finds its session gone; either way the backend
        // connects again and reads the state, never assuming it.
        var mode: ChargeControlMode?
        for _ in 0..<2 where mode == nil {
            mode = try? await backend.currentMode()
        }
        #expect(mode == .normal)
        #expect(await backend.reportedModeOrigin() == .releasedByBackend(.connectionLost))
        #expect(rig.events.openedSessions.count >= 2)

        clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(try await backend.setMode(.inhibitCharging) == .simulated)
        #expect(control.activeControls == [.chargingInhibited])
        #expect(try await backend.setMode(.normal) == .simulated)
        #expect(control.activeControls.isEmpty)
    }

    @Test("Transport failures map to the app's transport errors")
    func errorMapping() {
        #expect(HelperTransportError(HelperXPCError.interrupted) == .interrupted)
        #expect(HelperTransportError(HelperXPCError.invalidated) == .invalidated)
        #expect(HelperTransportError(HelperXPCError.requirementNotMet) == .requirementNotMet)
        #expect(HelperTransportError(HelperXPCError.timedOut) == .timedOut)
        #expect(HelperTransportError(HelperXPCError.malformedReply) == .malformedReply)
    }
}

/// A value the test reads after NSXPC's reply blocks set it.
final class Captured<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        lock.withLock { stored }
    }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.withLock {
            if var current = stored {
                change(&current)
                stored = current
            }
        }
    }
}
