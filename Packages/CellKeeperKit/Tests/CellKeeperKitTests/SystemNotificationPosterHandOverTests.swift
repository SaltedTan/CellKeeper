@testable import CellKeeperCore
@testable import CellKeeperKit
import Foundation
import Testing
import UserNotifications

/// The poster's own hand-over to the notification center, with a fake
/// center and answer bounds the test expires by hand. Turning notifications
/// off (ending the generation) never waits; a hand-over checks, right
/// before the system call, that its generation has not ended and its post
/// has not settled, so none is made after the end and none for a post that
/// expired or was cancelled while queued, while one that already passed its
/// check may still finish. The queue behind a stalled call is capped. Holds
/// run on the poster's own hand-over queue, never on Swift's cooperative
/// pool; no outcome depends on how fast anything runs, and every wait is
/// bounded and records an issue on expiry.
@Suite("System notification poster: hand-over")
struct SystemNotificationPosterHandOverTests {
    static let notification = PlannedNotification(kind: .limitReached, title: "Title", body: "Body")

    /// A notification center that records what reaches it. It can hold a
    /// submission inside the system call until released, or keep its
    /// answer to the first request back until the test gives it.
    final class FakeCenter: @unchecked Sendable {
        private let lock = NSLock()
        private var begun = 0
        private var completed = 0
        private var isHolding = false
        private var isWithholdingFirstAnswer = false
        private var withheld: (@Sendable ((any Error)?) -> Void)?
        private let release = DispatchSemaphore(value: 0)

        var submissionsBegun: Int { lock.withLock { begun } }
        var submissionsCompleted: Int { lock.withLock { completed } }

        /// Holds the next submission inside the system call.
        func hold() {
            lock.withLock { isHolding = true }
        }

        func letGo() {
            lock.withLock { isHolding = false }
            release.signal()
        }

        /// Keeps the answer to the first request back.
        func withholdFirstAnswer() {
            lock.withLock { isWithholdingFirstAnswer = true }
        }

        /// Gives the answer kept back, late.
        func answerWithheld() {
            let answer = lock.withLock {
                defer { withheld = nil }
                return withheld
            }
            answer?(nil)
        }

        var submission: SystemNotificationPoster.Submission {
            { [self] _, completion in
                let (mustHold, mustWithhold) = lock.withLock { () -> (Bool, Bool) in
                    begun += 1
                    let mustWithhold = isWithholdingFirstAnswer && begun == 1
                    if mustWithhold { withheld = completion }
                    return (isHolding, mustWithhold)
                }
                if mustHold {
                    release.wait()
                }
                lock.withLock { completed += 1 }
                if !mustWithhold {
                    completion(nil)
                }
            }
        }
    }

    /// Answer bounds that expire only when the test says so.
    final class ManualTimeouts: @unchecked Sendable {
        private let lock = NSLock()
        private var scheduled: [@Sendable () -> Void] = []

        /// Bounds scheduled so far, one per post that reached its wait.
        var count: Int { lock.withLock { scheduled.count } }

        var scheduler: SystemNotificationPoster.TimeoutScheduler {
            { [self] _, expire in
                lock.withLock { scheduled.append(expire) }
            }
        }

        /// Expires the bound of the `index`th post (from 0).
        func expire(_ index: Int) {
            let expire = lock.withLock { scheduled[index] }
            expire()
        }
    }

    /// Starts a post in a task of its own, and waits until it has reached
    /// its wait: its bound is scheduled, so it is the `count`th.
    private func startPost(_ poster: SystemNotificationPoster, in generation: NotificationGeneration, timeouts: ManualTimeouts, count: Int) async -> Task<NotificationPostResult, Never> {
        let task = Task { await poster.add(Self.notification, in: generation) }
        await posterBoundedWait("post \(count) to reach its wait") { await posterUntil { timeouts.count >= count } }
        return task
    }

    @Test("Turning notifications off never waits for a hand-over under way; that one may still finish, and none is made afterwards")
    func optOutDuringHandOver() async {
        let center = FakeCenter()
        center.hold()
        let timeouts = ManualTimeouts()
        let poster = SystemNotificationPoster(submission: center.submission, scheduleTimeout: timeouts.scheduler)
        let generation = NotificationGeneration()
        let adding = await startPost(poster, in: generation, timeouts: timeouts, count: 1)
        await posterBoundedWait("the hand-over to reach the center") { await posterUntil { center.submissionsBegun == 1 } }

        // Ending returns while the hand-over is held inside the system call.
        let ended = PosterSignal()
        DispatchQueue(label: "test.opting-out").async {
            generation.end()
            ended.fire()
        }
        await posterBoundedWait("turning off to return") { await ended.wait() }
        let completedBeforeRelease = center.submissionsCompleted
        #expect(completedBeforeRelease == 0)

        // The hand-over that passed its check finishes.
        center.letGo()
        let first = await posterBoundedValue("the held post") { await adding.value }
        #expect(first == .posted)

        // A hand-over attempted after the end never reaches the center.
        let late = await posterBoundedValue("a post after the end") { await poster.add(Self.notification, in: generation) }
        #expect(late == .ended)
        #expect(center.submissionsBegun == 1)
    }

