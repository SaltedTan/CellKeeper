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
/// holds, the Mac has not slept since the evidence was taken, and no more
/// than ``maximumSpan`` has passed since then. A read that has failed is
/// asked about too. Evidence taken only before a read says nothing about
/// it: an evaluation started by `NSWorkspace.willSleepNotification` races
/// the sleep, and one frozen in a dark wake resumes later, perhaps
/// unplugged and after macOS cleared its limit (note 08, O20), while the
/// notifications that would say so wait behind it.
///
/// The two ends of the bracket do not show that the Mac stayed on power in
/// between: it may have been unplugged and plugged in again, awake, while
/// the operation waited. What makes a judged read safe is the time macOS
/// takes. It clears its active limit only after the Mac has been off power
/// for about 300 s, and creates it again within about 0.1 s of a plug-in
/// (note 08, O20), so a cleared limit read on AC power needs an unplug of
/// at least 300 s that ended just before the read. That cannot fit inside
/// a bracket of at most ``maximumSpan``, and the controller starts its
/// settle time again when more than ``maximumSpan`` passes between two of
/// its readings of the power source, so it cannot fit between readings
/// either: one of them shows battery power, or the gap itself starts the
/// settle time again, and the read waits until the Mac has been on power
/// for the settle time. So that checks App Nap delays cannot keep that
/// time from ever ending, the app keeps itself from being napped while a
/// read waits for it, and checks again as it ends
/// (``ChargeLimitSettleWatch``).
///
/// A sleep shows in two monotonic clocks read together: one that counts
/// sleep (`ContinuousClock`) and one that does not (`SuspendingClock`).
/// Awake, they advance together; asleep, only the first does. A sleep needs
/// the same 300 s off power to matter, but a wake is where macOS may create
/// its limit again (D116), so a sleep fails the gate whatever its length.
///
/// A gate that failed once stays failed, so no later read in the same
/// operation is judged, and the controller starts its settle time again.
public final class ChargeLimitReadGate: @unchecked Sendable {
    /// The longest power evidence may span, on the clock that counts sleep:
    /// from the clocks read before the reading of the power source a gate
    /// is made from to the fresh reading after a read, and between two
    /// readings the controller takes before it starts its settle time
    /// again. Well under the 300 s off power after which macOS clears its
    /// limit (note 08, O20), so no unplug that long fits inside it; well
    /// over the 60 s between periodic checks and the time an operation's
    /// reads and requests take, so an ordinary check is never refused.
    /// Exactly this long still counts.
    public static let maximumSpan: TimeInterval = 120

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

        /// True if more than ``ChargeLimitReadGate/maximumSpan`` passed
        /// between `earlier` and this reading, asleep or awake.
        public func exceedsMaximumSpan(since earlier: Clocks) -> Bool {
            uptime - earlier.uptime > ChargeLimitReadGate.maximumSpan
        }
    }

    /// Why a read was not judged although the gate was settled when made.
    public struct Failure: Sendable, Equatable {
        /// What the read was judged by instead, and every later one.
        public var condition: ChargeLimitReadCondition
        /// True if the Mac slept since the evidence was taken.
        public var didSleep: Bool
        /// True if the read returned more than ``ChargeLimitReadGate/maximumSpan``
        /// after the evidence was taken.
        public var isTooLate: Bool

        public init(condition: ChargeLimitReadCondition, didSleep: Bool, isTooLate: Bool = false) {
            self.condition = condition
            self.didSleep = didSleep
            self.isTooLate = isTooLate
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

    /// Whether a read that has just returned, with a report or an error,
    /// can be judged. Takes the power source and the clocks afresh, after
    /// the read; costs nothing unless the gate was settled when made.
    public func conditionAfterRead() async -> ChargeLimitReadCondition {
        if let failure { return failure.condition }
        guard condition == .settled, let evidence else { return condition }
        let source = await evidence.powerSource()
        // After the power source, so that the window checked for a sleep
        // and the span end after everything this answer rests on.
        let now = evidence.readClocks()
        let didSleep = now.hasSlept(since: evidence.clocks)
        let isTooLate = now.exceedsMaximumSpan(since: evidence.clocks)
        let after: ChargeLimitReadCondition
        switch source {
        case .battery?:
            after = .onBattery
        case .externalPower?:
            if !didSleep, !isTooLate, let since = evidence.externalPowerSince, now.uptime - since >= evidence.settleTime {
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
                _failure = Failure(condition: after, didSleep: didSleep, isTooLate: isTooLate)
            }
            return _failure?.condition ?? after
        }
    }
}
