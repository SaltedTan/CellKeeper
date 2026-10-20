@testable import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// A calibration's request that no longer holds is withdrawn from
/// Notification Center, and one still queued is not posted.
@MainActor
@Suite("Calibration: obsolete requests are withdrawn")
struct CalibrationWithdrawalTests {
    let storage = InMemoryStorage()

    private func makeNotifier(_ poster: FakeNotificationPoster, clock: TestClock, enabled: Bool = true) async -> ChargingNotifier {
        let store = SettingsStore(defaults: storage)
        store.saveNotificationsEnabled(enabled)
        let notifier = ChargingNotifier(poster: poster, store: store, uptime: { clock.uptime })
        if enabled {
            await notifier.refreshPermission()
        }
        return notifier
    }

    private func settle(_ notifier: ChargingNotifier) async {
        await waitBounded("posting to finish") { await notifier.waitForPosts() }
    }

    /// Drives `rig` to the rest at the bottom, observing each status from
    /// the drain on, so the rest's request is posted.
    private func resting(_ rig: CalibrationRig, _ notifier: ChargingNotifier) async -> ControllerStatus {
        notifier.observe(await rig.drive(to: .drain), trigger: .periodic)
        rig.clock.advance(by: 4 * hour)
        let status = await rig.read(calibrationReading(20, .battery))
        notifier.observe(status, trigger: .periodic)
        return status
    }

    @Test("Cancelling during the rest withdraws its request from Notification Center")
    func cancelWithdrawsRest() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        _ = await resting(rig, notifier)
        await settle(notifier)
        let rest = try #require(poster.posted.last)
        #expect(rest.kind == .calibrationRest)
        notifier.observe(await rig.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
    }

