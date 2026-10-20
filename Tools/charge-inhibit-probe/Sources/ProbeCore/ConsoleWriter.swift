import Foundation

/// The one owner of `watch`'s console (code review r1 of #101, must 1).
/// Everyone else enqueues messages, which takes a lock held only for a
/// queue operation, and never waits for the terminal: a writer thread takes
/// them in order and hands each to `sink`, which may block on a terminal
/// that is not reading. Nothing that holds the run's lock, nor the
/// reminder, the signal handlers, the sleep notification or the teardown,
/// ever waits on the writer; only the end of the run waits, with a bound
/// (``drain(timeout:)``).
///
/// Prompts, banners and recovery text (``Kind/essential``) are never
/// dropped. Sample lines (``Kind/sample``) are coalesced: while more than
/// ``maximumQueuedSamples`` wait, the oldest is dropped and counted
/// (``droppedSampleLines``); the report keeps every reading.
public final class ConsoleWriter: @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        case essential
        case sample
    }

    struct Message {
        var id: UInt64
        var text: String
        var kind: Kind
        var onWritten: (@Sendable () -> Void)?
    }

    /// Sample lines that may wait at once; more, and the oldest is dropped.
    public let maximumQueuedSamples: Int
    private let condition = NSCondition()
    private var queue: [Message] = []
    private var lastID: UInt64 = 0
    /// The message the sink is writing now, if any.
    private var inFlight: UInt64?
    private var dropped = 0
    private let sink: @Sendable (String) -> Void

    /// Starts the writer thread. `sink` writes one message (with its
    /// newline) to the terminal; it runs only on the writer thread.
    public init(maximumQueuedSamples: Int = 3, sink: @escaping @Sendable (String) -> Void) {
        self.maximumQueuedSamples = maximumQueuedSamples
        self.sink = sink
        // The thread keeps its writer for the life of the process.
        let thread = Thread { self.writeForever() }
        thread.name = "charge-inhibit-probe.console"
        thread.start()
    }

    /// Queues `text` and returns at once; never waits for the terminal.
    /// `onWritten` runs on the writer thread once the sink has returned for
    /// this message. Returns the message's number.
    @discardableResult
    public func enqueue(_ text: String, kind: Kind = .essential, onWritten: (@Sendable () -> Void)? = nil) -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        if kind == .sample {
            while queue.filter({ $0.kind == .sample }).count >= maximumQueuedSamples,
                  let oldest = queue.firstIndex(where: { $0.kind == .sample }) {
                queue.remove(at: oldest)
                dropped += 1
            }
        }
        lastID += 1
        queue.append(Message(id: lastID, text: text, kind: kind, onWritten: onWritten))
        condition.broadcast()
        return lastID
    }

    /// Waits until message `id`, and every one before it, is written or
    /// dropped, or `timeout` seconds pass; returns whether it was. Only the
    /// end of the run calls this.
    public func waitUntilWritten(_ id: UInt64, timeout: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isDone(id) {
            guard condition.wait(until: deadline) else { return isDone(id) }
        }
        return true
    }

    /// Waits until everything queued so far is written, at most `timeout`
    /// seconds; returns whether it was.
    public func drain(timeout: Double) -> Bool {
        let last = condition.withLock { lastID }
        return waitUntilWritten(last, timeout: timeout)
    }

    /// How many sample lines were dropped from the console.
    public var droppedSampleLines: Int {
        condition.withLock { dropped }
    }

    /// Whether nothing waits and nothing is being written.
    public var isIdle: Bool {
        condition.withLock { queue.isEmpty && inFlight == nil }
    }

    /// Whether message `id` and every one before it are written or
    /// dropped. Called with the condition's lock held.
    private func isDone(_ id: UInt64) -> Bool {
        !queue.contains { $0.id <= id } && (inFlight.map { $0 > id } ?? true)
    }

    private func writeForever() {
        while true {
            condition.lock()
            while queue.isEmpty {
                condition.wait()
            }
            let message = queue.removeFirst()
            inFlight = message.id
            condition.unlock()

            sink(message.text)

            condition.lock()
            inFlight = nil
            condition.broadcast()
            condition.unlock()
            message.onWritten?()
        }
    }
}
