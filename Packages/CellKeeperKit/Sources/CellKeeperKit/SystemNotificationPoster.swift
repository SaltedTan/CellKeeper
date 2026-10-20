import CellKeeperCore
import Foundation
import UserNotifications

/// Local notifications through macOS's notification center
/// (`UNUserNotificationCenter`). No entitlement is needed in the App
/// Sandbox: only push notifications have one (`com.apple.developer.aps-environment`),
/// and CellKeeper posts nothing remotely.
///
/// Every call reads the center afresh and keeps nothing from it, so no
/// UserNotifications object crosses an isolation boundary. The center is
/// touched only when called, which ``ChargingNotifier`` does only after the
/// user opts in. It must not be called outside an app bundle (tests use a
/// fake): the system center needs one. Errors are logged by their numeric
/// code only.
public struct SystemNotificationPoster: NotificationPosting {
    /// Hands a request to the notification center and returns; the
    /// completion handler reports the outcome later. The system's center by
    /// default; tests give a fake, so a hand-over can be held.
    typealias Submission = @Sendable (UNNotificationRequest, @escaping @Sendable ((any Error)?) -> Void) -> Void

    /// Calls `expire` once `seconds` have passed; the system's timer by
    /// default, one the test fires in tests.
    typealias TimeoutScheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// Removes delivered and pending notifications by identifier; the
    /// system's center by default, a recorder in tests.
    typealias Removal = @Sendable ([String]) -> Void

    /// How long a post waits for the center's answer before its outcome
    /// counts as unknown (``NotificationPostResult/unconfirmed``).
    static let answerBound: TimeInterval = 30
    /// Hand-overs that may be queued or under way at once, so a system call
    /// that stalls cannot pile up others behind it; beyond it a post is
    /// dropped (``NotificationPostResult/dropped``). Notifications follow
    /// episodes and are rate-limited, so in practice one at most waits.
    static let maximumQueuedHandOvers = 8

    private let submission: Submission
    private let removal: Removal
    private let answerBound: TimeInterval
    private let scheduleTimeout: TimeoutScheduler
    /// Every hand-over runs here, one at a time: a system call that blocks
    /// holds this queue, never Swift's cooperative pool or the main thread.
    private let handOverQueue = DispatchQueue(label: "io.github.saltedtan.CellKeeper.notification-hand-over")
    private let queuedHandOvers: QueuedHandOvers
    /// Identifiers handed to the center whose add has not been answered,
    /// and those withdrawn meanwhile.
    private let inFlight = InFlightAdds()

    public init() {
        self.init(submission: { request, completion in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        }, removal: { identifiers in
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        })
    }

    init(
        submission: @escaping Submission,
        removal: @escaping Removal = { _ in },
        answerBound: TimeInterval = SystemNotificationPoster.answerBound,
        scheduleTimeout: @escaping TimeoutScheduler = { seconds, expire in
            // Not on the hand-over queue, which a blocked system call holds.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: expire)
        },
        queueLimit: Int = SystemNotificationPoster.maximumQueuedHandOvers
    ) {
        self.submission = submission
        self.removal = removal
        self.answerBound = answerBound
        self.scheduleTimeout = scheduleTimeout
        self.queuedHandOvers = QueuedHandOvers(limit: queueLimit)
    }

    /// Hand-overs queued or under way now.
    var queuedHandOverCount: Int {
        queuedHandOvers.count
    }

