@testable import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// macOS's Charge Limit report whose first `waitingReads` reads wait until
/// they are cancelled; later reads report 85%.
final class ReadsWaitForCancellation: ChargeLimitReading, @unchecked Sendable {
    private let lock = NSLock()
    private let waitingReads: Int
    private var readCount = 0

    init(waitingReads: Int) {
        self.waitingReads = waitingReads
    }

    var reads: Int {
        lock.withLock { readCount }
    }

    func readChargeLimit() async throws -> NativeChargeLimitReading {
        let number = lock.withLock {
            readCount += 1
            return readCount
        }
        if number <= waitingReads {
            try await Task.sleep(for: .seconds(3600))
        }
        return .limit(85)
    }
}

/// Waits, polling, until `condition` holds; fails the test after about 5 s.
func eventually(_ what: String, _ condition: () async -> Bool) async {
    for _ in 0..<5_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting until \(what)")
}

@Suite("macOS's Charge Limit monitor: settled reads")
struct MacOSChargeLimitSettledReadTests {
    static let off = MacOSChargeLimitStatus(reportedLimit: 100, isNoLimitReported: true, readAt: referenceDate)
    static let on = MacOSChargeLimitStatus(reportedLimit: 80, readAt: referenceDate)

    @Test("A late waiter for an older read cannot bring back its reading after a newer read was cancelled")
    func cancelledNewerReadKeepsOlderOut() {
        var cache = MacOSChargeLimitMonitor.ReadingCache()
        // Read 1 settles through its first waiter.
        let kept1 = cache.keep(Self.off, startedAt: 0, number: 1)
        #expect(kept1)
        // Read 2 is cancelled: nothing may stand in for it.
        cache.cancel(2)
        #expect(cache.latest == nil)
        // A second waiter for read 1 resumes only now.
        let kept2 = cache.keep(Self.off, startedAt: 0, number: 1)
        #expect(!kept2)
        #expect(cache.latest == nil)
        #expect(cache.isOvertaken(1))
        // A newer read counts again; cancelling an older one drops nothing.
        let kept3 = cache.keep(Self.on, startedAt: 40, number: 3)
        #expect(kept3)
        cache.cancel(2)
        #expect(cache.latest?.status == Self.on)
        #expect(cache.latest?.number == 3)
        #expect(!cache.isOvertaken(3))
    }

    @Test("A waiter for an overtaken read is never given an older reading than the one kept")
    func olderResultNeverReplacesNewer() {
        var cache = MacOSChargeLimitMonitor.ReadingCache()
        let kept4 = cache.keep(Self.on, startedAt: 40, number: 2)
        #expect(kept4)
        let kept5 = cache.keep(Self.off, startedAt: 0, number: 1)
        #expect(!kept5)
        #expect(cache.latest?.status == Self.on)
        #expect(cache.isOvertaken(1))
    }

    @Test("Another caller's cancellation does not cost a surviving caller its reading", .timeLimit(.minutes(1)))
    func survivorReadsAgain() async throws {
        let clock = TestClock()
        let reader = ReadsWaitForCancellation(waitingReads: 1)
        let monitor = MacOSChargeLimitMonitor(reader: reader, now: { clock.now }, uptime: { clock.uptime })
        let cancelled = Task { await monitor.status() }
        await eventually("the first caller waits for the read") { await monitor.waitingCallerCount == 1 }
        let survivor = Task { await monitor.status() }
        // Both callers wait for the same read before one is cancelled.
        await eventually("both callers wait for the same read") { await monitor.waitingCallerCount == 2 }
        #expect(reader.reads == 1)
        cancelled.cancel()
        let cancelledStatus = await cancelled.value
        let survivorStatus = await survivor.value
        #expect(cancelledStatus.readProblem == "the read was cancelled")
        #expect(survivorStatus.reportedLimit == 85)
        #expect(survivorStatus.readProblem == nil)
        #expect(reader.reads == 2)
        let kept = await monitor.lastStatus
        #expect(kept == survivorStatus)
    }

