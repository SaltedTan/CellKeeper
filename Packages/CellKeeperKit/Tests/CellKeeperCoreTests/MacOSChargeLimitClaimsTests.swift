@testable import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// macOS's Charge Limit report that a test can hold back until it lets it
/// through, so a read stays under way; counts reads.
final class SuspendingChargeLimitReader: ChargeLimitReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: NativeChargeLimitReading
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var readCount = 0

    init(_ reading: NativeChargeLimitReading) {
        self.reading = reading
    }

    var reads: Int {
        lock.withLock { readCount }
    }

    /// Holds every later read until ``release(with:)``.
    func hold() {
        lock.withLock { isHeld = true }
    }

    /// Lets held reads through, reporting `reading`.
    func release(with newReading: NativeChargeLimitReading) {
        let resumed = lock.withLock {
            reading = newReading
            isHeld = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in resumed {
            waiter.resume()
        }
    }

    func readChargeLimit() async throws -> NativeChargeLimitReading {
        let mustWait = lock.withLock {
            readCount += 1
            return isHeld
        }
        if mustWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    guard isHeld else { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        return lock.withLock { reading }
    }
}

/// A report that never comes unless the read is cancelled.
struct EndlessChargeLimitReader: ChargeLimitReading {
    func readChargeLimit() async throws -> NativeChargeLimitReading {
        try await Task.sleep(for: .seconds(3600))
        return .noLimit
    }
}

@Suite("macOS's Charge Limit monitor: reads under way")
struct MacOSChargeLimitMonitorInFlightTests {
    let clock = TestClock()

    @Test("A check while a forced read is under way waits for it instead of returning the older reading")
    func waitsForReadUnderWay() async throws {
        let reader = SuspendingChargeLimitReader(.noLimit)
        let clock = clock
        let monitor = MacOSChargeLimitMonitor(reader: reader, now: { clock.now }, uptime: { clock.uptime })
        #expect(await monitor.status().isLimiting == false)

        reader.hold()
        let forced = Task { await monitor.refresh() }
        await eventually("the forced read is under way") { await monitor.waitingCallerCount == 1 && reader.reads == 2 }
        // The cached "no limit" is fresh, but a read is under way: the
        // concurrent check must join it, which the waiter count establishes
        // before the read is let through.
        let concurrent = Task { await monitor.status() }
        await eventually("both callers wait for the forced read") { await monitor.waitingCallerCount == 2 }
        reader.release(with: .limit(80))
        let concurrentStatus = await concurrent.value
        let forcedStatus = await forced.value
        #expect(concurrentStatus.reportedLimit == 80)
        #expect(concurrentStatus.isLimiting)
        #expect(forcedStatus == concurrentStatus)
        let kept = await monitor.lastStatus
        #expect(kept == concurrentStatus)
        #expect(reader.reads == 2)
    }

    @Test("A cancelled caller cancels the read it waits for; nothing is kept, so the next check reads again", .timeLimit(.minutes(1)))
    func cancelledCallerCancelsRead() async {
        let clock = clock
        let monitor = MacOSChargeLimitMonitor(reader: EndlessChargeLimitReader(), now: { clock.now }, uptime: { clock.uptime })
        let waiting = Task { await monitor.status() }
        await eventually("the caller waits for the read") { await monitor.waitingCallerCount == 1 }
        waiting.cancel()
        let status = await waiting.value
        #expect(status.isLimiting)
        #expect(status.readProblem == "the read was cancelled")
        let kept = await monitor.lastStatus
        #expect(kept == nil)
    }

    @Test("A cancelled read drops the earlier reading too, so an old \"off\" never stands in for it", .timeLimit(.minutes(1)))
    func cancelledReadDropsEarlierReading() async {
        let reader = SuspendingChargeLimitReader(.noLimit)
        let clock = clock
        let monitor = MacOSChargeLimitMonitor(reader: reader, now: { clock.now }, uptime: { clock.uptime })
        _ = await monitor.status()
        reader.hold()
        let forced = Task { await monitor.refresh() }
        await eventually("the forced read is under way") { await monitor.waitingCallerCount == 1 && reader.reads == 2 }
        forced.cancel()
        // The held read ignores cancellation; let it finish.
        reader.release(with: .noLimit)
        _ = await forced.value
        let kept = await monitor.lastStatus
        #expect(kept == nil)
        _ = await monitor.status()
        #expect(reader.reads == 3)
    }
}

@Suite("Releases never wait for macOS's Charge Limit")
struct MacOSChargeLimitReleasePathTests {
    @Test("Restoring normal charging never waits for a read of macOS's Charge Limit")
    func restoreDoesNotRead() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        let reads = reader.reads
        // The cached reading is stale now; a restore must not read anew.
        rig.clock.advance(by: 120)
        let restored = await controller.restoreSystemDefaults(reason: "test")
        #expect(restored.currentMode == .normal)
        #expect(reader.reads == reads)
    }

    @Test("Quitting never waits for a read of macOS's Charge Limit")
    func shutdownDoesNotRead() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        let reads = reader.reads
        rig.clock.advance(by: 120)
        let stopped = await controller.shutdown(reason: "quitting")
        #expect(stopped.currentMode == .normal)
        #expect(rig.control.activeControls.isEmpty)
        #expect(reader.reads == reads)
    }

    @Test("A backend switch confirms normal charging without a read of macOS's Charge Limit")
    func switchDoesNotRead() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        let reads = reader.reads
        rig.clock.advance(by: 120)
        let switched = await controller.switchBackend(to: MockChargingBackend())
        #expect(switched.backend.identifier == "simulated")
        #expect(rig.control.activeControls.isEmpty)
        #expect(reader.reads == reads)
    }

    @Test("The release capabilities use the kept reading only, and withhold restrictions without one")
    func releaseCapabilities() async {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let before = await rig.backend.capabilitiesForRelease()
        #expect(reader.reads == 0)
        #expect(before.macOSChargeLimit == nil)
        #expect(before.supportedModes == [.normal])
        _ = await rig.backend.capabilities()
        let after = await rig.backend.capabilitiesForRelease()
        #expect(reader.reads == 1)
        #expect(after.macOSChargeLimit?.isNoLimitReported == true)
        #expect(after.supportedModes == ChargeControlMode.chargingModes)
    }
}

