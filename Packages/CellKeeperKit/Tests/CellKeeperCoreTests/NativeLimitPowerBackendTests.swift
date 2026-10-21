import CellKeeperCore
import Foundation
import Testing

/// The backend on its own, told that reads cannot be judged
/// (``ChargeLimitReadCondition``; research note 08, O20).
@Suite("Native Charge Limit backend: reads that cannot be judged")
struct NativeLimitPowerBackendTests {
    let system = FakeChargeLimitSystem(reading: .limit(80))
    let store = InMemoryRecordStore()
    let clock = TestClock()

    private func makeBackend(_ condition: ChargeLimitReadCondition) async -> NativeChargeLimitBackend {
        let backend = makeNativeBackend(system: system, store: store, clock: clock)
        await backend.noteChargeLimitReadCondition(condition)
        return backend
    }

    @Test("Each condition but a settled one keeps reads from being judged", arguments: ChargeLimitReadCondition.allCases)
    func judgedOnlyWhenSettled(condition: ChargeLimitReadCondition) {
        #expect(condition.isJudged == (condition == .settled))
    }

    @Test("A no-limit report that cannot be judged is not adopted: the record stands and CellKeeper's limit is reported", arguments: [ChargeLimitReadCondition.onBattery, .settling, .powerUnknown])
    func noLimitNotAdopted(condition: ChargeLimitReadCondition) async throws {
        storeOwnershipRecord(owner: 80, target: 85, in: store)
        system.isActiveLimitCleared = true
        let backend = await makeBackend(condition)
        let mode = try await backend.currentMode()
        #expect(mode == .nativeLimit(percent: 85))
        #expect(await backend.takeAdoptedLimitChange() == nil)
        #expect(await backend.reportedModeOrigin() == .cellKeeper)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 80)
        let status = await backend.nativeLimitStatus()
        #expect(status?.readDeferral == condition)
        #expect(status?.reportedLimit == 100, "what macOS showed")
        #expect(status?.ownerLimit == 80)
    }

    @Test("An active limit the record does not account for is not adopted until it can be judged")
    func otherActiveLimitWaits() async throws {
        storeOwnershipRecord(owner: 80, target: 85, in: store)
        system.reading = .limit(90)
        let backend = await makeBackend(.onBattery)
        #expect(try await backend.currentMode() == .nativeLimit(percent: 85))
        #expect(await backend.takeAdoptedLimitChange() == nil)
        #expect(await backend.nativeLimitStatus()?.readDeferral == .onBattery)
        #expect(try await backend.setMode(.nativeLimit(percent: 95)) == .deferred)
        #expect(try await backend.setMode(.normal) == .deferred)
        #expect(system.runInputs.isEmpty)

        await backend.noteChargeLimitReadCondition(.settled)
        #expect(try await backend.currentMode() == .normal)
        #expect(await backend.takeAdoptedLimitChange()?.limit == 90)
    }

    @Test("An active limit the record accounts for is evidence as when judged: a pending one is confirmed, the owner's own ends the record")
    func activeLimitIsEvidence() async throws {
        storeOwnershipRecord(owner: 80, target: 85, pending: 90, in: store)
        system.reading = .limit(90)
        let backend = await makeBackend(.onBattery)
        #expect(try await backend.currentMode() == .nativeLimit(percent: 90))
        #expect(await backend.nativeLimitStatus()?.target == 90)
        #expect(await backend.nativeLimitStatus()?.readDeferral == nil)

        // A record from an earlier session, with the owner's own limit back.
        let other = InMemoryRecordStore()
        storeOwnershipRecord(owner: 80, target: 85, in: other)
        let relaunched = makeNativeBackend(system: FakeChargeLimitSystem(reading: .limit(80)), store: other, clock: clock)
        await relaunched.noteChargeLimitReadCondition(.settling)
        #expect(try await relaunched.currentMode() == .normal)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: other) == nil)
    }

    @Test("A no-limit report that cannot be judged never stands for the owner's own 100%: the record is kept and nothing is written")
    func ownerHundredNotAssumed() async throws {
        storeOwnershipRecord(owner: 100, target: 80, in: store)
        system.isActiveLimitCleared = true
        let backend = await makeBackend(.onBattery)
        #expect(try await backend.currentMode() == .nativeLimit(percent: 80))
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 100)
        #expect(try await backend.setMode(.normal) == .deferred)
        #expect(system.runInputs.isEmpty)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 100)