    @Test("Other callers' cancellations cannot hold a surviving caller up without end: after two re-reads it gets \"may be limiting\"", .timeLimit(.minutes(1)))
    func repeatedCancellationsEnd() async {
        let clock = TestClock()
        let reader = ReadsWaitForCancellation(waitingReads: 100)
        let monitor = MacOSChargeLimitMonitor(reader: reader, now: { clock.now }, uptime: { clock.uptime })
        let survivor = Task { await monitor.status() }
        await eventually("the survivor waits for the first read") { await monitor.waitingCallerCount == 1 }
        for attempt in 1...(MacOSChargeLimitMonitor.maximumRereads + 1) {
            let canceller = Task { await monitor.status() }
            await eventually("caller \(attempt) shares read \(attempt)") { await monitor.waitingCallerCount == 2 }
            #expect(reader.reads == attempt)
            canceller.cancel()
            _ = await canceller.value
            if attempt <= MacOSChargeLimitMonitor.maximumRereads {
                // The survivor reads again and waits for the new read.
                await eventually("the survivor waits for read \(attempt + 1)") {
                    await monitor.waitingCallerCount == 1 && reader.reads == attempt + 1
                }
            }
        }
        let status = await survivor.value
        #expect(status.readProblem == "the read was interrupted")
        #expect(status.isLimiting)
        #expect(reader.reads == MacOSChargeLimitMonitor.maximumRereads + 1)
        let kept = await monitor.lastStatus
        #expect(kept == nil)
    }
}

@Suite("What CellKeeper may still have in effect")
struct OwnRestrictionResponsibilityTests {
    @Test("While an activation's reply is outstanding, the status no longer shows the read taken before it")
    func pendingActivation() async {
        let rig = HelperRig()
        let hooks = RequestHooks()
        let backend = rig.hookedBackend(hooks)
        let controller = rig.controller(on: backend, percent: 85)
        let before = await controller.evaluate(.launch)
        #expect(before.currentMode == .normal)
        #expect(before.ownRestriction == .noneInEffect)
        let seen = StatusBox()
        hooks.onNextActivation {
            // The activation has been applied; its reply has not arrived.
            seen.status = await controller.status
        }
        rig.clock.advance(by: 60)
        let held = await controller.evaluate(.periodic)
        #expect(held.currentMode == .inhibitCharging)
        let during = seen.status
        #expect(during?.currentMode == nil)
        #expect(during?.ownRestriction == .unconfirmed(.inhibitCharging))
        #expect(during?.ownRestriction.mayBeInEffect == true)
    }

    @Test("A restore that failed leaves CellKeeper's hold its own, also once macOS's limit turns on during the retry wait, and the gate's safety event names it")
    func failedRestoreThenGate() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, telemetry) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        // The charge falls to the resume threshold: CellKeeper asks for the
        // release, and both the clear and the helper's restore fail.
        await telemetry.set(snapshot(percent: 70))
        rig.control.failNextApplies(1)
        rig.control.failNextRestores(1)
        rig.clock.advance(by: 60)
        let failed = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(failed.ownRestriction.mayBeInEffect)
        if case .notCellKeepers = failed.ownRestriction {
            Issue.record("CellKeeper's own hold reported as someone else's: \(failed.ownRestriction)")
        }

        // macOS's limit turns on while the automatic retry still waits.
        reader.set(.limit(80))
        rig.clock.advance(by: 31)
        let gated = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(gated.currentMode == .inhibitCharging)
        #expect(gated.ownRestriction == .inEffect(.inhibitCharging, own: .inhibitCharging))
        let event = gated.events.last { $0.kind == .safety && $0.message.contains("macOS's Charge Limit was turned on (80%) while CellKeeper held inhibitCharging") }
        #expect(event?.message.contains("No read-back has confirmed that this restriction ended, so it may remain") == true)
        let limit = gated.capabilities.macOSChargeLimit
        let guidance = limit.map { MacOSChargeLimitWording.guidance($0, ownRestriction: gated.ownRestriction, isSimulated: gated.isControlSimulated) } ?? ""
        #expect(guidance.contains("The last read-back still shows CellKeeper's inhibitCharging"))
        #expect(!guidance.contains("set by something other than CellKeeper"))
        #expect(!guidance.contains("never compete"))
    }

    @Test("An activation that applied before it threw stays CellKeeper's responsibility")
    func failedActivationThatApplied() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        await controller.evaluate(.launch)
        // The activation takes effect but reports an error, and the helper's
        // restores keep failing, so the control stays active.
        rig.control.failNextAppliesAfterApplying(1)
        rig.control.failNextRestores(20)
        rig.clock.advance(by: 60)
        let failed = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(failed.ownRestrictionMode == .inhibitCharging)
        #expect(failed.ownRestriction.mayBeInEffect)
        if case .notCellKeepers = failed.ownRestriction {
            Issue.record("CellKeeper's own activation reported as someone else's: \(failed.ownRestriction)")
        }

        reader.set(.limit(80))
        rig.clock.advance(by: 31)
        let gated = await controller.evaluate(.periodic)
        if case .notCellKeepers = gated.ownRestriction {
            Issue.record("CellKeeper's own activation reported as someone else's: \(gated.ownRestriction)")
        }
        #expect(gated.ownRestriction.mayBeInEffect)
        #expect(gated.events.contains { $0.kind == .safety && $0.message.contains("while CellKeeper held inhibitCharging") })
    }

    @Test("A genuine takeover by another client stays someone else's, by the helper's history")
    func takeoverIsForeign() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        let held = await rig.confirmedEvaluation(controller)
        #expect(held.currentMode == .inhibitCharging)
        // Another tool changes the controls: the helper restores defaults,
        // which ends CellKeeper's hold, and then stops fighting the tool,
        // which sets its own inhibit.
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        rig.clock.advance(by: 5)
        let restored = await controller.evaluate(.periodic)
        #expect(restored.isBackendFaulted)
        #expect(restored.currentMode == .normal)
        #expect(restored.ownRestrictionMode == nil)
        rig.control.simulateOutsideChange(.chargingInhibited, active: true)
        rig.clock.advance(by: 61)
        // This evaluation's request for normal charging is refused as an
        // outside change; the next one waits before retrying it.
        await controller.evaluate(.periodic)
        rig.clock.advance(by: 5)
        let taken = await controller.evaluate(.periodic)
        #expect(taken.isBackendFaulted)
        #expect(taken.currentMode == .inhibitCharging)
        #expect(taken.isReportedModeOwn == false)
        #expect(taken.ownRestriction == .notCellKeepers(.inhibitCharging))
        #expect(taken.ownRestrictionMode == nil)
    }
}

