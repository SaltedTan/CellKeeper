@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper daemon: sleep and wake")
struct HelperDaemonSleepTests {
    @Test("Sleep is acknowledged only after the engine has run its sleep checks (R16, precondition 13)")
    func acknowledgedAfterEngine() async {
        let control = SimulatedChargeControl()
        let h = DaemonHarness(control: control)
        let running = await h.run()
        let session = await h.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 120)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .ok)

        let acknowledgements = Acknowledgements()
        h.sleep.announceSleep {
            // The engine cleared the adapter-disable before this runs.
            acknowledgements.record(activeAtAcknowledgement: control.activeControls)
        }
        let acknowledged = await eventually { acknowledgements.count == 1 }
        #expect(acknowledged)
        #expect(acknowledgements.activeAtFirst == [])
        #expect(control.writes.last == .apply(.adapterDisabled, active: false))
        #expect(await session.readState().interlocks.contains(.sleepImminent))
        let logged = await eventually { h.log.contains(.info, .lifecycle, "Sleep acknowledged after the engine's sleep checks.") }
        #expect(logged)
        // The deadline's timer was cancelled with the acknowledgement.
        h.clock.advance(by: HelperDaemon.sleepAcknowledgementTimeout)
        #expect(acknowledgements.count == 1)

        #expect(await h.terminate(running) == 0)
    }

    @Test("Wake is forwarded to the engine (R17)")
    func wakeForwarded() async {
        let h = DaemonHarness()
        let running = await h.run()
        let session = await h.introducedSession()

        let acknowledgements = Acknowledgements()
        h.sleep.announceSleep { acknowledgements.record(activeAtAcknowledgement: []) }
        let acknowledged = await eventually { acknowledgements.count == 1 }
        #expect(acknowledged)
        #expect(await session.readState().interlocks.contains(.sleepImminent))

        h.sleep.wake()
        let woke = await eventually { h.log.contains(.info, .lifecycle, "Wake forwarded to the engine.") }
        #expect(woke)
        let interlocks = await session.readState().interlocks
        #expect(!interlocks.contains(.sleepImminent))

        #expect(await h.terminate(running) == 0)
    }

    @Test("Sleep and wake reach the engine in the order they happened")
    func ordered() async {
        let h = DaemonHarness()
        let running = await h.run()
        let session = await h.introducedSession()

        let acknowledgements = Acknowledgements()
        for _ in 0..<5 {
            h.sleep.announceSleep { acknowledgements.record(activeAtAcknowledgement: []) }
            h.sleep.wake()
        }
        let done = await eventually {
            acknowledgements.count == 5 && h.log.lines.filter { $0.message == "Wake forwarded to the engine." }.count == 5
        }
        #expect(done)
        // The last event was a wake, so sleep is no longer imminent.
        let interlocks = await session.readState().interlocks
        #expect(!interlocks.contains(.sleepImminent))

        #expect(await h.terminate(running) == 0)
    }
}

/// Records the daemon's acknowledgements of sleep.
final class Acknowledgements: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Set<HelperControl>] = []

    var count: Int {
        lock.withLock { recorded.count }
    }

    var activeAtFirst: Set<HelperControl>? {
        lock.withLock { recorded.first }
    }

    func record(activeAtAcknowledgement active: Set<HelperControl>) {
        lock.withLock { recorded.append(active) }
    }
}
