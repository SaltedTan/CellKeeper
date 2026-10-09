import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper engine: faulty restores")
struct HelperFaultyRestoreTests {
    private let adapter = HelperControl.adapterDisabled.rawValue

    /// Starts clean, sets the inhibit from outside, arms the faults, and
    /// runs a tick, whose restore is the faulty one.
    private func restoreAfterOutsideChange(_ h: Harness, faults: (SimulatedChargeControl) -> Void) async -> HelperSession {
        let observer = await h.startedSession()
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        faults(h.control)
        await h.engine.tick()
        return observer
    }

    @Test("A restore that sets the wrong control makes that control the engine's until it reads back inactive")
    func wrongControl() async {
        let h = Harness()
        let observer = await restoreAfterOutsideChange(h) { $0.misrestoreNextRestores(1) }
        #expect(h.control.activeControls == [.adapterDisabled])
        #expect(await observer.readState().interlocks == [.externalModification, .hardwareFault])

        // Deactivating it retries the restore instead of answering ok.
        h.control.failNextRestores(1)
        #expect(await observer.setControl(control: adapter, active: false) == .hardwareError)
        #expect(h.control.activeControls == [.adapterDisabled])

        // Ticks retry it despite the outside change.
        let writes = h.control.writeCount
        await h.engine.tick()
        #expect(h.control.writeCount == writes + 1)
        #expect(h.control.activeControls.isEmpty)

        // Then the quiet state begins.
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        await h.engine.tick()
        #expect(h.control.writeCount == writes + 1)
    }

    @Test("A restore that sets the wrong control and then throws makes that control the engine's")
    func wrongControlThenThrew() async {
        let h = Harness()
        _ = await restoreAfterOutsideChange(h) {
            $0.misrestoreNextRestores(1)
            $0.failNextRestoresAfterRestoring(1)
        }
        #expect(h.control.activeControls == [.adapterDisabled])
        #expect(h.recorder.writes.last?.outcome == .threw(code: HelperHardwareError.simulatedFailure.code))

        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("A restore that sets the wrong control and cannot be read back makes that control the engine's")
    func wrongControlThenUnread() async {
        let h = Harness()
        _ = await restoreAfterOutsideChange(h) {
            $0.misrestoreNextRestores(1)
            $0.failReadBacksAfterNextRestores(1)
        }
        #expect(h.control.activeControls == [.adapterDisabled])
        #expect(h.recorder.writes.last?.outcome == .readBackFailed(code: HelperHardwareError.simulatedFailure.code))

        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("A restore that applies and then throws is retried until confirmed")
    func appliedThenThrew() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        h.control.failNextRestoresAfterRestoring(1)

        #expect(await session.restoreDefaults() == .hardwareError)
        #expect(h.control.activeControls.isEmpty)
        #expect(await session.readState().interlocks == .hardwareFault)
        await h.engine.tick()
        #expect(await session.readState().interlocks.isEmpty)
    }

    @Test("After a partial restore, the engine's own control is retried; another tool's is left alone", arguments: HelperControl.allCases)
    func partialRestore(kept: HelperControl) async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        h.control.simulateOutsideChange(.chargingInhibited, active: true)
        h.control.partiallyRestoreNextRestores(1, keeping: kept)

        await h.engine.tick()
        #expect(h.control.activeControls == [kept])
        let writes = h.control.writeCount
        await h.engine.tick()
        await h.engine.tick()
        if kept == .adapterDisabled {
            // The engine set it: retried until it reads back inactive.
            #expect(h.control.writeCount == writes + 1)
            #expect(h.control.activeControls.isEmpty)
        } else {
            // Active before and after the restore, and never the engine's:
            // the quiet state, until a client restores.
            #expect(h.control.writeCount == writes)
            #expect(h.control.activeControls == [.chargingInhibited])
            #expect(await session.restoreDefaults() == .ok)
            #expect(h.control.activeControls.isEmpty)
        }
    }
}

