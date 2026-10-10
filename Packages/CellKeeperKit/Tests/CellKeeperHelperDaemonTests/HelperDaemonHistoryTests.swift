@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper daemon: activation history")
struct HelperDaemonHistoryTests {
    /// Runs a daemon, activates the charging inhibit through it, and shuts
    /// it down; returns the history its engine kept.
    private func activateOnce(store: InMemoryHistoryStore, clock: ManualClock) async -> [HelperActivationRecord] {
        let h = DaemonHarness(store: store, clock: clock)
        let running = await h.run()
        let session = await h.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)
        let saved = await eventually { store.saveCount == 1 }
        #expect(saved)
        let history = await h.daemon.engine.activationHistory
        #expect(await h.terminate(running) == 0)
        return history
    }

    @Test("Each activation saves the engine's history with this boot's identifier (D35)")
    func persisted() async {
        let store = InMemoryHistoryStore()
        let clock = ManualClock()
        let history = await activateOnce(store: store, clock: clock)
        #expect(history.map(\.control) == [.chargingInhibited])
        #expect(store.saved(boot: .testBoot, now: clock.uptime()) == .loaded(history))
    }

    @Test("A new daemon in the same boot starts with the saved history and keeps enforcing the limits")
    func reloadedInSameBoot() async {
        let store = InMemoryHistoryStore()
        let clock = ManualClock()
        let history = await activateOnce(store: store, clock: clock)

        clock.advance(by: 10)
        let relaunched = DaemonHarness(store: store, clock: clock)
        #expect(await relaunched.daemon.engine.activationHistory == history)
        let running = await relaunched.run()
        let session = await relaunched.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .rateLimited)
        let logged = await eventually { relaunched.log.contains(.notice, .safety, "Loaded 1 activation record(s) saved earlier in this boot") }
        #expect(logged)
        #expect(await relaunched.terminate(running) == 0)
    }

    @Test("A history saved in another boot is discarded")
    func discardedAfterReboot() async {
        let store = InMemoryHistoryStore()
        let clock = ManualClock()
        _ = await activateOnce(store: store, clock: clock)

        let rebooted = DaemonHarness(store: store, boot: .otherBoot, clock: clock)
        #expect(await rebooted.daemon.engine.activationHistory.isEmpty)
        let running = await rebooted.run()
        let logged = await eventually { rebooted.log.contains(.notice, .safety, "Discarded the saved activation history because it was saved in another boot") }
        #expect(logged)
        #expect(await rebooted.terminate(running) == 0)
    }

    @Test("An unusable history never prevents start")
    func corruptHistoryStillStarts() async throws {
        let store = InMemoryHistoryStore()
        let clock = ManualClock()
        // A record from the future of this boot's clock is implausible.
        try store.preload([HelperActivationRecord(control: .chargingInhibited, uptime: clock.uptime() + 1_000)], boot: .testBoot)

        let h = DaemonHarness(store: store, clock: clock)
        #expect(await h.daemon.engine.activationHistory.isEmpty)
        let running = await h.run()
        #expect(h.frontend.calls == [.start])
        let logged = await eventually { h.log.contains(.notice, .safety, "a record has an impossible time") }
        #expect(logged)
        #expect(await h.terminate(running) == 0)
    }

    @Test("Without a boot identifier the history is neither loaded nor saved")
    func noBootIdentifier() async throws {
        let store = InMemoryHistoryStore()
        let clock = ManualClock()
        try store.preload([HelperActivationRecord(control: .chargingInhibited, uptime: clock.uptime())], boot: .testBoot)

        let h = DaemonHarness(store: store, boot: nil, clock: clock)
        #expect(await h.daemon.engine.activationHistory.isEmpty)
        let running = await h.run()
        let session = await h.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 120)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .ok)
        let logged = await eventually {
            h.log.contains(.fault, .safety, "The boot identifier (kern.boottime) cannot be read")
                && h.log.contains(.info, .control, "engine: activationRecorded")
        }
        #expect(logged)
        #expect(store.saveCount == 0)
        #expect(await h.terminate(running) == 0)
    }

    @Test("A history that cannot be saved is logged once, and the daemon carries on")
    func saveFailureLoggedOnce() async {
        let store = InMemoryHistoryStore()
        store.failNextSaves(2)
        let h = DaemonHarness(store: store)
        let running = await h.run()
        let session = await h.introducedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        _ = await session.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 120)
        #expect(await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true) == .ok)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .ok)
        let twoActivations = await eventually { h.log.lines.filter { $0.message.hasPrefix("engine: activationRecorded") }.count == 2 }
        #expect(twoActivations)
        let flushed = await eventually { h.log.lines.contains { $0.message.hasPrefix("engine: activated(") && $0.message.contains("adapterDisabled") } }
        #expect(flushed)
        #expect(h.log.lines.filter { $0.message.hasPrefix("Cannot save the activation history") }.count == 1)
        #expect(store.saveCount == 0)

        // The next save succeeds and says so.
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: false) == .ok)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .ok)
        let recovered = await eventually { store.saveCount == 1 && h.log.contains(.notice, .safety, "The activation history is being saved again.") }
        #expect(recovered)
        #expect(await h.terminate(running) == 0)
    }
}

@Suite("Helper daemon: audit log")
struct HelperDaemonAuditTests {
    @Test("Events are logged in the four categories at the Simulated helper's levels", arguments: [
        (HelperEvent.sessionOpened(HelperSessionID(rawValue: 1)), HelperLogLevel.info, HelperLogCategory.xpc),
        (.requestRejected(HelperSessionID(rawValue: 1), .setControl, .noLease), .notice, .xpc),
        (.leaseGranted(HelperSessionID(rawValue: 1), .chargingInhibited, seconds: 900), .info, .control),
        (.activationRecorded(HelperActivationRecord(control: .chargingInhibited, uptime: 1)), .info, .control),
        (.restored(.start), .notice, .control),
        (.interlocksRaised(.sleepImminent), .notice, .safety),
        (.restoreFailed(.terminate), .fault, .safety),
        (.hardwareError(code: -1), .fault, .safety),
        (.safeToExit, .notice, .lifecycle),
    ])
    func placement(event: HelperEvent, level: HelperLogLevel, category: HelperLogCategory) {
        let placement = event.logPlacement
        #expect(placement.level == level)
        #expect(placement.category == category)
    }
}