    @Test("An unanswered post becomes unknown when its bound expires, without holding the next post; its late answer is ignored")
    func unansweredPost() async {
        let center = FakeCenter()
        center.withholdFirstAnswer()
        let timeouts = ManualTimeouts()
        let poster = SystemNotificationPoster(submission: center.submission, scheduleTimeout: timeouts.scheduler)
        let generation = NotificationGeneration()
        let unanswered = await startPost(poster, in: generation, timeouts: timeouts, count: 1)
        await posterBoundedWait("the hand-over to reach the center") { await posterUntil { center.submissionsCompleted == 1 } }
        timeouts.expire(0)
        let expired = await posterBoundedValue("the unanswered post") { await unanswered.value }
        #expect(expired == .unconfirmed)

        // Its bound is never expired: the center's answer settles it.
        let next = await posterBoundedValue("the next post") { await poster.add(Self.notification, in: generation) }
        #expect(next == .posted)
        // The answer arriving now settles nothing.
        center.answerWithheld()
        #expect(center.submissionsBegun == 2)
    }

    @Test("Posts that expire or are cancelled while queued behind a stalled hand-over never reach the center; at most the cap is queued")
    func stalledHandOver() async {
        let center = FakeCenter()
        center.hold()
        let timeouts = ManualTimeouts()
        let poster = SystemNotificationPoster(submission: center.submission, scheduleTimeout: timeouts.scheduler)
        let generation = NotificationGeneration()
        let limit = SystemNotificationPoster.maximumQueuedHandOvers
        // The first stalls inside the system call; the rest queue behind it.
        var posts = [await startPost(poster, in: generation, timeouts: timeouts, count: 1)]
        await posterBoundedWait("the first hand-over to reach the center") { await posterUntil { center.submissionsBegun == 1 } }
        for count in 2...limit {
            posts.append(await startPost(poster, in: generation, timeouts: timeouts, count: count))
        }
        let queued = poster.queuedHandOverCount
        #expect(queued == limit)

        // Beyond the cap, a post is dropped at once.
        let beyond = await posterBoundedValue("a post beyond the cap") { await poster.add(Self.notification, in: generation) }
        #expect(beyond == .dropped)
        let queuedAfterDrop = poster.queuedHandOverCount
        #expect(queuedAfterDrop == limit)

        // Half the queued posts expire, the other half are cancelled.
        let middle = 1 + (limit - 1) / 2
        for index in 1..<middle {
            timeouts.expire(index)
        }
        for index in middle..<limit {
            posts[index].cancel()
        }
        for index in 1..<limit {
            let post = posts[index]
            let result = await posterBoundedValue("queued post \(index)") { await post.value }
            #expect(result == .unconfirmed)
        }
        // They still hold their places until their blocks have run.
        let queuedWhileStalled = poster.queuedHandOverCount
        #expect(queuedWhileStalled == limit)

        // Released, the stalled hand-over finishes; the expired and cancelled
        // ones behind it are skipped, never handed to the center.
        center.letGo()
        let stalled = posts[0]
        let first = await posterBoundedValue("the stalled post") { await stalled.value }
        #expect(first == .posted)
        await posterBoundedWait("the queue to drain") { await posterUntil { poster.queuedHandOverCount == 0 } }
        #expect(center.submissionsBegun == 1)
    }

    @Test("Cancelling a post that waits for the center's answer releases it at once")
    func cancellationReleasesWaiter() async {
        let center = FakeCenter()
        center.withholdFirstAnswer()
        let timeouts = ManualTimeouts()
        let poster = SystemNotificationPoster(submission: center.submission, scheduleTimeout: timeouts.scheduler)
        let generation = NotificationGeneration()
        let adding = await startPost(poster, in: generation, timeouts: timeouts, count: 1)
        await posterBoundedWait("the post to reach the center") { await posterUntil { center.submissionsCompleted == 1 } }
        adding.cancel()
        let result = await posterBoundedValue("the cancelled post") { await adding.value }
        #expect(result == .unconfirmed)
    }