        // Restoring 100% from CellKeeper's own 80% just after an unplug
        // goes ahead, but its no-limit read-back is not a confirmation.
        system.isActiveLimitCleared = false
        #expect(try await backend.setMode(.normal) == .awaitingConfirmation)
        #expect(system.runInputs == ["100"])
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 100)
        #expect(try await backend.currentMode() == .nativeLimit(percent: 80), "still owed, still reported as CellKeeper's")
        await backend.noteChargeLimitReadCondition(.settled)
        #expect(try await backend.currentMode() == .normal)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
    }

    @Test("Nothing is recorded as the owner's own limit from a read that cannot be judged, whatever it shows", arguments: [NativeChargeLimitReading.limit(85), .noLimit])
    func nothingRecorded(reading: NativeChargeLimitReading) async throws {
        system.reading = reading
        let backend = await makeBackend(.settling)
        await backend.confirmNoLimitIsOwnerLimit()
        #expect(await backend.capabilities().availability == .experimental)
        #expect(try await backend.setMode(.nativeLimit(percent: 90)) == .deferred)
        #expect(store.data == nil)
        #expect(system.runInputs.isEmpty)
        #expect(await backend.nativeLimitStatus()?.needsNoLimitConfirmation == false)

        await backend.noteChargeLimitReadCondition(.settled)
        #expect(try await backend.setMode(.nativeLimit(percent: 90)) == .applied)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == reading.percent)
    }

    @Test("Without a record, a no-limit report that cannot be judged asks for no confirmation and leaves the backend available")
    func noConfirmationOnBattery() async {
        system.isActiveLimitCleared = true
        let backend = await makeBackend(.onBattery)
        #expect(await backend.capabilities().availability == .experimental)
        let status = await backend.nativeLimitStatus()
        #expect(status?.needsNoLimitConfirmation == false)
        #expect(status?.readDeferral == .onBattery)

        await backend.noteChargeLimitReadCondition(.settled)
        guard case .unavailable(let reason) = await backend.capabilities().availability else {
            Issue.record("a judged no limit needs the owner's confirmation")
            return
        }
        #expect(reason.contains("confirm it in Settings › Control"))
        #expect(await backend.nativeLimitStatus()?.needsNoLimitConfirmation == true)
    }

    @Test("A write whose read-back cannot be judged waits: no failure, the value stays pending, and is not written again on no limit")
    func readBackWaits() async throws {
        storeOwnershipRecord(owner: 80, target: 80, in: store)
        let backend = await makeBackend(.onBattery)
        system.scheduleRuns([.appliesWithoutActiveLimit])
        #expect(try await backend.setMode(.nativeLimit(percent: 85)) == .awaitingConfirmation)
        #expect(system.runInputs == ["85"])
        #expect(await backend.nativeLimitStatus()?.readDeferral == .onBattery)
        #expect(try await backend.setMode(.nativeLimit(percent: 85)) == .deferred)
        #expect(system.runInputs == ["85"])
        // A read-back that cannot be judged but shows the value confirms it.
        system.isActiveLimitCleared = false
        #expect(try await backend.setMode(.nativeLimit(percent: 90)) == .applied)
        #expect(await backend.nativeLimitStatus()?.target == 90)
    }

    @Test("After a 100% step, a no-limit report lets CellKeeper's own return go ahead without confirming 100%; a write to 100% waits")
    func returnFromHundred() async throws {
        storeOwnershipRecord(owner: 80, target: 100, in: store)
        system.reading = .noLimit
        let backend = await makeBackend(.onBattery)
        #expect(try await backend.setMode(.nativeLimit(percent: 100)) == .deferred, "no limit confirms no 100%")
        #expect(try await backend.setMode(.nativeLimit(percent: 80)) == .applied)
        #expect(system.runInputs == ["80"])
        #expect(await backend.nativeLimitStatus()?.target == 80)
    }

    @Test("With 100% pending, a no-limit report keeps every value the record accounts for")
    func noLimitKeepsPending() async throws {
        storeOwnershipRecord(owner: 80, target: 85, pending: 100, in: store)
        system.reading = .noLimit
        let backend = await makeBackend(.onBattery)
        system.scheduleRuns([.hasNoEffect])
        #expect(try await backend.setMode(.nativeLimit(percent: 90)) == .awaitingConfirmation)
        // 85% was the setting all along: on power it is CellKeeper's own.
        system.reading = .limit(85)
        await backend.noteChargeLimitReadCondition(.settled)
        #expect(try await backend.currentMode() == .nativeLimit(percent: 85))
        #expect(await backend.takeAdoptedLimitChange() == nil)
    }

    @Test("A restore whose read-back cannot be judged waits, and is completed by a later read of the owner's own limit")
    func restoreWaits() async throws {
        storeOwnershipRecord(owner: 80, target: 85, in: store)
        system.reading = .limit(85)
        let backend = await makeBackend(.onBattery)
        system.scheduleRuns([.appliesWithoutActiveLimit])
        #expect(try await backend.setMode(.normal) == .awaitingConfirmation)
        #expect(await backend.nativeLimitStatus()?.isRestoreUnfinished == true)
        #expect(try await backend.setMode(.normal) == .deferred)
        #expect(system.runInputs == ["80"])
        system.isActiveLimitCleared = false
        #expect(try await backend.currentMode() == .normal)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store) == nil)
    }

    @Test("The owner's own limit shown on battery power after the first read is no adoption until it can be judged")
    func ownLimitShownAfterFirstContact() async throws {
        storeOwnershipRecord(owner: 80, target: 85, in: store)
        system.reading = .limit(85)
        let backend = await makeBackend(.onBattery)
        #expect(try await backend.currentMode() == .nativeLimit(percent: 85))
        system.reading = .limit(80)
        #expect(try await backend.currentMode() == .nativeLimit(percent: 85))
        #expect(await backend.takeAdoptedLimitChange() == nil)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 80)

        await backend.noteChargeLimitReadCondition(.settled)
        #expect(try await backend.currentMode() == .normal)
        #expect(await backend.takeAdoptedLimitChange()?.limit == 80, "chosen outside CellKeeper, even if it is the one recorded")
    }

    @Test("With 100% pending as CellKeeper's, a no-limit report on battery power does not end the record of the owner's own 100%")
    func ownerHundredPendingNotEnded() async throws {
        storeOwnershipRecord(owner: 100, target: 80, pending: 100, in: store)
        system.isActiveLimitCleared = true
        let backend = await makeBackend(.onBattery)
        #expect(try await backend.setMode(.normal) == .deferred)
        #expect(system.runInputs.isEmpty)
        #expect(NativeChargeLimitBackend.outstandingRecord(in: store)?.ownerLimit == 100)
    }

    @Test("A read that fails is still a failure, whatever the condition")
    func failedReadStillFails() async {
        storeOwnershipRecord(owner: 80, target: 85, in: store)
        system.readFails = true
        let backend = await makeBackend(.onBattery)
        await #expect(throws: BackendError.self) { try await backend.currentMode() }
        #expect(await backend.nativeLimitStatus()?.readDeferral == nil)
    }
}
