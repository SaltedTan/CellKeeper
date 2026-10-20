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
}
