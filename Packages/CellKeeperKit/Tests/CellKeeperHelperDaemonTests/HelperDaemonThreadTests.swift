@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper daemon: threads")
struct HelperDaemonThreadTests {
    @Test("A log that blocks and seam calls that block hold threads of their own, never ones of Swift's cooperative pool")
    func blockingWorkLeavesPoolFree() async {
        // More of each than the cooperative pool has threads.
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let clock = ManualClock()
        let engine = HelperEngine(control: SimulatedChargeControl(), power: StubPower(clock: clock), build: 1, uptime: { clock.uptime() }, events: { _ in })

        // Log writers whose log blocks on the first line. Like the seam
        // calls below, a write gives up only after 30 s, so a failing test
        // cannot hang the run.
        let logs = (0..<count).map { _ in RecordingLog() }
        let queues = logs.map { _ in DaemonEventQueue() }
        for (log, queue) in zip(logs, queues) {
            log.block(limit: 30)
            let writer = DaemonEventWriter(log: log, engine: engine, store: InMemoryHistoryStore(), boot: nil)
            Task { await writer.pump(queue.items) }
            queue.log(.notice, .lifecycle, "held")
        }
        // Seam calls that block; each counts itself in before it does, and
        // out once it no longer does.
        let seam = DispatchSemaphore(value: 0)
        let entered = EntryCounter()
        let left = EntryCounter()
        let calls = (0..<count).map { _ in
            Task {
                await HelperDaemon.blocking {
                    entered.increment()
                    _ = seam.wait(timeout: .now() + 30)
                    left.increment()
                }
            }
        }

        // Every log write and every seam call is blocked at the same time ...
        let blocked = await eventually { logs.allSatisfy(\.isWaiting) && entered.count == count }
        #expect(blocked)
        // ... and work on the cooperative pool still runs while they are:
        // when it has ended, every one is still blocked. Writes and calls
        // that held pool threads would leave it to run only once they gave
        // up, 30 s after blocking.
        let sum = await withTaskGroup(of: Int.self) { group in
            for value in 1...200 {
                group.addTask {
                    await Task.yield()
                    return value
                }
            }
            return await group.reduce(0, +)
        }
        let stillBlocked = logs.allSatisfy(\.isWaiting) && left.count == 0
        #expect(sum == 20_100)
        #expect(stillBlocked)

        for log in logs {
            log.release()
        }
        for _ in calls {
            seam.signal()
        }
        for call in calls {
            await call.value
        }
        for queue in queues {
            queue.finish()
        }
    }
}

/// Counts entries from any thread.
final class EntryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = 0

    var count: Int {
        lock.withLock { entries }
    }

    func increment() {
        lock.withLock { entries += 1 }
    }
}
