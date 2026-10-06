import CellKeeperCore
import Foundation
import Testing

@Suite("Native Charge Limit backend")
struct NativeChargeLimitBackendTests {
    let system = FakeChargeLimitSystem(reading: .limit(80))
    let storage = InMemoryStorage()
    let clock = TestClock()

    private func makeBackend(platformIssue: String? = nil) -> NativeChargeLimitBackend {
        makeNativeBackend(system: system, storage: storage, platformIssue: platformIssue, clock: clock)
    }

    // MARK: - Availability

    @Test("Offers 80–100% in 5% steps, enforced by macOS, as experimental")
    func capabilities() async {
        let capabilities = await makeBackend().capabilities()
        #expect(capabilities.availability == .experimental)
        #expect(capabilities.nativeLimitSteps == [80, 85, 90, 95, 100])
        #expect(capabilities.isEnforcedByMacOS)
        #expect(capabilities.supports(.normal))
        #expect(capabilities.supports(.nativeLimit(percent: 85)))
        #expect(!capabilities.supports(.nativeLimit(percent: 75)))
        #expect(!capabilities.supports(.inhibitCharging))
        #expect(!capabilities.supports(.forceDischarge))
    }

    @Test("Unsupported Macs are unavailable but keep the native style")
    func platformIssue() async {
        let capabilities = await makeBackend(platformIssue: "needs Apple silicon").capabilities()
        #expect(capabilities.availability == .unavailable(reason: "needs Apple silicon"))
        #expect(capabilities.isEnforcedByMacOS)
        #expect(system.listCalls == 0)
    }

    @Test("A missing shortcut makes the backend unavailable, and is looked for again")
    func missingShortcut() async {
        system.names = ["Something else"]
        let backend = makeBackend()
        guard case .unavailable(let reason) = await backend.capabilities().availability else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains(NativeChargeLimitBackend.defaultShortcutName))

