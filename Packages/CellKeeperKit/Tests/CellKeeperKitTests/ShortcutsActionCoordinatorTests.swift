import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

/// How Shortcuts actions are admitted: the readiness waits against one
/// deadline, quitting, cancellation, and the backend context. The app is a
/// fake that records what the actions ask for; the clock moves only when a
/// test says so.
@Suite("Shortcuts actions: admission", .timeLimit(.minutes(1)))
@MainActor
struct ShortcutsActionCoordinatorTests {
    let clock = ManualDeadlineClock()
    let logged = LogLines()

    private func makeCoordinator() -> ShortcutsActionCoordinator {
        let logged = logged
        return ShortcutsActionCoordinator(clock: clock, log: { logged.lines.append($0) })
    }

    private let notReady = ShortcutsActionOutcome.refused(ShortcutsActionWording.notReady)
    private let quitting = ShortcutsActionOutcome.refused(ShortcutsActionWording.quitting)

    // MARK: - Readiness

    @Test("Before the app is attached, an action waits for it, then refuses at the deadline")
    func notAttached() async {
        let coordinator = makeCoordinator()
        let action = Task { await coordinator.stopOverride() }
        await clock.waitForSleeps(1)
        clock.advance(by: ShortcutsActionCoordinator.readinessBound)
        let outcome = await action.value
        #expect(outcome == notReady)
        #expect(logged.lines == ["Shortcuts action Stop CellKeeper Full Charge or Discharge: refused: \(ShortcutsActionWording.notReady)"])
    }

