@testable import CellKeeperCore
import Foundation
import Testing

/// Ending a generation never waits: it marks the generation ended at once,
/// so no hand-over passes its check afterwards, while one that already
/// passed may still finish. Holds are on dispatch queues of their own,
/// never on Swift's cooperative pool; every wait is bounded.
@Suite("Notification generation")
struct NotificationGenerationTests {
    @Test("Ending returns at once, also while a hand-over that passed its check is still under way, which may then finish")
    func endNeverWaits() async {
        let generation = NotificationGeneration()
        let passed = TestSignal()
        let release = DispatchSemaphore(value: 0)
        let finished = TestSignal()
        DispatchQueue(label: "test.hand-over").async {
            guard generation.isCurrent else { return }
            passed.fire()
            release.wait()
            finished.fire()
        }
        await waitBounded("the hand-over to pass its check") { await passed.wait() }

        let ended = TestSignal()
        DispatchQueue(label: "test.ending").async {
            generation.end()
            ended.fire()
        }
        await waitBounded("ending to return") { await ended.wait() }
        let isHandOverHeld = !finished.isFired
        #expect(isHandOverHeld)
        #expect(!generation.isCurrent)

        release.signal()
        await waitBounded("the hand-over to finish") { await finished.wait() }
    }

    @Test("Once ended, a generation stays ended")
    func endedStaysEnded() {
        let generation = NotificationGeneration()
        #expect(generation.isCurrent)
        generation.end()
        generation.end()
        #expect(!generation.isCurrent)
    }
}

/// The bounded waits the notification tests rely on.
@Suite("Bounded waits")
struct BoundedWaitTests {
    @Test("A wait that expires records an issue, and its cancelled polling task stops within the second bound")
    func expiryStopsPolling() async {
        let polled = TestSignal()
        let stopped = TestSignal()
        // The wait expires once the condition has been polled, so the
        // polling is under way when it is cancelled.
        await withKnownIssue {
            await waitBounded("a condition that never holds", expiry: { await polled.wait() }) {
                await until {
                    polled.fire()
                    return false
                }
                stopped.fire()
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("Timed out") }
        }
        // Without a second issue, which the known issue above does not
        // match, the polling returned within the second bound, so it no
        // longer polls.
        #expect(stopped.isFired)
    }

    @Test("With an expiry that never comes, the watchdog still ends the wait, with an issue of its own")
    func expiryWatchdog() async {
        let stopped = TestSignal()
        await withKnownIssue {
            // The expiry never comes; it only ends when cancelled.
            await waitBounded("a condition that never holds", seconds: 0.05, expiry: { try? await Task.sleep(for: .seconds(3600)) }) {
                await until { false }
                stopped.fire()
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("never came") || $0.rawValue.contains("Timed out") }
        }
        #expect(stopped.isFired)
    }

    @Test("A wait that finishes in time returns the value and records nothing")
    func finishesInTime() async {
        let value = await boundedValue("a value") { 7 }
        #expect(value == 7)
    }
}