@Suite("Helper engine: slow event sink")
struct HelperSlowSinkTests {
    @Test("A slow event sink cannot make an activation outlive its lease; the reservation still counts")
    func leaseExpiresInSink() async {
        let h = Harness()
        let session = await h.startedSession()
        let adapter = HelperControl.adapterDisabled.rawValue
        #expect(await session.acquireOrRenewLease(control: adapter, seconds: 1).grantedSeconds == 1)
        let clock = h.clock
        h.recorder.react { event in
            if case .activationRecorded = event { clock.advance(by: 2) }
        }
        let writes = h.control.writeCount

        #expect(await session.setControl(control: adapter, active: true) == .noLease)
        #expect(h.control.writeCount == writes)
        #expect(h.control.activeControls.isEmpty)
        #expect(await h.engine.activationHistory.map(\.control) == [.adapterDisabled])

        h.recorder.react(nil)
        #expect(await h.activate(.adapterDisabled, on: session) == .rateLimited)
        #expect(h.control.writeCount == writes)
    }

    @Test("A slow event sink cannot make an activation rely on a power state that has gone stale")
    func powerStaleInSink() async {
        let h = Harness()
        let session = await h.startedSession()
        let inhibit = HelperControl.chargingInhibited.rawValue
        _ = await session.acquireOrRenewLease(control: inhibit, seconds: 900)
        let clock = h.clock
        h.recorder.react { event in
            if case .activationRecorded = event { clock.advance(by: HelperEngine.maximumPowerStateAge + 1) }
        }

        #expect(await session.setControl(control: inhibit, active: true) == .blockedByInterlock)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.interlocksRaised(.powerStateUnavailable)))

        h.recorder.react(nil)
        #expect(await session.readState().interlocks.isEmpty)
    }

    @Test("The activation limits measure from the real write time, not from the reservation")
    func dwellFromWriteTime() async {
        let h = Harness()
        let session = await h.startedSession()
        let inhibit = HelperControl.chargingInhibited.rawValue
        let clock = h.clock
        h.recorder.react { event in
            if case .activationRecorded = event { clock.advance(by: 30) }
        }
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        h.recorder.react(nil)
        #expect(await session.setControl(control: inhibit, active: false) == .ok)

        // 60 s after the reservation, but only 30 s after the write.
        h.clock.advance(by: 30)
        #expect(await session.setControl(control: inhibit, active: true) == .rateLimited)
        h.clock.advance(by: 30)
        #expect(await session.setControl(control: inhibit, active: true) == .ok)
    }
}

@Suite("Helper engine: exit readiness")
struct HelperExitReadinessTests {
    @Test("safeToExit is sent again when a new restore debt during shutdown is settled")
    func safeAgain() async {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await h.engine.terminate() == .ok)
        #expect(h.recorder.count(of: .safeToExit) == 1)

        h.control.failNextReadBacks(1)
        h.control.failNextRestores(1)
        #expect(await session.restoreDefaults() == .hardwareError)
        #expect(await h.engine.isSafeToExit == false)

        await h.engine.tick()
        #expect(await h.engine.isSafeToExit)
        #expect(h.recorder.count(of: .safeToExit) == 2)
    }
}

@Suite("Helper engine: imported history")
struct HelperImportedHistoryTests {
    @Test("Imported history keeps only the latest records the limits need")
    func bounded() async {
        let clock = HelperTestClock()
        clock.advance(by: 10_000)
        let now = clock.uptime
        let count = 100_000
        // Within the last hour, in a scrambled but fixed order.
        let valid = (0..<count).map { index -> HelperActivationRecord in
            let step = (index * 7_919) % count
            return HelperActivationRecord(
                control: step.isMultiple(of: 2) ? .chargingInhibited : .adapterDisabled,
                uptime: now - 3_000 + Double(step) * 0.02
            )
        }
        let invalid = [
            HelperActivationRecord(control: .chargingInhibited, uptime: now + 1),
            HelperActivationRecord(control: .chargingInhibited, uptime: .nan),
            HelperActivationRecord(control: .chargingInhibited, uptime: now - 3_600),
        ]
        let h = Harness(clock: clock, activationHistory: valid + invalid)

        let history = await h.engine.activationHistory
        let latest = valid.sorted { $0.uptime < $1.uptime }.suffix(HelperEngine.maximumActivationsPerHour)
        #expect(history == Array(latest))
        // Both limits still hold with the bounded history.
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .rateLimited)
        #expect(await h.activate(.adapterDisabled, on: session) == .rateLimited)
    }
}
