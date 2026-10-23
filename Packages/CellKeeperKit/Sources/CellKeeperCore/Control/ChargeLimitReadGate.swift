import Foundation

/// The power evidence a read of macOS's Charge Limit is judged by (D118,
/// amending D116). The controller makes one before every evaluation and
/// every restore, from its latest reading of the power source and from
/// clocks read just before that reading was taken. The native backend asks
/// it about every read once the read has returned, and judges the read by
/// that answer alone.
///
/// A read is judged only if the evidence brackets it: the condition was
/// ``ChargeLimitReadCondition/settled`` when the gate was made, and when the
/// read has returned the Mac is still on external power (a fresh reading
/// of the power source, taken after the read), the settle time still
/// holds, and the Mac has not slept since the evidence was taken. Evidence
/// taken only before a read says nothing about it: an evaluation started
/// by `NSWorkspace.willSleepNotification` races the sleep, and one frozen
/// in a dark wake resumes later, perhaps unplugged and after macOS cleared
/// its limit (note 08, O20), while the notifications that would say so
/// wait behind it.
///
/// A sleep shows in two monotonic clocks read together: one that counts
/// sleep (`ContinuousClock`) and one that does not (`SuspendingClock`).
/// Awake, they advance together; asleep, only the first does.
///
/// A gate that failed once stays failed, so no later read in the same
/// operation is judged, and the controller starts its settle time again.
public final class ChargeLimitReadGate: @unchecked Sendable {
    /// How much further the clock that counts sleep may have advanced than
    /// the one that does not before the Mac counts as having slept. Awake,
    /// both follow the same hardware counter, so only the moment between
    /// reading one and then the other separates them (microseconds, a
    /// preemption at most). A real sleep lasts longer, and macOS clears its
    /// limit only about 300 s after an unplug (note 08, O20), so a shorter
    /// one cannot matter.
    public static let sleepTolerance: TimeInterval = 1

    /// Two monotonic clocks, read together.
    public struct Clocks: Sendable, Equatable {
        /// Seconds that keep counting while the Mac sleeps.
        public var uptime: TimeInterval
        /// Seconds that stop while the Mac sleeps.
        public var awake: TimeInterval

        public init(uptime: TimeInterval, awake: TimeInterval) {
            self.uptime = uptime
            self.awake = awake
        }

        /// True if the Mac slept between `earlier` and this reading, by
        /// more than ``ChargeLimitReadGate/sleepTolerance``.
        public func hasSlept(since earlier: Clocks) -> Bool {
            (uptime - earlier.uptime) - (awake - earlier.awake) > ChargeLimitReadGate.sleepTolerance
        }
    }

    /// Why a read was not judged although the gate was settled when made.
    public struct Failure: Sendable, Equatable {
        /// What the read was judged by instead, and every later one.
        public var condition: ChargeLimitReadCondition
        /// True if the Mac slept since the evidence was taken.
        public var didSleep: Bool

        public init(condition: ChargeLimitReadCondition, didSleep: Bool) {
            self.condition = condition
            self.didSleep = didSleep
        }
    }

    private struct Evidence: Sendable {
        var clocks: Clocks
        var externalPowerSince: TimeInterval?
        var settleTime: TimeInterval
        var powerSource: @Sendable () async -> PowerSource?
        var readClocks: @Sendable () -> Clocks
    }

    /// The condition when the gate was made.
    public let condition: ChargeLimitReadCondition
    /// Nil for a gate without evidence (``fixed(_:)``).
    private let evidence: Evidence?
    private let lock = NSLock()
    private var _failure: Failure?

    /// - Parameters:
    ///   - condition: the condition from the latest reading.
    ///   - clocks: the clocks, read just before that reading was taken.
    ///   - externalPowerSince: when, on `clocks.uptime`'s clock, external
    ///     power was seen to begin; nil if it was not.
    ///   - settleTime: how long external power must have lasted.
    ///   - powerSource: reads the power source afresh; nil if it cannot.
    ///   - readClocks: reads both clocks now.
    public init(
        condition: ChargeLimitReadCondition,
        clocks: Clocks,
        externalPowerSince: TimeInterval?,
        settleTime: TimeInterval,
        powerSource: @escaping @Sendable () async -> PowerSource?,
        readClocks: @escaping @Sendable () -> Clocks
    ) {
        self.condition = condition
        evidence = Evidence(clocks: clocks, externalPowerSince: externalPowerSince, settleTime: settleTime, powerSource: powerSource, readClocks: readClocks)
    }

    private init(fixed condition: ChargeLimitReadCondition) {
        self.condition = condition
        evidence = nil
    }

    /// A gate without evidence: every read is judged by `condition`. For a
    /// backend used on its own, outside a controller.
    public static func fixed(_ condition: ChargeLimitReadCondition) -> ChargeLimitReadGate {
        ChargeLimitReadGate(fixed: condition)
    }

    /// The first read that was not judged although the gate was settled
    /// when made; nil while there is none.
    public var failure: Failure? {
        lock.withLock { _failure }
    }

    /// Whether a read that has just returned can be judged. Takes the
    /// power source and the clocks afresh, after the read; costs nothing
    /// unless the gate was settled when made.
    public func conditionAfterRead() async -> ChargeLimitReadCondition {
        if let failure { return failure.condition }
        guard condition == .settled, let evidence else { return condition }
        let source = await evidence.powerSource()
        // After the power source, so that the window checked for a sleep
        // ends after everything this answer rests on.
        let now = evidence.readClocks()
        let didSleep = now.hasSlept(since: evidence.clocks)
        let after: ChargeLimitReadCondition
        switch source {
        case .battery?:
            after = .onBattery
        case .externalPower?:
            if !didSleep, let since = evidence.externalPowerSince, now.uptime - since >= evidence.settleTime {
                after = .settled
            } else {
                after = .settling
            }
        case .unknown?, nil:
            after = .powerUnknown
        }
        guard after != .settled else { return .settled }
        return lock.withLock {
            if _failure == nil {
                _failure = Failure(condition: after, didSleep: didSleep)
            }
            return _failure?.condition ?? after
        }
    }
}
