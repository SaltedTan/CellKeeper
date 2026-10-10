import CellKeeperHelperCore
@testable import CellKeeperHelperXPC
import Foundation
import Testing

/// The NSXPC server's bounds and lifecycle: revocation, disconnects, the
/// request queue, timeouts, stopping, and how many clients it serves. Each
/// test makes its own anonymous listener and server; both sides require the
/// test binary's own code signature.
@Suite("Helper NSXPC server")
struct XPCHelperServerTests {
    // MARK: - Revocation

    @Test("A revoked session gets the revoking reply; requests queued behind it never run, and every call ends exactly once")
    func revocationBoundary() async throws {
        let control = SimulatedChargeControl()
        let rig = try await XPCRig(control: control)
        let client = try rig.client()
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        let session = HelperSessionID(rawValue: Int(hello.sessionID))
        #expect(try await client.acquireOrRenewLease(control: 1, seconds: 900).status == .ok)
        #expect(try await client.setControl(control: 1, active: true) == .ok)
        #expect(control.activeControls == [.chargingInhibited])

        // The clock stands still, so the budget never refills: 10 requests at
        // once, and the 21st in a row beyond it (the 31st request) revokes
        // the session. Requests 4 to 25 one by one, then 26 to 35 at once.
        for _ in 4...25 {
            _ = try await client.readState()
        }
        let outcomes = await withTaskGroup(of: Result<HelperStatus, HelperXPCError>.self) { group in
            for _ in 26...35 {
                group.addTask {
                    do {
                        return .success(try await client.readState().status)
                    } catch {
                        return .failure(error as? HelperXPCError ?? .malformedReply)
                    }
                }
            }
            var all: [Result<HelperStatus, HelperXPCError>] = []
            for await outcome in group {
                all.append(outcome)
            }
            return all
        }

        // Every call ended, each once (a second outcome would trap in its
        // continuation): six were answered, the revoking one last, all
        // refused for the budget; the four behind the revocation failed with
        // the connection, never by timing out.
        #expect(outcomes.count == 10)
        let replies = outcomes.compactMap { try? $0.get() }
        #expect(replies == Array(repeating: .rateLimited, count: 6))
        let failures = outcomes.compactMap { outcome -> HelperXPCError? in
            if case .failure(let error) = outcome { return error }
            return nil
        }
        #expect(failures.count == 4)
        #expect(failures.allSatisfy { connectionFailures.contains($0) }, "got \(failures)")

        // Nothing ran on the revoked session: no refusal for it, no request.
        #expect(rig.events.contains(.sessionRevoked(session)))
        #expect(!rig.events.requestEvents(of: session).contains {
            if case .requestRejected(_, _, .notIntroduced) = $0 { true } else { false }
        })
        #expect(control.activeControls.isEmpty)
        #expect(client.transportFailure != nil)
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.restoreDefaults()
        }
        #expect(await eventually { rig.connections.closeReason(of: session) == .revoked })
        #expect(rig.server.connectionCount == 0)
    }

    @Test("Requests sent at the moment of revocation activate nothing, even if NSXPC carries them to a new session")
    func revocationRace() async throws {
        let control = SimulatedChargeControl()
        let rig = try await XPCRig(control: control)
        let raw = try rig.raw()

        // Hello, lease and activation (requests 1 to 3) and 22 reads (4 to
        // 25), all answered before the rest is sent, so the burst after them
        // stays well within the server's queue bound.
        raw.hello(0)
        raw.lease(1, seconds: 900)
        raw.activate(2)
        for id in 3...24 {
            raw.readState(id)
        }
        try #require(await eventually { (0...24).allSatisfy { !raw.outcomes($0).isEmpty } })

        // Then ten at once, in order: five reads (26 to 30), the revoking
        // read (31), and four leases behind it. When the revoking reply
        // arrives, before the client could have seen the connection close,
        // it sends a lease and an activation at once.
        for id in 25...29 {
            raw.readState(id)
        }
        raw.proxy(30).readState { status, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
            raw.record(30, .reply(status: status))
            raw.lease(100, seconds: 900)
            raw.activate(101)
        }
        for id in 31...34 {
            raw.lease(id, seconds: 800 + id)
        }
        let ids = Array(0...34) + [100, 101]
        #expect(await eventually { ids.allSatisfy { !raw.outcomes($0).isEmpty } })
        // Let any second outcome arrive before counting.
        try await Task.sleep(for: .milliseconds(100))

        // Every call ended exactly once.
        for id in ids {
            #expect(raw.outcomes(id).count == 1, "call \(id): \(raw.outcomes(id))")
        }
        let ok = HelperStatus.ok.rawValue
        #expect(raw.outcomes(0) == [.reply(status: ok)])
        #expect(raw.outcomes(1) == [.reply(status: ok)])
        #expect(raw.outcomes(2) == [.reply(status: ok)])
        #expect(raw.outcomes(30) == [.reply(status: HelperStatus.rateLimited.rawValue)])
        let session = try #require(rig.events.openedSessions.first)
        #expect(rig.events.contains(.sessionRevoked(session)))
        for id in 31...34 {
            let outcomes = raw.outcomes(id)
            #expect(outcomes.count == 1)
            #expect(outcomes.allSatisfy { if case .error(let error) = $0 { connectionFailures.contains(error) } else { false } }, "call \(id): \(outcomes)")
        }
        // The late lease and activation either failed with the connection,
        // or reached a new session that has not said hello and were refused.
        for id in [100, 101] {
            let outcomes = raw.outcomes(id)
            #expect(outcomes.count == 1)
            #expect(outcomes.allSatisfy {
                switch $0 {
                case .reply(let status): status == HelperStatus.notIntroduced.rawValue
                case .error(let error): connectionFailures.contains(error)
                }
            }, "call \(id): \(outcomes)")
        }
        // Only the one activation before the revocation ever happened, and
        // nothing ran on the revoked session after it.
        let activations = rig.events.events.filter { if case .activated = $0 { true } else { false } }
        #expect(activations == [.activated(.chargingInhibited, by: session)])
        #expect(control.activeControls.isEmpty)
        #expect(!rig.events.requestEvents(of: session).contains {
            if case .requestRejected(_, _, .notIntroduced) = $0 { true } else { false }
        })
        for other in rig.events.openedSessions.dropFirst() {
            #expect(rig.events.requestEvents(of: other).allSatisfy {
                if case .requestRejected(_, _, .notIntroduced) = $0 { true } else { false }
            })
        }
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
        #expect(await eventually { rig.connections.closeReason(of: session) == .clientDisconnected })
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.readState()
        }
    }

    // MARK: - Lifecycle

    @Test("Stopping the server ends every session and refuses new connections")
    func stop() async throws {
        let control = SimulatedChargeControl()
        let rig = try await XPCRig(control: control)
        let client = try rig.client()
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(try await client.acquireOrRenewLease(control: 1, seconds: 900).status == .ok)
        #expect(try await client.setControl(control: 1, active: true) == .ok)

        await rig.server.stop()
        #expect(control.activeControls.isEmpty)
        #expect(rig.server.connectionCount == 0)
        #expect(await eventually { client.transportFailure != nil })
        let session = HelperSessionID(rawValue: Int(hello.sessionID))
        #expect(await eventually { rig.connections.closeReason(of: session) == .serverStopped })

        let late = try rig.client()
        let failure = await clientFailure { _ = try await late.hello(clientProtocolVersion: HelperProtocolVersion.current) }
        #expect(connectionFailures.contains(failure), "got \(String(describing: failure))")
        #expect(rig.events.openedSessions.count == 1)
    }

    @Test("Start and stop racing each other always end stopped: no listener is resumed after it was invalidated, and nothing is served")
    func startStopRace() async throws {
        for _ in 0..<20 {
            let rig = try await XPCRig(start: false)
            let server = rig.server
            async let started = server.start()
            async let stopped: Void = server.stop()
            _ = await (started, stopped)
            // Whichever came first, a stopped server serves nothing more.
            await server.start()
            let client = try rig.client()
            let failure = await clientFailure { _ = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current) }
            #expect(connectionFailures.contains(failure), "got \(String(describing: failure))")
            #expect(server.connectionCount == 0)
            #expect(rig.events.openedSessions.isEmpty)
        }
    }

    @Test("Connections accepted while the server stops are either closed by the stop or refused; every session opened is ended when stop returns")
    func acceptanceDuringStop() async throws {
        for _ in 0..<10 {
            let rig = try await XPCRig()
            let clients = try (0..<6).map { _ in try rig.client() }
            let calls = clients.map { client in
                Task { () -> Result<HelperStatus, HelperXPCError> in
                    do {
                        return .success(try await client.hello(clientProtocolVersion: HelperProtocolVersion.current).status)
                    } catch {
                        return .failure(error as? HelperXPCError ?? .malformedReply)
                    }
                }
            }
            await rig.server.stop()
            #expect(rig.server.connectionCount == 0)
            #expect(Set(rig.events.openedSessions) == Set(rig.events.invalidatedSessions))
            for call in calls {
                switch await call.value {
                case .success(let status):
                    #expect(status == .ok)
                case .failure(let error):
                    #expect(connectionFailures.contains(error), "got \(error)")
                }
            }
            #expect(Set(rig.events.openedSessions) == Set(rig.events.invalidatedSessions))
        }
    }

    @Test("At most the maximum number of clients are served at once; one more is refused and logged")
    func connectionLimit() async throws {
        let rig = try await XPCRig()
        var clients: [HelperXPCClient] = []
        for _ in 0..<HelperXPCServer.maximumConnections {
            let client = try rig.client()
            #expect(try await client.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
            clients.append(client)
        }
        let extra = try rig.client()
        let failure = await clientFailure { _ = try await extra.hello(clientProtocolVersion: HelperProtocolVersion.current) }
        #expect(connectionFailures.contains(failure), "got \(String(describing: failure))")
        #expect(await eventually { rig.connections.refusals == [.tooManyConnections] })
        #expect(rig.events.openedSessions.count == HelperXPCServer.maximumConnections)

        // Once one leaves, another is served.
        clients[0].invalidate()
        #expect(await eventually { rig.server.connectionCount == HelperXPCServer.maximumConnections - 1 })
        let next = try rig.client()
        #expect(try await next.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
    }

    // MARK: - Audit

    @Test("Each accepted connection is reported with its session, process and user, for the log only")
    func audit() async throws {
        let rig = try await XPCRig()
        let client = try rig.client()
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        let session = HelperSessionID(rawValue: Int(hello.sessionID))
        client.invalidate()
        #expect(await eventually { rig.connections.events.count == 2 })
        #expect(rig.connections.events == [
            .accepted(session, processID: getpid(), effectiveUserID: geteuid()),
            .closed(session, reason: .clientDisconnected),
        ])
    }
}

