@testable import CellKeeperCore
import Foundation
import Testing

/// The notifier: the opt-in, asking macOS, and posting through a fake
/// center, as a side channel that never waits for it or changes anything,
/// and whose every asynchronous step ends with the opt-in it belongs to.
@MainActor
@Suite("Charging notifier")
struct ChargingNotifierTests {
    let storage = InMemoryStorage()
    var store: SettingsStore { SettingsStore(defaults: storage) }

    private func makeNotifier(_ poster: FakeNotificationPoster, clock: TestClock, enabled: Bool) -> ChargingNotifier {
        store.saveNotificationsEnabled(enabled)
        return ChargingNotifier(poster: poster, store: store, uptime: { clock.uptime })
    }

    /// Charges from 76% to the limit and holds, giving every status to
    /// `notifier`.
    private func chargeToLimit(_ driver: ControllerDriver, _ notifier: ChargingNotifier) async {
        for (percent, trigger) in [(76, EvaluationTrigger.launch), (80, .periodic), (80, .periodic)] {
            notifier.observe(await driver.evaluate(percent, trigger), trigger: trigger)
        }
    }

    /// Waits, bounded, until every posting task of `notifier` has finished.
    private func settle(_ notifier: ChargingNotifier) async {
        await waitBounded("posting to finish") { await notifier.waitForPosts() }
    }

    /// Then the battery gets warm.
    private func warmUp(_ driver: ControllerDriver, _ notifier: ChargingNotifier) async {
        notifier.observe(await driver.evaluate(80, temperature: 41), trigger: .periodic)
    }

    /// Where a post is held: waiting for macOS's answer, or handing the
    /// notification to the system.
    enum Stage: Sendable, CaseIterable {
        case readingPermission
        case reachingSystem

        func gate(_ poster: FakeNotificationPoster) -> TestGate {
            switch self {
            case .readingPermission: poster.reads
            case .reachingSystem: poster.adds
            }
        }
    }

    /// A notifier opted in, with macOS showing its notifications, that has
    /// queued a limit and a temperature notification, the first of them held
    /// at `stage`. A read held there began after macOS stopped showing the
    /// notifications, so its answer would turn the toggle off if applied.
    private func queuedTwo(heldAt stage: Stage) async -> (ChargingNotifier, FakeNotificationPoster) {
        let poster = FakeNotificationPoster(permission: .shown)
        let driver = ControllerDriver(percent: 76)
        let notifier = makeNotifier(poster, clock: driver.clock, enabled: true)
        await notifier.refreshPermission()
        #expect(notifier.optIn.state == .on)
        if stage == .readingPermission {
            poster.setPermission(.denied)
        }
        stage.gate(poster).hold()
        await chargeToLimit(driver, notifier)
        await warmUp(driver, notifier)
        // The refresh above was the first read.
        let gate = stage.gate(poster)
        let arrivals = stage == .readingPermission ? 2 : 1
        await waitBounded("the first post to reach the hold") { await gate.waitForArrivals(arrivals) }
        #expect(notifier.pendingPostCount > 0)
        return (notifier, poster)
    }

    @Test("Nothing asks the system's notification center anything until the user opts in")
    func untouchedUntilOptIn() async {
        let poster = FakeNotificationPoster(permission: .shown)
        let driver = ControllerDriver(percent: 76)
        let notifier = makeNotifier(poster, clock: driver.clock, enabled: false)
        #expect(notifier.optIn.state == .off)
        await notifier.refreshPermission()
        await chargeToLimit(driver, notifier)
        await settle(notifier)
        #expect(poster.permissionReads == 0)
        #expect(poster.requests == 0)
        #expect(poster.posted.isEmpty)
    }

    @Test("Turning notifications on saves the choice and asks macOS; the toggle follows its answer")
    func turningOn() async {
        let allowing = FakeNotificationPoster(answer: .shown)
        let allowed = makeNotifier(allowing, clock: TestClock(), enabled: false)
        var changes: [NotificationOptIn.State] = []
        allowed.onChange = { changes.append($0.state) }
        await allowed.setEnabled(true)
        #expect(store.loadNotificationsEnabled())
        #expect(allowing.requests == 1)
        #expect(allowed.optIn.state == .on)
        #expect(allowed.optIn.isToggleOn)
        #expect(changes == [.requesting, .on])

        let denying = FakeNotificationPoster(answer: .denied)
        let denied = makeNotifier(denying, clock: TestClock(), enabled: false)
        await denied.setEnabled(true)
        #expect(denying.requests == 1)
        #expect(denied.optIn.state == .denied)
        #expect(!denied.optIn.isToggleOn)
        #expect(denied.optIn.offersSystemSettings)
        // The user's choice stays saved: allowing CellKeeper in System
        // Settings later is enough.
        #expect(store.loadNotificationsEnabled())
    }

    @Test("Turning notifications off saves it and asks nothing")
    func turningOff() async {
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = makeNotifier(poster, clock: TestClock(), enabled: true)
        await notifier.refreshPermission()
        #expect(notifier.optIn.state == .on)
        await notifier.setEnabled(false)
        #expect(!store.loadNotificationsEnabled())
        #expect(notifier.optIn.state == .off)
        #expect(poster.requests == 0)
        #expect(poster.permissionReads == 1)
    }

