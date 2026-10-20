import Foundation

/// The lifetime of posting under one opt-in: it ends when the user turns
/// notifications off or on again, and when CellKeeper quits. Used from any
/// thread.
///
/// Ending it never waits. Every notification not yet handed to macOS is
/// stopped: a hand-over checks ``isCurrent`` immediately before the system
/// call, and once ending has begun no hand-over passes that check. One that
/// had already passed it may still complete, and so appear, afterwards;
/// notifications already delivered stay in Notification Center.
public final class NotificationGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var hasEnded = false

    public init() {}

    /// False from the moment ``end()`` is called.
    public var isCurrent: Bool {
        lock.withLock { !hasEnded }
    }

    /// Marks the generation ended, at once; the lock is never held across a
    /// system call, so this never waits.
    func end() {
        lock.withLock { hasEnded = true }
    }
}

/// What became of a notification CellKeeper asked to post.
public enum NotificationPostResult: Sendable, Equatable {
    case posted
    /// Not posted: its generation ended first.
    case ended
    /// Not posted: the system reported an error. Only its numeric code is
    /// kept, for the log; never its description.
    case failed(code: Int)
    /// No answer from the system within the bound, or the wait was
    /// cancelled: the outcome is unknown, and never counted as delivered.
    /// The post may have been handed over, or may still have been queued;
    /// one still queued is never handed over afterwards.
    case unconfirmed
    /// Not handed over: too many hand-overs were already queued or under
    /// way.
    case dropped
}

/// The system's notification center. `SystemNotificationPoster` (Kit)
/// implements it with UserNotifications; tests use a fake.
public protocol NotificationPosting: Sendable {
    /// What macOS allows now. Never asks the user.
    func permission() async -> NotificationPermission
    /// Asks macOS to allow CellKeeper's notifications (macOS prompts the user
    /// only the first time), then returns what it allows.
    func requestPermission() async -> NotificationPermission
    /// Hands `notification` to the system, checking
    /// ``NotificationGeneration/isCurrent`` immediately before the system
    /// call (``NotificationPostResult/ended`` if it had ended), and waits for
    /// the system's answer for a bounded time, or until cancelled
    /// (``NotificationPostResult/unconfirmed``).
    func add(_ notification: PlannedNotification, in generation: NotificationGeneration) async -> NotificationPostResult
    /// Removes the notifications with these identifiers
    /// (``PlannedNotification/identifier``) from Notification Center, and
    /// any not shown yet, after every hand-over already queued. Asks the
    /// user nothing and returns without waiting for the system.
    func remove(identifiers: [String]) async
}

/// Turns the controller's statuses into notifications, if the user opted in.
///
/// A side channel: it never sees the controller, only the statuses the app
/// already has. ``observe(_:trigger:)`` plans synchronously and returns at
/// once; posting runs afterwards, one notification at a time and in order,
/// so the command queue never waits for it, and a failure to post is logged
/// by a fixed code and changes nothing else. The system's notification
/// center is not touched until the user opts in.
///
/// Every asynchronous step belongs to a generation and is checked before it
/// acts and after every suspension: posting to the ``NotificationGeneration``
/// of the opt-in it was planned under, which turning notifications off or on
/// and ``shutdown()`` end without waiting; each permission read or request
/// to its own operation, which any newer read, request, change of the
/// user's choice or ``shutdown()`` supersedes, so an older answer never
/// overwrites a newer one. Posting tasks hold no reference to the notifier
/// while they wait, and at most ``maximumPendingPosts`` wait at once.
@MainActor
public final class ChargingNotifier {
    public private(set) var optIn: NotificationOptIn {
        didSet {
            if optIn != oldValue { onChange?(optIn) }
        }
    }

    /// Called whenever ``optIn`` changes.
    public var onChange: ((NotificationOptIn) -> Void)?

    /// Posting tasks that may wait at once; beyond it, the newest
    /// notifications are dropped (and logged). Notifications follow episodes
    /// and are rate-limited per kind, so in practice no more than a few ever
    /// wait; this only bounds what a system that stops answering could pile
    /// up, each post waiting at most the poster's bound.
    public static let maximumPendingPosts = 8