    @Test("An outcome is settled once: the first of the answer, the end, the bound or cancellation")
    func outcomeSettlesOnce() async {
        let outcome = PostOutcome()
        #expect(!outcome.isSettled)
        let isFirst = outcome.settle(.unconfirmed)
        let isSecond = outcome.settle(.posted)
        #expect(isFirst)
        #expect(!isSecond)
        #expect(outcome.isSettled)
        let value = await posterBoundedValue("the settled outcome") { await outcome.value() }
        #expect(value == .unconfirmed)
    }

    @Test("Posting reports what the center answered, and nothing is handed over under an ended generation")
    func addOutcomes() async {
        let center = FakeCenter()
        let timeouts = ManualTimeouts()
        let poster = SystemNotificationPoster(submission: center.submission, scheduleTimeout: timeouts.scheduler)
        let current = NotificationGeneration()
        let posted = await posterBoundedValue("a post") { await poster.add(Self.notification, in: current) }
        #expect(posted == .posted)
        #expect(center.submissionsBegun == 1)

        let ended = NotificationGeneration()
        ended.end()
        let refused = await posterBoundedValue("a post after the end") { await poster.add(Self.notification, in: ended) }
        #expect(refused == .ended)
        #expect(center.submissionsBegun == 1)

        let failing = SystemNotificationPoster(submission: { _, completion in
            completion(NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue, userInfo: [NSLocalizedDescriptionKey: "/Users/someone"]))
        }, scheduleTimeout: timeouts.scheduler)
        let failed = await posterBoundedValue("a failing post") { await failing.add(Self.notification, in: current) }
        #expect(failed == .failed(code: UNError.Code.notificationsNotAllowed.rawValue))
    }
}

/// A one-time signal, fired from any thread.
final class PosterSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isFired: Bool {
        lock.withLock { isSet }
    }

    func fire() {
        let waiting = lock.withLock {
            isSet = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isDone = lock.withLock { () -> Bool in
                if isSet { return true }
                waiters.append(continuation)
                return false
            }
            if isDone {
                continuation.resume()
            }
        }
    }
}

/// Polls `condition` until it holds, and stops when cancelled; use inside
/// ``posterBoundedWait(_:seconds:_:)``.
func posterUntil(_ condition: @escaping @Sendable () -> Bool) async {
    while !condition() {
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            return
        }
    }
}

/// Waits for `body` at most `seconds`; records an issue naming `what` on
/// expiry. See ``posterBoundedValue(_:seconds:_:)``.
func posterBoundedWait(_ what: String, seconds: Double = 10, _ body: @escaping @Sendable () async -> Void) async {
    _ = await posterBoundedValue(what, seconds: seconds) { () async -> Bool in
        await body()
        return true
    }
}

/// What `body` returns within `seconds`. Otherwise it records an issue
/// naming `what`, cancels `body`, and waits a second bound of `seconds` for
/// it to stop, recording another issue if it has not; it then returns nil.
/// A `body` that ignored cancellation may still be running after that. The
/// time only bounds a failure.
func posterBoundedValue<Value: Sendable>(_ what: String, seconds: Double = 10, _ body: @escaping @Sendable () async -> Value) async -> Value? {
    let race = PosterOutcome<Value?>()
    let work = Task {
        let value = await body()
        race.settle(value)
    }
    let timer = Task {
        do {
            try await Task.sleep(for: .seconds(seconds))
            race.settle(nil)
        } catch {}
    }
    let value = await race.value()
    timer.cancel()
    if value == nil {
        Issue.record("Timed out after \(seconds) s waiting for \(what)")
        work.cancel()
        let stopped = PosterOutcome<Bool>()
        Task {
            await work.value
            stopped.settle(true)
        }
        let stopTimer = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
                stopped.settle(false)
            } catch {}
        }
        if await !stopped.value() {
            Issue.record("Waiting for \(what) did not stop when cancelled")
        }
        stopTimer.cancel()
    }
    return value
}

/// The first of several outcomes, whichever settles first.
final class PosterOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Value?
    private var isSettled = false
    private var waiter: CheckedContinuation<Value, Never>?

    func settle(_ value: Value) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            guard !isSettled else { return nil }
            isSettled = true
            outcome = value
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: value)
    }

    func value() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let (isDone, stored) = lock.withLock { () -> (Bool, Value?) in
                if isSettled { return (true, outcome) }
                waiter = continuation
                return (false, nil)
            }
            if isDone, let stored {
                continuation.resume(returning: stored)
            }
        }
    }
}
