import CellKeeperHelperCore
import Foundation

/// Hands the engine's events and the daemon's own log lines to one task,
/// in order. The engine delivers its events synchronously, before each call
/// returns, so its sink only enqueues here and returns at once; logging and
/// saving the activation history happen on that task.
final class DaemonEventQueue: Sendable {
    enum Item: Sendable {
        case event(HelperEvent)
        case log(HelperLogLevel, HelperLogCategory, String)
        /// Resumed once every item before it has been handled.
        case flush(CheckedContinuation<Void, Never>)
    }

    let items: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation

    init() {
        (items, continuation) = AsyncStream.makeStream(of: Item.self)
    }

    /// The engine's event sink.
    func event(_ event: HelperEvent) {
        enqueue(.event(event))
    }

    func log(_ level: HelperLogLevel, _ category: HelperLogCategory, _ message: String) {
        enqueue(.log(level, category, message))
    }

    /// Returns once everything enqueued before has been handled, or at once
    /// if the queue has finished.
    func flush() async {
        await withCheckedContinuation { enqueue(.flush($0)) }
    }

    /// Ends the queue: the task handles what is left and then ends.
    func finish() {
        continuation.finish()
    }

    private func enqueue(_ item: Item) {
        if case .terminated = continuation.yield(item), case .flush(let waiter) = item {
            waiter.resume()
        }
    }
}