@Suite("What CellKeeper claims about a release while macOS's Charge Limit is on")
struct MacOSChargeLimitReleaseClaimsTests {
    /// Claims a status must never make while a restriction may remain.
    static let overclaims = ["restricts nothing", "released its hold", "confirms that this restriction ended", "no restriction in effect", "never compete"]

    @Test("A release that fails is never reported as done; continuing failures stay honest; a read-back of the end is reported once")
    func failedReleaseThenRecovery() async throws {
        let reader = StubMacOSChargeLimit(.noLimit)
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        await rig.confirmedEvaluation(controller)
        reader.set(.limit(80))
        rig.control.failNextApplies(4)
        rig.control.failNextRestores(4)

        rig.clock.advance(by: 60)
        let failed = await controller.evaluate(.periodic)
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(failed.currentMode != .normal)
        #expect(failed.ownRestriction == .unconfirmed(.inhibitCharging))
        #expect(failed.ownRestriction.mayBeInEffect)
        let event = failed.events.last { $0.kind == .safety && $0.message.contains("macOS's Charge Limit was turned on (80%)") }
        #expect(event?.message.contains("No read-back has confirmed that this restriction ended, so it may remain") == true)
        for claim in Self.overclaims {
            #expect(!failed.events.contains { $0.message.contains(claim) })
            #expect(failed.decision?.reason.description.contains(claim) == false)
        }
        let failedLimit = try #require(failed.capabilities.macOSChargeLimit)
        let guidance = MacOSChargeLimitWording.guidance(failedLimit, ownRestriction: failed.ownRestriction, isSimulated: false)
        #expect(guidance.contains("may remain"))
        let report = DiagnosticsReport.text(status: failed, environment: DiagnosticsEnvironment(appVersion: "1", systemVersion: "27", modelIdentifier: nil), generatedAt: referenceDate)
        #expect(report.contains("Own restriction: No read-back has confirmed that CellKeeper's inhibitCharging ended, so it may remain."))
        #expect(!report.contains("Own restriction: The last read-back shows no restriction in effect."))

        // The release keeps failing: still nothing claimed.
        for _ in 0..<2 {
            rig.clock.advance(by: 60)
            let still = await controller.evaluate(.periodic)
            #expect(rig.control.activeControls == [.chargingInhibited])
            #expect(still.ownRestriction.mayBeInEffect)
            #expect(!still.events.contains { $0.message.contains("has ended") })
            let stillLimit = try #require(still.capabilities.macOSChargeLimit)
            let stillGuidance = MacOSChargeLimitWording.guidance(stillLimit, ownRestriction: still.ownRestriction, isSimulated: false)
            #expect(!stillGuidance.contains("no restriction in effect"))
        }

        // The control recovers: the end is reported once, after the read-back.
        var recovered: ControllerStatus?
        for _ in 0..<4 where recovered == nil {
            rig.clock.advance(by: 60)
            let status = await controller.evaluate(.periodic)
            if status.currentMode == .normal { recovered = status }
        }
        let status = try #require(recovered)
        #expect(rig.control.activeControls.isEmpty)
        #expect(status.ownRestriction == .noneInEffect)
        #expect(status.events.filter { $0.kind == .safety && $0.message.contains("has ended") }.count == 1)
        #expect(status.events.contains { $0.message.contains("A read-back now shows normal charging: CellKeeper's inhibitCharging") })
        let afterLimit = try #require(status.capabilities.macOSChargeLimit)
        let after = MacOSChargeLimitWording.guidance(afterLimit, ownRestriction: status.ownRestriction, isSimulated: false)
        #expect(after.contains("The last read-back shows no restriction in effect."))
    }
}

