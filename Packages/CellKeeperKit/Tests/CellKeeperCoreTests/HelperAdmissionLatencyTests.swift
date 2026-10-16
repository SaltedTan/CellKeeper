@testable import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// Delays taken in turn, round and round.
final class DelayScript: @unchecked Sendable {
    private let lock = NSLock()
    private let delays: [TimeInterval]
    private var index = 0

    init(_ delays: [TimeInterval]) {
        self.delays = delays
    }

    func next() -> TimeInterval {
        lock.withLock {
            defer { index = (index + 1) % delays.count }
            return delays[index]
        }
    }
}

/// The helper judges its request budget when it admits a request, at a
/// moment the backend cannot see (issue #67). These tests move the test
/// clock between the backend's sending of a request and the helper's
/// admission of it, and between the reply and its arrival, as a loaded Mac,
/// App Nap or the NSXPC transport would; nothing waits on the real clock.
@Suite("Helper backend: late admission")
struct HelperAdmissionLatencyTests {
    private typealias Exchange = TestHelperConnection.Exchange

    private static func isBudgetRefusal(_ event: HelperEvent) -> Bool {
        if case .requestRejected(_, _, .rateLimited) = event { true } else { false }
    }

    private static func isRevocation(_ event: HelperEvent) -> Bool {
        if case .sessionRevoked = event { true } else { false }
    }

    @Test("A hello admitted late, then a hold and its release, leaves no request refused")
    func lateHelloThenRelease() async throws {
        let rig = HelperRig()
        let clock = rig.clock
        // Admitted a quarter of a second after it was sent, while the
        // helper's budget is still full, so the helper's refill in that
        // time is lost at its cap.
        rig.transport.beforeAdmission = { kind in
            if kind == .hello { clock.advance(by: 0.25) }
        }
        #expect(await rig.backend.capabilities().supportedModes == ChargeControlMode.chargingModes)
        #expect(try await rig.backend.setMode(.inhibitCharging) == .simulated)
        // The release's clear and lease release go without waiting, and the
        // helper may spend its last token on them; the read that confirms
        // the release then waits for a token the helper has. (Before #67 the
        // helper refused that read, as in CI.)
        #expect(try await rig.backend.setMode(.normal) == .simulated)
        #expect(rig.control.activeControls.isEmpty)
        #expect(!rig.events.contains(where: Self.isBudgetRefusal))
    }

    @Test("Holds, switches and releases whose requests are admitted and answered late stay within the helper's budget")
    func lateBursts() async throws {
        let rig = HelperRig()
        let clock = rig.clock
        let admission = DelayScript([0.25, 0, 0.7, 0.05, 0, 1.5, 0.4, 0, 0.45, 0.1, 3, 0])
        let reply = DelayScript([0, 0.3, 0, 0, 1.2, 0.05, 0, 0.6])
        rig.transport.beforeAdmission = { _ in clock.advance(by: admission.next()) }
        rig.transport.beforeReply = { _ in clock.advance(by: reply.next()) }
        for _ in 0..<8 {
            _ = await rig.backend.capabilities()
            #expect(try await rig.backend.setMode(.inhibitCharging) == .simulated)
            #expect(try await rig.backend.currentMode() == .inhibitCharging)
            try await rig.backend.renewHold(.inhibitCharging)
            #expect(try await rig.backend.setMode(.forceDischarge) == .simulated)
            #expect(try await rig.backend.currentMode() == .forceDischarge)
            #expect(try await rig.backend.setMode(.normal) == .simulated)
            clock.advance(by: HelperEngine.minimumActivationInterval)
        }
        #expect(!rig.events.contains(where: Self.isBudgetRefusal))
        #expect(!rig.events.contains(where: Self.isRevocation))
        #expect(rig.transport.connections.count == 1)
    }

    @Test("A read the helper's budget refuses is sent once more, after a wait for a whole token")
    func refusedReadSentAgain() async throws {
        let rig = HelperRig()
        _ = try await rig.backend.setMode(.inhibitCharging)
        let connection = try #require(rig.transport.latest)
        let before = connection.exchanges.count
        // Something the backend does not know of spends the session's
        // budget just before its next read.
        connection.spendBudget(before: .readState)
        let start = rig.clock.uptime

        #expect(try await rig.backend.currentMode() == .inhibitCharging)
        #expect(Array(connection.exchanges.dropFirst(before)) == [
            Exchange(request: .readState, status: .rateLimited),
            Exchange(request: .readState, status: .ok),
        ])
        #expect(rig.clock.uptime - start >= 1 / HelperEngine.requestsPerSecond)
        #expect(await rig.backend.reportedModeOrigin() == nil)
        #expect(!rig.events.contains(where: Self.isRevocation))
    }

    @Test("A read refused twice is a failure that names the request budget, and nothing is read from the refusals")
    func readRefusedTwice() async throws {
        let rig = HelperRig()
        _ = try await rig.backend.setMode(.inhibitCharging)
        let connection = try #require(rig.transport.latest)
        let before = connection.exchanges.count
        connection.spendBudget(before: .readState, times: 2)

        await #expect(throws: BackendError.operationFailed("CellKeeper's helper did not report its state: its request budget refused the read, and again after CellKeeper waited for a token (rateLimited)")) {
            try await rig.backend.currentMode()
        }
        #expect(Array(connection.exchanges.dropFirst(before)) == Array(repeating: Exchange(request: .readState, status: .rateLimited), count: 2))
        // A refused reply lists no active control; none of it is taken as
        // the helper's state: no mode, no release, no change of ownership.
        #expect(await rig.backend.reportedModeOrigin() == nil)
        #expect(await rig.backend.isReportedModeOwn() == nil)
        #expect(await rig.backend.capabilities().supportedModes == ChargeControlMode.chargingModes)
        #expect(rig.control.activeControls == [.chargingInhibited])
        #expect(try await rig.backend.currentMode() == .inhibitCharging)
        #expect(await rig.backend.isReportedModeOwn() == true)
        #expect(!rig.events.contains(where: Self.isRevocation))
    }

    @Test("An activation refused with rateLimited is never sent again by the backend, and is reported as refused")
    func refusedActivationNotSentAgain() async throws {
        let rig = HelperRig()
        _ = await rig.backend.capabilities()
        let connection = try #require(rig.transport.latest)
        let refused = BackendError.operationFailed("CellKeeper's helper refused to set charging inhibited (rateLimited: its request budget or the control's activation limit)")
        func activations() -> [HelperStatus] {
            connection.exchanges.filter { $0.request == .setControl }.map(\.status)
        }

        // Refused by the request budget.
        connection.spendBudget(before: .setControl)
        await #expect(throws: refused) {
            try await rig.backend.setMode(.inhibitCharging)
        }
        #expect(activations() == [.rateLimited])
        #expect(rig.control.activeControls.isEmpty)
        #expect(try await rig.backend.currentMode() == .normal)

        // Refused by the control's activation limit (R13), which replies the
        // same.
        rig.clock.advance(by: HelperEngine.minimumActivationInterval)
        _ = try await rig.backend.setMode(.inhibitCharging)
        _ = try await rig.backend.setMode(.normal)
        await #expect(throws: refused) {
            try await rig.backend.setMode(.inhibitCharging)
        }
        #expect(activations() == [.rateLimited, .ok, .rateLimited])
        #expect(rig.control.activeControls.isEmpty)
        #expect(try await rig.backend.currentMode() == .normal)
        #expect(!rig.events.contains(where: Self.isRevocation))
    }
}
