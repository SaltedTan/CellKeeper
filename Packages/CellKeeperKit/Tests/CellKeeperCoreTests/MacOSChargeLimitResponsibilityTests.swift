@testable import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// macOS's Charge Limit report whose first read waits until it is
/// cancelled; later reads report 85%.
final class FirstReadWaitsForCancellation: ChargeLimitReading, @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0

    var reads: Int {
        lock.withLock { readCount }
    }

    func readChargeLimit() async throws -> NativeChargeLimitReading {
        let number = lock.withLock {
            readCount += 1
            return readCount
        }
        if number == 1 {
            try await Task.sleep(for: .seconds(3600))
        }
        return .limit(85)
    }
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
        let reader = FirstReadWaitsForCancellation()
        let monitor = MacOSChargeLimitMonitor(reader: reader, now: { clock.now }, uptime: { clock.uptime })
        let cancelled = Task { await monitor.status() }
        for _ in 0..<1_000 where reader.reads < 1 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let survivor = Task { await monitor.status() }
        try await Task.sleep(for: .milliseconds(20))
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
}
