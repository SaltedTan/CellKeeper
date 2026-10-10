@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper daemon: absolute deadlines")
struct HelperDaemonDeadlineTests {
    @Test("A deadline's timer that starts late still ends at the original deadline")
    func lateTimer() async {
        let clock = ManualClock()
        let deadline = clock.uptime() + HelperDaemon.terminationDeadline
        // The timer's task starts 3 s late.
        clock.beforeNextSleep { clock.advance(by: 3) }
        let never = Gate()
        let finished = Flag()
        let result = Task {
            let value = await withDeadline(at: deadline, on: clock) { await never.wait(); return 1 }
            finished.set(true)
            return value
        }

        // 5 s are left, not 8.
        let waiting = await eventually { clock.waits.count == 1 && clock.waits.contains(4.999...5) }
        #expect(waiting)
        clock.advance(by: 5)
        let timedOut = await eventually { finished.value }
        #expect(timedOut)
        if !timedOut {
            clock.advance(by: 10)
        }
        #expect(await result.value == nil)
        never.open()
    }

    @Test("A relative deadline is fixed when it is set, not when its timer starts")
    func lateRelativeTimer() async {
        let clock = ManualClock()
        clock.beforeNextSleep { clock.advance(by: 3) }
        let never = Gate()
        let finished = Flag()
        let result = Task {
            let value = await withDeadline(HelperDaemon.terminationDeadline, on: clock) { await never.wait(); return 1 }
            finished.set(true)
            return value
        }
        let waiting = await eventually { clock.waits.count == 1 && clock.waits.contains(4.999...5) }
        #expect(waiting)
        clock.advance(by: 5)
        let timedOut = await eventually { finished.value }
        #expect(timedOut)
        if !timedOut {
            clock.advance(by: 10)
        }
        #expect(await result.value == nil)
        never.open()
    }

    @Test("With no time left, the operation is not started")
    func expired() async {
        let clock = ManualClock()
        let deadline = clock.uptime()
        let ran = Flag()
        let value = await withDeadline(at: deadline, on: clock) { () -> Int in
            ran.set(true)
            return 1
        }
        #expect(value == nil)
        #expect(!ran.value)
    }

    @Test("An operation that finishes in time returns its result and cancels the timer")
    func inTime() async {
        let clock = ManualClock()
        let value = await withDeadline(1, on: clock) { 42 }
        #expect(value == 42)
        let cancelled = await eventually { clock.waits.isEmpty }
        #expect(cancelled)
    }
}

/// An operation's end, opened by the test.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let openNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if openNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting {
            waiter.resume()
        }
    }
}