/// Tests whose engine stalls inside the control's read-back. The control is
/// synchronous, so each stall blocks a thread of Swift's cooperative pool
/// until the test releases it. They run one at a time: on a runner with few
/// cores (three on GitHub's macOS 15 image), several stalls at once could
/// take every thread, and nothing would be left to run the code that
/// releases them.
@Suite("Helper NSXPC server with a stalled engine", .serialized)
struct XPCStalledEngineTests {
    @Test("A client that disconnects while a request is blocked: that request finishes, nothing queued behind it runs, and the session ends right after")
    func disconnectWhileBlocked() async throws {
        let control = StallingChargeControl()
        defer { control.release() }
        let rig = try await XPCRig(control: control)
        let client = try rig.client()
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        let session = HelperSessionID(rawValue: Int(hello.sessionID))
        #expect(try await client.acquireOrRenewLease(control: 1, seconds: 900).status == .ok)
        #expect(try await client.setControl(control: 1, active: true) == .ok)

        control.stallNextReadBack()
        let blocked = Task { await clientFailure { _ = try await client.readState() } }
        try #require(await eventually { control.isStalled })
        let queued = (0..<5).map { index in
            Task { await clientFailure { _ = try await client.acquireOrRenewLease(control: 1, seconds: 500 + index) } }
        }
        try #require(await eventually { rig.server.queuedRequestCount == 5 })
        let requestEventsBefore = rig.events.requestEvents(of: session)

        client.invalidate()
        // The server closes the connection while the engine is still blocked.
        #expect(await eventually { rig.server.openConnectionCount == 0 })
        #expect(control.isStalled)
        control.release()

        #expect(await eventually { rig.events.contains(.sessionInvalidated(session)) })
        #expect(rig.events.requestEvents(of: session) == requestEventsBefore)
        #expect(control.inner.activeControls.isEmpty)
        #expect(await blocked.value == .invalidated)
        for call in queued {
            #expect(await call.value == .invalidated)
        }
        #expect(await eventually { rig.connections.closeReason(of: session) == .clientDisconnected })
        #expect(await eventually { rig.server.connectionCount == 0 })
    }

