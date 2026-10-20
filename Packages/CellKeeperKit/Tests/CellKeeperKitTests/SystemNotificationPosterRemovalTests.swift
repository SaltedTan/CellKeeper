import CellKeeperCore
@testable import CellKeeperKit
import Foundation
import Testing

/// What the system poster handed to its center and asked it to remove, in
/// order.
private final class CenterRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] { lock.withLock { _events } }

    func append(_ event: String) {
        lock.withLock { _events.append(event) }
    }
}

/// A center that answers an add only when the test says so, and the poster's
/// timeout, fired only when the test says so.
private final class DelayedCenter: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [String: @Sendable ((any Error)?) -> Void] = [:]
    private var expiries: [@Sendable () -> Void] = []
    let record = CenterRecord()

    func submit(_ identifier: String, _ completion: @escaping @Sendable ((any Error)?) -> Void) {
        lock.withLock { completions[identifier] = completion }
        record.append("add \(identifier)")
    }

    func schedule(_ expire: @escaping @Sendable () -> Void) {
        lock.withLock { expiries.append(expire) }
    }

    var hasSubmission: Bool { lock.withLock { !completions.isEmpty } }

    func expireAll() {
        let pending = lock.withLock { () -> [@Sendable () -> Void] in
            defer { expiries = [] }
            return expiries
        }
        for expire in pending { expire() }
    }

    /// The center shows the notification, late.
    func complete(_ identifier: String) {
        let completion = lock.withLock { completions.removeValue(forKey: identifier) }
        record.append("shown \(identifier)")
        completion?(nil)
    }
}

@Suite("System notification poster: identities and withdrawals")
struct SystemNotificationPosterRemovalTests {
    @Test("A notification is handed over under its own identifier, and a removal runs after the hand-overs queued before it")
    func removalAfterHandOver() async throws {
        let record = CenterRecord()
        let poster = SystemNotificationPoster(
            submission: { request, completion in
                record.append("add \(request.identifier)")
                completion(nil)
            },
            removal: { identifiers in
                record.append("remove \(identifiers.joined(separator: ","))")
            }
        )
        let rest = PlannedNotification(kind: .calibrationRest, title: "Calibration: rest your Mac unplugged", body: "…", identifier: "calibration.session.rest")
        #expect(await poster.add(rest, in: NotificationGeneration()) == .posted)
        await poster.remove(identifiers: [rest.identifier])
        for _ in 0..<200 where record.events.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(record.events == ["add calibration.session.rest", "remove calibration.session.rest"])
        // Other kinds keep their replacement keys as identifiers.
        #expect(SystemNotificationPoster.request(for: PlannedNotification(kind: .backendFault, title: "", body: "")).identifier == NotificationKind.backendFault.replacementKey)
    }

    @Test("An add the center answers only after its withdrawal is removed again when it completes")
    func lateCompletionRemovedAgain() async throws {
        let center = DelayedCenter()
        let poster = SystemNotificationPoster(
            submission: { request, completion in center.submit(request.identifier, completion) },
            removal: { identifiers in center.record.append("remove \(identifiers.joined(separator: ","))") },
            scheduleTimeout: { _, expire in center.schedule(expire) }
        )
        let rest = PlannedNotification(kind: .calibrationRest, title: "Calibration: rest your Mac unplugged", body: "…", identifier: "calibration.session.rest")
        async let posted = poster.add(rest, in: NotificationGeneration())
        for _ in 0..<200 where !center.hasSubmission {
            try await Task.sleep(for: .milliseconds(5))
        }
        center.expireAll()
        #expect(await posted == .unconfirmed)
        await poster.remove(identifiers: [rest.identifier])
        for _ in 0..<200 where center.record.events.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        center.complete(rest.identifier)
        for _ in 0..<200 where center.record.events.count < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(center.record.events == ["add calibration.session.rest", "remove calibration.session.rest", "shown calibration.session.rest", "remove calibration.session.rest"])
    }

    @Test("An add that completes before its withdrawal is removed once")
    func completedThenRemovedOnce() async throws {
        let record = CenterRecord()
        let poster = SystemNotificationPoster(
            submission: { request, completion in
                record.append("add \(request.identifier)")
                completion(nil)
            },
            removal: { identifiers in record.append("remove \(identifiers.joined(separator: ","))") }
        )
        let unplug = PlannedNotification(kind: .calibrationUnplug, title: "", body: "", identifier: "calibration.session.unplug")
        #expect(await poster.add(unplug, in: NotificationGeneration()) == .posted)
        await poster.remove(identifiers: [unplug.identifier])
        try await Task.sleep(for: .milliseconds(50))
        #expect(record.events == ["add calibration.session.unplug", "remove calibration.session.unplug"])
    }
}
