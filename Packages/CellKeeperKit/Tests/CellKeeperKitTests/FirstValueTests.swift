import CellKeeperKit
import Foundation
import Testing

/// A value awaited until an absolute deadline, on a clock the tests move:
/// nothing here depends on how fast tasks run.
@Suite("Bounded wait for a first value", .timeLimit(.minutes(1)))
@MainActor
struct FirstValueTests {
    let clock = ManualDeadlineClock()

    private var deadline: ContinuousClock.Instant { clock.now.advanced(by: .seconds(10)) }

    @Test("A value provided before the wait is returned at once")
    func providedBefore() async {
        let gate = FirstValue<Int>(clock: clock)
        gate.provide(7)
        let value = await gate.value(by: deadline)
        #expect(value == 7)
    }

    @Test("A value provided during the wait, before the deadline, is returned")
    func providedDuring() async {
        let gate = FirstValue<Int>(clock: clock)
        let waiter = Task { await gate.value(by: deadline) }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(9))
        gate.provide(7)
        let value = await waiter.value
        #expect(value == 7)
    }

    @Test("At the deadline the waiter gets nil, and a value provided afterwards does not reach it")
    func deadlineReached() async {
        let gate = FirstValue<Int>(clock: clock)
        let waiter = Task { await gate.value(by: deadline) }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(10))
        let value = await waiter.value
        #expect(value == nil)
        gate.provide(7)
        #expect(gate.value == 7)
    }

    @Test("A value provided after the deadline is refused even though the waiter's timer has not fired")
    func lateValueRefused() async {
        let gate = FirstValue<Int>(clock: clock)
        let waiter = Task { await gate.value(by: deadline) }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(11), waking: false)
        gate.provide(7)
        let value = await waiter.value
        #expect(value == nil)
    }

    @Test("A timer that fires early does not end the wait; the value still arrives")
    func earlyTimer() async {
        let gate = FirstValue<Int>(clock: clock)
        let waiter = Task { await gate.value(by: deadline) }
        await clock.waitForSleeps(1)
        clock.wakeAllEarly()
        // The waiter sleeps again until its deadline.
        await clock.waitForSleeps(2)
        gate.provide(7)
        let value = await waiter.value
        #expect(value == 7)
    }

    @Test("A cancelled waiter gets nil once, and the value provided later is kept for others")
    func cancelled() async {
        let gate = FirstValue<Int>(clock: clock)
        let waiter = Task { await gate.value(by: deadline) }
        await clock.waitForSleeps(1)
        waiter.cancel()
        let value = await waiter.value
        #expect(value == nil)
        gate.provide(7)
        let later = await gate.value(by: deadline)
        #expect(later == 7)
    }

    @Test("A task cancelled before it waits gets nil without waiting")
    func cancelledBefore() async {
        let gate = FirstValue<Int>(clock: clock)
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.value(by: deadline)
        }
        let value = await waiter.value
        #expect(value == nil)
    }

    @Test("A value already there that was provided after the deadline is refused")
    func cachedValueProvidedLate() async {
        let gate = FirstValue<Int>(clock: clock)
        let deadline = clock.now.advanced(by: .seconds(10))
        clock.advance(by: .seconds(11))
        gate.provide(7)
        let value = await gate.value(by: deadline)
        #expect(value == nil)
        let later = await gate.value(by: clock.now.advanced(by: .seconds(1)))
        #expect(later == 7)
    }

    @Test("A value already there that was provided before the deadline is returned even once the clock has passed it: acting on it is the caller's decision")
    func cachedValueProvidedInTime() async {
        let gate = FirstValue<Int>(clock: clock)
        let deadline = clock.now.advanced(by: .seconds(10))
        gate.provide(7)
        clock.advance(by: .seconds(11))
        let value = await gate.value(by: deadline)
        #expect(value == 7)
        #expect(gate.providedAt != nil)
    }

    @Test("A deadline already passed gives nil without waiting")
    func deadlinePassed() async {
        let gate = FirstValue<Int>(clock: clock)
        let value = await gate.value(by: clock.now)
        #expect(value == nil)
    }

    @Test("Several waiters: those whose deadline has not passed get the value, the others nil")
    func severalWaiters() async {
        let gate = FirstValue<Int>(clock: clock)
        let short = clock.now.advanced(by: .seconds(2))
        let long = clock.now.advanced(by: .seconds(10))
        let early = Task { await gate.value(by: short) }
        await clock.waitForSleeps(1)
        let late = Task { await gate.value(by: long) }
        await clock.waitForSleeps(2)
        clock.advance(by: .seconds(5), waking: false)
        gate.provide(7)
        let earlyValue = await early.value
        let lateValue = await late.value
        #expect(earlyValue == nil)
        #expect(lateValue == 7)
    }

    @Test("Only the first value counts")
    func firstOnly() {
        let gate = FirstValue<Int>(clock: clock)
        gate.provide(1)
        gate.provide(2)
        #expect(gate.value == 1)
    }
}
