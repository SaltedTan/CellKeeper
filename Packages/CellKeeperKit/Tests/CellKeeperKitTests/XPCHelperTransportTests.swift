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

    @Test("A client that does not meet the listener's requirement is refused, and never reaches the server or the engine")
    func listenerRefusesClient() async throws {
        let rig = try await XPCRig(clientRequirement: try unmatchableRequirement())
        let client = try rig.client()
        // A refusal, not a timeout: the timeout is generous, and a timeout is
        // what a test would also see if no connection were processed at all.
        // NSXPC reports the refusal as an interruption or an invalidation,
        // depending on the macOS version.
        let failure = await clientFailure {
            _ = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        }
        #expect(connectionFailures.contains(failure), "got \(String(describing: failure))")
        #expect(connectionFailures.contains(client.transportFailure))
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.restoreDefaults()
        }
        #expect(rig.events.openedSessions.isEmpty)
        #expect(rig.connections.events.isEmpty)
        #expect(rig.server.connectionCount == 0)

        // Through the app's transport, the failure is a transport error.
        let connection = try await rig.transport().connect()
        let appFailure = await transportFailure {
            _ = try await connection.hello(clientProtocolVersion: HelperProtocolVersion.current)
        }
        #expect(appConnectionFailures.contains(appFailure), "got \(String(describing: appFailure))")
        #expect(rig.events.openedSessions.isEmpty)
        #expect(rig.connections.events.isEmpty)
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

    // MARK: - Replies

    @Test("A reply with a status this version does not know is never read as a status: it fails the call and closes the client")
    func unknownStatus() async throws {
        let helper = try RawStatusHelper(status: 999)
        let client = HelperXPCClient(destination: .endpoint(helper.listener.endpoint), helperRequirement: try ownRequirement(), timeout: setupTimeout)
        await #expect(throws: HelperXPCError.malformedReply) {
            try await client.setControl(control: 1, active: false)
        }
        #expect(client.transportFailure == .malformedReply)
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.readState()
        }

        // Through the app's transport, every kind of reply.
        let transport = XPCHelperTransport(destination: .endpoint(helper.listener.endpoint), helperRequirement: try ownRequirement(), timeout: setupTimeout)
        let requests: [@Sendable (any HelperConnection) async throws -> Void] = [
            { _ = try await $0.hello(clientProtocolVersion: HelperProtocolVersion.current) },
            { _ = try await $0.readState() },
            { _ = try await $0.acquireOrRenewLease(control: 1, seconds: 900) },
            { _ = try await $0.restoreDefaults() },
        ]
        for request in requests {
            let connection = try await transport.connect()
            await #expect(throws: HelperTransportError.malformedReply) {
                try await request(connection)
            }
        }

        // The same stand-in with a known status is read as it is.
        let refusing = try RawStatusHelper(status: HelperStatus.blockedByInterlock.rawValue)
        let connection = try await XPCHelperTransport(destination: .endpoint(refusing.listener.endpoint), helperRequirement: try ownRequirement(), timeout: setupTimeout).connect()
        #expect(try await connection.setControl(control: 1, active: true) == .blockedByInterlock)
        #expect(try await connection.acquireOrRenewLease(control: 1, seconds: 900) == HelperLeaseReply(status: .blockedByInterlock, grantedSeconds: 900))
        await connection.invalidate()
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
        let proxy = SendableProxy(try #require(connection.remoteObjectProxy as? CellKeeperHelperXPCProtocol))

        let count = 300
        // Many requests in flight at once, never more than the server lets
        // wait (more would be a protocol violation that closes the
        // connection): the first `window` go out together, and each reply
        // sends the next one. Numbering and sending happen together on one
        // serial queue, so the numbers are the order on the wire. Reply
        // blocks run on NSXPC's queue; the test checks what they saw.
        let window = HelperXPCServer.maximumQueuedRequests * 3 / 4
        let replies = Captured<[HelperLeaseReply]>()
        replies.set([])
        let introduced = Captured<Int>()
        let producer = OrderedProducer(count: count)
        @Sendable func sendNext() {
            producer.next { index in
                proxy.helper.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 600 + index) { status, granted in
                    replies.mutate { $0.append(HelperLeaseReply(status: HelperStatus(rawValue: status) ?? .hardwareError, grantedSeconds: granted)) }
                    sendNext()
                }
            }
        }
        producer.run {
            proxy.helper.hello(clientProtocolVersion: HelperProtocolVersion.current) { status, _, _, _, _, _, _ in introduced.set(status) }
        }
        for _ in 0..<window {
            sendNext()
        }
        #expect(await eventually(within: 20) { replies.value?.count == count })
        #expect(introduced.value == HelperStatus.ok.rawValue)
        #expect(rig.server.openConnectionCount == 1)

        let reached = rig.events.events.compactMap { event -> Int? in
            switch event {
            case .leaseGranted(_, .chargingInhibited, let seconds), .leaseRenewed(_, .chargingInhibited, let seconds): seconds
            default: nil
            }
        }
        #expect(reached == Array(600..<(600 + count)))
        #expect(replies.value == (600..<(600 + count)).map { HelperLeaseReply(status: .ok, grantedSeconds: $0) })
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