    @Test("Attached in time, an action that needs no status goes ahead at once")
    func attachedInTime() async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock)
        let action = Task { await coordinator.stopOverride() }
        await clock.waitForSleeps(1)
        coordinator.attach(target)
        let outcome = await action.value
        #expect(outcome == .done("CellKeeper will end any temporary full charge or discharge in progress. The menu shows what CellKeeper does now."))
        #expect(target.cancelsQueued == 1)
    }

    @Test("Attached without a status: an action that needs one waits, then refuses at the deadline and changes nothing")
    func noFirstStatus() async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock)
        coordinator.attach(target)
        let action = Task { await coordinator.setChargeLimit(70) }
        await clock.waitForSleeps(1)
        clock.advance(by: ShortcutsActionCoordinator.readinessBound)
        let outcome = await action.value
        #expect(outcome == notReady)
        #expect(target.changes.isEmpty)
    }

    @Test("Both waits share one deadline: time spent waiting for the app is not given back for the status")
    func oneDeadline() async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock)
        let action = Task { await coordinator.setChargeLimit(70) }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(6))
        coordinator.attach(target)
        await clock.waitForSleeps(2)
        clock.advance(by: .seconds(4))
        let outcome = await action.value
        #expect(outcome == notReady)
        #expect(target.changes.isEmpty)
    }

    @Test("A first status that arrives after the deadline is refused, even if the timer has not fired")
    func lateStatus() async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock)
        coordinator.attach(target)
        let action = Task { await coordinator.setChargeLimit(70) }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(11), waking: false)
        target.receive(await evaluatedActionStatus())
        let outcome = await action.value
        #expect(outcome == notReady)
        #expect(target.changes.isEmpty)
    }

    @Test("A first status in time lets the action go ahead")
    func statusInTime() async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock)
        coordinator.attach(target)
        let status = await evaluatedActionStatus()
        let action = Task { await coordinator.setChargeLimit(70) }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(9))
        target.receive(status)
        let outcome = await action.value
        guard case .done = outcome else {
            Issue.record("expected the limit to be saved, got \(outcome)")
            return
        }
        #expect(target.changes.map(\.settings.chargeLimit) == [70])
        #expect(target.changes.map(\.source) == [.shortcuts])
    }

    @Test("Cancelled while waiting for the app, an action refuses and changes nothing, also once the app arrives")
    func cancelledWaitingForApp() async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock, status: await evaluatedActionStatus())
        let action = Task { await coordinator.setManagement(false) }
        await clock.waitForSleeps(1)
        action.cancel()
        let outcome = await action.value
        #expect(outcome == notReady)
        coordinator.attach(target)
        #expect(target.changes.isEmpty)
    }

    @Test("Cancelled while waiting for the first status, an action refuses and changes nothing, also once the status arrives")
    func cancelledWaitingForStatus() async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock)
        coordinator.attach(target)
        let action = Task { await coordinator.startFullCharge() }
        await clock.waitForSleeps(1)
        action.cancel()
        let outcome = await action.value
        #expect(outcome == notReady)
        target.receive(await evaluatedActionStatus())
        #expect(target.fullChargesQueued == 0)
    }

    @Test("Quitting while an action waits for the status: it refuses as quitting and changes nothing")
    func quittingDuringWait() async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock)
        coordinator.attach(target)
        let action = Task { await coordinator.setManagement(true) }
        await clock.waitForSleeps(1)
        target.isTerminating = true
        target.receive(await evaluatedActionStatus())
        let outcome = await action.value
        #expect(outcome == quitting)
        #expect(target.changes.isEmpty)
    }

    @Test("Once quitting has started, every action refuses and changes nothing", arguments: 0..<5)
    func quitting(action index: Int) async {
        let coordinator = makeCoordinator()
        let target = FakeActionTarget(clock: clock, status: await evaluatedActionStatus())
        target.isTerminating = true
        coordinator.attach(target)
        let outcome: ShortcutsActionOutcome
        switch index {
        case 0: outcome = await coordinator.setChargeLimit(70)
        case 1: outcome = await coordinator.startFullCharge()
        case 2: outcome = await coordinator.stopOverride()
        case 3: outcome = await coordinator.setManagement(false)
        default:
            let status = await coordinator.status()
            #expect(status == .refused(ShortcutsActionWording.quitting))
            return
        }
        #expect(outcome == quitting)
        #expect(target.changes.isEmpty)
        #expect(target.fullChargesQueued == 0)
        #expect(target.cancelsQueued == 0)
    }

    // MARK: - Backend context

    /// The three ways the context is not settled: a pending switch, the
    /// startup switch (the native backend in charge, another selected), and
    /// a switch the user chose that is still queued.
    private func unsettledTargets() async -> [FakeActionTarget] {
        let simulated = await evaluatedActionStatus()
        var pending = simulated
        pending.pendingBackend = ReadOnlyChargingBackend().descriptor
        let pendingTarget = FakeActionTarget(clock: clock, status: pending)
        let startupTarget = FakeActionTarget(clock: clock, status: asNativeLimit(simulated))
        let queuedTarget = FakeActionTarget(clock: clock, status: simulated, selectedBackendIdentifier: ReadOnlyChargingBackend().descriptor.identifier)
        return [pendingTarget, startupTarget, queuedTarget]
    }

    @Test("While unsettled, setting the limit, starting a full charge and turning management on are refused and change nothing")
    func unsettledRefuses() async {
        for target in await unsettledTargets() {
            let coordinator = makeCoordinator()
            coordinator.attach(target)
            let limit = await coordinator.setChargeLimit(70)
            let start = await coordinator.startFullCharge()
            let on = await coordinator.setManagement(true)
            #expect(limit == notReady)
            #expect(start == notReady)
            #expect(on == notReady)
            #expect(target.changes.isEmpty)
            #expect(target.fullChargesQueued == 0)
        }
    }

    @Test("While unsettled, turning management off and stopping are accepted, with generic text and no qualifiers")
    func unsettledAcceptsRelease() async {
        for target in await unsettledTargets() {
            let coordinator = makeCoordinator()
            coordinator.attach(target)
            let off = await coordinator.setManagement(false)
            let stop = await coordinator.stopOverride()
            #expect(off == .done("CellKeeper saved Manage charging as off. The menu shows what CellKeeper does now."))
            #expect(stop == .done("CellKeeper will end any temporary full charge or discharge in progress. The menu shows what CellKeeper does now."))
            #expect(target.changes.map(\.settings.isManagementEnabled) == [false])
            #expect(target.changes.map(\.source) == [.shortcuts])
            #expect(target.cancelsQueued == 1)
        }
    }

    @Test("While unsettled, the status reports the battery and settings, and says it is starting or switching")
    func unsettledStatus() async throws {
        let target = try #require(await unsettledTargets().first)
        let coordinator = makeCoordinator()
        coordinator.attach(target)
        guard case .status(let value) = await coordinator.status() else {
            Issue.record("expected a status")
            return
        }
        #expect(value.batteryCharge == 70)
        #expect(value.state == "still starting or switching")
        #expect(value.control == "still starting or switching")
        #expect(value.isSimulated == nil)
        #expect(value.chargeLimit == 80)
    }

    @Test("A fault alone does not unsettle the context: the limit is saved and the fault is said")
    func faultIsSettled() async {
        var status = await evaluatedActionStatus()
        status.isBackendFaulted = true
        let target = FakeActionTarget(clock: clock, status: status)
        let coordinator = makeCoordinator()
        coordinator.attach(target)
        let outcome = await coordinator.setChargeLimit(70)
        guard case .done(let text) = outcome else {
            Issue.record("expected the limit to be saved, got \(outcome)")
            return
        }
        #expect(text.contains("The control backend is faulted"))
        #expect(target.changes.count == 1)
    }

    // MARK: - The UI's checks

    @Test("A limit outside the choices is refused before anything is saved, with Settings' text")
    func limitOutsideChoices() async {
        let target = FakeActionTarget(clock: clock, status: await evaluatedActionStatus())
        let coordinator = makeCoordinator()
        coordinator.attach(target)
        let outcome = await coordinator.setChargeLimit(15)
        #expect(outcome == .refused(SettingsIssue.chargeLimitOutOfRange(15, allowed: ChargingSettings.chargeLimitRange).description))
        #expect(target.changes.isEmpty)
    }

    @Test("A start the menu would not offer is refused and not queued; one it would offer is queued once")
    func startChecks() async {
        var discharging = await evaluatedActionStatus(percent: 90)
        discharging.activeOverride = ChargeOverride.dischargeToLimit(target: 80, at: Date(timeIntervalSince1970: 1_800_000_000), uptime: 10_000)
        let busy = FakeActionTarget(clock: clock, status: discharging)
        let coordinator = makeCoordinator()
        coordinator.attach(busy)
        let refused = await coordinator.startFullCharge()
        #expect(refused == .refused("A discharge to the limit is running. Stop it first."))
        #expect(busy.fullChargesQueued == 0)

        let idle = FakeActionTarget(clock: clock, status: await evaluatedActionStatus())
        let other = makeCoordinator()
        other.attach(idle)
        let queued = await other.startFullCharge()
        #expect(queued == .done("CellKeeper received the request for a temporary full charge. Simulated: nothing on your Mac changes. The menu shows what CellKeeper does with it."))
        #expect(idle.fullChargesQueued == 1)
    }

    @Test("A failed save is refused with the fixed text")
    func saveFails() async {
        let target = FakeActionTarget(clock: clock, status: await evaluatedActionStatus())
        target.failsToSave = true
        let coordinator = makeCoordinator()
        coordinator.attach(target)
        let limit = await coordinator.setChargeLimit(70)
        let off = await coordinator.setManagement(false)
        #expect(limit == .refused(SettingsChangeResult.saveFailed))
        #expect(off == .refused(SettingsChangeResult.saveFailed))
    }

    @Test("Every settings change an action makes carries the Shortcuts source")
    func source() async {
        let target = FakeActionTarget(clock: clock, status: await evaluatedActionStatus())
        let coordinator = makeCoordinator()
        coordinator.attach(target)
        _ = await coordinator.setChargeLimit(60)
        _ = await coordinator.setManagement(false)
        _ = await coordinator.setManagement(true)
        #expect(target.changes.count == 3)
        #expect(target.changes.allSatisfy { $0.source == .shortcuts })
    }
}

/// Collects the coordinator's log lines.
@MainActor
final class LogLines {
    var lines: [String] = []
}
