import Foundation

/// When the app checks macOS's Charge Limit again while a read waits for
/// power to settle, and whether it keeps itself from being napped meanwhile
/// (D118). Pure: the app gives it every status and every deadline it asked
/// for, on the controller's monotonic clock
/// (``ChargeController/monotonicNow``), and does what it says.
///
/// The controller starts its settle time again when more than
/// ``ChargeLimitReadGate/maximumSpan`` passes between two of its readings of
/// the power source, since an unplug long enough for macOS to clear its
/// limit could have fitted between them unseen. CellKeeper is a menu-bar
/// app, and App Nap may delay its periodic check, and the delivery of power
/// notifications, beyond that: the settle time could then start again at
/// every check, and no read would be judged, so an outside change would
/// never be kept, a value written never confirmed, a calibration stalled.
/// So while a read waits for the settle time
/// (``ControllerStatus/chargeLimitJudgmentDue``), the app holds
/// ``ChargeLimitSettleActivity``, so that macOS does not nap it, and checks
/// once more ``margin`` after the settle time ends, rather than at the next
/// periodic check.
///
/// An episode begins with the first status that waits. It ends with the
/// first that does not (a read judged, battery power, the power source
/// unknown, Manage charging off with nothing owed), at sleep and at quit
/// (``stop()``), and in any case ``cap`` after it began. Settling is a state
/// of AC power only, so the activity is never held on battery power.
public struct ChargeLimitSettleWatch: Sendable, Equatable {
    /// The longest an episode keeps the app from being napped. The settle
    /// time is a minute and the follow-up check comes a second after it,
    /// so an episode ends after about a minute, unless the settle time
    /// starts again meanwhile (a sleep the app was not told of, checks
    /// further apart than ``ChargeLimitReadGate/maximumSpan`` despite the
    /// activity) or a check takes long (a shortcut may run for 20 s per
    /// request). Five settle times leave room for that, and bound what a
    /// wait that does not end costs: no more than five minutes per episode,
    /// on AC power. A wait that outlasts it holds no activity until it ends
    /// or the Mac sleeps.
    public static let cap: TimeInterval = 5 * 60
    /// How long after the settle time ends the follow-up check is due, so
    /// that its reading of the power source comes after the end.
    public static let margin: TimeInterval = 1

    /// When the episode began, on the controller's clock; nil outside one.
    public private(set) var heldSince: TimeInterval?
    /// The end of the settle time the pending follow-up check is for.
    private var pendingEnd: TimeInterval?
    /// The end of the settle time the last follow-up check was for: never
    /// followed up twice.
    private var lastEnd: TimeInterval?
    /// True once ``cap`` ended an episode whose wait went on: no other
    /// begins until the wait ends or the Mac sleeps.
    private var isCapped = false

    public init() {}

    /// True while the app should hold ``ChargeLimitSettleActivity``.
    public var isHoldingActivity: Bool {
        heldSince != nil
    }

    /// When the follow-up check is due, on the controller's clock; nil
    /// while none is pending. There is never more than one.
    public var followUpAt: TimeInterval? {
        pendingEnd.map { $0 + Self.margin }
    }

    /// When the app must next call ``deadlineReached(at:)``: the follow-up
    /// check, or the end of the episode's ``cap`` if that comes first; nil
    /// outside an episode.
    public var nextDeadline: TimeInterval? {
        guard let heldSince else { return nil }
        let capEnd = heldSince + Self.cap
        guard let followUpAt else { return capEnd }
        return min(followUpAt, capEnd)
    }

    /// Takes in a status the app received at `now`: `due` is its
    /// ``ControllerStatus/chargeLimitJudgmentDue``. A newer end of the
    /// settle time replaces the pending follow-up check; nil ends the
    /// episode.
    public mutating func observe(judgmentDue due: TimeInterval?, at now: TimeInterval) {
        guard let due else {
            self = ChargeLimitSettleWatch()
            return
        }
        if heldSince == nil, !isCapped {
            heldSince = now
        }
        guard let heldSince else { return }
        guard now < heldSince + Self.cap else {
            endAtCap()
            return
        }
        pendingEnd = due == lastEnd ? nil : due
    }

    /// At ``nextDeadline``: true if the follow-up check is due, which the
    /// app then runs; the episode ends here if its ``cap`` has passed.
    public mutating func deadlineReached(at now: TimeInterval) -> Bool {
        guard let heldSince else { return false }
        guard now < heldSince + Self.cap else {
            endAtCap()
            return false
        }
        guard let end = pendingEnd, now >= end + Self.margin else { return false }
        lastEnd = end
        pendingEnd = nil
        return true
    }

    /// At sleep and at quit: no activity and no follow-up check. A wake
    /// starts the settle time again, and the status after it a new episode.
    public mutating func stop() {
        self = ChargeLimitSettleWatch()
    }

    private mutating func endAtCap() {
        heldSince = nil
        pendingEnd = nil
        isCapped = true
    }
}

/// A `ProcessInfo` activity held while a read of macOS's Charge Limit waits
/// for power to settle (``ChargeLimitSettleWatch``, D118): macOS does not nap
/// the app, so its checks come on time, but may still put an idle Mac to
/// sleep (`userInitiatedAllowingIdleSystemSleep`).
public final class ChargeLimitSettleActivity: @unchecked Sendable {
    public static let reason = "CellKeeper checks macOS's Charge Limit once power has settled"

    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?

    public init() {}

    deinit {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    /// True while the activity is held.
    public var isActive: Bool {
        lock.withLock { token != nil }
    }

    public func setHolding(_ isHolding: Bool) {
        lock.withLock {
            if isHolding, token == nil {
                token = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: Self.reason)
            } else if !isHolding, let held = token {
                ProcessInfo.processInfo.endActivity(held)
                token = nil
            }
        }
    }
}
