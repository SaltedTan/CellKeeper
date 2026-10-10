@testable import CellKeeperHelperXPC
import Foundation
import Testing

@Suite("Helper NSXPC client timeouts")
struct HelperXPCClientTimeoutTests {
    @Test("Durations convert to Dispatch intervals exactly, and one too long to represent never fires")
    func dispatchIntervals() {
        #expect(HelperXPCClient.dispatchInterval(.seconds(10)) == .nanoseconds(10_000_000_000))
        #expect(HelperXPCClient.dispatchInterval(.milliseconds(300)) == .nanoseconds(300_000_000))
        #expect(HelperXPCClient.dispatchInterval(.nanoseconds(1)) == .nanoseconds(1))
        #expect(HelperXPCClient.dispatchInterval(.seconds(Int64.max)) == .never)
    }

    @Test("The default scheduler runs the timeout once its delay has passed, not before")
    func defaultScheduler() async {
        let start = ContinuousClock.now
        let fired: ContinuousClock.Instant = await withCheckedContinuation { continuation in
            HelperXPCClient.dispatchScheduler(.milliseconds(50)) {
                continuation.resume(returning: ContinuousClock.now)
            }
        }
        #expect(fired - start >= .milliseconds(50))
    }
}