    @Test("A saved opt-in that macOS blocks can be withdrawn, and stays withdrawn", arguments: [
        NotificationPermission.denied, .shownNowhere, .notDetermined, .unrecognized,
    ])
    func withdrawWhileBlocked(permission: NotificationPermission) async {
        let poster = FakeNotificationPoster(permission: permission)
        let notifier = makeNotifier(poster, clock: TestClock(), enabled: true)
        await notifier.refreshPermission()
        #expect(!notifier.optIn.isToggleOn)
        #expect(notifier.optIn.offersWithdrawal)
        await notifier.setEnabled(false)
        #expect(!store.loadNotificationsEnabled())
        #expect(notifier.optIn.state == .off)
        #expect(!notifier.optIn.offersWithdrawal)
        #expect(poster.requests == 0)
        // Nothing read afterwards brings it back.
        await notifier.refreshPermission()
        #expect(notifier.optIn.state == .off)
        #expect(!store.loadNotificationsEnabled())
    }

    @Test("Opted in and allowed, the planned notifications are posted, in order")
    func posts() async {
        let poster = FakeNotificationPoster(permission: .shown)
        let driver = ControllerDriver(percent: 76)
        let notifier = makeNotifier(poster, clock: driver.clock, enabled: true)
        await notifier.refreshPermission()
        await chargeToLimit(driver, notifier)
        await warmUp(driver, notifier)
        await settle(notifier)
        #expect(poster.posted.map(\.kind) == [.limitReached, .temperaturePause])
    }

    @Test("A notification is handed over while the first read of macOS's answer is still under way; it is read again before posting")
    func deliversWhileChecking() async {
        let poster = FakeNotificationPoster(permission: .shown)
        let driver = ControllerDriver(percent: 76)
        let notifier = makeNotifier(poster, clock: driver.clock, enabled: true)
        #expect(notifier.optIn.state == .checking)
        await chargeToLimit(driver, notifier)
        await settle(notifier)
        #expect(poster.posted.map(\.kind) == [.limitReached])
        #expect(notifier.optIn.state == .on)
    }

    @Test("A failure to post changes nothing else; a post macOS no longer shows is not handed over, and the toggle says why")
    func postFailures() async {
        let poster = FakeNotificationPoster(permission: .shown)
        let driver = ControllerDriver(percent: 76)
        let notifier = makeNotifier(poster, clock: driver.clock, enabled: true)
        await notifier.refreshPermission()
        poster.failPosts(code: 1)
        await chargeToLimit(driver, notifier)
        await settle(notifier)
        #expect(poster.posted.isEmpty)
        #expect(notifier.optIn.state == .on)

        let other = FakeNotificationPoster(permission: .shown)
        let revoked = ControllerDriver(percent: 76)
        let revokedNotifier = makeNotifier(other, clock: revoked.clock, enabled: true)
        await revokedNotifier.refreshPermission()
        other.setPermission(.denied)
        await chargeToLimit(revoked, revokedNotifier)
        await settle(revokedNotifier)
        #expect(other.posted.isEmpty)
        #expect(revokedNotifier.optIn.state == .denied)
        #expect(!revokedNotifier.optIn.isToggleOn)
    }

    @Test("Observing never waits for the poster, and posts keep their order")
    func neverWaits() async {
        // The first post has reached the system and waits there; observing
        // returned all the same.
        let (notifier, poster) = await queuedTwo(heldAt: .reachingSystem)
        #expect(poster.posted.isEmpty)
        poster.adds.release()
        await settle(notifier)
        #expect(poster.posted.map(\.kind) == [.limitReached, .temperaturePause])
    }

    @Test("Nothing not yet handed to the system is posted once the user turns notifications off, while it waits for macOS's answer or before the hand-over", arguments: Stage.allCases)
    func turningOffStopsQueued(stage: Stage) async {
        let (notifier, poster) = await queuedTwo(heldAt: stage)
        await notifier.setEnabled(false)
        // The held post has not finished: waiting below waits for it.
        #expect(notifier.pendingPostCount > 0)
        stage.gate(poster).release()
        await settle(notifier)
        #expect(notifier.pendingPostCount == 0)
        // It ran on, and stopped at the generation check.
        switch stage {
        case .readingPermission: #expect(poster.finishedReads == 2)
        case .reachingSystem: #expect(poster.refusedAdds == 1)
        }
        #expect(poster.posted.isEmpty)
        #expect(notifier.optIn.state == .off)
        // The held read's answer was not applied.
        #expect(notifier.optIn.permission == .shown)
    }

