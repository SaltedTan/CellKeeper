import Foundation

/// The one deadline over the end of `watch` (code review r3 of #101, must
/// 1). Every ending path arms it as its very first action: before it tears
/// anything down, drains the sleep queue, claims the report's save or waits
/// for the console. From then on nothing in the ending can outlast it:
/// SIGALRM's default action ends the process, whatever is blocked, as #98's
/// emergency exit does (``EmergencyExit``). So a path that waits for
/// another's save needs no timeout of its own (``OneShotSave``).
///
/// It is never cancelled: every ending exits the process. A later ending
/// path arms it again, which moves the same process-wide deadline and never
/// removes it.
public final class EndingWatchdog: @unchecked Sendable {
    public struct Hooks: Sendable {
        /// Arms the process-wide deadline, `seconds` from now.
        public var arm: @Sendable (_ seconds: UInt32) -> Void

        public init(arm: @escaping @Sendable (_ seconds: UInt32) -> Void) {
            self.arm = arm
        }

        /// `watch`'s: SIGALRM back to its default action, which ends the
        /// process, then `alarm(2)`.
        public static let real = Hooks { seconds in
            signal(SIGALRM, SIG_DFL)
            alarm(seconds)
        }
    }

    /// The most the end waits for the sleep queue's drain.
    public static let sleepDrainBound = 2.0
    /// The most the report's save should take: #98's emergency exit's
    /// deadline.
    public static let saveBound = Double(EmergencyExit.deadline)
    /// Time for the steps between the bounded ones: the teardown, the
    /// report's rendering, the exit.
    public static let margin = 1.0
    /// The deadline, in seconds, from the arm: the sleep queue's drain, the
    /// save, the console's drain (``BoundedEnd/drainBound``) and the margin.
    public static let bound = UInt32((sleepDrainBound + saveBound + BoundedEnd.drainBound + margin).rounded(.up))

    private let hooks: Hooks
    private let lock = NSLock()
    private var armed = false

    public init(hooks: Hooks = .real) {
        self.hooks = hooks
    }

    /// Arms the deadline, ``bound`` seconds from now; an ending path's
    /// first action.
    public func arm() {
        hooks.arm(Self.bound)
        lock.withLock { armed = true }
    }

    /// Arms the deadline unless it is armed already: the save's own check
    /// that no save is claimed before it is (``OneShotSave``).
    public func armIfNeeded() {
        guard !isArmed else { return }
        arm()
    }

    /// Whether an arm has completed.
    public var isArmed: Bool {
        lock.withLock { armed }
    }
}

/// Every way `watch` ends (code review r3 of #101, must 1).
///
/// - The main path, once the flow has ended: the after readings ran their
///   course, a timeout or an early stop ended the run, the first signal
///   stopped it, or a write to the terminal failed. The main loop sees the
///   end and comes here. The probe's refusal after it registered for sleep
///   takes this path too.
/// - A second signal, at once, on a thread of its own.
///
/// Each arms the ending's watchdog first (``EndingWatchdog``), then drains
/// the sleep queue and reads the sleep log once more
/// (``ManualCutSession/reconciledFlow(drainSleepQueue:)``), renders the
/// report and takes the bounded end (``BoundedEnd``): the save, once for the
/// run (``OneShotSave``), then the console, then the exit. Each step is a
/// part, so the tests drive the order and the waits.
///
/// The sleep queue is drained once for the run, within its bound, however
/// many paths end (``BoundedOnce``). If that drain does not complete, the
/// end never touches the sleep watch again (code review r3 of #101, must
/// 2): its lock may be held by the teardown or an acknowledgement that has
/// not finished. The report is then rendered from the lock-free sleep log
/// alone, says that the sleep notices are unavailable, and no confirmation
/// of recovery counts (``ManualCutFlow/reconcile(with:drained:)``).
public final class ManualCutEnding: @unchecked Sendable {
    public struct Parts: Sendable {
        /// Deregisters from sleep notifications and drains their queue. It
        /// may block (the sleep watch's lock, a callback that runs), so it
        /// runs once, on a thread of its own, waited for at most
        /// ``EndingWatchdog/sleepDrainBound``.
        public var stopSleepNotifications: @Sendable () -> Void
        /// The sleep notifications received. It takes the sleep watch's
        /// lock, so it is read only after the drain has completed.
        public var sleepNotices: @Sendable () -> [ProbeRun.SleepNotice]
        /// The report: the flow is nil when the probe refused to start; the
        /// sleep notices are nil when the drain did not complete.
        public var render: @Sendable (_ outcome: ManualCutOutcome, _ flow: ManualCutFlow?, _ sleepNotices: [ProbeRun.SleepNotice]?) -> String
        /// Saves the report (``ReportFile/persist(_:)``); returns whether it
        /// was saved.
        public var persist: @Sendable (_ report: String) -> Bool
        /// The console's last line: where the report is, or that it could
        /// not be saved.
        public var savedLine: @Sendable (_ saved: Bool) -> String

