@testable import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600

/// After a relaunch the notifier remembers nothing it posted; it reconciles
/// Notification Center, which keeps what an earlier run posted, with the
/// request that holds now.
@MainActor
@Suite("Calibration: requests reconciled after a relaunch")
struct CalibrationReconciliationTests {
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

    /// A first run posts the rest's request and quits; returns the request
    /// and the relaunched rig.
    private func postedRestThenRelaunched(_ poster: FakeNotificationPoster, reading: BatterySnapshot = calibrationReading(18, .battery)) async throws -> (PlannedNotification, CalibrationRig) {
        let rig = CalibrationRig()
        let first = await makeNotifier(poster, clock: rig.clock)
        first.observe(await rig.drive(to: .drain), trigger: .periodic)
        rig.clock.advance(by: 4 * hour)
        first.observe(await rig.read(calibrationReading(20, .battery)), trigger: .periodic)
        await settle(first)
        let rest = try #require(poster.posted.last)
        #expect(rest.kind == .calibrationRest)
        await rig.controller.shutdown(reason: "shutting down")
        rig.clock.advance(by: hour)
        return (rest, rig.relaunched(reading: reading))
    }

    @Test("A request posted before a relaunch is kept while it still holds, and removed once the session ends")
    func relaunchThenCancel() async throws {
        let poster = FakeNotificationPoster(permission: .shown)
        let (rest, second) = try await postedRestThenRelaunched(poster)
        let listedBefore = poster.listings
        let notifier = await makeNotifier(poster, clock: second.clock)
        notifier.observe(await second.controller.evaluate(.launch), trigger: .launch)
        await settle(notifier)
        #expect(poster.listings == listedBefore + 1)
        #expect(poster.removed.isEmpty, "the paused session's rest still holds")
        notifier.observe(await second.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
        #expect(poster.identifiers.isEmpty)
    }

    @Test("A request kept by reconciliation is withdrawn like one this run posted: turning notifications off removes it, and cancelling then removes nothing more")
    func keptThenOptOutThenCancel() async throws {
        let poster = FakeNotificationPoster(permission: .shown)
        let (rest, second) = try await postedRestThenRelaunched(poster)
        let notifier = await makeNotifier(poster, clock: second.clock)
        notifier.observe(await second.controller.evaluate(.launch), trigger: .launch)
        await settle(notifier)
        #expect(poster.removed.isEmpty, "kept: the paused session's rest holds")
        await notifier.setEnabled(false)
        notifier.observe(await second.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
        #expect(poster.identifiers.isEmpty)
    }

    @Test("Turning notifications off before the list arrives: the request it would have kept is removed")
    func optOutBeforeListing() async throws {
        let poster = FakeNotificationPoster(permission: .shown)
        let (rest, second) = try await postedRestThenRelaunched(poster)
        let notifier = await makeNotifier(poster, clock: second.clock)
        poster.listing.hold()
        let listedBefore = poster.listings
        notifier.observe(await second.controller.evaluate(.launch), trigger: .launch)
        await waitBounded("the listing to be asked for") {
            while poster.listings == listedBefore { await Task.yield() }
        }
        await notifier.setEnabled(false)
        poster.listing.release()
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
        notifier.observe(await second.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
    }

    @Test("A request kept by reconciliation is withdrawn when the session ends, with notifications on")
    func keptThenCancelOnce() async throws {
        let poster = FakeNotificationPoster(permission: .shown)
        let (rest, second) = try await postedRestThenRelaunched(poster)
        let notifier = await makeNotifier(poster, clock: second.clock)
        notifier.observe(await second.controller.evaluate(.launch), trigger: .launch)
        await settle(notifier)
        notifier.observe(await second.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]], "once, by its withdrawal; reconciliation leaves it to that")
    }

    @Test("A request posted before a relaunch is removed once a newer request replaces it")
    func relaunchThenRestAgain() async throws {
        let poster = FakeNotificationPoster(permission: .shown)
        let (rest, second) = try await postedRestThenRelaunched(poster)
        let notifier = await makeNotifier(poster, clock: second.clock)
        notifier.observe(await second.controller.evaluate(.launch), trigger: .launch)
        let continued = await second.controller.continueCalibration()
        #expect(continued.calibration.session?.isRestAgainRequested == true)
        notifier.observe(continued, trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
    }

    @Test("A session's end report is not a request: reconciliation keeps it, also after a relaunch")
    func reportSurvives() async throws {
        let rig = CalibrationRig()
        let poster = FakeNotificationPoster(permission: .shown)
        let first = await makeNotifier(poster, clock: rig.clock)
        first.observe(await rig.drive(to: .drain), trigger: .periodic)
        rig.clock.advance(by: hour)
        first.observe(await rig.read(calibrationReading(15, .battery)), trigger: .periodic)
        await settle(first)
        let report = try #require(poster.posted.last)
        #expect(report.kind == .calibrationEndedEarly)
        #expect(poster.listings >= 1)
        #expect(poster.identifiers.contains(report.identifier))
        let second = rig.relaunched(reading: calibrationReading(15, .battery))
        let notifier = await makeNotifier(poster, clock: rig.clock)
        notifier.observe(await second.controller.evaluate(.launch), trigger: .launch)
        await settle(notifier)
        #expect(poster.identifiers.contains(report.identifier))
        #expect(!poster.removed.contains { $0.contains(report.identifier) })
    }

    @Test("Nothing is listed or removed before the owner opts in; opting in reconciles at the next status")
    func notBeforeOptIn() async throws {
        let poster = FakeNotificationPoster(permission: .shown)
        let (rest, second) = try await postedRestThenRelaunched(poster)
        let listedBefore = poster.listings
        let notifier = await makeNotifier(poster, clock: second.clock, enabled: false)
        notifier.observe(await second.controller.evaluate(.launch), trigger: .launch)
        notifier.observe(await second.controller.cancelCalibration(), trigger: .overrideChanged)
        await settle(notifier)
        #expect(poster.listings == listedBefore)
        #expect(poster.removed.isEmpty)
        await notifier.setEnabled(true)
        notifier.observe(await second.controller.evaluate(.periodic), trigger: .periodic)
        await settle(notifier)
        #expect(poster.removed == [[rest.identifier]])
    }

    @Test("Calibration requests and reports carry their own prefixes")
    func prefixes() async throws {
        let poster = FakeNotificationPoster(permission: .shown)
        let (rest, _) = try await postedRestThenRelaunched(poster)
        #expect(rest.identifier.hasPrefix(NotificationWording.calibrationRequestPrefix))
        #expect(!"calibration.report.x".hasPrefix(NotificationWording.calibrationRequestPrefix))
    }
}
