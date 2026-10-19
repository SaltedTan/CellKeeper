import Foundation
import IOKit.pwr_mgt
import ProbeCore

/// The probe's one `ChargeInhibit` assertion.
///
/// This is the only code in the project that creates a power assertion. It
/// creates at most one, only as root, and never after a stop was requested.
/// One lock covers creation, release and the stop latch, so the signal
/// handler, which runs on another thread, cannot race them.
///
/// Fail-safes, in order:
/// 1. the probe releases it after the hold, on a stop signal, on an early
///    end, and in a `defer` on every path out of `run`; a release that
///    fails keeps the ID and is retried, a bounded number of times per call;
/// 2. it carries a timeout (hold + 30 s) with `kIOPMAssertionTimeoutActionRelease`,
///    so powerd releases it if the probe stalls;
/// 3. powerd releases every assertion a process owns when the process exits,
///    however it exits (`HandleProcessExit` in Apple's published
///    PowerManagement source).
final class AssertionHolder: @unchecked Sendable {
    /// Attempts per call to ``release()``, 0.2 s apart.
    static let releaseAttemptsPerCall = 3

    private let lock = NSLock()
    private let clock: Clock
    private var assertionID: IOPMAssertionID?
    private var attempted = false
    private var cancelled = false
    private var firstReleaseTime: Double?
    private var releaseResults: [Int32] = []

    init(clock: Clock) {
        self.clock = clock
    }

    /// The properties passed to `IOPMAssertionCreateWithProperties`. Keys
    /// and the timeout action are public constants from
    /// `IOKit/pwr_mgt/IOPMLib.h`; the type string is from Apple's open
    /// source (`kIOPMAssertionTypeInhibitCharging` in IOKitUser's
    /// `IOPMLibPrivate.h`).
    static func properties(hold: Int) -> [String: Any] {
        [
            kIOPMAssertionTypeKey: ProbeAssertion.type,
            kIOPMAssertionNameKey: ProbeAssertion.name,
            kIOPMAssertionDetailsKey: ProbeAssertion.details,
            kIOPMAssertionLevelKey: NSNumber(value: kIOPMAssertionLevelOn),
            kIOPMAssertionTimeoutKey: NSNumber(value: ProbeAssertion.timeout(hold: hold)),
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
    }

    /// Creates the assertion and returns powerd's IOReturn, or nil without
    /// calling powerd if the process is not root, a stop was requested, or
    /// an assertion was attempted before.
    func create(hold: Int) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard geteuid() == 0, !cancelled, !attempted else { return nil }
        attempted = true
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithProperties(Self.properties(hold: hold) as CFDictionary, &newID)
        if result == kIOReturnSuccess {
            assertionID = newID
        }
        return result
    }

    /// Latches the stop, so ``create(hold:)`` refuses from now on, and
    /// releases the assertion if one is held. For the signal handler.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        release()
    }

    /// Releases the assertion if the probe still holds it, trying up to
    /// ``releaseAttemptsPerCall`` times. The ID is forgotten only once
    /// `IOPMAssertionRelease` succeeds. Safe to call from any thread.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let id = assertionID else { return }
        if firstReleaseTime == nil { firstReleaseTime = clock.now }
        for attempt in 1...Self.releaseAttemptsPerCall {
            let result = IOPMAssertionRelease(id)
            releaseResults.append(result)
            if result == kIOReturnSuccess {
                assertionID = nil
                return
            }
            if attempt < Self.releaseAttemptsPerCall {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    /// The release as the verdict needs it, without the listing check; nil
    /// if no release was attempted.
    var releaseRecord: (time: Double, result: Int32, attempts: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let time = firstReleaseTime, let last = releaseResults.last else { return nil }
        return (time, last, releaseResults.count)
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }
}