    public func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.permission(
            authorization: settings.authorizationStatus,
            alertSetting: settings.alertSetting,
            alertStyle: settings.alertStyle,
            notificationCenterSetting: settings.notificationCenterSetting
        )
    }

    /// Asks for alerts only: no sound or badge.
    public func requestPermission() async -> NotificationPermission {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        } catch {
            // The answer is read below either way.
            CellKeeperLog.app.error("macOS did not complete the request to allow notifications: error code \(Self.errorCode(error), privacy: .public)")
        }
        return await permission()
    }

    /// Posts at once, replacing an earlier notification of the same
    /// ``NotificationKind/replacementKey``. The hand-over runs on a private
    /// serial queue and, immediately before the system call, checks that the
    /// generation has not ended and that the post has not already settled
    /// (its answer bound passed, or it was cancelled): a post that expired
    /// while queued behind a stalled call never reaches macOS later, while
    /// one that already passed the check may still complete. At most
    /// ``maximumQueuedHandOvers`` are queued or under way. The center's
    /// answer is awaited through a ``PostOutcome``, which also settles, as
    /// ``NotificationPostResult/unconfirmed``, after the bound or when the
    /// waiting task is cancelled; a later answer is ignored.
    public func add(_ notification: PlannedNotification, in generation: NotificationGeneration) async -> NotificationPostResult {
        guard queuedHandOvers.reserve() else { return .dropped }
        let outcome = PostOutcome()
        let submission = submission
        let queuedHandOvers = queuedHandOvers
        let inFlight = inFlight
        let removal = removal
        let handOverQueue = handOverQueue
        let identifier = notification.identifier
        handOverQueue.async {
            defer { queuedHandOvers.release() }
            guard generation.isCurrent else {
                outcome.settle(.ended)
                return
            }
            guard !outcome.isSettled else { return }
            inFlight.begin(identifier)
            submission(Self.request(for: notification)) { error in
                outcome.settle(error.map { .failed(code: Self.errorCode($0)) } ?? .posted)
                // An answer after a withdrawal, also one after the wait
                // timed out: what it showed is removed again.
                if inFlight.end(identifier) {
                    handOverQueue.async { removal([identifier]) }
                }
            }
        }
        scheduleTimeout(answerBound) {
            outcome.settle(.unconfirmed)
        }
        return await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            outcome.settle(.unconfirmed)
        }
    }

    /// Runs on the hand-over queue, after every hand-over already queued.
    /// An add of one of them that the center has not answered yet, also
    /// one whose wait timed out, is removed again when its answer comes,
    /// so a withdrawn notification never stays shown.
    public func remove(identifiers: [String]) async {
        let removal = removal
        let inFlight = inFlight
        handOverQueue.async {
            inFlight.withdraw(identifiers)
            removal(identifiers)
        }
    }

    static func request(for notification: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        return UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
    }

    /// An error's numeric code, without its description, which may carry
    /// paths or other free-form text.
    static func errorCode(_ error: any Error) -> Int {
        (error as NSError).code
    }

    /// What the system's notification settings allow, in Core's terms.
    /// Banners count only with alerts enabled and an alert style other than
    /// None; Notification Center only when listing there is enabled.
    static func permission(
        authorization: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting,
        alertStyle: UNAlertStyle,
        notificationCenterSetting: UNNotificationSetting
    ) -> NotificationPermission {
        let mapped: NotificationPermission.Authorization = switch authorization {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        @unknown default: .unrecognized
        }
        return NotificationPermission(
            authorization: mapped,
            showsBanners: alertSetting == .enabled && alertStyle != .none,
            listsInNotificationCenter: notificationCenterSetting == .enabled
        )
    }
}

/// The outcome of one post, settled once by whichever comes first: the
/// center's answer, the end of the generation before the hand-over, the
/// bound, or cancellation. Later settlements are ignored, so the waiter is
/// resumed exactly once.
final class PostOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: NotificationPostResult?
    private var waiter: CheckedContinuation<NotificationPostResult, Never>?

    /// Whether the outcome is settled: answered, ended, expired or
    /// cancelled.
    var isSettled: Bool {
        lock.withLock { result != nil }
    }

    /// Settles the outcome, unless it is settled already; returns whether
    /// this call did.
    @discardableResult
    func settle(_ value: NotificationPostResult) -> Bool {
        let (isFirst, waiting) = lock.withLock { () -> (Bool, CheckedContinuation<NotificationPostResult, Never>?) in
            guard result == nil else { return (false, nil) }
            result = value
            defer { waiter = nil }
            return (true, waiter)
        }
        waiting?.resume(returning: value)
        return isFirst
    }

    func value() async -> NotificationPostResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<NotificationPostResult, Never>) in
            let settled = lock.withLock { () -> NotificationPostResult? in
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let settled {
                continuation.resume(returning: settled)
            }
        }
    }
}

/// Hand-overs queued or under way, up to a limit.
/// The identifiers whose add the center has not answered, and those
/// withdrawn while it had not. Thread-safe; the center's answers arrive on
/// its own queue.
final class InFlightAdds: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var withdrawn: Set<String> = []

    func begin(_ identifier: String) {
        lock.withLock { counts[identifier, default: 0] += 1 }
    }

    /// The add of `identifier` was answered (shown or failed): true if it
    /// was withdrawn while unanswered, so it is to be removed again.
    func end(_ identifier: String) -> Bool {
        lock.withLock {
            let left = (counts[identifier] ?? 1) - 1
            let wasWithdrawn = withdrawn.contains(identifier)
            if left <= 0 {
                counts[identifier] = nil
                withdrawn.remove(identifier)
            } else {
                counts[identifier] = left
            }
            return wasWithdrawn
        }
    }

    /// Notes the identifiers among `identifiers` with an add unanswered.
    func withdraw(_ identifiers: [String]) {
        lock.withLock {
            for identifier in identifiers where counts[identifier] != nil {
                withdrawn.insert(identifier)
            }
        }
    }
}

final class QueuedHandOvers: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var queued = 0

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int {
        lock.withLock { queued }
    }

    /// Takes a place, if one is free.
    func reserve() -> Bool {
        lock.withLock {
            guard queued < limit else { return false }
            queued += 1
            return true
        }
    }

    /// Gives a place back, once the hand-over has finished or been skipped.
    func release() {
        lock.withLock { queued -= 1 }
    }
}

/// Where System Settings shows notification settings.
public enum NotificationSettingsLink {
    /// System Settings › Notifications, through System Settings' URL scheme.
    /// Apple does not document this pane's identifier; it is the bundle
    /// identifier of the Notifications settings extension on macOS 27.0.1
    /// (its `Info.plist`). Opening it has not been observed yet, so callers
    /// fall back to ``BatterySettingsLink/systemSettingsApp`` if opening it
    /// fails.
    public static let notificationsPane = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}
