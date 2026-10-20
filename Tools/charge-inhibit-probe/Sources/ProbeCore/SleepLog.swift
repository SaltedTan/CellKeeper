import Foundation
import ProbeAtomics

/// `watch`'s sleep log (code review r1 of #101, must 2; r2, must D): every
/// `kIOMessageSystemWillSleep`'s time, on the run's clock, appended by the
/// sleep notification alone, without a lock it could block on and without
/// I/O, before it allows the sleep. The flow reads it at the start of every
/// event, inside the run's lock, and the end of the run reads it once more
/// after draining the sleep queue (``ManualCutFlow/reconcile(with:drained:)``).
///
/// A snapshot is always a coherent prefix of the log: the writer stores a
/// time and only then publishes the new count (release), and a reader loads
/// the count (acquire) before it reads the times below it. Past
/// ``capacity`` occurrences the log only says it overflowed, which
/// invalidates every confirmation of recovery.
public final class SleepLog: @unchecked Sendable {
    /// What a read of the log saw.
    public struct Snapshot: Sendable, Equatable {
        /// Every occurrence so far, in order.
        public var times: [Double]
        /// Whether a sleep came after the log was full.
        public var overflowed: Bool

        public init(times: [Double], overflowed: Bool = false) {
            self.times = times
            self.overflowed = overflowed
        }

        /// No sleep yet.
        public static let none = Snapshot(times: [])
    }

    public static let capacity = Int(PROBE_LOG_CAPACITY)

    private let log: OpaquePointer

    public init() {
        guard let log = probe_log_create() else { fatalError("no memory for the sleep log") }
        self.log = log
    }

    deinit {
        probe_log_destroy(log)
    }

    /// For the sleep notification, the log's single writer: lock-free, no
    /// I/O.
    public func record(at time: Double) {
        probe_log_append(log, time)
    }

    /// The overflow mark is read first: the writer sets it only after the
    /// log is full, so a snapshot that says it overflowed always holds every
    /// place.
    public var snapshot: Snapshot {
        let overflowed = probe_log_overflowed(log)
        let count = probe_log_count(log)
        let times = (0..<count).map { probe_log_time(log, $0) }
        return Snapshot(times: times, overflowed: overflowed)
    }
}