@Suite("Helper backend: who set what is in effect")
struct HelperOwnershipEvidenceTests {
    @Test("Ownership is reported only by a read that returns normally")
    func publishedOnlyOnSuccess() async throws {
        let rig = HelperRig()
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.isReportedModeOwn() == false)
        // The read-back fails: the read throws, and says nothing about who
        // set what.
        rig.control.failNextReadBacks(1)
        await #expect(throws: BackendError.self) { _ = try await rig.backend.currentMode() }
        #expect(await rig.backend.isReportedModeOwn() == nil)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.isReportedModeOwn() == false)
        // Another client's read-back fails and the helper's restore after it
        // reads back clean: CellKeeper's next read succeeds, but reports the
        // new hardware error by throwing, after the ownership was computed.
        rig.control.failNextReadBacks(1)
        let other = await rig.otherClient()
        _ = await other.readState()
        await #expect(throws: BackendError.self) { _ = try await rig.backend.currentMode() }
        #expect(await rig.backend.isReportedModeOwn() == nil)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(await rig.backend.isReportedModeOwn() == false)
    }

    @Test("A control the helper's failed restore activated after CellKeeper's failed release is not someone else's")
    func misrestoreAfterFailedRelease() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, telemetry) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        // CellKeeper asks for the release; the clear fails, and the helper's
        // restore after it activates the adapter-disable instead.
        await telemetry.set(snapshot(percent: 70))
        rig.control.failNextApplies(1)
        rig.control.misrestoreNextRestores(1)
        rig.clock.advance(by: 60)
        let failed = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.adapterDisabled])
        // Later restores fail too.
        rig.control.failNextRestores(50)
        reader.set(.limit(80))
        rig.clock.advance(by: 31)
        let gated = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.adapterDisabled])
        for status in [failed, gated] {
            #expect(status.isReportedModeOwn != false)
            #expect(status.ownRestrictionMode == .inhibitCharging)
            if case .notCellKeepers = status.ownRestriction {
                Issue.record("a control the helper's own restore activated reported as someone else's: \(status.ownRestriction)")
            }
            #expect(status.ownRestriction.mayBeInEffect)
        }
        #expect(gated.events.contains { $0.kind == .safety && $0.message.contains("macOS's Charge Limit was turned on (80%) while CellKeeper held inhibitCharging") })
        // The helper's own restore made the restriction; no outside writer
        // took part, and none is named. The backend still faults.
        #expect(gated.isBackendFaulted)
        assertNamesHelperFailure(gated, "CellKeeper's helper's own restore after a failure (restoredAfterWriteFailure) left the adapter disabled active")
    }

    /// The activity log and the diagnostics report name the helper's own
    /// failure, never an outside writer.
    private func assertNamesHelperFailure(_ status: ControllerStatus, _ expected: String) {
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains(expected) && $0.message.contains("Backend faulted") })
        #expect(!status.events.contains { $0.message.localizedCaseInsensitiveContains("changed outside CellKeeper") })
        #expect(!status.events.contains { $0.message.contains("another tool") || $0.message.contains("System Settings or by another") })
        let report = DiagnosticsReport.text(status: status, environment: DiagnosticsEnvironment(appVersion: "1", systemVersion: "27", modelIdentifier: nil), generatedAt: referenceDate)
        #expect(report.contains(expected))
        #expect(!report.localizedCaseInsensitiveContains("changed outside CellKeeper"))
    }

    @Test("A restarted helper whose start restore keeps failing establishes nothing: CellKeeper's hold stays its responsibility")
    func restartWithFailingStartRestore() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        // The helper stops without confirming its restore, and launchd starts
        // it again; its start restore fails and keeps failing.
        rig.control.failNextRestores(50)
        _ = await rig.engine.terminate()
        rig.transport.relaunch()
        reader.set(.limit(80))
        rig.clock.advance(by: 61)
        let status = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(status.isReportedModeOwn != false)
        #expect(status.ownRestrictionMode == .inhibitCharging)
        if case .notCellKeepers = status.ownRestriction {
            Issue.record("CellKeeper's hold reported as someone else's after a failed start restore: \(status.ownRestriction)")
        }
        #expect(status.ownRestriction.mayBeInEffect)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("macOS's Charge Limit was turned on (80%) while CellKeeper held inhibitCharging") })
        // The new helper records the control it found active as changed
        // outside, but reports no outside change, only an owed restore: no
        // writer is named, and the backend still faults.
        #expect(status.isBackendFaulted)
        assertNamesHelperFailure(status, "reports no outside change, only that its restore of macOS's defaults has not read back clean, so it cannot say who set it")
    }

    @Test("A tool that re-sets its control during the helper's restore leaves the helper quiet, and the message does not promise retries")
    func competingWriterDuringRestore() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        // Another tool sets the adapter-disable, and sets it again while the
        // helper's restore after that outside change runs.
        rig.control.simulateCompetingWriterDuringNextRestores(1, setting: .adapterDisabled)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        rig.clock.advance(by: 5)
        let status = await controller.evaluate(.periodic)
        #expect(status.isBackendFaulted)
        #expect(rig.control.activeControls == [.adapterDisabled])
        let state = await rig.observedState()
        #expect(state.interlocks.contains(.externalModification))
        #expect(state.interlocks.contains(.hardwareFault))
        // The engine owns no active control, so it stays quiet (D28).
        let writes = rig.control.writeCount
        for _ in 0..<5 {
            rig.clock.advance(by: 5)
            await rig.engine.tick()
        }
        #expect(rig.control.writeCount == writes)
        let fault = status.events.last { $0.kind == .safety && $0.message.contains("changed by something other than CellKeeper") }
        #expect(fault?.message.contains("It retries only while a control it set itself may still be active; otherwise it writes nothing more until you clear the fault, which asks it to restore") == true)
        #expect(!status.events.contains { $0.message.contains("owed and retried") })
    }

    @Test("An outside change whose restore fails is not reported as restored")
    func outsideChangeWithFailingRestore() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        rig.control.failNextRestores(50)
        rig.control.failNextApplies(50)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        rig.clock.advance(by: 5)
        let status = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.chargingInhibited, .adapterDisabled])
        #expect(status.isBackendFaulted)
        let fault = status.events.last { $0.kind == .safety && $0.message.contains("changed by something other than CellKeeper") }
        #expect(fault?.message.contains("it tried to restore macOS's defaults, but that restore has not read back clean") == true)
        #expect(fault?.message.contains("(simulated controls; your Mac's charging is not changed)") == true)
        #expect(!status.events.contains { $0.message.contains("it restored macOS's defaults") })
    }

    @Test("An outside change whose restore reads back clean says so")
    func outsideChangeWithConfirmedRestore() async {
        let rig = HelperRig()
        let (controller, _) = rig.controller(percent: 85)
        #expect(await rig.confirmedEvaluation(controller).currentMode == .inhibitCharging)
        rig.control.simulateOutsideChange(.adapterDisabled, active: true)
        rig.clock.advance(by: 5)
        let status = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls.isEmpty)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("it restored macOS's defaults and read them back with nothing active") })
    }
}

/// Holds a status captured inside a hook.
final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ControllerStatus?

    var status: ControllerStatus? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
