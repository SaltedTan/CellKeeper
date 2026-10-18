import Foundation

/// The monotonic clock a bounded wait is measured on.
public protocol DeadlineClock: Sendable {
    var now: ContinuousClock.Instant { get }
    /// Returns once `deadline` has passed, or earlier if the calling task is
    /// cancelled.
    func sleep(until deadline: ContinuousClock.Instant) async
}

/// `ContinuousClock`, which keeps counting while the Mac sleeps.
public struct SystemDeadlineClock: DeadlineClock {
    public init() {}

    public var now: ContinuousClock.Instant { ContinuousClock.now }

    public func sleep(until deadline: ContinuousClock.Instant) async {
        try? await Task.sleep(until: deadline, clock: .continuous)
    }
}

/// A value that is provided once and can be awaited until an absolute
/// deadline: for a Shortcuts action, the app model once it has started, and
/// the model's first status.
///
/// A waiter gets the value only if it was provided before the waiter's
/// deadline by the clock (recorded when provided, also for a value already
/// there), however late the waiter's timer runs; otherwise, and when its
/// task is cancelled while it waits, it gets nil. Each waiter is resumed
/// once.
///
/// It does not decide whether to act: a value can reach a task that was
/// cancelled in the same main-actor turn, and the task may run later than
/// the deadline. A caller that acts on the value checks cancellation and the
/// clock itself, after its last suspension.
@MainActor
public final class FirstValue<Value: Sendable> {
    public private(set) var value: Value?
    /// When the value was provided, by the clock.
    public private(set) var providedAt: ContinuousClock.Instant?
    private let clock: any DeadlineClock
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiterID = 0

    private struct Waiter {
        var deadline: ContinuousClock.Instant
        var continuation: CheckedContinuation<Value?, Never>
        var timer: Task<Void, Never>?
    }

    public init(clock: any DeadlineClock = SystemDeadlineClock()) {
        self.clock = clock
    }

    /// Provides the value; only the first call counts. Waiters whose
    /// deadline has passed get nil, even if their timer has not fired yet.
    public func provide(_ newValue: Value) {
        guard value == nil else { return }
        let now = clock.now
        value = newValue
        providedAt = now
        for id in Array(waiters.keys) {
            guard let deadline = waiters[id]?.deadline else { continue }
            resume(id, with: now < deadline ? newValue : nil)
        }
    }

    /// The value if it was provided before `deadline`, waiting for it until
    /// then at the latest; nil otherwise, or if the task is cancelled before
    /// it arrives. A value already there is returned without waiting, and
    /// only if it was provided before `deadline`.
    public func value(by deadline: ContinuousClock.Instant) async -> Value? {
        if let value, let providedAt {
            return providedAt < deadline ? value : nil
        }
        guard clock.now < deadline, !Task.isCancelled else { return nil }
        let id = nextWaiterID
        nextWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                // Cancelled meanwhile: nil at once, rather than when the
                // cancellation handler's main-actor task runs.
                if Task.isCancelled {
                    resume(id, with: nil)
                    return
                }
                let clock = clock
                waiters[id]?.timer = Task {
                    await clock.sleep(until: deadline)
                    self.expire(id)
                }
            }
        } onCancel: {
            Task { @MainActor in self.resume(id, with: nil) }
        }
    }

    /// The timer fired: the waiter, if still waiting, gets nil once the clock
    /// shows its deadline passed. A timer that woke early sleeps again.
    private func expire(_ id: Int) {
        guard let deadline = waiters[id]?.deadline else { return }
        guard clock.now >= deadline else {
            let clock = clock
            waiters[id]?.timer = Task {
                await clock.sleep(until: deadline)
                self.expire(id)
            }
            return
        }
        resume(id, with: nil)
    }

    private func resume(_ id: Int, with result: Value?) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer?.cancel()
        waiter.continuation.resume(returning: result)
    }
}
