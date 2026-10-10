import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// Where the conversation with the helper fails or goes silent.
struct ConversationFault: Sendable, CustomStringConvertible {
    enum Kind: Sendable {
        case failure, timeout
    }

    var step: RemovalTestTransport.Step
    var kind: Kind

    static let all: [ConversationFault] = [
        ConversationFault(step: .connect, kind: .failure),
        ConversationFault(step: .hello, kind: .failure),
        ConversationFault(step: .restoreAndExit, kind: .failure),
        ConversationFault(step: .connect, kind: .timeout),
        ConversationFault(step: .hello, kind: .timeout),
        ConversationFault(step: .restoreAndExit, kind: .timeout),
    ]

    /// The log entry made when the step starts.
    var logEntry: String {
        switch step {
        case .connect: "helper.connect"
        case .hello: "helper.hello"
        case .restoreAndExit: "helper.restoreDefaultsAndExit"
        case .invalidate: "helper.invalidate"
        }
    }

    /// The reason the removal reports, with the helper's deadline.
    func reason(deadline: Duration) -> HelperNoConfirmationReason {
        switch (step, kind) {
        case (.connect, .failure): .connectFailed("test transport failure")
        case (.hello, .failure): .helloFailed("test transport failure")
        case (.restoreAndExit, .failure): .restoreConnectionFailed("test transport failure", helper: .simulated)
        case (.connect, .timeout), (.hello, .timeout): .noHello(deadline)
        case (.restoreAndExit, .timeout): .noRestoreReply(deadline, helper: .simulated)
        case (.invalidate, _): .noHello(deadline)
        }
    }

    var description: String {
        "\(kind) at \(step)"
    }
}

/// Safety precondition 9: the helper is unregistered only after it has
/// confirmed that it restored defaults, and every outcome says only what was
/// confirmed.
@Suite("Helper removal")
struct HelperRemovalTests {
    private static let unregisterSteps: Set<String> = ["helper.restoreDefaultsAndExit", "registration.unregister"]
    private static let deadline: Duration = HelperRemoval.defaultHelperDeadline

    /// Runs the removal while the test drives the helper's deadline.
    private func remove(_ removal: HelperRemoval, force: Bool) -> Task<HelperRemovalOutcome, Never> {
        Task {
            if force {
                return await removal.remove(force: .userHasSeenRecoveryProcedure)
            }
            return await removal.remove()
        }
    }

    // MARK: - The registration decides whether there is anything to remove

