import CellKeeperCore
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
        for _ in 0..<1_000 where reader.reads < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(reader.reads == 2)
        // The cached "no limit" is fresh, but a read is under way.
        let concurrent = Task { await monitor.status() }
        try await Task.sleep(for: .milliseconds(20))
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
        try? await Task.sleep(for: .milliseconds(20))
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
        try? await Task.sleep(for: .milliseconds(20))
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