    @Test("Nothing not yet handed to the system is posted, and no answer applied, once CellKeeper quits", arguments: Stage.allCases)
    func shutdownStopsQueued(stage: Stage) async {
        let (notifier, poster) = await queuedTwo(heldAt: stage)
        let before = notifier.optIn
        notifier.shutdown()
        #expect(notifier.pendingPostCount > 0)
        stage.gate(poster).release()
        await settle(notifier)
        #expect(notifier.pendingPostCount == 0)
        switch stage {
        case .readingPermission: #expect(poster.finishedReads == 2)
        case .reachingSystem: #expect(poster.refusedAdds == 1)
        }
        #expect(poster.posted.isEmpty)
        #expect(notifier.optIn == before)
        // Later statuses and calls do nothing.
        await notifier.refreshPermission()
        await notifier.setEnabled(false)
        #expect(notifier.optIn == before)
        #expect(store.loadNotificationsEnabled())
    }

    @Test("At most a fixed number of posts wait for the system at once; beyond it the newest are dropped")
    func pendingPostsCapped() async {
        let poster = FakeNotificationPoster(permission: .shown)
        let driver = ControllerDriver(percent: 70)
        let notifier = makeNotifier(poster, clock: driver.clock, enabled: true)
        await notifier.refreshPermission()
        poster.adds.hold()
        var status = await driver.evaluate(70, .launch)
        // A new fault each time, past the fault notification's interval, so
        // every status calls for a notification.
        for episode in 1...(ChargingNotifier.maximumPendingPosts + 4) {
            status.isBackendFaulted = true
            status.faultsRaised = episode
            notifier.observe(status, trigger: .periodic)
            driver.clock.advance(by: NotificationKind.backendFault.minimumInterval)
        }
        let pending = notifier.pendingPostCount
        #expect(pending == ChargingNotifier.maximumPendingPosts)
        poster.adds.release()
        await settle(notifier)
        #expect(poster.posted.count == ChargingNotifier.maximumPendingPosts)
    }

    @Test("A post waiting for the system does not keep the notifier alive once its owner drops it")
    func releasedWhileWaiting() async {
        let poster = FakeNotificationPoster(permission: .shown)
        let driver = ControllerDriver(percent: 76)
        let reference = WeakReference()
        do {
            let notifier = makeNotifier(poster, clock: driver.clock, enabled: true)
            await notifier.refreshPermission()
            poster.adds.hold()
            await chargeToLimit(driver, notifier)
            await waitBounded("the post to reach the system") { await poster.adds.waitForArrivals(1) }
            #expect(notifier.pendingPostCount == 1)
            reference.object = notifier
        }
        await waitBounded("the notifier to be released") { await until { reference.object == nil } }
        poster.adds.release()
    }

    @Test("An older answer from macOS never overwrites a newer one")
    func olderAnswerDiscarded() async {
        let poster = FakeNotificationPoster(permission: .shown, answer: .denied)
        let notifier = makeNotifier(poster, clock: TestClock(), enabled: true)
        poster.reads.hold()
        // A read that began while macOS still showed the notifications...
        let stale = Task { await notifier.refreshPermission() }
        await waitBounded("the older read to begin") { await poster.reads.waitForArrivals(1) }
        // ...is overtaken by a request that macOS answers with a denial.
        await notifier.setEnabled(true)
        #expect(notifier.optIn.state == .denied)
        poster.reads.release()
        await waitBounded("the older read to return") { await stale.value }
        #expect(notifier.optIn.state == .denied)
        #expect(!notifier.optIn.isToggleOn)
    }

    @Test("Turning notifications on later replays nothing that happened while they were off")
    func noReplayAfterOptIn() async {
        let poster = FakeNotificationPoster(answer: .shown)
        let driver = ControllerDriver(percent: 76)
        let notifier = makeNotifier(poster, clock: driver.clock, enabled: false)
        await chargeToLimit(driver, notifier)
        await notifier.setEnabled(true)
        for _ in 0..<3 {
            notifier.observe(await driver.evaluate(80), trigger: .periodic)
        }
        await settle(notifier)
        #expect(poster.posted.isEmpty)
    }

    @Test("The controller does the same whether or not its statuses are notified about, and whatever posting does")
    func noEffectOnCharging() async {
        func run(notifying: Bool) async -> (ControllerStatus, [ChargeControlMode]) {
            let backend = MockChargingBackend()
            let driver = ControllerDriver(percent: 76, backend: backend)
            let poster = FakeNotificationPoster(permission: .shown)
            poster.failPosts(code: 1)
            let notifier = makeNotifier(poster, clock: driver.clock, enabled: true)
            for (percent, temperature) in [(76, 30.0), (80, 30), (80, 30), (80, 41)] {
                let status = await driver.evaluate(percent, temperature: temperature)
                if notifying {
                    notifier.observe(status, trigger: .periodic)
                }
            }
            await settle(notifier)
            return (await driver.controller.status, await backend.requestedModes)
        }
        let quiet = await run(notifying: false)
        let notified = await run(notifying: true)
        #expect(notified.0 == quiet.0)
        #expect(notified.1 == quiet.1)
        #expect(quiet.1 == [.inhibitCharging])
    }
}

/// A weak reference, readable from any thread.
final class WeakReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _object: AnyObject?

    var object: AnyObject? {
        get { lock.withLock { _object } }
        set { lock.withLock { _object = newValue } }
    }
}
