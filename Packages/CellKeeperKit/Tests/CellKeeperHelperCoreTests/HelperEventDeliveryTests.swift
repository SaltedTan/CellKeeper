// A sink that re-enters the engine calls its request methods synchronously,
// on the engine's executor; those are internal to the module.
@testable import CellKeeperHelperCore
import Foundation
import Testing

/// Thread-safe bookkeeping for a sink: whether it has fired, and how deeply
/// it was entered.
private final class SinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private var depth = 0
    private(set) var maximumDepth = 0

    /// True the first time only.
    func fireOnce() -> Bool {
        lock.withLock {
            defer { hasFired = true }
            return !hasFired
        }
    }

    func enter() {
        lock.withLock {
            depth += 1
            maximumDepth = max(maximumDepth, depth)
        }
    }

    func leave() {
        lock.withLock { depth -= 1 }
    }
}

@Suite("Helper engine: event delivery")
struct HelperEventDeliveryTests {
    enum Reentry: String, CaseIterable, Sendable {
        case tickAtZeroPercent, systemWillSleep, invalidation, restoreDefaults
    }

    /// Activates the adapter-disable while the sink re-enters the engine at
    /// the first event it sees. Returns the activation's status.
    private func activate(reentering reentry: Reentry, _ h: Harness, _ session: HelperSession, _ other: HelperSession) async -> HelperStatus {
        _ = await session.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 120)
        let engine = h.engine
        let power = h.power
        let probe = SinkProbe()
        h.recorder.react { _ in
            guard probe.fireOnce() else { return }
            engine.assumeIsolated { engine in
                switch reentry {
                case .tickAtZeroPercent:
                    power.update { $0.stateOfCharge = 0 }
                    engine.tick()
                case .systemWillSleep:
                    engine.systemWillSleep()
                case .invalidation:
                    engine.invalidate(session.id)
                case .restoreDefaults:
                    _ = engine.restoreDefaults(other.id)
                }
            }
        }
        h.recorder.removeAll()
        let status = await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true)
        h.recorder.react(nil)
        return status
    }

    @Test("A sink that re-enters the engine runs a complete operation after this one: no activation slips past an interlock", arguments: Reentry.allCases)
    func reentrantSink(reentry: Reentry) async {
        let h = Harness()
        let session = await h.startedSession()
        let other = await h.introducedSession()

        // The activation completed before any event was delivered.
        #expect(await activate(reentering: reentry, h, session, other) == .ok)
        let events = h.recorder.events
        #expect(events.prefix(3) == [
            .write(HelperWriteRecord(target: .control(.adapterDisabled, active: true), outcome: .confirmed, readBack: [.adapterDisabled])),
            .activationRecorded(events.compactMap { event -> HelperActivationRecord? in
                if case .activationRecorded(let record) = event { return record }
                return nil
            }.first ?? HelperActivationRecord(control: .adapterDisabled, uptime: -1)),
            .activated(.adapterDisabled, by: session.id),
        ])
        // The re-entered operation then cleared it, and its events follow.
        #expect(h.control.activeControls.isEmpty)
        let clearing = events.firstIndex(of: .write(HelperWriteRecord(
            target: .control(.adapterDisabled, active: false), outcome: .confirmed, readBack: []
        ))) ?? events.firstIndex(of: .write(HelperWriteRecord(
            target: .restoreDefaults, outcome: .confirmed, readBack: []
        )))
        #expect(clearing.map { $0 > 2 } == true)

        // And what the re-entered operation decided holds.
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        let adapter = HelperControl.adapterDisabled.rawValue
        switch reentry {
        case .tickAtZeroPercent, .systemWillSleep:
            #expect(await session.acquireOrRenewLease(control: adapter, seconds: 120).status == .ok)
            #expect(await session.setControl(control: adapter, active: true) == .blockedByInterlock)
        case .invalidation:
            #expect(await session.acquireOrRenewLease(control: adapter, seconds: 120).status == .notIntroduced)
        case .restoreDefaults:
            #expect(await session.readState().isLeaseHolder == false)
        }
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("Events of a re-entered operation follow in order, and the sink is never entered recursively")
    func reentryOrder() async {
        let h = Harness()
        let session = await h.startedSession()
        _ = await session.acquireOrRenewLease(control: HelperControl.adapterDisabled.rawValue, seconds: 120)
        let engine = h.engine
        let power = h.power
        let probe = SinkProbe()
        h.recorder.removeAll()
        h.recorder.react { _ in
            probe.enter()
            defer { probe.leave() }
            // Every event re-enters with a tick; only the first changes
            // anything, so the rest add no events.
            if probe.fireOnce() {
                power.update { $0.stateOfCharge = 0 }
            }
            engine.assumeIsolated { $0.tick() }
        }
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .ok)
        h.recorder.react(nil)

        #expect(probe.maximumDepth == 1)
        let events = h.recorder.events
        let activated = events.firstIndex(of: .activated(.adapterDisabled, by: session.id))
        let raised = events.firstIndex(of: .interlocksRaised([.belowBatteryFloor, .belowAdapterFloor]))
        let deactivated = events.firstIndex(of: .deactivated(.adapterDisabled, .interlock([.belowBatteryFloor, .belowAdapterFloor])))
        #expect(activated != nil && raised != nil && deactivated != nil)
        if let activated, let raised, let deactivated {
            #expect(activated < raised && raised < deactivated)
        }
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("A sink that blocks delays only what follows; the write was made within its lease")
    func blockingSink() async {
        let h = Harness()
        let session = await h.startedSession()
        let adapter = HelperControl.adapterDisabled.rawValue
        #expect(await session.acquireOrRenewLease(control: adapter, seconds: 1).grantedSeconds == 1)
        let grantedAt = h.clock.uptime
        let clock = h.clock
        h.recorder.react { event in
            if case .activationRecorded = event { clock.advance(by: 2) }
        }
        #expect(await session.setControl(control: adapter, active: true) == .ok)
        h.recorder.react(nil)

        let history = await h.engine.activationHistory
        #expect(history.count == 1)
        #expect(history.first.map { $0.uptime < grantedAt + 1 } == true)
        // The lease has run out meanwhile; the next check clears the control.
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
    }
}

