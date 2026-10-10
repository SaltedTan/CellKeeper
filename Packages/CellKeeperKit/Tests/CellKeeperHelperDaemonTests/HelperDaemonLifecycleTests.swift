@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper daemon: start and ticks")
struct HelperDaemonStartTests {
    @Test("Defaults are restored and read back before the frontend starts serving (R2)")
    func restoresBeforeServing() async throws {
        let control = SimulatedChargeControl(initiallyActive: [.chargingInhibited])
        let h = DaemonHarness(control: control)
        let atStart = StartObservation()
        h.frontend.onStart { _ in
            atStart.record(writes: control.writes, active: control.activeControls, sleepRegistered: h.sleep.isStarted)
        }

        let running = await h.run()
        #expect(h.frontend.calls == [.start])
        let observed = try #require(atStart.value)
        #expect(observed.writes == [.restoreDefaults])
        #expect(observed.active.isEmpty)
        #expect(observed.sleepRegistered)
        #expect(h.signals.isStarted)
        // The engine serves the frontend's sessions.
        let session = await h.introducedSession()
        let state = await session.readState()
        #expect(state.status == .ok)

        #expect(await h.terminate(running) == 0)
    }

    @Test("The engine is ticked every 5 seconds")
    func ticks() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let reads = control.readBackCount

        h.clock.advance(by: HelperDaemon.tickInterval - 0.5)
        let early = control.readBackCount
        #expect(early == reads)

        h.clock.advance(by: 0.5)
        let ticked = await eventually { control.readBackCount > reads }
        #expect(ticked)
        let afterFirst = control.readBackCount
        let rescheduled = await eventually { h.clock.waits.contains(HelperDaemon.tickInterval - 0.001...HelperDaemon.tickInterval) }
        #expect(rescheduled)
        h.clock.advance(by: HelperDaemon.tickInterval)
        let tickedAgain = await eventually { control.readBackCount > afterFirst }
        #expect(tickedAgain)

        #expect(await h.terminate(running) == 0)
    }

    @Test("The engine's events reach the frontend, so it can close a revoked session's connection")
    func eventsReachFrontend() async {
        let h = DaemonHarness()
        let running = await h.run()
        let session = await h.introducedSession()
        let forwarded = await eventually { h.frontend.handledEvents.contains(.sessionOpened(session.id)) }
        #expect(forwarded)
        #expect(h.frontend.handledEvents.contains { if case .started = $0 { true } else { false } })
        #expect(await h.terminate(running) == 0)
    }

    @Test("Start logs what the daemon is and that the engine confirmed defaults")
    func startLog() async {
        let h = DaemonHarness()
        let running = await h.run()
        let logged = await eventually {
            h.log.contains(.notice, .lifecycle, "CellKeeperHelper build 7 starting")
                && h.log.contains(.notice, .lifecycle, "Engine started; defaults confirmed.")
                && h.log.contains(.notice, .lifecycle, "engine: started")
        }
        #expect(logged)
        #expect(await h.terminate(running) == 0)
    }

    @Test("If sleep notifications cannot be registered, the daemon restores, serves nobody and exits")
    func sleepRegistrationFails() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        h.sleep.failToStart()

        let status = await h.run().value
        #expect(status == 0)
        #expect(h.exits.statuses == [0])
        #expect(!h.frontend.calls.contains(.start))
        #expect(await h.daemon.engine.isSafeToExit)
        #expect(h.log.contains(.fault, .safety, "Sleep notifications could not be registered"))
    }

    @Test("If the frontend refuses to start, the daemon restores and exits")
    func frontendFails() async {
        struct NoRequirement: Error {}
        let h = DaemonHarness()
        h.frontend.onStart { _ in throw NoRequirement() }

        let status = await h.run().value
        #expect(status == 0)
        #expect(h.frontend.calls == [.start, .stop])
        #expect(await h.daemon.engine.isSafeToExit)
        #expect(h.log.contains(.fault, .xpc, "The frontend could not start"))
    }
}

@Suite("Helper daemon: SIGTERM")
struct HelperDaemonTerminationTests {
    @Test("SIGTERM stops the frontend, restores defaults and exits with 0 (R4)")
    func exitsWhenSafe() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(control.activeControls == [.chargingInhibited])

