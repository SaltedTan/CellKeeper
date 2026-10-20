import Foundation
import ProbeAtomics

/// `watch`'s sleep latch (code review r1 of #101, must 2): a sequence
/// number and the moment of the latest `kIOMessageSystemWillSleep`. The
/// sleep notification only records into it, with no lock it could block on
/// and no I/O, then allows the sleep. The flow reads it at the start of
/// every event, inside the run's lock, so a sleep that came before an
/// answer is always delivered before that answer is accepted.
public final class SleepLatch: @unchecked Sendable {
    /// What a read of the latch saw.
    public struct Snapshot: Sendable, Equatable {
        public var sequence: UInt64
        /// When the latest sleep was recorded, on the run's clock.
        public var time: Double

        public init(sequence: UInt64, time: Double) {
            self.sequence = sequence
            self.time = time
        }

        /// No sleep yet.
        public static let none = Snapshot(sequence: 0, time: 0)
    }

    private let latch: OpaquePointer

    public init() {
        guard let latch = probe_latch_create() else { fatalError("no memory for the sleep latch") }
        self.latch = latch
    }

    deinit {
        probe_latch_destroy(latch)
    }

    /// For the sleep notification: lock-free, no I/O.
    public func record(at time: Double) {
        probe_latch_record(latch, time)
    }

    public var snapshot: Snapshot {
        var time = 0.0
        let sequence = probe_latch_read(latch, &time)
        return Snapshot(sequence: sequence, time: time)
    }
}
