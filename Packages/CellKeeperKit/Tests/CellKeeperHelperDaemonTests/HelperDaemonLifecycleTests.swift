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
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)
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
        #expect(h.log.contains(.notice, .lifecycle, "Exiting with status 0."))
    }

    @Test("An owed restore is retried about once a second; at the deadline the daemon exits non-zero")
    func exitsAtDeadline() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 120)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .ok)
        control.failNextRestores(1_000)
        let restoresBefore = control.restoreCount

        h.signals.sendSIGTERM()
        // The first attempt at once, then one a second (ticks retry too).
        // Between steps the daemon waits on three things: the next tick,
        // the termination deadline and the next retry.
        for second in 0..<Int(HelperDaemon.terminationDeadline) {
            let polled = await eventually {
                control.restoreCount >= restoresBefore + 1 + second && h.clock.waits.count == 3
            }
            #expect(polled)
            #expect(h.exits.statuses.isEmpty)
            h.clock.advance(by: HelperDaemon.exitPollInterval)
        }

        #expect(await running.value == HelperDaemon.restoreNotConfirmedExitStatus)
        #expect(h.exits.statuses == [HelperDaemon.restoreNotConfirmedExitStatus])
        #expect(control.activeControls == [.adapterDisabled])
        #expect(control.restoreCount - restoresBefore >= Int(HelperDaemon.terminationDeadline))
        #expect(h.log.contains(.fault, .safety, "Defaults not confirmed within 8 s: exiting with status 75."))
    }

    @Test("A restore that succeeds on a retry exits with 0 before the deadline")
    func recoversBeforeDeadline() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)
        control.failNextRestores(2)
        let restoresBefore = control.restoreCount

        h.signals.sendSIGTERM()
        for retry in 0..<2 {
            let polled = await eventually { control.restoreCount >= restoresBefore + 1 + retry && h.clock.waits.count == 3 }
            #expect(polled)
            #expect(h.exits.statuses.isEmpty)
            h.clock.advance(by: HelperDaemon.exitPollInterval)
        }
        #expect(await running.value == 0)
        #expect(control.activeControls.isEmpty)
    }

    @Test("A second SIGTERM during shutdown is ignored")
    func secondSignal() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)
        control.failNextRestores(1)

        h.signals.sendSIGTERM()
        let polling = await eventually { h.clock.waits.count == 3 }
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
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)

        #expect(await session.restoreDefaultsAndExit() == .ok)
        #expect(await running.value == 0)
        #expect(h.exits.statuses == [0])
        #expect(h.frontend.calls == [.start, .stop])
        #expect(control.activeControls.isEmpty)
        #expect(h.log.contains(.notice, .lifecycle, "The engine shut down at a client's request"))
    }

    @Test("If that restore fails, the daemon waits until the engine confirms defaults, then exits")
    func restoreAndExitAfterRetry() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)
        control.failNextRestores(1)

        #expect(await session.restoreDefaultsAndExit() == .hardwareError)
        #expect(await h.daemon.engine.isShuttingDown)
        #expect(h.exits.statuses.isEmpty)

        // The next tick retries the restore; the engine then says it is safe.
        let scheduled = await eventually { h.clock.waits.contains(HelperDaemon.tickInterval - 0.001...HelperDaemon.tickInterval) }
        #expect(scheduled)
        h.clock.advance(by: HelperDaemon.tickInterval)
        #expect(await running.value == 0)
        #expect(control.activeControls.isEmpty)
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
