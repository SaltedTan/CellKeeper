import CellKeeperCore
import CellKeeperHelperCore
import CellKeeperKit
import Foundation
import Testing

/// Phase 4a registers no helper, so its removal never contacts one.
@Suite("No helper registration")
struct NoHelperRegistrationTests {
    /// Counts connections and refuses them.
    final class CountingTransport: HelperTransport, @unchecked Sendable {
        struct Refused: Error {}

        private let lock = NSLock()
        private var count = 0

        var connections: Int {
            lock.withLock { count }
        }

        func connect() async throws -> any HelperConnection {
            lock.withLock { count += 1 }
            throw Refused()
        }
    }

    @Test("Reports no helper registered")
    func reportsNotRegistered() async {
        let status = await NoHelperRegistration().status()
        #expect(status == .notRegistered)
        #expect(status.meansNoHelperRegistered)
    }

    @Test("Removal stops at the registration: no helper is contacted, nothing is unregistered, even when forced")
    func removalStopsAtTheRegistration() async {
        let transport = CountingTransport()
        let removal = HelperRemoval(transport: transport, registration: NoHelperRegistration())
        let outcome = await removal.remove()
        let forced = await removal.remove(force: .userHasSeenRecoveryProcedure)
        #expect(outcome == .nothingToRemove(.notRegistered))
        #expect(forced == .nothingToRemove(.notRegistered))
        #expect(transport.connections == 0)
    }
}
