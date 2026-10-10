import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper engine: executor")
struct HelperEngineExecutorTests {
    @Test("A control that blocks holds the engine's own thread, never one of Swift's cooperative pool")
    func blockedControlLeavesPoolFree() async {
        // More blocked engines than the cooperative pool has threads.
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let clock = HelperTestClock()
        let controls = (0..<count).map { _ in BlockingReadBackControl() }
        let engines = controls.map { control in
            HelperEngine(control: control, power: StubPowerReading(clock: clock), build: 1, uptime: { clock.uptime }, events: { _ in })
        }
        let starts = engines.map { engine in Task { await engine.start() } }

        // Every engine is blocked in its start-up read-back at the same time ...
        let allBlocked = await poll { controls.allSatisfy(\.isBlocked) }
        #expect(allBlocked)
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

        for control in controls {
            control.release()
        }
        for start in starts {
            _ = await start.value
        }
    }
}

/// Waits, in real time and for at most 3 s, until `condition` holds.
private func poll(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// A control whose first read-back blocks its caller's thread until the test
/// releases it, or for 5 s at the latest, as a hung hardware call would.
final class BlockingReadBackControl: HelperChargeControl, @unchecked Sendable {
    private let inner = SimulatedChargeControl()
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var hasBlocked = false
    private var blocked = false

    var isBlocked: Bool {
        lock.withLock { blocked }
    }

    func release() {
        released.signal()
    }

    func probe() -> HelperProbe {
        inner.probe()
    }

    func apply(_ control: HelperControl, active: Bool) throws {
        try inner.apply(control, active: active)
    }

    func readBack() throws -> Set<HelperControl> {
        let blocks = lock.withLock { () -> Bool in
            defer { hasBlocked = true }
            blocked = !hasBlocked
            return !hasBlocked
        }
        if blocks {
            _ = released.wait(timeout: .now() + 5)
            lock.withLock { blocked = false }
        }
        return try inner.readBack()
    }

    func restoreDefaults() throws {
        try inner.restoreDefaults()
    }
}
