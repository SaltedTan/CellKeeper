import Foundation
import ProbeAtomics

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
/// dropped for being too many. Sample lines (``Kind/sample``) are
/// coalesced: while more than ``maximumQueuedSamples`` wait, the oldest is
/// dropped and counted (``droppedSampleLines``); the report keeps every
/// reading.
///
/// An actionable message carries the question generation it belongs to
/// (code review r2 of #101, must B). The run publishes its current
/// generation (``setCurrentGeneration(_:)``), which the writer reads
/// without the run's lock, and right before it writes an actionable
/// message it drops it if that generation is no longer current: a prompt
/// that a sleep, a timeout or an answer superseded while the terminal held
/// output back never appears after the text that superseded it.
public final class ConsoleWriter: @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        case essential
        case sample
    }

    /// What became of a message.
    public enum Result: Sendable, Equatable {
        /// The sink wrote all of it.
        case written
        /// It was not written: its generation was no longer current.
        case superseded
        /// The sink could not write all of it: the terminal is unusable.
        case failed
    }

    struct Message {
        var id: UInt64
        var text: String
        var kind: Kind
        var generation: UInt64?
        var onWritten: (@Sendable (Result) -> Void)?
    }

    /// Sample lines that may wait at once; more, and the oldest is dropped.
    public let maximumQueuedSamples: Int
    private let condition = NSCondition()
    private var queue: [Message] = []
    private var lastID: UInt64 = 0
    /// The message the sink is writing now, if any.
    private var inFlight: UInt64?
    private var dropped = 0
    private var superseded = 0
    private let current: OpaquePointer
    private let sink: @Sendable (String) -> Bool

    /// Starts the writer thread. `sink` writes one message (with its
    /// newline) to the terminal and returns whether it wrote all of it; it
    /// runs only on the writer thread.
    public init(maximumQueuedSamples: Int = 3, sink: @escaping @Sendable (String) -> Bool) {
        self.maximumQueuedSamples = maximumQueuedSamples
        self.sink = sink
        guard let current = probe_value_create() else { fatalError("no memory for the console's generation") }
        self.current = current
        // The thread keeps its writer for the life of the process.
        let thread = Thread { self.writeForever() }
        thread.name = "charge-inhibit-probe.console"
        thread.start()
    }

    /// Publishes the run's current question generation, for the writer to
    /// compare actionable messages with. Lock-free.
    public func setCurrentGeneration(_ generation: UInt64) {
        probe_value_store(current, generation)
    }

    /// Queues `text` and returns at once; never waits for the terminal.
    /// `generation`: the question generation an actionable message belongs
    /// to; nil for a message that is always written. `onWritten` runs on the
    /// writer thread once the message is written, superseded or failed.
    /// Returns the message's number.
    @discardableResult
    public func enqueue(
        _ text: String,
        kind: Kind = .essential,
        generation: UInt64? = nil,
        onWritten: (@Sendable (Result) -> Void)? = nil
    ) -> UInt64 {
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
        queue.append(Message(id: lastID, text: text, kind: kind, generation: generation, onWritten: onWritten))
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

    /// How many actionable messages were dropped as superseded.
    public var supersededMessages: Int {
        condition.withLock { superseded }
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
            // Right before writing: an actionable message whose generation
            // is no longer current is dropped.
            if let generation = message.generation, generation != probe_value_load(current) {
                superseded += 1
                condition.broadcast()
                condition.unlock()
                message.onWritten?(.superseded)
                continue
            }
            inFlight = message.id
            condition.unlock()

            let wrote = sink(message.text)

            condition.lock()
            inFlight = nil
            condition.broadcast()
            condition.unlock()
            message.onWritten?(wrote ? .written : .failed)
        }
    }
}
