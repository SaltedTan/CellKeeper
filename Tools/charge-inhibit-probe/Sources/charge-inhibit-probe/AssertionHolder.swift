import Foundation
import IOKit.pwr_mgt
import ProbeCore

/// The probe's one `ChargeInhibit` assertion.
///
/// This is the only code in the project that creates a power assertion. It
/// creates at most one, only as root, and releases it at most once; a lock
/// makes creation and release safe against the signal handler, which
/// releases from another thread.
///
/// Fail-safes, in order:
/// 1. the probe releases it after the hold, on a stop signal, on an early
///    end, and in a `defer` on every path out of `run`;
/// 2. it carries a timeout (hold + 30 s) with `kIOPMAssertionTimeoutActionRelease`,
///    so powerd releases it if the probe stalls;
/// 3. powerd releases every assertion a process owns when the process exits,
///    however it exits (`HandleProcessExit` in Apple's published
///    PowerManagement source).
final class AssertionHolder: @unchecked Sendable {
    /// `kIOReturnNotPrivileged` (IOReturn.h), returned without calling
    /// powerd when the probe is not root.
    static let notPrivileged = Int32(bitPattern: 0xE000_02C1)
    /// `kIOReturnError`, returned if a second creation is attempted.
    static let error = Int32(bitPattern: 0xE000_02BC)

    private let lock = NSLock()
    private let clock: Clock
    private var assertionID: IOPMAssertionID?
    private var created = false
    private var releaseTime: Double?
    private var releaseReturn: Int32?

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

    /// Creates the assertion. Refuses, without calling powerd, unless the
    /// process runs as root, and if an assertion was created before.
    func create(hold: Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard geteuid() == 0 else { return Self.notPrivileged }
        guard !created else { return Self.error }
        created = true
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithProperties(Self.properties(hold: hold) as CFDictionary, &newID)
        if result == kIOReturnSuccess {
            assertionID = newID
        }
        return result
    }

    /// Releases the assertion if the probe still holds it. Safe to call any
    /// number of times, from any thread.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let id = assertionID else { return }
        assertionID = nil
        releaseReturn = IOPMAssertionRelease(id)
        releaseTime = clock.now
    }

    /// When the probe released the assertion, in run seconds.
    var releasedAt: Double? {
        lock.lock()
        defer { lock.unlock() }
        return releaseTime
    }

    /// The IOReturn of `IOPMAssertionRelease`.
    var releaseResult: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return releaseReturn
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }
}