    @Test("No helper registered: nothing to remove, no helper contacted, nothing unregistered", arguments: [HelperRegistrationStatus.notRegistered, .notFound])
    func nothingRegistered(status: HelperRegistrationStatus) async {
        let rig = RemovalRig(registration: status)
        let outcome = await rig.removal().remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .nothingToRemove(status))
        #expect(rig.log.count(of: "helper.connect") == 0)
        #expect(rig.registration.unregisterCount == 0)
        #expect(!outcome.isRestoreConfirmed)
        #expect(!outcome.isHelperRemoved)
        #expect(outcome.summary.contains("nothing to remove"))
    }

    @Test("Any other status contacts the helper, and unregisters only after its restore", arguments: [HelperRegistrationStatus.enabled, .requiresApproval, .unknown("a status this version does not know")])
    func registeredStatusesContactTheHelper(status: HelperRegistrationStatus) async {
        let rig = RemovalRig(registration: status)
        let outcome = await rig.removal().remove()
        #expect(outcome == .removed(.simulated))
        #expect(rig.log.order(of: Self.unregisterSteps) == ["helper.restoreDefaultsAndExit", "registration.unregister"])
    }

    // MARK: - A confirmed restore

    @Test("ok, then unregister, then the status: removed, with the helper's controls at their defaults")
    func confirmedRestoreThenUnregister() async {
        let rig = RemovalRig()
        await rig.engine.start()
        await rig.holdInhibit()
        #expect(rig.control.activeControls == [.chargingInhibited])

        let outcome = await rig.removal().remove()

        #expect(outcome == .removed(.simulated))
        #expect(outcome.isRestoreConfirmed)
        #expect(outcome.isHelperRemoved)
        #expect(rig.control.activeControls.isEmpty)
        let isSafeToExit = await rig.engine.isSafeToExit
        #expect(isSafeToExit)
        // The status is read again after unregistering.
        #expect(rig.log.order(of: [
            "registration.status", "helper.connect", "helper.hello", "helper.restoreDefaultsAndExit",
            "helper.restoreDefaultsAndExit replied ok", "registration.unregister",
        ]) == [
            "registration.status", "helper.connect", "helper.hello", "helper.restoreDefaultsAndExit",
            "helper.restoreDefaultsAndExit replied ok", "registration.unregister", "registration.status",
        ])
        #expect(rig.registration.unregisterCount == 1)
    }

    @Test("A confirmation that arrives before the deadline counts, also while the connection is still being closed")
    func confirmationBeforeTheDeadlineCounts() async {
        let rig = RemovalRig()
        defer { rig.transport.gate.open() }
        rig.transport.stall(at: .invalidate)
        // The clock never moves, so the deadline never passes.
        let outcome = await rig.removal(clock: ManualDeadlineClock()).remove()
        #expect(outcome == .removed(.simulated))
        #expect(rig.log.count(of: "helper.invalidate") == 1)
    }

    @Test("A helper that really refuses hello still gets the restore, which needs no introduction")
    func refusedHelloStillRestores() async {
        let rig = RemovalRig(chargeControl: UnsimulatedChargeControl(inner: SimulatedChargeControl()))
        rig.transport.sayHello(withClientVersion: HelperProtocolVersion.current + 1)
        let outcome = await rig.removal().remove()
        #expect(rig.log.all.contains("helper.hello replied incompatibleProtocol"))
        // It did not complete hello, so it did not say what it controls.
        #expect(outcome == .removed(.unknown))
        #expect(outcome.summary.contains("The helper confirmed that its controls are back at their defaults."))
        let isSafeToExit = await rig.engine.isSafeToExit
        #expect(isSafeToExit)
    }

    @Test("A helper already shutting down confirms defaults with its restore")
    func helperAlreadyShuttingDown() async {
        let rig = RemovalRig()
        await rig.engine.start()
        await rig.engine.terminate()
        let outcome = await rig.removal().remove()
        #expect(outcome == .removed(.simulated))
    }

    // MARK: - An explicit refusal is never overridden

    @Test("A helper that replies hardwareError is never unregistered, even when forced, and keeps retrying the restore itself", arguments: [false, true])
    func hardwareErrorIsNotUnregistered(force: Bool) async {
        let rig = RemovalRig()
        await rig.engine.start()
        await rig.holdInhibit()
        rig.control.failNextRestores(1)

        let outcome = await remove(rig.removal(), force: force).value

        #expect(outcome == .restoreRefused(.hardwareError, helper: .simulated))
        #expect(!outcome.isRestoreConfirmed)
        #expect(!outcome.offersForcedRemoval)
        #expect(rig.registration.unregisterCount == 0)
        #expect(outcome.summary.contains("keeps retrying the restore by itself"))
        let isSafeToExit = await rig.engine.isSafeToExit
        #expect(!isSafeToExit)
        // The helper that was not unregistered is the one that finishes the
        // restore: its next tick retries it.
        await rig.engine.tick()
        let isSafeAfterRetry = await rig.engine.isSafeToExit
        #expect(isSafeAfterRetry)
        #expect(rig.control.activeControls.isEmpty)
    }

    @Test("Each explicit reply other than ok stops before unregistering, with or without force", arguments: [HelperStatus.hardwareError, .notIntroduced, .rateLimited], [false, true])
    func refusalsAreNeverOverridden(reply: HelperStatus, force: Bool) async {
        let rig = RemovalRig()
        rig.transport.replaceRestoreReply(with: reply)
        let outcome = await remove(rig.removal(), force: force).value
        #expect(outcome == .restoreRefused(reply, helper: .simulated))
        #expect(!outcome.offersForcedRemoval)
        #expect(rig.registration.unregisterCount == 0)
        #expect(rig.log.count(of: "registration.unregister") == 0)
        if reply != .hardwareError {
            // Only hardwareError establishes that the helper keeps retrying.
            #expect(!outcome.summary.contains("retrying"))
            #expect(outcome.summary.contains("refused the request"))
        }
    }

    @Test("A session that ended before the restore reached the helper gets notIntroduced, which is not overridden", arguments: [false, true])
    func invalidatedSessionIsRefused(force: Bool) async {
        let rig = RemovalRig()
        rig.transport.invalidateSessionBeforeRestore()
        let outcome = await remove(rig.removal(), force: force).value
        #expect(outcome == .restoreRefused(.notIntroduced, helper: .simulated))
        #expect(rig.log.all.contains("helper.restoreDefaultsAndExit replied notIntroduced"))
        #expect(rig.registration.unregisterCount == 0)
        #expect(!outcome.summary.contains("retrying"))
        // The engine did not start shutting down for that request.
        let isShuttingDown = await rig.engine.isShuttingDown
        #expect(!isShuttingDown)
    }

    // MARK: - No confirmation: a transport failure or a missing reply

    @Test("A failure or a missing reply at any stage leaves the restore unconfirmed; only force unregisters", arguments: ConversationFault.all, [false, true])
    func unconfirmedAtEveryStage(fault: ConversationFault, force: Bool) async {
        let rig = RemovalRig()
        let clock = ManualDeadlineClock()
        defer { rig.transport.gate.open() }
        switch fault.kind {
        case .failure: rig.transport.fail(at: fault.step)
        case .timeout: rig.transport.stall(at: fault.step)
        }

        let running = remove(rig.removal(clock: clock), force: force)
        if fault.kind == .timeout {
            await rig.log.waitFor(fault.logEntry)
            clock.advance(by: Self.deadline)
        }
        let outcome = await running.value

        let reason = fault.reason(deadline: Self.deadline)
        #expect(!outcome.isRestoreConfirmed)
        #expect(!outcome.summary.contains("keeps retrying"))
        if force {
            #expect(outcome == .removedWithoutConfirmedRestore(reason))
            #expect(outcome.isHelperRemoved)
            #expect(rig.registration.unregisterCount == 1)
        } else {
            #expect(outcome == .restoreUnconfirmed(reason))
            #expect(outcome.offersForcedRemoval)
            #expect(rig.registration.unregisterCount == 0)
            #expect(outcome.summary.contains("whether it is still trying, is unknown"))
        }
    }

    @Test("A reply that the deadline's cancellation sets off never authorises unregistering")
    func lateRestoreReplyIsIgnored() async {
        for _ in 0..<20 {
            let rig = RemovalRig()
            let clock = ManualDeadlineClock()
            rig.transport.answerOnlyWhenCancelled(at: .restoreAndExit)

            let running = remove(rig.removal(clock: clock), force: false)
            await rig.log.waitFor("helper.restoreDefaultsAndExit")
            clock.advance(by: Self.deadline)
            let outcome = await running.value

            #expect(outcome == .restoreUnconfirmed(.noRestoreReply(Self.deadline, helper: .simulated)))
            // The late ok did arrive, and changed nothing.
            await rig.log.waitFor("helper.restoreDefaultsAndExit replied ok")
            await rig.log.waitFor("helper.invalidate")
            #expect(rig.registration.unregisterCount == 0)
        }
    }

    @Test("A hello that the deadline's cancellation sets off does not get the helper asked to exit")
    func lateHelloAuthorisesNothing() async {
        let rig = RemovalRig()
        let clock = ManualDeadlineClock()
        rig.transport.answerOnlyWhenCancelled(at: .hello)

        let running = remove(rig.removal(clock: clock), force: false)
        await rig.log.waitFor("helper.hello")
        clock.advance(by: Self.deadline)
        let outcome = await running.value

        #expect(outcome == .restoreUnconfirmed(.noHello(Self.deadline)))
        await rig.log.waitFor("helper.hello replied ok")
        await rig.log.waitFor("helper.invalidate")
        #expect(rig.log.count(of: "helper.restoreDefaultsAndExit") == 0)
        let isShuttingDown = await rig.engine.isShuttingDown
        #expect(!isShuttingDown)
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("Once the deadline has passed by the clock, a restore reply is refused even before any timer wakes", arguments: [false, true])
    func elapsedDeadlineRefusesRestoreReply(force: Bool) async {
        let rig = RemovalRig()
        let clock = ManualDeadlineClock()
        rig.transport.stall(at: .restoreAndExit)
        defer { clock.releaseTimers() }

        let running = remove(rig.removal(clock: clock), force: force)
        await rig.log.waitFor("helper.restoreDefaultsAndExit")
        clock.holdTimers()
        clock.advance(by: Self.deadline)
        rig.transport.gate.open()
        let outcome = await running.value

        // The ok arrived, but after the expiry: it counts for nothing.
        #expect(rig.log.all.contains("helper.restoreDefaultsAndExit replied ok"))
        let reason = HelperNoConfirmationReason.noRestoreReply(Self.deadline, helper: .simulated)
        if force {
            #expect(outcome == .removedWithoutConfirmedRestore(reason))
        } else {
            #expect(outcome == .restoreUnconfirmed(reason))
            #expect(rig.registration.unregisterCount == 0)
        }
        #expect(!outcome.isRestoreConfirmed)
    }

    @Test("Once the deadline has passed by the clock, a hello is refused and the helper is not asked to exit")
    func elapsedDeadlineRefusesHello() async {
        let rig = RemovalRig()
        let clock = ManualDeadlineClock()
        rig.transport.stall(at: .hello)
        defer { clock.releaseTimers() }

        let running = remove(rig.removal(clock: clock), force: false)
        await rig.log.waitFor("helper.hello")
        clock.holdTimers()
        clock.advance(by: Self.deadline)
        rig.transport.gate.open()
        let outcome = await running.value

        #expect(outcome == .restoreUnconfirmed(.noHello(Self.deadline)))
        #expect(rig.log.all.contains("helper.hello replied ok"))
        await rig.log.waitFor("helper.invalidate")
        #expect(rig.log.count(of: "helper.restoreDefaultsAndExit") == 0)
        let isShuttingDown = await rig.engine.isShuttingDown
        #expect(!isShuttingDown)
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("Once the deadline has passed by the clock, a failure is not taken as the reason: the timeout is")
    func elapsedDeadlineRefusesLateFailure() async {
        let rig = RemovalRig()
        let clock = ManualDeadlineClock()
        rig.transport.stall(at: .connect)
        rig.transport.fail(at: .connect)
        defer { clock.releaseTimers() }

        let running = remove(rig.removal(clock: clock), force: false)
        await rig.log.waitFor("helper.connect")
        clock.holdTimers()
        clock.advance(by: Self.deadline)
        rig.transport.gate.open()
        let outcome = await running.value

        #expect(outcome == .restoreUnconfirmed(.noHello(Self.deadline)))
    }

    @Test("A registration status that answers after its deadline counts as unknown, not as \"nothing to remove\"")
    func lateStatusBeforeIsRefused() async {
        let rig = RemovalRig(registration: .notRegistered)
        let clock = ManualDeadlineClock()
        let gate = Gate()
        rig.registration.holdStatus(call: 1, on: gate)
        defer {
            gate.open()
            clock.releaseTimers()
        }

        let running = remove(rig.removal(clock: clock), force: false)
        await rig.log.waitFor("registration.status")
        clock.holdTimers()
        clock.advance(by: HelperRemoval.defaultRegistrationDeadline)
        gate.open()
        let outcome = await running.value

        // A timely notRegistered would have stopped the removal here.
        #expect(outcome != .nothingToRemove(.notRegistered))
        #expect(rig.log.count(of: "helper.connect") == 1)
        #expect(outcome == .removed(.simulated))
    }

    @Test("A registration status after unregistering that answers after its deadline counts as unknown, not as removed")
    func lateStatusAfterIsRefused() async {
        let rig = RemovalRig()
        let clock = ManualDeadlineClock()
        let gate = Gate()
        rig.registration.holdStatus(call: 2, on: gate)
        defer {
            gate.open()
            clock.releaseTimers()
        }

        let running = remove(rig.removal(clock: clock), force: false)
        await rig.log.waitFor("registration.status", occurrences: 2)
        clock.holdTimers()
        clock.advance(by: HelperRemoval.defaultRegistrationDeadline)
        gate.open()
        let outcome = await running.value

        #expect(outcome == .unregisterIncomplete(.simulated, status: .unknown("no answer within 15 s"), error: nil))
        #expect(!outcome.isHelperRemoved)
    }

    @Test("An unregistering that returns after its deadline counts as unanswered")
    func lateUnregisterIsRefused() async {
        let rig = RemovalRig()
        let clock = ManualDeadlineClock()
        let gate = Gate()
        rig.registration.holdUnregister(on: gate)
        rig.registration.statusAfterUnregister = .enabled
        defer {
            gate.open()
            clock.releaseTimers()
        }

        let running = remove(rig.removal(clock: clock), force: false)
        await rig.log.waitFor("registration.unregister")
        clock.holdTimers()
        clock.advance(by: HelperRemoval.defaultRegistrationDeadline)
        gate.open()
        let outcome = await running.value

        #expect(outcome == .unregisterIncomplete(.simulated, status: .enabled, error: "no answer within 15 s"))
    }

    @Test("With a real timer, a helper slower than the deadline is not unregistered, even when it confirms later")
    func slowRestoreHitsTheDeadline() async {
        let rig = RemovalRig()
        rig.transport.stall(at: .restoreAndExit)
        defer { rig.transport.gate.open() }

        let outcome = await rig.removal(helperDeadline: .milliseconds(50)).remove()

        #expect(outcome == .restoreUnconfirmed(.noRestoreReply(.milliseconds(50), helper: .simulated)))
        #expect(rig.registration.unregisterCount == 0)
        rig.transport.gate.open()
        await rig.log.waitFor("helper.restoreDefaultsAndExit replied ok")
        await rig.log.waitFor("helper.invalidate")
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("With a real timer, a helper that does not answer hello in time is not asked to exit afterwards")
    func slowHelloHitsTheDeadline() async {
        let rig = RemovalRig()
        rig.transport.stall(at: .hello)
        defer { rig.transport.gate.open() }

        let outcome = await rig.removal(helperDeadline: .milliseconds(50)).remove()

        #expect(outcome == .restoreUnconfirmed(.noHello(.milliseconds(50))))
        rig.transport.gate.open()
        await rig.log.waitFor("helper.invalidate")
        #expect(rig.log.count(of: "helper.restoreDefaultsAndExit") == 0)
        let isShuttingDown = await rig.engine.isShuttingDown
        #expect(!isShuttingDown)
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("A forced removal says what it could not confirm, and what removing the helper gives up")
    func forcedRemovalWording() async {
        let rig = RemovalRig()
        rig.transport.fail(at: .hello)
        let outcome = await rig.removal().remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .removedWithoutConfirmedRestore(.helloFailed("test transport failure")))
        #expect(!outcome.isRestoreConfirmed)
        #expect(outcome.summary.contains("Nothing confirmed that the helper restored defaults"))
        #expect(outcome.summary.contains("attempts the restore as it exits, but nothing confirmed that"))
        #expect(outcome.summary.contains("a missing reply does not show that the helper had stopped trying"))
        #expect(outcome.summary.contains("no helper starts at the next startup to restore defaults"))
        #expect(outcome.summary.contains("may outlast the helper"))
        #expect(outcome.summary.contains(HelperRemoval.recoveryProcedureTitle))
    }

    @Test("A forced unregistering that does not complete says so")
    func forcedUnregisterIncomplete() async {
        let rig = RemovalRig()
        rig.transport.fail(at: .connect)
        rig.registration.statusAfterUnregister = .enabled
        let outcome = await rig.removal().remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .forcedUnregisterIncomplete(.connectFailed("test transport failure"), status: .enabled, error: nil))
        #expect(!outcome.isHelperRemoved)
        #expect(outcome.summary.contains("Nothing confirms that defaults are in effect"))
    }

    @Test("Force with a helper that confirms is an ordinary, confirmed removal")
    func forceWithAConfirmingHelper() async {
        let rig = RemovalRig()
        let outcome = await rig.removal().remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .removed(.simulated))
        #expect(outcome.isRestoreConfirmed)
    }

    // MARK: - Unregistering

    @Test("An unregistering that does not answer in time is incomplete")
    func slowUnregister() async {
        let rig = RemovalRig()
        let gate = Gate()
        defer { gate.open() }
        rig.registration.holdUnregister(on: gate)
        let outcome = await rig.removal(registrationDeadline: .milliseconds(50)).remove()
        guard case .unregisterIncomplete(.simulated, status: .enabled, let error) = outcome else {
            Issue.record("unexpected outcome \(outcome)")
            return
        }
        #expect(error?.contains("no answer within") == true)
        #expect(!outcome.isHelperRemoved)
    }

    @Test("A registration that does not answer counts as unknown: the helper is asked, but removal is never reported done")
    func silentRegistration() async {
        let rig = RemovalRig()
        let gate = Gate()
        defer { gate.open() }
        rig.registration.holdStatus(on: gate)
        let outcome = await rig.removal(registrationDeadline: .milliseconds(50)).remove()
        guard case .unregisterIncomplete(.simulated, status: .unknown(let detail), error: nil) = outcome else {
            Issue.record("unexpected outcome \(outcome)")
            return
        }
        #expect(detail.contains("no answer within"))
        #expect(rig.registration.unregisterCount == 1)
    }

    @Test("Unregistering that throws while the helper stays registered is incomplete")
    func unregisterThrows() async {
        let rig = RemovalRig()
        rig.registration.failUnregister()
        rig.registration.statusAfterUnregister = .enabled
        let outcome = await rig.removal().remove()
        #expect(outcome == .unregisterIncomplete(.simulated, status: .enabled, error: "test unregister failure"))
        #expect(outcome.isRestoreConfirmed)
        #expect(!outcome.isHelperRemoved)
        #expect(outcome.summary.contains("Unregistering the helper did not complete"))
    }

    @Test("Unregistering that throws although the helper is gone counts as removed: the status decides")
    func unregisterThrowsButHelperIsGone() async {
        let rig = RemovalRig()
        rig.registration.failUnregister()
        let outcome = await rig.removal().remove()
        #expect(outcome == .removed(.simulated))
    }

    @Test("A helper still enabled after unregistering is incomplete")
    func stillEnabledAfterUnregistering() async {
        let rig = RemovalRig()
        rig.registration.statusAfterUnregister = .enabled
        let outcome = await rig.removal().remove()
        #expect(outcome == .unregisterIncomplete(.simulated, status: .enabled, error: nil))
        #expect(!outcome.isHelperRemoved)
    }

    // MARK: - Wording

    @Test("The Simulated helper's outcome says its simulated controls were restored and the Mac's charging was not changed")
    func simulatedHelperWording() async {
        let rig = RemovalRig()
        let outcome = await rig.removal().remove()
        #expect(outcome == .removed(.simulated))
        #expect(outcome.summary.contains("restored its simulated controls"))
        #expect(outcome.summary.contains("Your Mac's charging was not changed"))
        #expect(!outcome.summary.contains("restored macOS's default charging"))
    }

    @Test("A helper that controls charging says defaults were restored, after ok")
    func hardwareHelperWording() async {
        let rig = RemovalRig(chargeControl: UnsimulatedChargeControl(inner: SimulatedChargeControl()))
        let outcome = await rig.removal().remove()
        #expect(outcome == .removed(.controlsCharging))
        #expect(outcome.summary.contains("restored macOS's default charging and confirmed it"))
    }

    @Test("A helper that controls nothing never claims a restore of the Mac's charging")
    func monitorOnlyHelperWording() async {
        let rig = RemovalRig(chargeControl: UnknownHardwareChargeControl())
        let outcome = await rig.removal().remove()
        #expect(outcome == .removed(.monitorOnly))
        #expect(outcome.summary.contains("controls no charging on this Mac"))
        #expect(!outcome.summary.contains("restored macOS"))
    }

    @Test("No outcome without ok says defaults were restored; only hardwareError says the helper keeps retrying")
    func unconfirmedOutcomesClaimNoRestore() {
        let unconfirmed: [HelperRemovalOutcome] = [
            .nothingToRemove(.notRegistered),
            .restoreRefused(.hardwareError, helper: .controlsCharging),
            .restoreRefused(.notIntroduced, helper: .controlsCharging),
            .restoreRefused(.rateLimited, helper: .unknown),
            .restoreUnconfirmed(.connectFailed("invalidated")),
            .restoreUnconfirmed(.restoreConnectionFailed("interrupted", helper: .controlsCharging)),
            .restoreUnconfirmed(.noRestoreReply(.seconds(20), helper: .simulated)),
            .removedWithoutConfirmedRestore(.noHello(.seconds(20))),
            .forcedUnregisterIncomplete(.helloFailed("invalidated"), status: .enabled, error: "denied"),
        ]
        for outcome in unconfirmed {
            #expect(!outcome.isRestoreConfirmed)
            for claim in ["restored macOS", "restored its simulated controls", "confirmed that its controls are back", "confirmed that none of its controls"] {
                #expect(!outcome.summary.contains(claim), "\(outcome) claims \"\(claim)\"")
            }
            let saysRetrying = outcome.summary.contains("keeps retrying")
            #expect(saysRetrying == (outcome == .restoreRefused(.hardwareError, helper: .controlsCharging)), "\(outcome)")
        }
        #expect(HelperRemovalOutcome.restoreUnconfirmed(.noRestoreReply(.seconds(20), helper: .simulated)).summary.contains("your Mac's charging is not affected"))
        #expect(HelperRemovalOutcome.restoreRefused(.notIntroduced, helper: .simulated).summary.contains("your Mac's charging is not affected"))
    }
}
