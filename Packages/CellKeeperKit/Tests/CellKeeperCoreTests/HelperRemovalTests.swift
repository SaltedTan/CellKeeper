import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// Safety precondition 9: the helper is unregistered only after it has
/// confirmed that it restored defaults, and every outcome says only what was
/// confirmed.
@Suite("Helper removal")
struct HelperRemovalTests {
    private static let unregisterSteps: Set<String> = ["helper.restoreDefaultsAndExit", "registration.unregister"]

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

    @Test("A helper that refuses hello still gets the restore, which needs no introduction")
    func refusedHelloStillRestores() async {
        let rig = RemovalRig(chargeControl: UnsimulatedChargeControl(inner: SimulatedChargeControl()))
        rig.transport.replaceHelloStatus(with: .incompatibleProtocol)
        let outcome = await rig.removal().remove()
        // It did not complete hello, so it did not say what it controls.
        #expect(outcome == .removed(.unknown))
        #expect(outcome.summary.contains("The helper confirmed that its controls are back at their defaults."))
    }

    @Test("A helper already shutting down confirms defaults with its restore")
    func helperAlreadyShuttingDown() async {
        let rig = RemovalRig()
        await rig.engine.start()
        await rig.engine.terminate()
        let outcome = await rig.removal().remove()
        #expect(outcome == .removed(.simulated))
    }

    // MARK: - A restore that is not confirmed

    @Test("A helper that replies hardwareError is never unregistered, and keeps retrying the restore itself")
    func hardwareErrorIsNotUnregistered() async {
        let rig = RemovalRig()
        await rig.engine.start()
        await rig.holdInhibit()
        rig.control.failNextRestores(1)

        let outcome = await rig.removal().remove()

        #expect(outcome == .restoreNotConfirmed(.refused(.hardwareError), helper: .simulated))
        #expect(!outcome.isRestoreConfirmed)
        #expect(!outcome.offersForcedRemoval)
        #expect(rig.registration.unregisterCount == 0)
        #expect(rig.log.count(of: "registration.unregister") == 0)
        let isSafeToExit = await rig.engine.isSafeToExit
        #expect(!isSafeToExit)
        // The helper that was not unregistered is the one that finishes the
        // restore: its next tick retries it.
        await rig.engine.tick()
        let isSafeAfterRetry = await rig.engine.isSafeToExit
        #expect(isSafeAfterRetry)
        #expect(rig.control.activeControls.isEmpty)
    }

    @Test("Every reply other than ok stops before unregistering", arguments: [HelperStatus.hardwareError, .notIntroduced, .rateLimited])
    func otherRepliesStop(reply: HelperStatus) async {
        let rig = RemovalRig()
        rig.transport.replaceRestoreReply(with: reply)
        let outcome = await rig.removal().remove()
        #expect(outcome == .restoreNotConfirmed(.refused(reply), helper: .simulated))
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("A connection that fails after hello, before the restore's reply, is not confirmed and not unregistered")
    func connectionFailsDuringRestore() async {
        let rig = RemovalRig()
        rig.transport.fail(at: .restoreAndExit)
        let outcome = await rig.removal().remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .restoreNotConfirmed(.connectionFailed("test transport failure"), helper: .simulated))
        #expect(rig.registration.unregisterCount == 0)
    }

    // MARK: - A helper that cannot be reached

    @Test("A helper that cannot be reached is not unregistered without force", arguments: [RemovalTestTransport.Step.connect, .hello])
    func unreachableIsNotUnregistered(step: RemovalTestTransport.Step) async {
        let rig = RemovalRig()
        rig.transport.fail(at: step)
        let outcome = await rig.removal().remove()
        let expected: HelperUnreachableReason = step == .connect ? .connectFailed("test transport failure") : .helloFailed("test transport failure")
        #expect(outcome == .helperUnreachable(expected))
        #expect(outcome.offersForcedRemoval)
        #expect(!outcome.isRestoreConfirmed)
        #expect(rig.registration.unregisterCount == 0)
        #expect(rig.log.count(of: "helper.restoreDefaultsAndExit") == 0)
    }