        #expect(await h.terminate(running) == 0)
        #expect(h.exits.statuses == [0])
        #expect(h.frontend.calls == [.start, .stop])
        #expect(control.activeControls.isEmpty)
        #expect(await h.daemon.engine.isSafeToExit)
        #expect(h.sleep.isStopped)
        // The log is written before the daemon exits.
        #expect(h.log.contains(.notice, .lifecycle, "SIGTERM: stopping the frontend"))
        #expect(h.log.contains(.notice, .lifecycle, "engine: shuttingDown("))
        #expect(h.log.contains(.notice, .lifecycle, "The frontend stopped and defaults are confirmed: exiting with status 0."))
    }

    @Test("A SIGTERM before run() is held, and handled before anything is served")
    func signalBeforeRun() async {
        let signals = FakeTerminationSignals()
        let store = InMemoryHistoryStore()
        let handledWhenLoading = Flag()
        store.onLoad { handledWhenLoading.set(signals.isStarted) }
        let h = DaemonHarness(store: store, signals: signals)
        // Handled from the initialiser on, before the history was loaded.
        #expect(handledWhenLoading.value)
        h.signals.sendSIGTERM()

        let daemon = h.daemon
        #expect(await daemon.run() == 0)
        #expect(h.frontend.calls == [.stop])
        #expect(await h.daemon.engine.isSafeToExit)
    }

    @Test("An owed restore is retried about once a second; it stops in time to exit non-zero by the deadline", arguments: ShutdownPath.allCases)
    func exitsAtDeadline(path: ShutdownPath) async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        control.failNextRestores(1_000)
        let restoresBefore = control.restoreCount

        await h.beginShutdown(path, on: session)
        // Retries every second (ticks retry too). Between steps the daemon
        // waits on three things: the next tick, the end of the retries and
        // the next retry.
        let retries = Int(HelperDaemon.terminationDeadline - HelperDaemon.finalisationReserve)
        for second in 0..<retries {
            let polled = await eventually {
                control.restoreCount >= restoresBefore + path.firstDaemonAttempt + second && h.clock.waits.count == 3
            }
            #expect(polled)
            #expect(h.exits.statuses.isEmpty)
            h.clock.advance(by: HelperDaemon.exitPollInterval)
        }

        #expect(await running.value == HelperDaemon.restoreNotConfirmedExitStatus)
        #expect(h.exits.statuses == [HelperDaemon.restoreNotConfirmedExitStatus])
        #expect(control.activeControls == [.adapterDisabled])
        #expect(control.restoreCount - restoresBefore >= retries)
        #expect(h.log.contains(.fault, .safety, "Defaults not confirmed within the shutdown's retries."))
        #expect(h.log.contains(.fault, .safety, "exiting with status 75"))
    }

    @Test("A restore that succeeds on a retry exits with 0", arguments: ShutdownPath.allCases)
    func recoversBeforeDeadline(path: ShutdownPath) async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        control.failNextRestores(2)
        let restoresBefore = control.restoreCount

        await h.beginShutdown(path, on: session)
        for retry in 0..<3 where h.exits.statuses.isEmpty {
            let polled = await eventually {
                !h.exits.statuses.isEmpty
                    || (control.restoreCount >= restoresBefore + path.firstDaemonAttempt + retry && h.clock.waits.count == 3)
            }
            #expect(polled)
            if h.exits.statuses.isEmpty {
                h.clock.advance(by: HelperDaemon.exitPollInterval)
            }
        }
        #expect(await running.value == 0)
        #expect(control.activeControls.isEmpty)
    }

    @Test("A second SIGTERM during shutdown is ignored", arguments: ShutdownPath.allCases)
    func secondSignal(path: ShutdownPath) async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        control.failNextRestores(path.firstDaemonAttempt)
        let restoresBefore = control.restoreCount

        await h.beginShutdown(path, on: session)
        let polling = await eventually { control.restoreCount >= restoresBefore + path.firstDaemonAttempt && h.clock.waits.count == 3 }
        #expect(polling)
        h.signals.sendSIGTERM()
        let ignored = await eventually { h.log.contains(.notice, .lifecycle, "SIGTERM while already shutting down: ignored.") }
        #expect(ignored)
        h.clock.advance(by: HelperDaemon.exitPollInterval)
        #expect(await running.value == 0)
        #expect(h.exits.statuses == [0])
    }
}

@Suite("Helper daemon: exit at a client's request")
struct HelperDaemonClientExitTests {
    @Test("After restoreDefaultsAndExit the daemon stops the frontend and exits with 0")
    func restoreAndExit() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)

        #expect(await session.restoreDefaultsAndExit() == .ok)
        #expect(await running.value == 0)
        #expect(h.exits.statuses == [0])
        #expect(h.frontend.calls == [.start, .stop])
        #expect(control.activeControls.isEmpty)
        #expect(h.log.contains(.notice, .lifecycle, "Exit requested by a client: stopping the frontend"))
    }

    @Test("If that restore fails, shutdown retries it and exits with 0 once defaults are confirmed")
    func restoreAndExitAfterRetry() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        control.failNextRestores(1)

        #expect(await session.restoreDefaultsAndExit() == .hardwareError)
        #expect(await running.value == 0)
        #expect(control.activeControls.isEmpty)
    }
}