    @Test("A request that is done is withdrawn: the unplug request once the Mac is on battery power")
    func doneWithdrawn() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        notifier.observe(await rig.drive(to: .restAtTop), trigger: .periodic)
        rig.clock.advance(by: 2 * hour)
        notifier.observe(await rig.read(calibrationReading(100, charging: false, full: true)), trigger: .periodic)
        await settle(notifier)
        let unplug = try #require(poster.posted.last)
        #expect(unplug.kind == .calibrationUnplug)
        notifier.observe(await rig.read(calibrationReading(99, .battery), .powerSourceChanged), trigger: .powerSourceChanged)
        await settle(notifier)
        #expect(poster.removed == [[unplug.identifier]])
    }

    @Test("A request asked again replaces the first: the rest is withdrawn and the rest again posted under its own identity")
    func supersededWithdrawn() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        _ = await resting(rig, notifier)
        notifier.observe(await rig.read(calibrationReading(19, .battery), .willSleep), trigger: .willSleep)
        rig.clock.advance(by: hour)
        notifier.observe(await rig.read(calibrationReading(19, .battery), .didWake), trigger: .didWake)
        await settle(notifier)
        let posted = poster.posted
        #expect(posted.map(\.kind) == [.calibrationRest, .calibrationRest])
        #expect(posted[0].identifier != posted[1].identifier)
        #expect(poster.removed == [[posted[0].identifier]])
    }

    @Test("A request still queued when its session ends is not posted")
    func staleQueuedPostDropped() async {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        notifier.observe(await rig.drive(to: .drain), trigger: .periodic)
        rig.clock.advance(by: 4 * hour)
        // The rest's post waits for its permission read.
        poster.reads.hold()
        notifier.observe(await rig.read(calibrationReading(20, .battery)), trigger: .periodic)
        await waitBounded("the post to reach its permission read") { await poster.reads.waitForArrivals(2) }
        notifier.observe(await rig.controller.cancelCalibration(), trigger: .overrideChanged)
        poster.reads.release()
        await settle(notifier)
        #expect(poster.posted.isEmpty)
        #expect(poster.removed.count == 1)
    }

    @Test("Turning notifications off withdraws an outstanding request at once; ending the session later removes nothing more")
    func optOutThenCancel() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        _ = await resting(rig, notifier)
        await settle(notifier)
        let rest = try #require(poster.posted.last)
        await notifier.setEnabled(false)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
        notifier.observe(await rig.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
        // Turning them on again replays and removes nothing.
        await notifier.setEnabled(true)
        notifier.observe(await rig.controller.evaluate(.periodic), trigger: .periodic)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
        #expect(poster.posted == [rest])
    }

    @Test("Ending the session withdraws its request; turning notifications off afterwards removes nothing more")
    func cancelThenOptOut() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        _ = await resting(rig, notifier)
        await settle(notifier)
        let rest = try #require(poster.posted.last)
        notifier.observe(await rig.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        await notifier.setEnabled(false)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
    }

    @Test("An outstanding request survives a new generation: after turning notifications on again, the request ending still removes it")
    func outstandingAcrossGenerations() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        notifier.observe(await rig.drive(to: .restAtTop), trigger: .periodic)
        rig.clock.advance(by: 2 * hour)
        notifier.observe(await rig.read(calibrationReading(100, charging: false, full: true)), trigger: .periodic)
        await settle(notifier)
        let unplug = try #require(poster.posted.last)
        await notifier.setEnabled(true)
        notifier.observe(await rig.read(calibrationReading(99, .battery), .powerSourceChanged), trigger: .powerSourceChanged)
        await settle(notifier)
        #expect(poster.removed == [[unplug.identifier]])
    }

    @Test("A generation change does not drop a removal queued behind a post")
    func generationChangeKeepsRemoval() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        notifier.observe(await rig.drive(to: .drain), trigger: .periodic)
        rig.clock.advance(by: 4 * hour)
        poster.reads.hold()
        notifier.observe(await rig.read(calibrationReading(20, .battery)), trigger: .periodic)
        await waitBounded("the post to reach its permission read") { await poster.reads.waitForArrivals(2) }
        notifier.observe(await rig.controller.cancelCalibration(), trigger: .overrideChanged)
        // Turning notifications on again starts a new generation, which
        // stops the posts of the old one.
        await notifier.setEnabled(true)
        poster.reads.release()
        await settle(notifier)
        #expect(poster.posted.isEmpty)
        #expect(poster.removed.count == 1)
        #expect(poster.removed.first?.first?.hasSuffix(".rest") == true)
    }

    @Test("A withdrawal during the hand-over, before the center has the request, removes it again once it is shown")
    func withdrawnDuringHandOver() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        notifier.observe(await rig.drive(to: .drain), trigger: .periodic)
        rig.clock.advance(by: 4 * hour)
        // The rest's post passes every check and is held on its way to the
        // center, as in the hop into the poster.
        poster.adds.hold()
        notifier.observe(await rig.read(calibrationReading(20, .battery)), trigger: .periodic)
        await waitBounded("the post to reach the center's door") { await poster.adds.waitForArrivals(1) }
        notifier.observe(await rig.controller.cancelCalibration(), trigger: .overrideChanged)
        await waitBounded("the withdrawal to reach the center") {
            while poster.removed.isEmpty { await Task.yield() }
        }
        poster.adds.release()
        await settle(notifier)
        let rest = try #require(poster.posted.first)
        #expect(poster.events == ["remove \(rest.identifier)", "add \(rest.identifier)", "remove \(rest.identifier)"])
    }

    @Test("Without the owner's opt-in nothing is posted and Notification Center is not touched")
    func notOptedIn() async {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock, enabled: false)
        _ = await resting(rig, notifier)
        notifier.observe(await rig.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.posted.isEmpty)
        #expect(poster.removed.isEmpty)
        #expect(poster.permissionReads == 0)
    }

    @Test("A request that began on the owner's own command was never posted, so nothing is withdrawn when it ends")
    func ownCommandNothingToWithdraw() async {
        let rig = CalibrationRig()
        _ = await rig.drive(to: .restAtBottom)
        await rig.controller.shutdown(reason: "quit")
        rig.clock.advance(by: hour)
        let second = rig.relaunched(reading: calibrationReading(18, .battery))
        let poster = FakeNotificationPoster(permission: .shown)
        let notifier = await makeNotifier(poster, clock: rig.clock)
        notifier.observe(await second.controller.evaluate(.launch), trigger: .launch)
        let continued = await second.controller.continueCalibration()
        #expect(continued.calibration.session?.isRestAgainRequested == true)
        notifier.observe(continued, trigger: .overrideChanged)
        notifier.observe(await second.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.posted.isEmpty)
        #expect(poster.removed.isEmpty)
    }

    @Test("The planner lists what to withdraw; other kinds keep their identifiers")
    func plannerWithdrawals() async throws {
        let rig = CalibrationRig()
        var planner = NotificationPlanner()
        _ = planner.plan(await rig.drive(to: .restAtTop), trigger: .periodic, uptime: 1, isDelivering: true)
        rig.clock.advance(by: 2 * hour)
        let unplug = planner.planAll(await rig.read(calibrationReading(100, charging: false, full: true)), trigger: .periodic, uptime: 2, isDelivering: true)
        let posted = try #require(unplug.notifications.first)
        let session = try #require(await rig.controller.evaluate(.manual).calibration.session)
        #expect(posted.identifier == "calibration.\(session.id.uuidString).unplug")
        #expect(unplug.withdrawals.isEmpty)
        let drained = planner.planAll(await rig.read(calibrationReading(99, .battery), .powerSourceChanged), trigger: .powerSourceChanged, uptime: 3, isDelivering: true)
        #expect(drained.withdrawals == [posted.identifier])
        #expect(PlannedNotification(kind: .backendFault, title: "", body: "").identifier == NotificationKind.backendFault.replacementKey)
    }
}
