import Foundation
import IOKit.pwr_mgt
import ProbeCore

/// The probe's one private assertion, `DisableInflow` or `ChargeInhibit`.
///
/// This and ``IdleSleepAssertion`` are the only code in the project that
/// create a power assertion. It creates at most one, only as root, and
/// never after a stop was requested. One lock covers creation, release and
/// the stop latch, so the signal handler and the sleep notification, which
/// run on other threads, cannot race them.
///
/// Fail-safes, in order:
/// 1. the probe releases it after the hold, on a stop signal, on a system
///    sleep notification, on an early end, and in a `defer` on every path
///    out of `run`; a release that fails keeps the ID and is retried, a
///    bounded number of times per call;
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
    private let kind: AssertionKind
    private var assertionID: IOPMAssertionID?
    private var attempted = false
    private var cancelled = false
    private var firstReleaseTime: Double?
    private var releaseUnixTime: Double?
    private var releaseResults: [Int32] = []

    init(clock: Clock, kind: AssertionKind) {
        self.clock = clock
        self.kind = kind
    }

    /// The properties passed to `IOPMAssertionCreateWithProperties`. Keys
    /// and the timeout action are public constants from
    /// `IOKit/pwr_mgt/IOPMLib.h`; the type string is from Apple's open
    /// source (IOKitUser's `IOPMLibPrivate.h`).
    static func properties(kind: AssertionKind, hold: Int) -> [String: Any] {
        [
            kIOPMAssertionTypeKey: kind.type,
            kIOPMAssertionNameKey: kind.name,
            kIOPMAssertionDetailsKey: kind.details,
            kIOPMAssertionLevelKey: NSNumber(value: kIOPMAssertionLevelOn),
            kIOPMAssertionTimeoutKey: NSNumber(value: ProbeAssertion.timeout(hold: hold)),
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
    }

    enum CreateOutcome: Equatable {
        /// powerd was asked; its IOReturn, and the moment it returned (run
        /// seconds and Unix time).
        case attempted(Int32, time: Double, unixTime: Double)
        /// powerd was not asked, for this reason.
        case notAttempted(String)
    }

    /// Creates the assertion, unless the process is not root, a stop was
    /// requested, an assertion was attempted before, or `lastCheck` (run
    /// under the lock, immediately before the call to powerd) returns a
    /// reason not to.
    func create(hold: Int, lastCheck: () -> String?) -> CreateOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard geteuid() == 0 else { return .notAttempted("the probe is not running as root") }
        guard !cancelled else { return .notAttempted("a stop was requested") }
        guard !attempted else { return .notAttempted("an assertion was already attempted") }
        if let reason = lastCheck() { return .notAttempted(reason) }
        attempted = true
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithProperties(Self.properties(kind: kind, hold: hold) as CFDictionary, &newID)
        if result == kIOReturnSuccess {
            assertionID = newID
        }
        return .attempted(result, time: clock.now, unixTime: Clock.unixNow)
    }

    /// Latches the stop, so ``create(hold:lastCheck:)`` refuses from now on,
    /// and releases the assertion if one is held. For the signal handler and
    /// the sleep notification.
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
        defer { releaseUnixTime = Clock.unixNow }
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

    /// The release as the verdict needs it, without the listing check: when
    /// the first attempt began (run seconds), when the last returned (Unix
    /// time), its IOReturn and the number of attempts; nil if no release was
    /// attempted.
    var releaseRecord: (time: Double, unixTime: Double, result: Int32, attempts: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let time = firstReleaseTime, let unixTime = releaseUnixTime, let last = releaseResults.last else { return nil }
        return (time, unixTime, last, releaseResults.count)
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }
}

/// The run's public `PreventUserIdleSystemSleep` assertion
/// (`kIOPMAssertionTypePreventUserIdleSystemSleep`, `IOPMLib.h`): if the Mac
/// runs from its battery, idle sleep becomes likelier during a run of
/// several minutes. It stops idle sleep only, not a closed lid or the Apple
/// menu (research note 10 §4, §7). Created only by `run`, only as root,
/// with a timeout that covers the longest run plus 120 s; released after
/// the private assertion, in a `defer`, and by powerd when the probe exits.
final class IdleSleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?

    static func properties(hold: Int) -> [String: Any] {
        [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: ProbeAssertion.idleSleepName,
            kIOPMAssertionLevelKey: NSNumber(value: kIOPMAssertionLevelOn),
            kIOPMAssertionTimeoutKey: NSNumber(value: ProbeAssertion.idleSleepTimeout(hold: hold)),
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
    }

    /// Creates the assertion unless the process is not root or it exists;
    /// returns the IOReturn.
    func create(hold: Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard geteuid() == 0 else { return Int32(bitPattern: 0xE000_02C1) }
        guard assertionID == nil else { return kIOReturnSuccess }
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithProperties(Self.properties(hold: hold) as CFDictionary, &newID)
        if result == kIOReturnSuccess {
            assertionID = newID
        }
        return result
    }

    /// Releases the assertion if it is held, trying up to 3 times; returns
    /// the last IOReturn, or nil if nothing was held.
    @discardableResult
    func release() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = assertionID else { return nil }
        var result = kIOReturnError
        for attempt in 1...AssertionHolder.releaseAttemptsPerCall {
            result = IOPMAssertionRelease(id)
            if result == kIOReturnSuccess {
                assertionID = nil
                break
            }
            if attempt < AssertionHolder.releaseAttemptsPerCall {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        return result
    }
}