@Suite("Controller: what macOS's Charge Limit going off means")
struct MacOSChargeLimitGateClearedTests {
    @Test("With Manage charging off, macOS's limit going off is not reported as CellKeeper managing again")
    func managementOff() async {
        let reader = StubMacOSChargeLimit(.limit(80))
        let rig = HelperRig(macOSReader: reader)
        var settings = ChargingSettings.default
        settings.isManagementEnabled = false
        let (controller, _) = rig.controller(percent: 85, settings: settings)
        await controller.evaluate(.launch)
        reader.set(.noLimit)
        rig.clock.advance(by: 60)
        let status = await controller.evaluate(.periodic)
        #expect(status.decision?.state == .unmanaged)
        #expect(status.events.contains { $0.message.contains("macOS reports no active Charge Limit any more, so CellKeeper stops deferring to it") })
        #expect(!status.events.contains { $0.message.contains("manages charging") && $0.message.contains("again") })
    }

    @Test("With a faulted backend, macOS's limit going off is not reported as CellKeeper managing again")
    func faulted() async {
        let reader = StubMacOSChargeLimit(.limit(80))
        let rig = HelperRig(macOSReader: reader)
        let (controller, _) = rig.controller(percent: 85)
        await controller.evaluate(.launch)
        rig.control.simulateOutsideChange(.chargingInhibited, active: true)
        rig.clock.advance(by: 60)
        let faulted = await controller.evaluate(.periodic)
        #expect(faulted.isBackendFaulted)
        reader.set(.noLimit)
        rig.clock.advance(by: 60)
        let status = await controller.evaluate(.periodic)
        #expect(status.isBackendFaulted)
        #expect(status.events.contains { $0.message.contains("stops deferring to it") })
        #expect(!status.events.contains { $0.message.contains("manages charging") && $0.message.contains("again") })
    }

    @Test("A helper that cannot be reached, holding nothing, is not reported as possibly restricting")
    func unreachableHoldingNothing() async {
        let reader = StubMacOSChargeLimit(.limit(80))
        let rig = HelperRig(macOSReader: reader)
        rig.transport.isReachable = false
        let (controller, _) = rig.controller(percent: 85)
        let status = await controller.evaluate(.launch)
        #expect(status.ownRestriction == .noneKnown)
        #expect(!status.ownRestriction.mayBeInEffect)
    }
}

@Suite("Wording about macOS's Charge Limit")
struct MacOSChargeLimitWordingTests {
    static let noLimit = MacOSChargeLimitStatus(reportedLimit: 100, isNoLimitReported: true, readAt: referenceDate)
    static let hundred = MacOSChargeLimitStatus(reportedLimit: 100, readAt: referenceDate)
    static let on = MacOSChargeLimitStatus(reportedLimit: 80, readAt: referenceDate)
    static let unreadable = MacOSChargeLimitStatus(reportedLimit: nil, readAt: referenceDate, readProblem: "pmset -g battlimit failed: exit status 1")