    // MARK: - Queue bound

    @Test("More requests waiting than the bound is a protocol violation: the server closes the connection, runs none of them, and ends the session")
    func queueOverflow() async throws {
        let control = StallingChargeControl()
        defer { control.release() }
        let rig = try await XPCRig(control: control)
        let client = try rig.client()
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        let session = HelperSessionID(rawValue: Int(hello.sessionID))

        control.stallNextReadBack()
        let blocked = Task { await clientFailure { _ = try await client.readState() } }
        try #require(await eventually { control.isStalled })
        let limit = HelperXPCServer.maximumQueuedRequests
        let queued = (0..<limit).map { index in
            Task { await clientFailure { _ = try await client.acquireOrRenewLease(control: 1, seconds: 500 + index) } }
        }
        try #require(await eventually { rig.server.queuedRequestCount == limit })
        #expect(rig.server.openConnectionCount == 1)

        // One more.
        let overflow = await clientFailure { _ = try await client.restoreDefaults() }
        #expect(connectionFailures.contains(overflow), "got \(String(describing: overflow))")
        #expect(await eventually { rig.server.openConnectionCount == 0 })
        control.release()

        #expect(await eventually { rig.events.contains(.sessionInvalidated(session)) })
        #expect(rig.events.requestEvents(of: session).isEmpty)
        #expect(await blocked.value != nil)
        for call in queued {
            let failure = await call.value
            #expect(connectionFailures.contains(failure), "got \(String(describing: failure))")
        }
        #expect(await eventually { rig.connections.closeReason(of: session) == .requestQueueFull })
        #expect(await eventually { rig.server.connectionCount == 0 })
    }