    @Test("A forced removal of an unreachable helper unregisters it and says its restore was not confirmed")
    func forcedRemovalOfUnreachableHelper() async {
        let rig = RemovalRig()
        rig.transport.fail(at: .hello)
        let outcome = await rig.removal().remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .removedWithoutConfirmedRestore(.helloFailed("test transport failure")))
        #expect(outcome.isHelperRemoved)
        #expect(!outcome.isRestoreConfirmed)
        #expect(rig.registration.unregisterCount == 1)
        #expect(outcome.summary.contains("its restore of defaults was not confirmed"))
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
    }

    @Test("Force never unregisters a helper that answers without confirming")
    func forceDoesNotOverrideAnUnconfirmedRestore() async {
        let rig = RemovalRig()
        await rig.engine.start()
        rig.control.failNextRestores(1)
        let outcome = await rig.removal().remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .restoreNotConfirmed(.refused(.hardwareError), helper: .simulated))
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("Force with a helper that confirms is an ordinary, confirmed removal")
    func forceWithAConfirmingHelper() async {
        let rig = RemovalRig()
        let outcome = await rig.removal().remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .removed(.simulated))
        #expect(outcome.isRestoreConfirmed)
    }

    // MARK: - Deadlines

    @Test("A helper slower than the deadline is not unregistered, even when it confirms later")
    func slowRestoreHitsTheDeadline() async {
        let rig = RemovalRig()
        rig.transport.stall(at: .restoreAndExit)
        defer { rig.transport.gate.open() }

        let outcome = await rig.removal(helperDeadline: .milliseconds(50)).remove()

        #expect(outcome == .restoreNotConfirmed(.noReply(.milliseconds(50)), helper: .simulated))
        #expect(rig.registration.unregisterCount == 0)
        // The late ok changes nothing.
        rig.transport.gate.open()
        await rig.log.waitFor("helper.restoreDefaultsAndExit replied ok")
        await rig.log.waitFor("helper.invalidate")
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("A helper that does not answer hello in time is unreachable, and is not asked to exit afterwards")
    func slowHelloHitsTheDeadline() async {
        let rig = RemovalRig()
        rig.transport.stall(at: .hello)
        defer { rig.transport.gate.open() }

        let outcome = await rig.removal(helperDeadline: .milliseconds(50)).remove()

        #expect(outcome == .helperUnreachable(.noAnswer(.milliseconds(50))))
        rig.transport.gate.open()
        await rig.log.waitFor("helper.invalidate")
        #expect(rig.log.count(of: "helper.restoreDefaultsAndExit") == 0)
        let isShuttingDown = await rig.engine.isShuttingDown
        #expect(!isShuttingDown)
        #expect(rig.registration.unregisterCount == 0)
    }

    @Test("A connection that does not open in time is unreachable")
    func slowConnectHitsTheDeadline() async {
        let rig = RemovalRig()
        rig.transport.stall(at: .connect)
        defer { rig.transport.gate.open() }
        let outcome = await rig.removal(helperDeadline: .milliseconds(50)).remove()
        #expect(outcome == .helperUnreachable(.noAnswer(.milliseconds(50))))
        #expect(rig.registration.unregisterCount == 0)
    }

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

    // MARK: - Unregistering

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

    @Test("No outcome without ok says defaults were restored")
    func unconfirmedOutcomesClaimNoRestore() {
        let unconfirmed: [HelperRemovalOutcome] = [
            .nothingToRemove(.notRegistered),
            .restoreNotConfirmed(.refused(.hardwareError), helper: .controlsCharging),
            .restoreNotConfirmed(.noReply(.seconds(20)), helper: .simulated),
            .restoreNotConfirmed(.connectionFailed("interrupted"), helper: .unknown),
            .helperUnreachable(.connectFailed("invalidated")),
            .removedWithoutConfirmedRestore(.noAnswer(.seconds(20))),
            .forcedUnregisterIncomplete(.helloFailed("invalidated"), status: .enabled, error: "denied"),
        ]
        for outcome in unconfirmed {
            #expect(!outcome.isRestoreConfirmed)
            for claim in ["restored macOS", "restored its simulated controls", "confirmed that its controls are back", "confirmed that none of its controls"] {
                #expect(!outcome.summary.contains(claim), "\(outcome) claims \"\(claim)\"")
            }
        }
        #expect(HelperRemovalOutcome.restoreNotConfirmed(.refused(.hardwareError), helper: .simulated).summary.contains("your Mac's charging is not affected"))
    }
}
