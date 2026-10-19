/// The outcome of releasing the probe's private assertion.
public enum ReleaseOutcome: Sendable, Equatable {
    /// Nothing was held: none was created, or it was already released.
    case nothingHeld
    /// `IOPMAssertionRelease` succeeded.
    case released
    /// Every attempt failed: the last IOReturn and how many attempts were
    /// made.
    case failed(result: Int32, attempts: Int)
}

/// What the probe does when the system announces sleep
/// (`kIOMessageSystemWillSleep`; research note 10 §4, §7). It depends only
/// on the closures it is given, so the tests can fake them.
public enum SleepResponse {
    /// The exit status when the probe exits because the release failed: the
    /// same as a run after which charging did not resume, so that the owner
    /// follows the recovery steps.
    public static let failedReleaseExitStatus: Int32 = 3

    /// Releases the private assertion through `release` (which also latches
    /// the run's stop against a later creation), then:
    /// - if `IOPMAssertionRelease` succeeded, or none was held, records the
    ///   sleep notice in memory through `recordNotice` (a lock held only
    ///   briefly) and calls `acknowledge`, which allows the sleep. No I/O:
    ///   the main thread writes the notice into the report, and the verdict
    ///   is inconclusive;
    /// - if every attempt failed, never acknowledges, and hands one line
    ///   saying so, and ``failedReleaseExitStatus``, to `emergencyExit`. In
    ///   the probe that is ``EmergencyExit/perform(_:status:steps:)``: a 2 s
    ///   exit deadline, then the line in the report file, then `_exit`; it
    ///   does not return. powerd frees every assertion of a process that
    ///   exits (`HandleProcessExit` in Apple's published PowerManagement
    ///   source), and without an acknowledgement the system waits until the
    ///   client is gone, or for its acknowledgement timeout (about 30 s),
    ///   before it sleeps.
    ///
    /// It runs on the sleep queue, where nothing may block (``SleepQueue``).
    @discardableResult
    public static func willSleep(
        assertion: AssertionKind,
        release: () -> ReleaseOutcome,
        recordNotice: () -> Void,
        acknowledge: () -> Void,
        emergencyExit: (_ line: String, _ status: Int32) -> Void
    ) -> ReleaseOutcome {
        let outcome = release()
        if case let .failed(result, attempts) = outcome {
            emergencyExit(failureLine(assertion, result: result, attempts: attempts), failedReleaseExitStatus)
            return outcome
        }
        recordNotice()
        acknowledge()
        return outcome
    }

    /// The probe's handler for `kIOMessageSystemWillSleep`, as it runs on
    /// the sleep queue: it decides through
    /// ``willSleep(assertion:release:recordNotice:acknowledge:emergencyExit:)``.
    /// It is given no console and, apart from the emergency exit, no file.
    public static func willSleepHandler(
        assertion: AssertionKind,
        release: @escaping @Sendable () -> ReleaseOutcome,
        recordNotice: @escaping @Sendable () -> Void,
        emergencyExit: @escaping @Sendable (_ line: String, _ status: Int32) -> Void
    ) -> @Sendable (_ acknowledge: () -> Void) -> Void {
        { acknowledge in
            willSleep(
                assertion: assertion,
                release: release,
                recordNotice: recordNotice,
                acknowledge: acknowledge,
                emergencyExit: emergencyExit
            )
        }
    }

    /// The one line recorded when the release failed. It never says the
    /// assertion was released.
    static func failureLine(_ assertion: AssertionKind, result: Int32, attempts: Int) -> String {
        """
        kIOMessageSystemWillSleep: for the \(assertion.type) assertion, \
        \(ReleaseWording.failed(attempts: attempts, result: result)). The probe does not allow \
        the sleep and exits now. Run `pmset -g assertions` and follow the recovery steps \
        (\(assertion.note) §7).
        """
    }
}

/// The run's teardown, in the order of research note 10 §4: the private
/// assertion first (with retries), then the idle-sleep assertion, then the
/// sleep notifications. A stop signal or a sleep notification releases the
/// private assertion at once; the rest follows when the run finishes. Every
/// step is harmless to repeat.
public final class Teardown: @unchecked Sendable {
    private let releasePrivate: @Sendable () -> ReleaseOutcome
    private let releaseIdleSleep: @Sendable () -> Void
    private let deregisterSleep: @Sendable () -> Void

    public init(
        releasePrivate: @escaping @Sendable () -> ReleaseOutcome,
        releaseIdleSleep: @escaping @Sendable () -> Void,
        deregisterSleep: @escaping @Sendable () -> Void
    ) {
        self.releasePrivate = releasePrivate
        self.releaseIdleSleep = releaseIdleSleep
        self.deregisterSleep = deregisterSleep
    }

    /// For a stop signal or a sleep notification: releases the private
    /// assertion now.
    @discardableResult
    public func stop() -> ReleaseOutcome {
        releasePrivate()
    }

    /// At the end of the run, and in a `defer` on every path out of it.
    public func finish() {
        _ = releasePrivate()
        releaseIdleSleep()
        deregisterSleep()
    }
}
