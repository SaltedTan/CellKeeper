import CellKeeperCore
import Foundation
import Testing

/// The controller driving ``NativeChargeLimitBackend`` against a fake macOS:
/// the user's own limit must be recorded before any change and restored
/// exactly on every way out.
@Suite("Charge controller with macOS's Charge Limit")
struct NativeLimitControllerTests {
    let clock = TestClock()
    let system = FakeChargeLimitSystem(reading: .limit(80))
    let store = InMemoryRecordStore()

    private func makeController(limit: Int = 90, managed: Bool = true, percent: Int = 75) -> (ChargeController, StubTelemetry) {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: percent), clock: clock)
        var settings = ChargingSettings.default.withChargeLimit(limit)
        settings.isManagementEnabled = managed
        let controller = ChargeController(
            telemetry: telemetry,
            backend: makeNativeBackend(system: system, store: store, clock: clock),
            settings: settings,
            adoptionMarkerStore: store,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        return (controller, telemetry)
    }

    private func settings(limit: Int, managed: Bool = true) -> ChargingSettings {
        var settings = ChargingSettings.default.withChargeLimit(limit)
        settings.isManagementEnabled = managed
        return settings
    }

    // MARK: - Applying

    @Test("The limit is set through the shortcut, confirmed, logged, and macOS shown as enforcing it")
    func appliesLimit() async {
        let (controller, _) = makeController(limit: 90)
        let status = await controller.evaluate(.launch)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("Recorded your own macOS Charge Limit of 80%") })
        #expect(system.runInputs == ["90"])
        #expect(system.reading == .limit(90))
        #expect(status.decision?.state == .osEnforcedLimit)
        #expect(status.currentMode == .nativeLimit(percent: 90))
        #expect(status.lastExecution?.result == .applied)
        #expect(status.capabilities.isEnforcedByMacOS)
        #expect(status.nativeLimit?.reportedLimit == 90)
        #expect(status.nativeLimit?.ownerLimit == 80)
        #expect(status.events.contains { $0.kind == .request && $0.message.contains("macOS Charge Limit of 90%") })
        #expect(status.events.contains { $0.kind == .result && $0.message.contains("macOS reports 90%") })

        let again = await controller.evaluate(.periodic)
        #expect(again.decision?.action == .noAction)
        #expect(system.runInputs == ["90"])
    }

    @Test("When CellKeeper's limit equals the user's, the shortcut never runs")
    func sameLimitRunsNothing() async {
        let (controller, _) = makeController(limit: 80)
        let status = await controller.evaluate(.launch)
        #expect(status.lastExecution?.result == .unchanged)
        #expect(status.nativeLimit?.ownerLimit == 80)
        await controller.shutdown(reason: "quit")
        #expect(system.runInputs.isEmpty)
        #expect(system.reading == .limit(80))
    }

    // MARK: - The four ways out

    @Test("Quitting restores exactly the user's own limit")
    func quitRestores() async {
        system.reading = .limit(85)
        let (controller, _) = makeController(limit: 95)
        await controller.evaluate(.launch)
        let stopped = await controller.shutdown(reason: "CellKeeper is quitting")
        #expect(system.runInputs == ["95", "85"])
        #expect(system.reading == .limit(85))
        #expect(stopped.currentMode == .normal)
        #expect(stopped.nativeLimit?.ownerLimit == nil)
        #expect(stopped.events.contains { $0.kind == .safety && $0.message.contains("Restored your own macOS Charge Limit of 85%") })
    }

    @Test("Turning management off restores exactly the user's own limit")
    func managementOffRestores() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        let status = try await controller.apply(settings: settings(limit: 90, managed: false))
        #expect(status.decision?.state == .unmanaged)
        #expect(system.reading == .limit(80))
        #expect(system.runInputs == ["90", "80"])
        #expect(status.nativeLimit?.ownerLimit == nil)
    }

    @Test("Switching backend restores exactly the user's own limit first")
    func switchRestores() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        let status = await controller.switchBackend(to: MockChargingBackend())
        #expect(status.backend.identifier == "simulated")
        #expect(system.reading == .limit(80))
        #expect(system.runInputs == ["90", "80"])
    }

    @Test("If the user's limit cannot be restored, the switch waits and keeps restoring until it can")
    func switchPendingUntilRestored() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.runBehaviour = .fails
        let refused = await controller.switchBackend(to: MockChargingBackend())
        #expect(refused.backend.identifier == NativeChargeLimitBackend.identifier)
        #expect(refused.pendingBackend?.identifier == "simulated")
        #expect(refused.nativeLimit?.ownerLimit == 80)
        #expect(refused.events.contains { $0.kind == .safety && $0.message.contains("refused") })

        // Management is still on, but the pending switch wins: CellKeeper
        // keeps asking for the user's limit, with automatic retries spaced.
        system.runBehaviour = .applies
        clock.advance(by: 10)
        let waiting = await controller.evaluate(.periodic)
        #expect(waiting.decision?.reason == .releaseRequired(.backendSwitch))
        #expect(system.reading == .limit(90))

        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let switched = await controller.evaluate(.periodic)
        #expect(system.reading == .limit(80))
        #expect(switched.backend.identifier == "simulated")
        #expect(switched.pendingBackend == nil)
    }

    @Test("Choosing the current backend again cancels a pending switch")
    func pendingSwitchCancelled() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.runBehaviour = .fails
        await controller.switchBackend(to: MockChargingBackend())
        system.runBehaviour = .applies
        let status = await controller.switchBackend(to: makeNativeBackend(system: system, store: store, clock: clock))
        #expect(status.pendingBackend == nil)
        #expect(status.backend.identifier == NativeChargeLimitBackend.identifier)
        // The restore the switch started is still finished first.
        #expect(status.decision?.reason == .releaseRequired(.restoreUnfinished))
        #expect(system.reading == .limit(80))

        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let managing = await controller.evaluate(.periodic)
        #expect(managing.decision?.state == .osEnforcedLimit)
        #expect(system.reading == .limit(90))
    }

    @Test("An earlier session's change is restored before switching to another backend")
    func startupRecoveryBeforeSwitch() async {
        storeOwnershipRecord(owner: 80, target: 90, in: store)
        system.reading = .limit(90)
        let (controller, _) = makeController(limit: 90)
        let status = await controller.switchBackend(to: MockChargingBackend())
        #expect(system.reading == .limit(80))
        #expect(system.runInputs == ["80"])
        #expect(status.backend.identifier == "simulated")
        #expect(store.data == nil)
    }

    @Test("An unreadable record is never treated as nothing to restore")
    func unreadableRecordBlocksSwitch() async {
        store.data = Data("not json".utf8)
        system.reading = .limit(90)
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        let status = await controller.switchBackend(to: MockChargingBackend())
        #expect(status.backend.identifier == NativeChargeLimitBackend.identifier)
        #expect(status.pendingBackend != nil)
        #expect(status.nativeLimit?.hasUnresolvedOwnership == true)
        #expect(!status.events.contains { $0.message.contains("nothing to restore") })
        #expect(status.events.contains { $0.message.contains("cannot be read") })
        #expect(system.runInputs.isEmpty)

        let stopped = await controller.shutdown(reason: "quit")
        #expect(stopped.nativeLimit?.hasUnresolvedOwnership == true)
    }

    @Test("A quit whose restore fails reports the limit as unresolved")
    func shutdownReportsUnresolved() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.runBehaviour = .fails
        let stopped = await controller.shutdown(reason: "quit")
        #expect(stopped.nativeLimit?.hasUnresolvedOwnership == true)
        #expect(stopped.nativeLimit?.ownerLimit == 80)
    }

    @Test("A shortcut that finishes without effect is a failure; nothing is reported as applied")
    func unconfirmedChangeFails() async {
        system.runBehaviour = .hasNoEffect
        let (controller, _) = makeController(limit: 90)
        let status = await controller.evaluate(.launch)
        guard case .failed = status.lastExecution?.result else {
            Issue.record("expected a failure, got \(String(describing: status.lastExecution?.result))")
            return
        }
        #expect(status.consecutiveFailures == 1)
        // The fallback finds the user's limit still in effect and releases it.
        #expect(system.reading == .limit(80))
        #expect(status.currentMode == .normal)
        #expect(status.nativeLimit?.ownerLimit == nil)
    }

    @Test("A failed change restores the user's own limit at once")
    func failedChangeRestores() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        system.scheduleRuns([.fails])
        let status = try await controller.apply(settings: settings(limit: 95))
        guard case .failed = status.lastExecution?.result else {
            Issue.record("expected a failure, got \(String(describing: status.lastExecution?.result))")
            return
        }
        #expect(system.runInputs == ["90", "95", "80"])
        #expect(system.reading == .limit(80))
        #expect(status.currentMode == .normal)
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("Restored your own macOS Charge Limit of 80%") })
    }

    @Test("A restore that does not take effect is retried after a minute")
    func ineffectiveRestoreRetried() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        #expect(system.reading == .limit(90))

        // The shortcut reports success but leaves CellKeeper's 90% in place.
        system.runBehaviour = .hasNoEffect
        let off = try await controller.apply(settings: settings(limit: 90, managed: false))
        #expect(off.nativeLimit?.ownerLimit == 80)
        #expect(system.reading == .limit(90))
        system.runBehaviour = .applies
        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let recovered = await controller.evaluate(.periodic)
        #expect(system.reading == .limit(80))
        #expect(recovered.currentMode == .normal)
        #expect(recovered.nativeLimit?.ownerLimit == nil)
    }

    // MARK: - Outside changes

    @Test("A change made outside CellKeeper is kept as the user's own limit, and management turns off")
    func externalChange() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 95)
        let status = await controller.evaluate(.periodic)
        #expect(!status.isBackendFaulted)
        #expect(system.reading == .limit(95))
        #expect(system.runInputs == ["90"])
        #expect(status.currentMode == .normal)
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store)?.limit == 95)
        #expect(!status.settings.isManagementEnabled)
        #expect(status.decision?.state == .unmanaged)
        #expect(status.adoptedChange?.limit == 95)
        #expect(status.adoptedChange?.previousOwnerLimit == 80)
        #expect(status.adoptedChange?.expectedLimit == 90)
        #expect(status.adoptionCount == 1)
        #expect(status.events.contains { $0.kind == .safety && $0.message.hasPrefix("macOS's Charge Limit was changed outside CellKeeper to 95%") && $0.message.contains("kept it as your own limit") && $0.message.contains("turned off Manage charging") })

        // Nothing is written afterwards, not even when quitting.
        clock.advance(by: 600)
        await controller.evaluate(.periodic)
        let stopped = await controller.shutdown(reason: "quit")
        #expect(system.runInputs == ["90"])
        #expect(system.reading == .limit(95))
        #expect(stopped.adoptionCount == 1)
    }

    @Test("Turning management on again records the adopted limit as the user's own")
    func managingAgainAfterAdoption() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)

        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let resumed = try await controller.apply(settings: settings(limit: 90))
        #expect(resumed.adoptedChange == nil)
        #expect(resumed.nativeLimit?.ownerLimit == 95)
        #expect(system.reading == .limit(90))
        await controller.shutdown(reason: "quit")
        #expect(system.reading == .limit(95))
        #expect(system.runInputs == ["90", "90", "95"])
    }

    @Test("A change found just before writing is adopted and does not use up the rate limit")
    func outsideChangeBeforeWriteAdopted() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        // The evaluation still reads 90%; the change lands before the write.
        system.changeExternally(to: 85, afterReads: 1)
        let status = try await controller.apply(settings: settings(limit: 95))
        #expect(status.lastExecution?.result == .adoptedOutsideChange)
        #expect(system.reading == .limit(85))
        #expect(system.runInputs == ["90"])
        #expect(status.adoptedChange?.limit == 85)
        #expect(!status.settings.isManagementEnabled)
        #expect(!status.isBackendFaulted)

        let resumed = try await controller.apply(settings: settings(limit: 95))
        #expect(resumed.nativeLimit?.ownerLimit == 85)
        #expect(system.runInputs == ["90", "95"])
    }

    @Test("A limit CellKeeper cannot record is refused, not counted as a backend failure")
    func unsupportedOwnLimitNeverFaults() async {
        system.reading = .limit(70)
        let (controller, _) = makeController(limit: 80)
        for trigger in [EvaluationTrigger.launch, .periodic, .periodic, .periodic, .periodic] {
            let status = await controller.evaluate(trigger)
            #expect(status.consecutiveFailures == 0)
            #expect(!status.isBackendFaulted)
            guard case .refuse(.controlUnavailable)? = status.decision?.action else {
                Issue.record("expected a refusal, got \(String(describing: status.decision?.action))")
                return
            }
            clock.advance(by: ChargingPolicy.minimumRestrictingInterval + 1)
        }
        #expect(system.runInputs.isEmpty)
        #expect(system.reading == .limit(70))
    }

    @Test("\"No limit\" set just before management is turned on waits for confirmation without faulting")
    func noLimitBeforeManagingNeverFaults() async throws {
        let (controller, _) = makeController(limit: 80, managed: false)
        let unmanaged = await controller.evaluate(.launch)
        #expect(unmanaged.capabilities.availability == .experimental)

        // Within the shortcut check's validity, the user sets 100% in System
        // Settings and then turns management on.
        system.changeExternally(to: 100)
        clock.advance(by: 10)
        var managing = try await controller.apply(settings: settings(limit: 80))
        for _ in 0..<3 {
            #expect(!managing.isBackendFaulted)
            #expect(managing.consecutiveFailures == 0)
            #expect(managing.nativeLimit?.needsNoLimitConfirmation == true)
            clock.advance(by: ChargingPolicy.minimumRestrictingInterval + 1)
            managing = await controller.evaluate(.periodic)
        }
        #expect(system.runInputs.isEmpty)

        // Confirming is all it takes; there is no fault to clear.
        let confirmed = await controller.confirmNoLimitIsOwnerLimit()
        #expect(confirmed.nativeLimit?.ownerLimit == 100)
        #expect(system.reading == .limit(80))
    }

    @Test("Settings made before CellKeeper kept an outside change cannot turn management back on")
    func staleSettingsKeepManagementOff() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 95)
        let adopted = await controller.evaluate(.periodic)
        #expect(adopted.adoptionCount == 1)

        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        // For example, queued in the app before it saw the adoption.
        let stale = try await controller.apply(settings: settings(limit: 85), adoptionsSeen: 0)
        #expect(!stale.settings.isManagementEnabled)
        #expect(stale.managementRefusal?.contains("has just kept a Charge Limit changed outside it") == true)
        #expect(stale.settings.chargeLimit == 85)
        #expect(system.reading == .limit(95))
        #expect(system.runInputs == ["90"])

        // A change made after seeing it is the user's explicit wish.
        let fresh = try await controller.apply(settings: settings(limit: 85), adoptionsSeen: 1)
        #expect(fresh.settings.isManagementEnabled)
        #expect(fresh.managementRefusal == nil)
        #expect(fresh.nativeLimit?.ownerLimit == 95)
        #expect(system.reading == .limit(85))
    }

    @Test("A change found while reading back CellKeeper's own write is kept, even if CellKeeper quits at once")
    func outsideChangeDuringReadBack() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        // Reads: the evaluation's, the backend's before writing, and its
        // confirmation. The controller's own read-back then sees the change.
        system.changeExternally(to: 95, afterReads: 3)
        let status = try await controller.apply(settings: settings(limit: 85))
        #expect(system.runInputs == ["90", "85"])
        #expect(status.lastExecution?.result == .adoptedOutsideChange)
        #expect(status.adoptedChange?.limit == 95)
        #expect(!status.settings.isManagementEnabled)
        #expect(!status.isBackendFaulted)

        // CellKeeper did write 85%, so that still counts toward the rate limit.
        let resumed = try await controller.apply(settings: settings(limit: 90), adoptionsSeen: 1)
        guard case .refuse(.rateLimited) = resumed.decision?.action else {
            Issue.record("expected rate limiting, got \(String(describing: resumed.decision?.action))")
            return
        }
        let stopped = await controller.shutdown(reason: "quit")
        #expect(system.reading == .limit(95))
        #expect(system.runInputs == ["90", "85"])
        #expect(stopped.currentMode == .normal)
    }

    @Test("A change found while confirming CellKeeper's write is kept, with no restore over it")
    func outsideChangeDuringConfirmation() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        // Reads: the evaluation's, the backend's before writing, and its
        // confirmation, which sees the change. A fallback restore whose own
        // first read failed would otherwise write over it.
        system.changeExternally(to: 95, afterReads: 2)
        system.failRead(after: 3)
        let status = try await controller.apply(settings: settings(limit: 85))
        let stopped = await controller.shutdown(reason: "quit")
        #expect(status.adoptedChange?.limit == 95)
        #expect(!status.isBackendFaulted)
        #expect(system.reading == .limit(95))
        #expect(system.runInputs == ["90", "85"])
        #expect(stopped.adoptionCount == 1)
    }

    @Test("Setting the recorded limit again by hand and quitting at once is kept as the user's choice")
    func ownerValueSetByHandBeforeQuit() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 80)
        let stopped = await controller.shutdown(reason: "quit")
        #expect(system.runInputs == ["90"])
        #expect(system.reading == .limit(80))
        #expect(stopped.adoptedChange?.limit == 80)
        #expect(!stopped.settings.isManagementEnabled)
    }

    @Test("At first contact, the recorded limit already back in effect is cleared quietly, not adopted")
    func firstContactOwnerValueNotAdopted() async {
        storeOwnershipRecord(owner: 80, target: 90, in: store)
        system.reading = .limit(80)
        let (controller, _) = makeController(limit: 90)
        let status = await controller.switchBackend(to: MockChargingBackend())
        #expect(status.backend.identifier == "simulated")
        #expect(status.adoptionCount == 0)
        #expect(status.settings.isManagementEnabled)
        #expect(system.runInputs.isEmpty)
        #expect(store.data == nil)
    }

    @Test("The adoption marker keeps management off across launches until the user turns it on")
    func adoptionMarkerSurvivesCrash() async throws {
        let (first, _) = makeController(limit: 90)
        await first.evaluate(.launch)
        system.changeExternally(to: 95)
        await first.evaluate(.periodic)
        // The app stops before its "Manage charging" off reaches the disk.

        let (second, _) = makeController(limit: 90)
        let status = await second.evaluate(.launch)
        #expect(status.adoptedChange?.isFromEarlierSession == true)
        #expect(!status.settings.isManagementEnabled)
        #expect(status.events.contains { $0.message.hasPrefix("Before CellKeeper last stopped, macOS's Charge Limit was changed") })
        #expect(system.reading == .limit(95))
        #expect(system.runInputs == ["90"])
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store)?.limit == 95)

        // With management already off, a later launch has nothing to report.
        let (third, _) = makeController(limit: 90, managed: false)
        let quiet = await third.evaluate(.launch)
        #expect(quiet.adoptionCount == 0)
        #expect(!quiet.events.contains { $0.message.contains("changed outside CellKeeper") })
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store) != nil)

        // Turning management on removes the marker and records 95% as the
        // user's own limit.
        let managing = try await third.apply(settings: settings(limit: 90), adoptionsSeen: 0)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store) == nil)
        #expect(managing.nativeLimit?.ownerLimit == 95)
        #expect(system.reading == .limit(90))
    }

    @Test("Turning management on removes the adoption marker even on another backend")
    func markerRemovedOnOtherBackend() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)
        await controller.switchBackend(to: MockChargingBackend())
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store) != nil)

        // A settings change from before the adoption leaves it in place.
        try await controller.apply(settings: settings(limit: 85), adoptionsSeen: 0)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store) != nil)

        try await controller.apply(settings: settings(limit: 85), adoptionsSeen: 1)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store) == nil)
    }

    @Test("If the adoption marker cannot be stored, the old record is kept and the marker is retried")
    func markerSaveFailureKeepsEvidence() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        store.saveFails = true
        system.changeExternally(to: 95)
        let adopted = await controller.evaluate(.periodic)
        #expect(adopted.adoptedChange?.limit == 95)
        #expect(!adopted.settings.isManagementEnabled)
        // The old record stays: at a relaunch it makes CellKeeper keep 95% again.
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 80)

        // Nothing is restored over the change in the meantime.
        let stopped = await controller.shutdown(reason: "quit")
        #expect(system.runInputs == ["90"])
        #expect(stopped.adoptedChange?.limit == 95)

        let (relaunched, _) = makeController(limit: 90)
        store.saveFails = false
        let again = await relaunched.evaluate(.launch)
        #expect(again.adoptedChange?.limit == 95)
        #expect(!again.settings.isManagementEnabled)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store)?.limit == 95)
        #expect(system.runInputs == ["90"])
    }

    @Test("A record from an earlier session is not restored blind over a change CellKeeper kept")
    func noBlindRestoreOfEarlierRecord() async {
        let (first, _) = makeController(limit: 90)
        await first.evaluate(.launch)
        store.saveFails = true
        system.changeExternally(to: 95)
        await first.evaluate(.periodic)
        await first.shutdown(reason: "quit")
        // The marker never reached the disk, so the old record is still there.
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 80)

        store.saveFails = false
        system.failNextReads(2)
        let (second, _) = makeController(limit: 90)
        let blind = await second.evaluate(.launch)
        #expect(system.runInputs == ["90"])
        #expect(system.reading == .limit(95))
        #expect(blind.nativeLimit?.ownerLimit == 80)

        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let checked = await second.evaluate(.periodic)
        #expect(system.runInputs == ["90"])
        #expect(checked.adoptedChange?.limit == 95)
        #expect(!checked.settings.isManagementEnabled)
    }

    @Test("While the marker is unsaved, a backend switch waits and turning management on retires the old record")
    func unsavedMarkerBlocksSwitchAndIsRetired() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        store.saveFails = true
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)

        let waiting = await controller.switchBackend(to: MockChargingBackend())
        #expect(waiting.backend.identifier == NativeChargeLimitBackend.identifier)
        #expect(waiting.pendingBackend?.identifier == "simulated")
        #expect(waiting.nativeLimit?.isAdoptionUnsaved == true)

        // Choosing the native backend again cancels the switch; turning
        // management on then removes the old record before recording 95%.
        await controller.switchBackend(to: makeNativeBackend(system: system, store: store, clock: clock))
        store.saveFails = false
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let managing = try await controller.apply(settings: settings(limit: 90), adoptionsSeen: 1)
        #expect(managing.settings.isManagementEnabled)
        #expect(managing.nativeLimit?.ownerLimit == 95)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 95)
        #expect(system.reading == .limit(90))
    }

    @Test("Turning management on while the store still fails removes the old record, so quitting has nothing owed")
    func reEnableRetiresRecordWhileSavesFail() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        store.saveFails = true
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 80)

        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let managing = try await controller.apply(settings: settings(limit: 90), adoptionsSeen: 1)
        #expect(managing.settings.isManagementEnabled)
        // Nothing can be recorded, so nothing is changed, and the old record
        // of 80% (no longer owed) is gone.
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
        #expect(system.runInputs == ["90"])
        #expect(system.reading == .limit(95))
    }

    @Test("If the old record left by an unsaved marker cannot be removed, management stays off")
    func reEnableRefusedWhenOldRecordStays() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        store.saveFails = true
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)
        store.removeFails = true
        let refused = try await controller.apply(settings: settings(limit: 90), adoptionsSeen: 1)
        #expect(!refused.settings.isManagementEnabled)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 80)
        #expect(system.runInputs == ["90"])
    }

    @Test("An unsaved marker that is stored later lets the waiting switch complete")
    func unsavedMarkerSwitchCompletes() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        store.saveFails = true
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)
        await controller.switchBackend(to: MockChargingBackend())
        store.saveFails = false
        let switched = await controller.evaluate(.periodic)
        #expect(switched.backend.identifier == "simulated")
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store)?.limit == 95)
        #expect(system.runInputs == ["90"])
    }

    @Test("If what kept management off cannot be removed, management stays off")
    func reEnableRefusedWhenMarkerStays() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)
        store.removeFails = true
        let refused = try await controller.apply(settings: settings(limit: 90), adoptionsSeen: 1)
        #expect(!refused.settings.isManagementEnabled)
        #expect(refused.adoptedChange?.limit == 95)
        #expect(refused.events.contains { $0.message.hasPrefix("Manage charging stays off: CellKeeper could not remove") })
        #expect(refused.managementRefusal?.contains("could not remove its record") == true)
        #expect(system.runInputs == ["90"])

        store.removeFails = false
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let managing = try await controller.apply(settings: settings(limit: 90), adoptionsSeen: 1)
        #expect(managing.settings.isManagementEnabled)
        #expect(managing.managementRefusal == nil)
        #expect(system.reading == .limit(90))
    }

    @Test("Turning management on before the first evaluation drops a marker's report from launch")
    func reEnableBeforeFirstEvaluation() async throws {
        let (first, _) = makeController(limit: 90)
        await first.evaluate(.launch)
        system.changeExternally(to: 95)
        await first.evaluate(.periodic)

        let (second, _) = makeController(limit: 90, managed: false)
        try await second.apply(settings: settings(limit: 90), adoptionsSeen: 0)
        let status = await second.evaluate(.launch)
        #expect(status.settings.isManagementEnabled)
        #expect(status.adoptionCount == 0)
        #expect(status.nativeLimit?.ownerLimit == 95)
        #expect(system.reading == .limit(90))
    }

    @Test("A marker that could not be stored at first is stored at the next read")
    func markerSaveRetried() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        store.saveFails = true
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store) == nil)
        store.saveFails = false
        await controller.evaluate(.periodic)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store)?.limit == 95)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
    }

    @Test("A change made just before quitting is kept, not overwritten by the restore")
    func quitKeepsOutsideChange() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 85)
        let stopped = await controller.shutdown(reason: "quit")
        #expect(system.reading == .limit(85))
        #expect(system.runInputs == ["90"])
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store)?.limit == 85)
        #expect(stopped.adoptedChange?.limit == 85)
        #expect(!stopped.settings.isManagementEnabled)
    }

    @Test("A change made just before switching backend is kept, and the switch completes")
    func switchKeepsOutsideChange() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 85)
        let status = await controller.switchBackend(to: MockChargingBackend())
        #expect(status.backend.identifier == "simulated")
        #expect(system.reading == .limit(85))
        #expect(system.runInputs == ["90"])
        #expect(status.adoptionCount == 1)
        #expect(!status.settings.isManagementEnabled)
    }

    @Test("\"No limit\" set outside CellKeeper is kept, and the earlier limit is named in case it was temporary")
    func noLimitAdopted() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.changeExternally(to: 100)
        let status = await controller.evaluate(.periodic)
        #expect(system.reading == .noLimit)
        #expect(system.runInputs == ["90"])
        #expect(status.adoptedChange?.isNoLimit == true)
        #expect(status.events.contains { $0.message.contains("no limit (100%)") && $0.message.contains("your earlier limit was 80%") })
    }

    @Test("After a read failure, a later outside change is still recognised and kept rather than overwritten")
    func detectionSurvivesReadFailure() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.readFails = true
        system.runBehaviour = .fails
        let unverified = await controller.evaluate(.periodic)
        #expect(unverified.decision?.reason == .releaseRequired(.stateUnverified))

        system.changeExternally(to: 95)
        system.readFails = false
        system.runBehaviour = .applies
        clock.advance(by: 120)
        let status = await controller.evaluate(.periodic)
        #expect(!status.isBackendFaulted)
        #expect(status.adoptedChange?.limit == 95)
        #expect(system.reading == .limit(95))
        // Only the launch and the failed restore attempt ran the shortcut.
        #expect(system.runInputs == ["90", "80"])
    }

    @Test("A change CellKeeper made without confirming it is not mistaken for an outside change")
    func ownUnconfirmedChangeAccepted() async throws {
        let (controller, _) = makeController(limit: 85)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        system.scheduleRuns([.appliesButNextReadFails, .fails])
        let failed = try await controller.apply(settings: settings(limit: 90))
        #expect(system.reading == .limit(90))
        #expect(failed.nativeLimit?.ownerLimit == 80)

        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let later = await controller.evaluate(.periodic)
        #expect(!later.isBackendFaulted)
        #expect(later.events.contains { $0.message.contains("Now confirmed") })
        // Recognising its own change does not cancel the restore that failed.
        #expect(later.decision?.reason == .releaseRequired(.restoreUnfinished))
        #expect(system.reading == .limit(80))
        #expect(later.nativeLimit?.ownerLimit == nil)
    }

    @Test("A request rejected before anything was written never makes an outside change look like CellKeeper's")
    func rejectedRequestNotTrusted() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        store.saveFails = true
        system.runBehaviour = .fails
        let failed = try await controller.apply(settings: settings(limit: 95))
        #expect(system.runInputs == ["90", "80"])
        #expect(failed.nativeLimit?.ownerLimit == 80)

        system.changeExternally(to: 95)
        store.saveFails = false
        system.runBehaviour = .applies
        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let status = await controller.evaluate(.periodic)
        #expect(!status.events.contains { $0.message.contains("Now confirmed") })
        #expect(status.adoptedChange?.limit == 95)
        #expect(system.reading == .limit(95))
        #expect(system.runInputs == ["90", "80"])
    }

    @Test("A restore that failed when quitting is finished at the next launch")
    func unfinishedRestoreResumedAtLaunch() async {
        storeOwnershipRecord(owner: 80, target: 90, restoring: true, in: store)
        system.reading = .limit(90)
        let (controller, _) = makeController(limit: 90)
        let status = await controller.evaluate(.launch)
        #expect(status.decision?.reason == .releaseRequired(.restoreUnfinished))
        #expect(system.reading == .limit(80))
        #expect(system.runInputs == ["80"])
        #expect(store.data == nil)
        #expect(status.events.contains { $0.message.contains("finish restoring your own limit of 80% first") })
    }

    @Test("A restore that took effect without confirmation is not mistaken for an outside change")
    func ownUnconfirmedRestoreAccepted() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.scheduleRuns([.appliesButNextReadFails])
        let off = try await controller.apply(settings: settings(limit: 90, managed: false))
        #expect(system.reading == .limit(80))
        #expect(off.nativeLimit?.ownerLimit == 80)

        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let later = await controller.evaluate(.periodic)
        #expect(!later.isBackendFaulted)
        #expect(later.currentMode == .normal)
        #expect(later.nativeLimit?.ownerLimit == nil)
        #expect(system.runInputs == ["90", "80"])
    }

    @Test("At relaunch, a pending change that took effect is CellKeeper's own even if the record cannot be updated")
    func relaunchPromotionWithoutSave() async {
        storeOwnershipRecord(owner: 80, target: 85, pending: 90, in: store)
        store.saveFails = true
        system.reading = .limit(90)
        let (controller, _) = makeController(limit: 90)
        let status = await controller.evaluate(.launch)
        #expect(!status.isBackendFaulted)
        #expect(!status.events.contains { $0.message.contains("changed outside CellKeeper") })
        // The unfinished session is still wound up: the user's limit first.
        #expect(system.reading == .limit(80))
        #expect(system.runInputs == ["80"])
    }

    @Test("If CellKeeper cannot read back the limit it set, it restores the user's limit")
    func unverifiedStateRestores() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.failNextReads(1)
        let status = await controller.evaluate(.periodic)
        #expect(status.decision?.reason == .releaseRequired(.stateUnverified))
        #expect(system.reading == .limit(80))
        #expect(status.nativeLimit?.ownerLimit == nil)
    }

    @Test("A backend that reports an outside change without adopting it is faulted and restored")
    func outsideChangeFoundByBackend() async {
        let backend = ChangedOutsideBackend()
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: 75), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: backend, settings: settings(limit: 90), now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        #expect(status.isBackendFaulted)
        #expect(await backend.requests == [.nativeLimit(percent: 90), .normal])
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("Changed outside CellKeeper") })
    }

    // MARK: - Relaunch

    @Test("After a crash, the next session restores the recorded limit before managing again")
    func relaunchAfterCrash() async {
        let (first, _) = makeController(limit: 90)
        await first.evaluate(.launch)
        // The first controller disappears without restoring (a crash).

        let (second, _) = makeController(limit: 90)
        let status = await second.evaluate(.launch)
        #expect(status.decision?.reason == .releaseRequired(.restoreUnfinished))
        #expect(status.events.contains { $0.message.contains("earlier CellKeeper session") })
        #expect(system.reading == .limit(80))
        #expect(store.data == nil)

        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let managing = await second.evaluate(.periodic)
        #expect(managing.decision?.state == .osEnforcedLimit)
        #expect(managing.nativeLimit?.ownerLimit == 80)
        await second.shutdown(reason: "quit")
        #expect(system.reading == .limit(80))
        #expect(system.runInputs == ["90", "80", "90", "80"])
    }

    @Test("If the restore marker could not be stored, the next launch still restores first")
    func relaunchWithStaleMarker() async {
        let (first, _) = makeController(limit: 90)
        await first.evaluate(.launch)
        store.saveFails = true
        system.runBehaviour = .fails
        let stopped = await first.shutdown(reason: "quit")
        #expect(stopped.nativeLimit?.isRestoreUnfinished == true)
        #expect(String(data: store.data ?? Data(), encoding: .utf8)?.contains(#""isRestoring":true"#) == false)

        store.saveFails = false
        system.runBehaviour = .applies
        let (second, _) = makeController(limit: 90)
        await second.evaluate(.launch)
        #expect(system.reading == .limit(80))
        #expect(store.data == nil)
    }

    @Test("If the first read at launch fails, the earlier session's limit is still restored")
    func relaunchWithFailedFirstRead() async {
        storeOwnershipRecord(owner: 80, target: 90, in: store)
        system.reading = .limit(90)
        system.failNextReads(1)
        system.runBehaviour = .fails
        let (controller, _) = makeController(limit: 90)
        let first = await controller.evaluate(.launch)
        #expect(first.decision?.reason == .releaseRequired(.stateUnverified))
        #expect(system.reading == .limit(90))

        system.runBehaviour = .applies
        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let later = await controller.evaluate(.periodic)
        #expect(later.decision?.reason == .releaseRequired(.restoreUnfinished))
        #expect(system.reading == .limit(80))
        #expect(store.data == nil)
    }

    @Test("A startup switch whose restore fails waits, retries, and then switches")
    func failedStartupSwitchRecovers() async {
        storeOwnershipRecord(owner: 80, target: 90, in: store)
        system.reading = .limit(90)
        system.runBehaviour = .fails
        let (controller, _) = makeController(limit: 90)
        let pending = await controller.switchBackend(to: MockChargingBackend())
        #expect(pending.pendingBackend?.identifier == "simulated")
        let attempts = system.runInputs.count

        clock.advance(by: 10)
        await controller.evaluate(.launch)
        #expect(system.runInputs.count == attempts)

        system.runBehaviour = .applies
        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let switched = await controller.evaluate(.periodic)
        #expect(switched.backend.identifier == "simulated")
        #expect(system.reading == .limit(80))
        #expect(store.data == nil)
    }

    @Test("A stale record never lets a new limit be set before the owed restore")
    func relaunchRestoresBeforeNewLimit() async throws {
        let (first, _) = makeController(limit: 90)
        await first.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        store.saveFails = true
        system.runBehaviour = .fails
        try await first.apply(settings: settings(limit: 95))

        store.saveFails = false
        system.runBehaviour = .applies
        let (second, _) = makeController(limit: 95)
        await second.evaluate(.launch)
        let afterRelaunch = Array(system.runInputs.dropFirst(2))
        #expect(afterRelaunch.first == "80")
        #expect(system.reading == .limit(80))
    }

    @Test("A change made while CellKeeper was not running is kept as the user's own limit")
    func relaunchAfterOutsideChange() async {
        storeOwnershipRecord(owner: 80, target: 90, in: store)
        system.reading = .limit(95)
        let (controller, _) = makeController(limit: 90)
        let status = await controller.evaluate(.launch)
        #expect(!status.isBackendFaulted)
        #expect(system.reading == .limit(95))
        #expect(system.runInputs.isEmpty)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
        #expect(NativeChargeLimitBackend.pendingAdoption(in: store)?.limit == 95)
        #expect(status.adoptedChange?.limit == 95)
        #expect(!status.settings.isManagementEnabled)
        #expect(!status.events.contains { $0.message.contains("finish restoring") })
    }

    @Test("A restore that completed after the last session stopped waiting is recognised")
    func relaunchAfterLateRestore() async {
        storeOwnershipRecord(owner: 80, target: 90, in: store)
        system.reading = .limit(80)
        let (controller, _) = makeController(limit: 80, managed: false)
        let status = await controller.evaluate(.launch)
        #expect(!status.isBackendFaulted)
        #expect(status.nativeLimit?.ownerLimit == nil)
        #expect(system.runInputs.isEmpty)
    }

    // MARK: - Rate limiting and retries

    @Test("Limit changes are rate-limited; returning to the user's limit is not")
    func rateLimited() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        let limited = try await controller.apply(settings: settings(limit: 95))
        guard case .refuse(.rateLimited) = limited.decision?.action else {
            Issue.record("expected rate limiting, got \(String(describing: limited.decision?.action))")
            return
        }
        #expect(system.runInputs == ["90"])

        let released = try await controller.apply(settings: settings(limit: 95, managed: false))
        #expect(released.currentMode == .normal)
        #expect(system.runInputs == ["90", "80"])

        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        try await controller.apply(settings: settings(limit: 95))
        #expect(system.runInputs == ["90", "80", "95"])
    }

    @Test("A no-op take-over does not use up the rate limit")
    func unchangedNotCounted() async throws {
        let (controller, _) = makeController(limit: 80)
        await controller.evaluate(.launch)
        let changed = try await controller.apply(settings: settings(limit: 90))
        #expect(changed.currentMode == .nativeLimit(percent: 90))
        #expect(system.runInputs == ["90"])
    }

    @Test("Simulated requests do not delay the first real change after switching")
    func simulatedRequestsNotCounted() async {
        let clock = clock
        let controller = ChargeController(
            telemetry: StubTelemetry(snapshot(percent: 92), clock: clock),
            backend: MockChargingBackend(),
            settings: settings(limit: 90),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        // The second reading at 92% confirms the limit and makes the request.
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        let simulated = await controller.evaluate(.periodic)
        #expect(simulated.lastExecution?.result == .simulated)

        clock.advance(by: 5)
        let status = await controller.switchBackend(to: makeNativeBackend(system: system, store: store, clock: clock))
        #expect(status.backend.identifier == NativeChargeLimitBackend.identifier)
        #expect(status.currentMode == .nativeLimit(percent: 90))
        #expect(system.runInputs == ["90"])
    }

    @Test("Real changes still count after a round trip through Simulated")
    func realRequestsCountedAcrossSwitches() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        await controller.switchBackend(to: MockChargingBackend())
        #expect(system.runInputs == ["90", "80"])

        let back = await controller.switchBackend(to: makeNativeBackend(system: system, store: store, clock: clock))
        guard case .refuse(.rateLimited) = back.decision?.action else {
            Issue.record("expected rate limiting, got \(String(describing: back.decision?.action))")
            return
        }
        #expect(system.runInputs == ["90", "80"])

        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        await controller.evaluate(.periodic)
        #expect(system.runInputs == ["90", "80", "90"])
    }

    @Test("A failing restore is retried automatically at most once a minute, but at once on a user action")
    func restoreRetriesSpaced() async throws {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.runBehaviour = .fails
        let off = try await controller.apply(settings: settings(limit: 90, managed: false))
        #expect(off.nativeLimit?.ownerLimit == 80)
        let attempts = system.runInputs.count

        clock.advance(by: 10)
        let waiting = await controller.evaluate(.periodic)
        guard case .refuse(.rateLimited) = waiting.decision?.action else {
            Issue.record("expected the retry to wait, got \(String(describing: waiting.decision?.action))")
            return
        }
        await controller.evaluate(.powerSourceChanged)
        #expect(system.runInputs.count == attempts)

        await controller.evaluate(.manual)
        #expect(system.runInputs.count == attempts + 1)

        system.runBehaviour = .applies
        clock.advance(by: ChargingPolicy.minimumRestoreRetryInterval)
        let restored = await controller.evaluate(.periodic)
        #expect(system.reading == .limit(80))
        #expect(restored.nativeLimit?.ownerLimit == nil)
    }

    // MARK: - Never assume

    @Test("If macOS's limit cannot be recognised, nothing is changed or restored")
    func unrecognisedLimit() async {
        system.reading = .unrecognized("test")
        let (controller, _) = makeController(limit: 90)
        let status = await controller.evaluate(.launch)
        guard case .refuse(.controlUnavailable) = status.decision?.action else {
            Issue.record("expected the backend to be unavailable, got \(String(describing: status.decision?.action))")
            return
        }
        await controller.shutdown(reason: "quit")
        #expect(system.runInputs.isEmpty)
    }

    @Test("A user limit of 100% is recorded only after confirmation, and restored as 100%")
    func restoresNoLimit() async {
        system.reading = .noLimit
        let (controller, _) = makeController(limit: 80)
        let unconfirmed = await controller.evaluate(.launch)
        #expect(unconfirmed.nativeLimit?.needsNoLimitConfirmation == true)
        #expect(system.runInputs.isEmpty)
        await controller.confirmNoLimitIsOwnerLimit()
        #expect(system.reading == .limit(80))
        await controller.shutdown(reason: "quit")
        #expect(system.reading == .noLimit)
        #expect(system.runInputs == ["80", "100"])
    }

    @Test("If the shortcut disappears while CellKeeper owns the limit, quitting says how to restore it")
    func shortcutGoneWhileOwned() async {
        let (controller, _) = makeController(limit: 90)
        await controller.evaluate(.launch)
        system.names = []
        let backendStatus = await controller.restoreSystemDefaults(reason: "test")
        // The cached check still allows an attempt; the run itself fails.
        #expect(system.reading == .limit(90))
        #expect(backendStatus.nativeLimit?.ownerLimit == 80)
        clock.advance(by: NativeChargeLimitBackend.shortcutCheckValidity)
        let stopped = await controller.shutdown(reason: "quit")
        #expect(stopped.events.contains { $0.message.contains("System Settings") })
        #expect(stopped.nativeLimit?.ownerLimit == 80)
    }

    // MARK: - Overrides

    @Test("A temporary full charge raises the limit to 100% and then sets the limit again")
    func fullCharge() async {
        let (controller, telemetry) = makeController(limit: 85, percent: 85)
        await controller.evaluate(.launch)
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let started = await controller.startFullCharge()
        #expect(started.decision?.state == .fullChargeOverride)
        #expect(system.reading == .noLimit)

        await telemetry.set(snapshot(percent: 100, charging: false, fullyCharged: true))
        clock.advance(by: ChargingPolicy.minimumRestrictingInterval)
        let finished = await controller.evaluate(.powerSourceChanged)
        #expect(finished.activeOverride == nil)
        #expect(system.reading == .limit(85))
        #expect(system.runInputs == ["85", "100", "85"])
    }

    @Test("A discharge session does not start on the native limit")
    func dischargeRefused() async {
        let (controller, _) = makeController(limit: 80, percent: 90)
        await controller.evaluate(.launch)
        let status = await controller.startDischargeToLimit()
        #expect(status.activeOverride == nil)
        #expect(status.decision?.notes.contains(.dischargeUnsupported) == true)
        #expect(system.runInputs.isEmpty)
    }
}

/// A native-limit backend whose pre-write check always finds an outside
/// change.
actor ChangedOutsideBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "changed-outside", displayName: "Changed outside", summary: "")
    private(set) var requests: [ChargeControlMode] = []
    private var mode: ChargeControlMode = .normal

    func capabilities() -> ControlCapabilities { nativeCapabilities }
    func currentMode() -> ChargeControlMode? { mode }

    func setMode(_ newMode: ChargeControlMode) throws -> ControlOutcome {
        requests.append(newMode)
        if newMode == .normal {
            mode = .normal
            return .applied
        }
        throw BackendError.changedOutside(expected: .nativeLimit(percent: 85), found: .nativeLimit(percent: 95))
    }
}