        system.names = [NativeChargeLimitBackend.defaultShortcutName]
        #expect(await backend.capabilities().availability == .experimental)
    }

    @Test("A confirmed shortcut is not looked up on every evaluation, until a recheck")
    func shortcutCheckCached() async {
        let backend = makeBackend()
        _ = await backend.capabilities()
        _ = await backend.capabilities()
        #expect(system.listCalls == 1)
        await backend.recheckAvailability()
        _ = await backend.capabilities()
        #expect(system.listCalls == 2)
        clock.advance(by: NativeChargeLimitBackend.shortcutCheckValidity)
        _ = await backend.capabilities()
        #expect(system.listCalls == 3)
    }

    @Test("An unrecognised report without a recorded limit makes the backend unavailable")
    func unrecognisedReportUnavailable() async {
        system.reading = .unrecognized("test")
        guard case .unavailable = await makeBackend().capabilities().availability else {
            Issue.record("expected unavailable")
            return
        }
    }

    @Test("Failing to list shortcuts or to read the limit makes the backend unavailable")
    func listOrReadFailure() async {
        system.listFails = true
        guard case .unavailable = await makeBackend().capabilities().availability else {
            Issue.record("expected unavailable after a list failure")
            return
        }
        system.listFails = false
        system.readFails = true
        guard case .unavailable = await makeBackend().capabilities().availability else {
            Issue.record("expected unavailable after a read failure")
            return
        }
    }

    // MARK: - Ownership and restore

    @Test("Without a record, the user's own limit is in effect whatever its value")
    func normalWithoutRecord() async throws {
        system.reading = .limit(85)
        let backend = makeBackend()
        #expect(try await backend.currentMode() == .normal)
        let status = await backend.nativeLimitStatus()
        #expect(status?.reportedLimit == 85)
        #expect(status?.ownerLimit == nil)
        #expect(status?.isOwnedByCellKeeper == false)
    }

    @Test("The user's limit is recorded before the first change, then the change is confirmed")
    func recordsThenChanges() async throws {
        let backend = makeBackend()
        #expect(try await backend.setMode(.nativeLimit(percent: 90)) == .applied)
        #expect(system.runInputs == ["90"])
        #expect(system.reading == .limit(90))
        #expect(try await backend.currentMode() == .nativeLimit(percent: 90))
        let status = await backend.nativeLimitStatus()
        #expect(status?.ownerLimit == 80)
        #expect(status?.target == 90)
        #expect(storage.data(forKey: NativeChargeLimitBackend.ownershipKey) != nil)
    }

    @Test("Releasing restores exactly the recorded limit and forgets it")
    func restoresExactly() async throws {
        system.reading = .limit(85)
        let backend = makeBackend()
        _ = try await backend.setMode(.nativeLimit(percent: 95))
        _ = try await backend.setMode(.nativeLimit(percent: 90))
        #expect(try await backend.setMode(.normal) == .applied)
        #expect(system.runInputs == ["95", "90", "85"])
        #expect(system.reading == .limit(85))
        #expect(try await backend.currentMode() == .normal)
        #expect(await backend.nativeLimitStatus()?.ownerLimit == nil)
        #expect(storage.data(forKey: NativeChargeLimitBackend.ownershipKey) == nil)
    }

    @Test("A limit of 100% (reported as no limit) is restored as 100%, not assumed")
    func restoresNoLimit() async throws {
        system.reading = .noLimit
        let backend = makeBackend()
        _ = try await backend.setMode(.nativeLimit(percent: 80))
        #expect(await backend.nativeLimitStatus()?.ownerLimit == 100)
        _ = try await backend.setMode(.normal)
        #expect(system.runInputs == ["80", "100"])
        #expect(system.reading == .noLimit)
    }

    @Test("Asking for the limit already in effect records it but runs nothing")
    func unchangedRunsNothing() async throws {
        let backend = makeBackend()
        #expect(try await backend.setMode(.nativeLimit(percent: 80)) == .unchanged)
        #expect(system.runInputs.isEmpty)
        #expect(await backend.nativeLimitStatus()?.ownerLimit == 80)
        #expect(try await backend.setMode(.normal) == .unchanged)
        #expect(system.runInputs.isEmpty)
        #expect(await backend.nativeLimitStatus()?.ownerLimit == nil)
    }

    @Test("Restoring with nothing recorded changes nothing")
    func restoreWithoutRecord() async throws {
        let backend = makeBackend()
        #expect(try await backend.setMode(.normal) == .unchanged)
        #expect(system.runInputs.isEmpty)
    }

    @Test("An unrecognised limit is never recorded or changed", arguments: [
        NativeChargeLimitReading.unrecognized("test"), .limit(83), .limit(50),
    ])
    func neverAssumes(reading: NativeChargeLimitReading) async {
        system.reading = reading
        let backend = makeBackend()
        await #expect(throws: BackendError.self) {
            try await backend.setMode(.nativeLimit(percent: 90))
        }
        #expect(system.runInputs.isEmpty)
        #expect(storage.data(forKey: NativeChargeLimitBackend.ownershipKey) == nil)
    }

    @Test("Only the advertised steps and normal are accepted")
    func rejectsOtherModes() async {
        let backend = makeBackend()
        for mode in [ChargeControlMode.nativeLimit(percent: 83), .nativeLimit(percent: 75), .inhibitCharging, .forceDischarge] {
            await #expect(throws: BackendError.unsupportedMode(mode)) {
                try await backend.setMode(mode)
            }
        }
        #expect(system.runInputs.isEmpty)
    }

    // MARK: - Confirmation

    @Test("A shortcut that finishes without effect is not a confirmation")
    func noEffectIsFailure() async throws {
        system.runBehaviour = .hasNoEffect
        let backend = makeBackend()
        await #expect(throws: BackendError.verificationFailed(expected: .nativeLimit(percent: 90), actual: .nativeLimit(percent: 80))) {
            try await backend.setMode(.nativeLimit(percent: 90))
        }
        // The record survives, so the user's limit can still be restored;
        // here it is still in effect, so nothing needs to run.
        #expect(await backend.nativeLimitStatus()?.ownerLimit == 80)
        #expect(try await backend.setMode(.normal) == .unchanged)
        #expect(await backend.nativeLimitStatus()?.ownerLimit == nil)
    }

    @Test("A failing shortcut is an error and the shortcut is looked for again")
    func shortcutFailure() async throws {
        let backend = makeBackend()
        _ = await backend.capabilities()
        system.runBehaviour = .fails
        await #expect(throws: BackendError.self) {
            try await backend.setMode(.nativeLimit(percent: 90))
        }
        _ = await backend.capabilities()
        #expect(system.listCalls == 2)
    }

    @Test("A failed restore keeps the record and is reported")
    func failedRestoreKeepsRecord() async throws {
        let backend = makeBackend()
        _ = try await backend.setMode(.nativeLimit(percent: 90))
        system.runBehaviour = .hasNoEffect
        await #expect(throws: BackendError.self) {
            try await backend.setMode(.normal)
        }
        #expect(await backend.nativeLimitStatus()?.ownerLimit == 80)
        system.runBehaviour = .applies
        #expect(try await backend.setMode(.normal) == .applied)
        #expect(system.reading == .limit(80))
    }

    @Test("While CellKeeper owns the limit, a read failure is an error")
    func readFailureWhileOwned() async throws {
        let backend = makeBackend()
        _ = try await backend.setMode(.nativeLimit(percent: 90))
        system.readFails = true
        await #expect(throws: BackendError.self) {
            try await backend.currentMode()
        }
        #expect(await backend.nativeLimitStatus()?.readProblem != nil)
    }

    @Test("Another change to the setting shows up as a different limit")
    func externalChangeVisible() async throws {
        let backend = makeBackend()
        _ = try await backend.setMode(.nativeLimit(percent: 90))
        system.changeExternally(to: 95)
        #expect(try await backend.currentMode() == .nativeLimit(percent: 95))
    }

    // MARK: - Persistence

    @Test("The record survives a relaunch and is restored from there")
    func recordSurvivesRelaunch() async throws {
        _ = try await makeBackend().setMode(.nativeLimit(percent: 90))

        let relaunched = makeBackend()
        #expect(try await relaunched.currentMode() == .nativeLimit(percent: 90))
        #expect(await relaunched.nativeLimitStatus()?.target == 90)
        #expect(try await relaunched.setMode(.normal) == .applied)
        #expect(system.reading == .limit(80))
        #expect(system.runInputs == ["90", "80"])
    }

    @Test("At relaunch, a record whose limit is already back in effect is cleared")
    func relaunchAfterCompletedRestore() async throws {
        storeOwnershipRecord(owner: 80, target: 90, in: storage)
        system.reading = .limit(80)
        let backend = makeBackend()
        #expect(try await backend.currentMode() == .normal)
        #expect(await backend.nativeLimitStatus()?.ownerLimit == nil)
        #expect(storage.data(forKey: NativeChargeLimitBackend.ownershipKey) == nil)
    }

    @Test("An unreadable record blocks all changes rather than losing the user's limit")
    func unreadableRecord() async throws {
        storage.set(Data("not json".utf8), forKey: NativeChargeLimitBackend.ownershipKey)
        let backend = makeBackend()
        guard case .unavailable = await backend.capabilities().availability else {
            Issue.record("expected unavailable")
            return
        }
        #expect(try await backend.currentMode() == nil)
        await #expect(throws: BackendError.self) {
            try await backend.setMode(.nativeLimit(percent: 90))
        }
        await #expect(throws: BackendError.self) {
            try await backend.setMode(.normal)
        }
        #expect(system.runInputs.isEmpty)
    }

    @Test("A record with values outside the Charge Limit's range is unreadable")
    func implausibleRecord() async {
        storeOwnershipRecord(owner: 50, target: 90, in: storage)
        guard case .unavailable = await makeBackend().capabilities().availability else {
            Issue.record("expected unavailable")
            return
        }
    }
}