@Suite("Helper engine: final checks")
struct HelperFinalCheckTests {
    @Test("A power state that goes stale during the checks clears the other active control too", arguments: HelperControl.allCases)
    func staleAtFinalCheck(alreadyActive: HelperControl) async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(alreadyActive, on: session) == .ok)
        let requested = HelperControl.allCases.first { $0 != alreadyActive } ?? alreadyActive
        #expect(await session.acquireOrRenewLease(control: requested.rawValue, seconds: 60).status == .ok)

        // A sample 59 s old when the checks judge it; 2 s pass before the
        // final check.
        let readAt = h.clock.uptime - 59
        h.power.update {
            $0.readAtUptime = readAt
            $0.jumpAfterJudged = 2
        }
        #expect(await session.setControl(control: requested.rawValue, active: true) == .blockedByInterlock)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.deactivated(alreadyActive, .interlock(.powerStateUnavailable))))
        #expect(await session.readState().interlocks == .powerStateUnavailable)
    }
}

@Suite("Helper engine: restore ownership after failed reads")
struct HelperRestoreOwnershipTests {
    @Test("A failed read never makes another tool's control the engine's", arguments: [false, true])
    func failedReadKeepsForeignControl(preRestoreReadFails: Bool) async {
        let h = Harness()
        let observer = await h.startedSession()
        // Another tool's inhibit survives a failed restore; the engine goes quiet.
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        h.control.failNextRestores(1)
        await h.engine.tick()
        var writes = h.control.writeCount
        await h.engine.tick()
        #expect(h.control.writeCount == writes)

        // A read fails; then a client's restore leaves the inhibit as it was.
        h.control.failNextReadBacks(1)
        #expect(await observer.readState().status == .hardwareError)
        if preRestoreReadFails {
            h.control.failNextReadBacks(1)
        }
        h.control.ignoreNextRestores(1)
        #expect(await observer.restoreDefaults() == .hardwareError)
        #expect(h.control.activeControls == [.chargingInhibited])

        // Still not the engine's: no restores of its own.
        writes = h.control.writeCount
        for _ in 0..<10 {
            await h.engine.tick()
        }
        #expect(h.control.writeCount == writes)
    }

    @Test("A competing writer that sets an inactive control during each restore is taken for the engine's (a known limitation)")
    func competingWriterIsRetried() async {
        let h = Harness()
        _ = await h.startedSession()
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        h.control.simulateCompetingWriterDuringNextRestores(11, setting: .adapterDisabled)
        await h.engine.tick()
        #expect(h.control.activeControls == [.adapterDisabled])

        // Before and after the restore look exactly like a restore that set
        // the wrong control, so the engine retries once per tick.
        let writes = h.control.writeCount
        for _ in 0..<10 {
            await h.engine.tick()
        }
        #expect(h.control.writeCount == writes + 10)
        #expect(h.control.activeControls == [.adapterDisabled])
    }
}

@Suite("Helper engine: activation records")
struct HelperActivationRecordTests {
    @Test("A history rebuilt from the events equals the engine's, with the write times, and holds across a relaunch")
    func eventsCarryWriteTimes() async {
        let clock = HelperTestClock()
        let first = Harness(clock: clock)
        let session = await first.startedSession()
        let inhibit = HelperControl.chargingInhibited.rawValue
        #expect(await first.activate(.chargingInhibited, on: session) == .ok)
        #expect(await session.setControl(control: inhibit, active: false) == .ok)
        clock.advance(by: HelperEngine.minimumActivationInterval)
        #expect(await first.activate(.chargingInhibited, on: session) == .ok)

        let fromEvents = first.recorder.events.compactMap { event -> HelperActivationRecord? in
            if case .activationRecorded(let record) = event { return record }
            return nil
        }
        #expect(fromEvents == (await first.engine.activationHistory))
        _ = await session.restoreDefaultsAndExit()

        // A relaunch with the persisted events: 59.9 s after the last write.
        clock.advance(by: HelperEngine.minimumActivationInterval - 0.1 - (clock.uptime - (fromEvents.last?.uptime ?? 0)))
        let second = Harness(clock: clock, activationHistory: fromEvents)
        let reconnected = await second.startedSession()
        #expect(await second.activate(.chargingInhibited, on: reconnected) == .rateLimited)
        clock.advance(by: 0.2)
        #expect(await second.activate(.chargingInhibited, on: reconnected) == .ok)
    }
}