    private let poster: any NotificationPosting
    private let store: SettingsStore
    private let uptime: @Sendable () -> TimeInterval
    private var planner = NotificationPlanner()
    private var generation = NotificationGeneration()
    /// The latest posting task; each waits for the one before it, within
    /// a generation.
    private var lastPost: Task<Void, Never>?
    /// Every posting task that has not finished, also those of an ended
    /// generation, by number; each removes itself when it finishes.
    private var postTasks: [Int: Task<Void, Never>] = [:]
    private var nextPostTask = 0
    /// The latest permission read or request; an answer applies only if it
    /// is still the latest when it arrives.
    private var permissionOperation = 0
    private var isShutDown = false
    /// How many times each identifier was withdrawn. A post captures the
    /// count when it is queued and is dropped if the count has changed by
    /// the time it would be handed over, so a request withdrawn while it
    /// waited is never posted.
    private var withdrawals: [String: Int] = [:]

    /// - Parameter uptime: monotonic seconds for the planner's minimum
    ///   intervals. Defaults to `ContinuousClock`, which keeps counting
    ///   during sleep.
    public init(poster: any NotificationPosting, store: SettingsStore, uptime: (@Sendable () -> TimeInterval)? = nil) {
        self.poster = poster
        self.store = store
        self.uptime = uptime ?? Self.continuousUptime()
        optIn = NotificationOptIn(isEnabled: store.loadNotificationsEnabled())
    }

    private static func continuousUptime() -> @Sendable () -> TimeInterval {
        let clock = ContinuousClock()
        let origin = clock.now
        return {
            let elapsed = origin.duration(to: clock.now).components
            return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
        }
    }

    // MARK: - Opt-in

    /// Saves the user's choice. Under the previous choice, nothing not yet
    /// handed to macOS is posted (one being handed over at that moment may
    /// still appear); this never waits. Turning notifications on asks macOS
    /// for permission (macOS
    /// prompts only the first time, and answers at once after that).
    /// Turning them off asks nothing and ends any request in flight, so
    /// the user can withdraw the choice whatever macOS allows.
    public func setEnabled(_ enabled: Bool) async {
        guard !isShutDown else { return }
        store.saveNotificationsEnabled(enabled)
        endGeneration()
        let operation = beginPermissionOperation()
        // One change, so ``onChange`` sees no state in between.
        var asking = optIn
        asking.isEnabled = enabled
        asking.isRequesting = enabled
        optIn = asking
        guard enabled else { return }
        let permission = await poster.requestPermission()
        guard isLatest(operation) else { return }
        var answered = optIn
        answered.permission = permission
        answered.isRequesting = false
        answered.hasRequested = true
        optIn = answered
        CellKeeperLog.app.notice("Notifications turned on; macOS reports them \(permission.isShown ? "shown" : "not shown", privacy: .public)")
    }

    /// Reads again what macOS allows, which the user can change in System
    /// Settings at any time. Asks nothing while the user has not opted in,
    /// and nothing while a request waits for the user's answer.
    public func refreshPermission() async {
        guard !isShutDown, optIn.isEnabled, !optIn.isRequesting else { return }
        let operation = beginPermissionOperation()
        let permission = await poster.permission()
        guard isLatest(operation) else { return }
        optIn.permission = permission
    }

    /// For quitting: ends every generation and operation without waiting, so
    /// nothing not yet handed to macOS is posted (one being handed over at
    /// that moment may still appear), no answer is applied afterwards, and
    /// every later call does nothing.
    public func shutdown() {
        isShutDown = true
        permissionOperation += 1
        endGeneration()
    }

    // MARK: - Statuses

