import CellKeeperHelperCore
import Foundation

/// The daemon's time: the engine's monotonic clock and the waits between
/// ticks, polls and deadlines, on the same clock, so tests can drive both.
///
/// Waits are expressed as absolute deadlines on ``uptime()``: time that
/// passes before a wait actually starts (a task scheduled late) is taken
/// from the wait, never added to it.
public protocol HelperDaemonClock: Sendable {
    /// Monotonic seconds that keep counting during sleep (R22). The engine
    /// and the power reading use the same clock.
    func uptime() -> TimeInterval
    /// Waits until ``uptime()`` reaches `deadline`; returns at once if it
    /// already has. Returns early, without an error, if the calling task is
    /// cancelled. Deadlines use this.
    func sleep(until deadline: TimeInterval) async
    /// Waits `seconds` from when it is called, for periodic work (ticks,
    /// retries), never for a deadline.
    func sleep(for seconds: TimeInterval) async
}

extension HelperDaemonClock {
    public func sleep(for seconds: TimeInterval) async {
        await sleep(until: uptime() + seconds)
    }
}

/// One absolute deadline on the daemon's clock, carried to whatever it
/// bounds, so that every wait under it ends at the same instant however
/// late it starts.
public struct HelperDaemonDeadline: Sendable {
    /// The instant, in seconds of the clock's ``HelperDaemonClock/uptime()``.
    public let uptime: TimeInterval
    private let clock: any HelperDaemonClock

    public init(uptime: TimeInterval, on clock: any HelperDaemonClock) {
        self.uptime = uptime
        self.clock = clock
    }

    /// Whether the clock has reached the deadline.
    public var hasPassed: Bool {
        clock.uptime() >= uptime
    }

    /// Returns once the clock has reached the deadline (at once if it has),
    /// or earlier if the calling task is cancelled.
    public func wait() async {
        await clock.sleep(until: uptime)
    }
}

/// The system's clock: ``HelperEngine/continuousUptime`` (`CLOCK_MONOTONIC`)
/// and `Task.sleep` on the continuous clock, which also counts sleep.
public struct SystemDaemonClock: HelperDaemonClock {
    public init() {}

    public func uptime() -> TimeInterval {
        HelperEngine.continuousUptime()
    }

    public func sleep(until deadline: TimeInterval) async {
        // What is left is computed now, when the wait starts, and the wait
        // ends at an absolute instant of the continuous clock.
        let remaining = deadline - uptime()
        guard remaining > 0 else { return }
        try? await Task.sleep(until: .now + .seconds(remaining), clock: .continuous)
    }
}

/// Runs `operation` in a new task and returns its result, unless `deadline`
/// on `clock`'s uptime comes first: then it returns nil and cancels the
/// task. A cancelled task may keep running, because an engine call cannot
/// be interrupted; the caller only stops waiting for it.
///
/// The deadline is absolute: with no time left, the operation is not
/// started; the timer waits for what is left when it starts, however late
/// that is; and a result that arrives after the deadline is not used.
func withDeadline<Value: Sendable>(
    at deadline: TimeInterval,
    on clock: any HelperDaemonClock,
    _ operation: @escaping @Sendable () async -> Value
) async -> Value? {
    guard clock.uptime() < deadline else { return nil }
    let race = DeadlineRace<Value>()
    return await withCheckedContinuation { continuation in
        race.begin(continuation)
        let work = Task {
            let value = await operation()
            race.finish(clock.uptime() <= deadline ? value : nil)
        }
        let timer = Task {
            await clock.sleep(until: deadline)
            race.finish(nil)
        }
        race.adopt(work, timer)
    }
}

/// ``withDeadline(at:on:_:)`` with the deadline `seconds` from now.
func withDeadline<Value: Sendable>(
    _ seconds: TimeInterval,
    on clock: any HelperDaemonClock,
    _ operation: @escaping @Sendable () async -> Value
) async -> Value? {
    await withDeadline(at: clock.uptime() + seconds, on: clock, operation)
}

/// The two sides of ``withDeadline(at:on:_:)``: the first to finish resumes
/// the caller, and both tasks are then cancelled.
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var isFinished = false
    private var tasks: [Task<Void, Never>] = []

    func begin(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func adopt(_ work: Task<Void, Never>, _ timer: Task<Void, Never>) {
        let cancelNow = lock.withLock {
            tasks = [work, timer]
            return isFinished
        }
        if cancelNow {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ value: Value?) {
        let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<Value?, Never>?, [Task<Void, Never>]) in
            guard !isFinished else { return (nil, []) }
            isFinished = true
            defer { self.continuation = nil }
            return (self.continuation, self.tasks)
        }
        continuation?.resume(returning: value)
        for task in tasks {
            task.cancel()
        }
    }
}
