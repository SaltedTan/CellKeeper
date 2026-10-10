@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

/// Calls that do not return in time: a hung call to the control, a slow log
/// or history file. Each test holds one thread of the cooperative pool on
/// purpose, as such a call would, so they run one at a time and a small
/// pool (CI machines have three cores) never runs out of threads.
@Suite("Helper daemon: calls that do not return in time", .serialized)
struct HelperDaemonStuckCallTests {
    @Test("SIGTERM while the engine is still starting: the frontend never starts")
    func sigtermDuringStart() async {
        let control = BlockingControl()
        control.holdNextReadBack()
        let h = DaemonHarness(control: control)
        let daemon = h.daemon
        let running = Task { await daemon.run() }
        let holding = await eventually { control.isHolding }
        #expect(holding)

        h.signals.sendSIGTERM()
        let stoppedFrontend = await eventually { h.frontend.calls.contains(.stop) }
        #expect(stoppedFrontend)
        control.release()

        #expect(await running.value == 0)
        #expect(h.frontend.calls == [.stop])
        #expect(!h.sleep.isStarted)
    }

    @Test("The deadline holds even while the engine is stuck in a call to the control")
    func deadlineWithStuckEngine() async {
        let control = BlockingControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        control.holdNextReadBack()
        h.clock.advance(by: HelperDaemon.tickInterval)
        let stuck = await eventually { control.isHolding }
        #expect(stuck)

        h.signals.sendSIGTERM()
        let waiting = await eventually { h.clock.waits.contains(HelperDaemon.terminationDeadline - 0.001...HelperDaemon.terminationDeadline) }
        #expect(waiting)
        h.clock.advance(by: HelperDaemon.terminationDeadline)
        let exited = await eventually { !h.exits.statuses.isEmpty }
        #expect(exited)
        #expect(h.exits.statuses == [HelperDaemon.restoreNotConfirmedExitStatus])
        control.release()
        #expect(await running.value == HelperDaemon.restoreNotConfirmedExitStatus)
    }

    @Test("If the engine does not return in time, sleep is acknowledged anyway, once, and a fault is logged")
    func boundedAcknowledgement() async {
        let control = BlockingControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()

        control.holdNextReadBack()
        let acknowledgements = Acknowledgements()
        h.sleep.announceSleep { acknowledgements.record(activeAtAcknowledgement: []) }
        // The engine is stuck in its sleep checks; the daemon waits for the
        // next tick and for the acknowledgement's deadline.
        let stuck = await eventually { control.isHolding && h.clock.waits.count == 2 }
        #expect(stuck)
        h.clock.advance(by: HelperDaemon.sleepAcknowledgementTimeout - 0.5)
        #expect(acknowledgements.count == 0)

        h.clock.advance(by: 0.5)
        let acknowledged = await eventually { acknowledgements.count == 1 }
        #expect(acknowledged)
        let fault = await eventually { h.log.contains(.fault, .safety, "sleep acknowledged anyway") }
        #expect(fault)

        // The engine finishes later; sleep is not acknowledged twice.
        control.release()
        let late = await eventually { h.log.contains(.notice, .lifecycle, "The engine finished its sleep checks after sleep had been acknowledged.") }
        #expect(late)
        #expect(acknowledgements.count == 1)

        #expect(await h.terminate(running) == 0)
    }

    @Test("The engine's sink returns without waiting for the log or the history file")
    func sinkDoesNotWait() async {
        let store = InMemoryHistoryStore()
        let h = DaemonHarness(store: store)
        let running = await h.run()
        let settled = await eventually { h.log.lines.contains { $0.message.hasPrefix("Engine started") } }
        #expect(settled)

        // Hold the log's next write and the next save, as if both were slow.
        h.log.block()
        store.blockSaves()
        let session = await h.introducedSession()
        let held = await eventually { h.log.isWaiting }
        #expect(held)
        // The engine keeps serving: each call delivers its events to the
        // sink and returns while the log is still held.
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)
        #expect(await session.readState().activeControls.controls == [.chargingInhibited])
        #expect(h.log.isWaiting)
        #expect(!h.log.lines.contains { $0.message.hasPrefix("engine: activated") })
        #expect(store.saveCount == 0)

        // Released, the log reaches the activation and waits for the save,
        // which is still held; then the lines arrive in the order of the
        // events.
        h.log.release()
        let recorded = await eventually { h.log.lines.contains { $0.message.hasPrefix("engine: activationRecorded") } }
        #expect(recorded)
        #expect(store.saveCount == 0)
        store.release()
        let saved = await eventually { store.saveCount == 1 && h.log.lines.contains { $0.message.hasPrefix("engine: activated") } }
        #expect(saved)
        let messages = h.log.lines.map(\.message)
        let opened = messages.firstIndex { $0.hasPrefix("engine: sessionOpened") }
        let granted = messages.firstIndex { $0.hasPrefix("engine: leaseGranted") }
        let activated = messages.firstIndex { $0.hasPrefix("engine: activated") }
        #expect(opened != nil && granted != nil && activated != nil)
        if let opened, let granted, let activated {
            #expect(opened < granted && granted < activated)
        }
        #expect(await h.terminate(running) == 0)
    }
}