    @Test("No active limit: says what macOS reports, not that the setting is 100% or that macOS holds nothing")
    func noActiveLimit() {
        #expect(MacOSChargeLimitWording.summary(Self.noLimit) == "No active limit reported")
        let text = MacOSChargeLimitWording.guidance(Self.noLimit, ownRestriction: .noneInEffect, isSimulated: false)
        #expect(text.contains("macOS reports no active Charge Limit"))
        #expect(text.contains("does not establish that the setting is 100% or that macOS holds nothing"))
        #expect(text.contains("a temporary full charge may look the same"))
        #expect(text.contains("Optimized Battery Charging or battery health management can hold charging without appearing in this report"))
        #expect(!text.contains("Off (100%)"))
        #expect(!text.contains("nothing competes"))
    }

    @Test("A reported 100% limit is named as such")
    func hundredPercent() {
        #expect(MacOSChargeLimitWording.summary(Self.hundred) == "A 100% limit reported")
        #expect(MacOSChargeLimitWording.guidance(Self.hundred, ownRestriction: .noneInEffect, isSimulated: false).contains("macOS reports a Charge Limit of 100%"))
    }

    @Test("While macOS's limit is on, the text says only what the read-back establishes", arguments: [
        (OwnRestrictionState.noneInEffect, "The last read-back shows no restriction in effect."),
        (.inEffect(.inhibitCharging, own: .inhibitCharging), "The last read-back still shows CellKeeper's inhibitCharging"),
        (.inEffect(.forceDischarge, own: .inhibitCharging), "cannot rule out that it is its own (it asked for inhibitCharging)"),
        (.unexplained(.inhibitCharging), "knows of no request of its own that set it"),
        (.unconfirmed(.forceDischarge), "No read-back has confirmed that CellKeeper's forceDischarge ended, so it may remain."),
        (.unknown, "it cannot confirm that nothing it set remains"),
        (.noneKnown, "knows of no request of its own that could be in effect there"),
        (.notCellKeepers(.inhibitCharging), "set by something other than CellKeeper"),
    ])
    func onWithEachReleaseState(own: OwnRestrictionState, expected: String) {
        for status in [Self.on, Self.unreadable] {
            let text = MacOSChargeLimitWording.guidance(status, ownRestriction: own, isSimulated: false)
            #expect(text.contains(expected))
            #expect(text.contains("withholds new restrictions and asks for the release of any restriction of its own"))
            #expect(!text.contains("never compete"))
            #expect(!text.contains("simulated"))
            let simulated = MacOSChargeLimitWording.guidance(status, ownRestriction: own, isSimulated: true)
            #expect(simulated.contains("These are the simulated helper's controls; your Mac's charging is not changed."))
            #expect(!text.contains("restricts nothing"))
            #expect(!text.contains("released"))
            #expect(text.contains("never changes it itself"))
        }
        #expect(MacOSChargeLimitWording.guidance(Self.on, ownRestriction: own, isSimulated: false).contains("macOS reports its Charge Limit on at 80%"))
        #expect(MacOSChargeLimitWording.guidance(Self.unreadable, ownRestriction: own, isSimulated: false).contains("pmset -g battlimit failed: exit status 1"))
    }

    @Test("The policy's reasons describe a request, not an outcome")
    func reasonsDescribeRequests() {
        for reason in [DecisionReason.macOSChargeLimitActive(limit: 80), .macOSChargeLimitUnknown(problem: "unrecognised report (x)")] {
            let text = reason.description
            #expect(text.contains("withholds new restrictions and asks for the release of any restriction of its own"))
            #expect(!text.contains("never compete"))
            #expect(!text.contains("restricts nothing"))
        }
        #expect(!PolicyNote.dischargeEndedForMacOSChargeLimit.description.contains("does not run the Mac"))
    }

    @Test("Summaries")
    func summaries() {
        #expect(MacOSChargeLimitWording.summary(Self.on) == "On at 80%")
        #expect(MacOSChargeLimitWording.summary(Self.unreadable) == "Could not be read")
    }
}
