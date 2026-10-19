import Foundation

/// The serial queue the system's sleep notifications run on (research note
/// 10 §4). Nothing that runs there may block: no console, no lock the main
/// thread holds across a blocking call, no Foundation file handle. The
/// only exceptions are the private assertion's release, whose retries are
/// bounded, and the report file's one-line append. The main thread waits
/// for this queue when it deregisters from the notifications
/// (``drain(_:)``), so anything that blocked here would stop the run from
/// finishing.
public final class SleepQueue: @unchecked Sendable {
    private static let key = DispatchSpecificKey<Bool>()

    public let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: Self.key, value: true)
    }

    /// Whether the caller runs on a sleep queue.
    public static var isCurrent: Bool {
        DispatchQueue.getSpecific(key: key) == true
    }

    /// Waits until no callback runs on the queue, then runs `body` there.
    /// Never call it from the queue itself.
    public func drain(_ body: () -> Void = {}) {
        queue.sync(execute: body)
    }
}

/// One of the probe's console streams. A write from a sleep queue is never
/// made: it is dropped and counted, so that a console that blocks (a full
/// pipe, a pager that is not reading) can never hold up that queue
/// (``SleepQueue``).
public final class ProbeConsole: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: @Sendable (String) -> Void
    private var dropped = 0

    public init(sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    public func write(_ text: String) {
        guard !SleepQueue.isCurrent else {
            lock.withLock { dropped += 1 }
            return
        }
        sink(text)
    }

    /// How many writes were dropped because they came from a sleep queue.
    public var droppedOnSleepQueue: Int {
        lock.withLock { dropped }
    }
}