@Suite("Helper daemon: the frontend's confirmation decides")
struct HelperDaemonFrontendStopTests {
    @Test("A frontend that has not confirmed its stop never lets the daemon exit with 0", arguments: ShutdownPath.allCases)
    func unconfirmedStop(path: ShutdownPath) async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        h.frontend.holdStop()
        let running = await h.run()
        let session = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)

        await h.beginShutdown(path, on: session)
        // Defaults are restored at once, but the frontend's requests might
        // still change them. The daemon waits for the next tick, the end of
        // the retries, and the frontend (then the next retry).
        let retries = Int(HelperDaemon.terminationDeadline - HelperDaemon.finalisationReserve)
        for _ in 0..<retries {
            let waiting = await eventually { h.clock.waits.count == 3 }
            #expect(waiting)
            #expect(h.exits.statuses.isEmpty)
            h.clock.advance(by: 1)
        }
        #expect(control.activeControls.isEmpty)
        #expect(await h.daemon.engine.isSafeToExit)
        #expect(await running.value == HelperDaemon.restoreNotConfirmedExitStatus)
        #expect(h.log.contains(.fault, .xpc, "The frontend has not confirmed that it stopped serving"))
        h.frontend.confirmStop()
    }

    @Test("A frontend that confirms its stop late lets the daemon exit with 0 then")
    func lateConfirmation() async {
        let h = DaemonHarness()
        h.frontend.holdStop()
        let running = await h.run()
        let session = await h.introducedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)

        h.signals.sendSIGTERM()
        let first = await eventually { h.frontend.isStopHeld && h.clock.waits.count == 3 }
        #expect(first)
        h.clock.advance(by: HelperDaemon.frontendStopTimeout)
        let polling = await eventually { h.clock.waits.count == 3 && h.clock.waits.contains(HelperDaemon.exitPollInterval - 0.001...HelperDaemon.exitPollInterval) }
        #expect(polling)
        h.frontend.confirmStop()
        #expect(h.exits.statuses.isEmpty)
        // The next retry sees the confirmation (or the one after, if the
        // stop's task has not recorded it yet), well before the deadline.
        for _ in 0..<3 where h.exits.statuses.isEmpty {
            h.clock.advance(by: HelperDaemon.exitPollInterval)
            let next = await eventually { !h.exits.statuses.isEmpty || h.clock.waits.count == 3 }
            #expect(next)
        }
        #expect(await running.value == 0)
    }

    @Test("A frontend that reports it could not stop cleanly makes the daemon exit non-zero")
    func refusedStop() async {
        let h = DaemonHarness()
        h.frontend.refuseStop()
        let running = await h.run()
        #expect(await h.terminate(running) == HelperDaemon.restoreNotConfirmedExitStatus)
        #expect(await h.daemon.engine.isSafeToExit)
        #expect(h.log.contains(.fault, .xpc, "The frontend could not confirm that it stopped serving"))
    }
}

/// How a test begins the daemon's shutdown.
enum ShutdownPath: CaseIterable, Sendable, CustomStringConvertible {
    case sigterm
    /// A client's `restoreDefaultsAndExit`.
    case clientExit

    /// The restore attempt the daemon's own shutdown makes first, counting
    /// from before shutdown began: the client's request makes one itself.
    var firstDaemonAttempt: Int {
        switch self {
        case .sigterm: 1
        case .clientExit: 2
        }
    }

    var description: String {
        switch self {
        case .sigterm: "SIGTERM"
        case .clientExit: "restoreDefaultsAndExit"
        }
    }
}

extension DaemonHarness {
    /// Takes the maximum lease on `control` and activates it.
    func activate(_ control: HelperControl, on session: HelperSession) async -> HelperStatus {
        _ = await session.acquireOrRenewLease(control: control.rawValue, seconds: control.maximumLeaseSeconds)
        return await session.setControl(control: control.rawValue, active: true)
    }

    /// Begins the daemon's shutdown: SIGTERM, or `session`'s
    /// `restoreDefaultsAndExit`.
    func beginShutdown(_ path: ShutdownPath, on session: HelperSession) async {
        switch path {
        case .sigterm: signals.sendSIGTERM()
        case .clientExit: _ = await session.restoreDefaultsAndExit()
        }
    }
}

/// A boolean set from another context.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool {
        lock.withLock { isSet }
    }

    func set(_ value: Bool) {
        lock.withLock { isSet = value }
    }
}

/// What the frontend saw when it was started.
final class StartObservation: @unchecked Sendable {
    struct Value {
        var writes: [SimulatedChargeControl.Write]
        var active: Set<HelperControl>
        var sleepRegistered: Bool
    }

    private let lock = NSLock()
    private var observed: Value?

    var value: Value? {
        lock.withLock { observed }
    }

    func record(writes: [SimulatedChargeControl.Write], active: Set<HelperControl>, sleepRegistered: Bool) {
        lock.withLock { observed = Value(writes: writes, active: active, sleepRegistered: sleepRegistered) }
    }
}

extension SimulatedChargeControl {
    /// Restores of defaults received so far, including failed ones.
    var restoreCount: Int {
        writes.filter { $0 == .restoreDefaults }.count
    }
}