    /// Plans the notifications `status` calls for and queues them for
    /// posting. Statuses must be given in the order their commands ran.
    /// Returns without waiting for anything.
    public func observe(_ status: ControllerStatus, trigger: EvaluationTrigger) {
        guard !isShutDown else { return }
        let plan = planner.planAll(status, trigger: trigger, uptime: uptime(), isDelivering: optIn.isDelivering)
        if !plan.withdrawals.isEmpty, optIn.isEnabled {
            withdraw(plan.withdrawals)
        }
        let planned = plan.notifications
        guard !planned.isEmpty else { return }
        guard postTasks.count < Self.maximumPendingPosts else {
            let kinds = planned.map(\.kind.rawValue).joined(separator: ", ")
            CellKeeperLog.app.error("Notifications not queued (\(kinds, privacy: .public)): too many are waiting for the system")
            return
        }
        let generation = generation
        let previous = lastPost
        let number = nextPostTask
        nextPostTask += 1
        let queuedWithdrawals = withdrawals
        // Runs on the main actor, so it cannot start before it is recorded.
        // It refers to the notifier only between suspensions, so a post
        // waiting for the system never keeps it alive.
        let task = Task { [weak self, poster] in
            await previous?.value
            for notification in planned {
                guard generation.isCurrent, !Task.isCancelled else { break }
                let operation = self?.beginPermissionOperation()
                let permission = await poster.permission()
                guard generation.isCurrent, !Task.isCancelled else { break }
                if let operation, let self, self.isLatest(operation) {
                    self.optIn.permission = permission
                }
                guard permission.isShown else {
                    CellKeeperLog.app.notice("Notification not posted (\(notification.kind.rawValue, privacy: .public)): macOS does not show CellKeeper's notifications")
                    continue
                }
                if let self, self.withdrawals[notification.identifier] != queuedWithdrawals[notification.identifier] {
                    CellKeeperLog.app.notice("Notification not posted (\(notification.kind.rawValue, privacy: .public)): it was withdrawn while it waited")
                    continue
                }
                Self.log(await poster.add(notification, in: generation), for: notification.kind)
            }
            self?.postTasks[number] = nil
        }
        lastPost = task
        postTasks[number] = task
    }

    /// Withdraws notifications that no longer hold: a post of one still
    /// waiting is dropped, and the system is asked to remove them, after
    /// every post queued before, so one being handed over is removed once
    /// shown. Within the current generation only; never waits.
    private func withdraw(_ identifiers: [String]) {
        for identifier in identifiers {
            withdrawals[identifier, default: 0] += 1
        }
        guard postTasks.count < Self.maximumPendingPosts else {
            CellKeeperLog.app.error("Notifications not withdrawn: too many are waiting for the system")
            return
        }
        let generation = generation
        let previous = lastPost
        let number = nextPostTask
        nextPostTask += 1
        let task = Task { [weak self, poster] in
            await previous?.value
            if generation.isCurrent, !Task.isCancelled {
                await poster.remove(identifiers: identifiers)
                CellKeeperLog.app.notice("Notifications withdrawn: \(identifiers.count, privacy: .public)")
            }
            self?.postTasks[number] = nil
        }
        lastPost = task
        postTasks[number] = task
    }

    /// Waits until every posting task has finished, whether it handed its
    /// notifications to the system or stopped because its generation ended,
    /// including tasks started while waiting.
    func waitForPosts() async {
        while let task = postTasks.values.first {
            await task.value
        }
    }

    /// Posting tasks that have not finished.
    var pendingPostCount: Int {
        postTasks.count
    }

    /// Logs what became of a post, by fixed text, kind and code only.
    private static func log(_ result: NotificationPostResult, for kind: NotificationKind) {
        switch result {
        case .posted:
            CellKeeperLog.app.notice("Notification posted: \(kind.rawValue, privacy: .public)")
        case .ended:
            CellKeeperLog.app.notice("Notification not posted (\(kind.rawValue, privacy: .public)): notifications were turned off or CellKeeper is quitting")
        case .failed(let code):
            CellKeeperLog.app.error("Notification not posted (\(kind.rawValue, privacy: .public)): system error \(code, privacy: .public)")
        case .unconfirmed:
            CellKeeperLog.app.error("Notification outcome unknown (\(kind.rawValue, privacy: .public)): no answer from the system in time, or the wait was cancelled")
        case .dropped:
            CellKeeperLog.app.error("Notification not handed over (\(kind.rawValue, privacy: .public)): too many are waiting for the system")
        }
    }

    /// Ends the current generation, without waiting
    /// (``NotificationGeneration/end()``), and cancels its posting tasks,
    /// which releases one waiting for the system's answer. The tasks stay
    /// in ``postTasks`` until they have finished.
    private func endGeneration() {
        generation.end()
        generation = NotificationGeneration()
        for task in postTasks.values {
            task.cancel()
        }
        lastPost = nil
    }

    private func beginPermissionOperation() -> Int {
        permissionOperation += 1
        return permissionOperation
    }

    private func isLatest(_ operation: Int) -> Bool {
        !isShutDown && operation == permissionOperation
    }
}