    @Test("An overflow ends admission at once: a request that finishes just as the overflow is detected cannot let a queued activation through")
    func overflowRacesCompletion() async throws {
        let control = StallingChargeControl()
        defer { control.release() }
        let rig = try await XPCRig(control: control)
        let client = try rig.client()
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        let session = HelperSessionID(rawValue: Int(hello.sessionID))
        // With the lease held, the engine would carry out the activation
        // queued below.
        #expect(try await client.acquireOrRenewLease(control: 1, seconds: 900).status == .ok)
        let requestEventsBefore = rig.events.requestEvents(of: session)

        control.stallNextReadBack()
        let blocked = Task { await clientFailure { _ = try await client.readState() } }
        try #require(await eventually { control.isStalled })
        let activation = Task { await clientFailure { _ = try await client.setControl(control: 1, active: true) } }
        try #require(await eventually { rig.server.queuedRequestCount == 1 })
        let limit = HelperXPCServer.maximumQueuedRequests
        let queued = (1..<limit).map { index in
            Task { await clientFailure { _ = try await client.acquireOrRenewLease(control: 1, seconds: 500 + index) } }
        }
        try #require(await eventually { rig.server.queuedRequestCount == limit })

        // Once the overflow is decided, and before it is carried out, the
        // running request ends and the consumer gets every chance to take
        // the activation: it may take it off the queue, but must not run it.
        let server = rig.server
        // Weak: the server keeps the hook, so a strong reference would keep
        // the server, its listener and the control alive after the test.
        server.onOverflowDecided { [weak server] in
            control.release()
            let deadline = Date().addingTimeInterval(5)
            while server?.queuedRequestCount == limit, Date() < deadline {
                usleep(1_000)
            }
            usleep(200_000)
        }
        let overflow = await clientFailure { _ = try await client.restoreDefaults() }
        #expect(connectionFailures.contains(overflow), "got \(String(describing: overflow))")
        #expect(server.queuedRequestCount < limit)

        #expect(await eventually { rig.events.contains(.sessionInvalidated(session)) })
        #expect(rig.events.requestEvents(of: session) == requestEventsBefore)
        #expect(!rig.events.events.contains { if case .activated = $0 { true } else { false } })
        #expect(control.inner.activeControls.isEmpty)
        #expect(!control.inner.writes.contains(.apply(.chargingInhibited, active: true)))
        #expect(connectionFailures.contains(await activation.value))
        // The request in progress was allowed to finish: it may have been
        // answered before the connection closed.
        let blockedFailure = await blocked.value
        #expect(blockedFailure == nil || connectionFailures.contains(blockedFailure), "got \(String(describing: blockedFailure))")
        for call in queued {
            #expect(connectionFailures.contains(await call.value))
        }
        #expect(await eventually { rig.connections.closeReason(of: session) == .requestQueueFull })
    }

    // MARK: - Timeout

    @Test("A call the helper does not answer in time throws, and the connection is invalidated so a late reply goes nowhere")
    func timeout() async throws {
        let control = StallingChargeControl()
        defer { control.release() }
        let rig = try await XPCRig(control: control)
        // The connection is set up under no deadline the test controls; the
        // timeout under test fires only when the test fires it.
        let timeouts = ManualTimeouts()
        let client = try rig.client(timeouts: timeouts)
        let hello = try await client.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(hello.status == .ok)
        let session = HelperSessionID(rawValue: Int(hello.sessionID))

        control.stallNextReadBack()
        let call = Task { await clientFailure { _ = try await client.readState() } }
        try #require(await eventually { control.isStalled })
        timeouts.fireAll()
        #expect(await call.value == .timedOut)
        #expect(client.transportFailure == .timedOut)
        await #expect(throws: HelperXPCError.invalidated) {
            try await client.restoreDefaults()
        }

        // The server sees the connection end while the engine is still
        // stalled; the request finishes, its reply has nowhere to go, and the
        // session ends.
        #expect(await eventually { rig.server.openConnectionCount == 0 })
        control.release()
        #expect(await eventually { rig.events.contains(.sessionInvalidated(session)) })
        #expect(await eventually { rig.connections.closeReason(of: session) == .clientDisconnected })
        #expect(await eventually { rig.server.connectionCount == 0 })
    }
}
