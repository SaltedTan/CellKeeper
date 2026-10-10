import CellKeeperHelperCore
import Foundation

/// The daemon's time: the engine's monotonic clock and the waits between
/// ticks, polls and deadlines, on the same clock, so tests can drive both.
public protocol HelperDaemonClock: Sendable {
    /// Monotonic seconds that keep counting during sleep (R22). The engine
    /// and the power reading use the same clock.
    func uptime() -> TimeInterval
    /// Waits `seconds` on this clock. Returns early, without an error, if
    /// the calling task is cancelled.
    func sleep(for seconds: TimeInterval) async
}

/// The system's clock: ``HelperEngine/continuousUptime`` (`CLOCK_MONOTONIC`)
/// and `Task.sleep`, which waits on the continuous clock and so also counts
/// sleep.
public struct SystemDaemonClock: HelperDaemonClock {
    public init() {}

    public func uptime() -> TimeInterval {
        HelperEngine.continuousUptime()
    }

    public func sleep(for seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Runs `operation` in a new task and returns its result, unless `seconds`
/// pass on `clock` first: then it returns nil and cancels the task. A
/// cancelled task may keep running, because an engine call cannot be
/// interrupted; the caller only stops waiting for it.
func withDeadline<Value: Sendable>(
    _ seconds: TimeInterval,
    on clock: any HelperDaemonClock,
    _ operation: @escaping @Sendable () async -> Value
) async -> Value? {
    let race = DeadlineRace<Value>()
    return await withCheckedContinuation { continuation in
        race.begin(continuation)
        let work = Task { race.finish(await operation()) }
        let timer = Task {
            await clock.sleep(for: seconds)
            race.finish(nil)
        }
        race.adopt(work, timer)
    }
}

/// The two sides of ``withDeadline(_:on:_:)``: the first to finish resumes
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