        public init(
            stopSleepNotifications: @escaping @Sendable () -> Void,
            sleepNotices: @escaping @Sendable () -> [ProbeRun.SleepNotice],
            render: @escaping @Sendable (_ outcome: ManualCutOutcome, _ flow: ManualCutFlow?, _ sleepNotices: [ProbeRun.SleepNotice]?) -> String,
            persist: @escaping @Sendable (_ report: String) -> Bool,
            savedLine: @escaping @Sendable (_ saved: Bool) -> String
        ) {
            self.stopSleepNotifications = stopSleepNotifications
            self.sleepNotices = sleepNotices
            self.render = render
            self.persist = persist
            self.savedLine = savedLine
        }
    }

    public let watchdog: EndingWatchdog
    private let session: ManualCutSession
    private let parts: Parts
    private let oneSave: OneShotSave
    private let sleepDrain: BoundedOnce

    /// `sleepDrainBound`: the most the end waits for the sleep queue's
    /// drain; the tests shorten it.
    public init(
        session: ManualCutSession,
        watchdog: EndingWatchdog = EndingWatchdog(),
        sleepDrainBound: Double = EndingWatchdog.sleepDrainBound,
        parts: Parts
    ) {
        self.session = session
        self.watchdog = watchdog
        self.parts = parts
        oneSave = OneShotSave(watchdog: watchdog)
        sleepDrain = BoundedOnce(within: sleepDrainBound, parts.stopSleepNotifications)
    }

    /// Whether the report's save has finished.
    public var saveFinished: Bool {
        oneSave.isFinished
    }

    /// The main path's end, once the flow has ended; or, with `refusal`,
    /// the end of a probe that refused to start after it registered for
    /// sleep. `tearDown` releases what the run holds; it may block, so it
    /// comes after the watchdog is armed. Returns the status, and whether
    /// the console took everything (if not, `watch` exits at once).
    public func endMainPath(refusal: ManualCutOutcome? = nil, tearDown: () -> Void) -> (status: Int32, drained: Bool) {
        watchdog.arm()
        tearDown()
        let (flow, notices) = reconciled()
        let outcome = refusal ?? ManualCutOutcome.of(flow, sleepNotices: notices ?? [])
        let text = parts.render(outcome, refusal == nil ? flow : nil, notices)
        var result = (status: outcome.exitStatus, drained: false)
        finish(text, status: outcome.exitStatus) { result = ($0, $1) }
        return result
    }

    /// A second signal's end: at once, on a thread of its own in `watch`.
    /// The console shows again what the owner must do, if anything
    /// (``ManualCutFlow/secondSignal(_:)``); `exit` ends the process.
    public func endAtSecondSignal(_ number: Int32, exit: @escaping (Int32) -> Void) {
        watchdog.arm()
        let (flow, notices) = reconciled()
        let second = flow.secondSignal(number)
        if let banner = second.banner {
            session.console.enqueue("\n\(ManualCutFlow.signalName(number)) again: quitting. " + ManualCut.text(banner))
        }
        let text = parts.render(ManualCutOutcome.of(flow, sleepNotices: notices ?? []), flow, notices)
        finish(text, status: second.exitStatus) { status, _ in exit(status) }
    }

    /// The flow after the sleep queue's drain and the sleep log's last
    /// read; and the sleep notices, only if the drain completed: if not,
    /// the sleep watch's lock is never taken again.
    private func reconciled() -> (flow: ManualCutFlow, sleepNotices: [ProbeRun.SleepNotice]?) {
        let drained = sleepDrain.run()
        let flow = session.reconciledFlow { drained }
        return (flow, drained ? parts.sleepNotices() : nil)
    }

    /// The bounded end: the save (or the wait for another path's), then the
    /// report and where it is, queued for the console, then the console's
    /// drain, then `exit`.
    private func finish(_ text: String, status: Int32, exit: @escaping (Int32, Bool) -> Void) {
        let console = session.console
        BoundedEnd.perform(status: status, steps: BoundedEnd.Steps(
            persist: { [oneSave, parts] in oneSave.save { parts.persist(text) } },
            print: { [parts] saved in
                console.enqueue("\n" + text)
                console.enqueue(parts.savedLine(saved))
            },
            drain: { console.drain(timeout: $0) },
            exit: exit
        ))
    }
}

/// Work run once, on a thread of its own, and waited for against one
/// deadline: the first call starts it, and every call, from any thread,
/// waits until it has finished or until `seconds` after it started, then
/// says whether it finished. A later call never starts it again, and never
/// waits past that deadline. If the work never finishes, its thread is left
/// to it.
public final class BoundedOnce: @unchecked Sendable {
    private let seconds: Double
    private let work: @Sendable () -> Void
    private let condition = NSCondition()
    private var deadline: Date?
    private var finished = false

    public init(within seconds: Double, _ work: @escaping @Sendable () -> Void) {
        self.seconds = seconds
        self.work = work
    }

    /// Starts the work if no call has; waits for it, at most until its
    /// deadline. Returns whether it finished.
    public func run() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline: Date
        if let started = self.deadline {
            deadline = started
        } else {
            deadline = Date(timeIntervalSinceNow: seconds)
            self.deadline = deadline
            let work = work
            Thread { [self] in
                work()
                condition.withLock {
                    finished = true
                    condition.broadcast()
                }
            }.start()
        }
        while !finished {
            guard condition.wait(until: deadline) else { return finished }
        }
        return true
    }
}
