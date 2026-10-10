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

        // Log writers whose log blocks on the first line.
        let logs = (0..<count).map { _ in RecordingLog() }
        let queues = logs.map { _ in DaemonEventQueue() }
        for (log, queue) in zip(logs, queues) {
            log.block()
            let writer = DaemonEventWriter(log: log, engine: engine, store: InMemoryHistoryStore(), boot: nil)
            Task { await writer.pump(queue.items) }
            queue.log(.notice, .lifecycle, "held")
        }
        // Seam calls that block.
        let seam = DispatchSemaphore(value: 0)
        let calls = (0..<count).map { _ in
            Task { await HelperDaemon.blocking { _ = seam.wait(timeout: .now() + 10) } }
        }

        // Every log write is blocked at the same time ...
        let blocked = await eventually { logs.allSatisfy(\.isWaiting) }
        #expect(blocked)
        // ... and work on the cooperative pool still runs at once.
        let began = ContinuousClock.now
        let sum = await withTaskGroup(of: Int.self) { group in
            for value in 1...200 {
                group.addTask {
                    await Task.yield()
                    return value
                }
            }
            return await group.reduce(0, +)
        }
        #expect(sum == 20_100)
        #expect(ContinuousClock.now - began < .seconds(2))

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
