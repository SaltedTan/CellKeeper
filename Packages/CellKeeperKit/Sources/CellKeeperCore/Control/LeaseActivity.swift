import Foundation

/// Keeps CellKeeper's evaluations on time while it holds a control under a
/// lease that only those evaluations renew. A napped app renews late, and a
/// late renewal lets the lease lapse, which is safe but toggles charging for
/// nothing (research note 04, §3.4).
public protocol LeaseActivity: Sendable {
    /// Called with true when CellKeeper starts holding a control under a
    /// lease, and with false when it no longer holds any.
    func setHolding(_ isHolding: Bool)
}

/// A `ProcessInfo` activity held while CellKeeper holds a control: macOS
/// does not nap the app, but may still put an idle Mac to sleep
/// (`userInitiatedAllowingIdleSystemSleep`). The lease keeps counting during
/// sleep, and the helper handles sleep itself.
public final class ProcessLeaseActivity: LeaseActivity, @unchecked Sendable {
    public static let reason = "CellKeeper holds a charging control that it must renew on time"

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
