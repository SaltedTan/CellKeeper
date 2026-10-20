import Foundation

/// The one deadline over the end of `watch` (code review r3 of #101, must
/// 1). Every ending path arms it as its very first action: before it tears
/// anything down, drains the sleep queue, claims the report's save or waits
/// for the console. From then on nothing in the ending can outlast it:
/// SIGALRM's default action ends the process, whatever is blocked, as #98's
/// emergency exit does (``EmergencyExit``). So a path that waits for the
/// end another path settles needs no timeout of its own
/// (``ManualCutEnding``).
///
/// It is never cancelled: every ending exits the process. The first arm
/// wins: a later one, from a second signal's ending or a claim, never
/// moves the deadline, so pressing Ctrl-C again cannot postpone it; it only
/// waits until the first arm has set it.
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
    /// console's drain before the outcome is decided (code review r3 of
    /// #101, should 3), the save, the console's drain after it
    /// (``BoundedEnd/drainBound`` each) and the margin.
    public static let bound = UInt32((sleepDrainBound + 2 * BoundedEnd.drainBound + saveBound + margin).rounded(.up))

    private let hooks: Hooks
    private let condition = NSCondition()
    private var claimed = false
    private var armed = false

    public init(hooks: Hooks = .real) {
        self.hooks = hooks
    }

    /// An ending path's first action, and the save's before it is claimed:
    /// the first call arms the deadline, ``bound`` seconds from now. A later
    /// call leaves it where it is, and returns once the first has set it
    /// (setting it never blocks: `signal(3)` and `alarm(2)`), so that the
    /// deadline is set whenever an arm has returned.
    public func arm() {
        condition.lock()
        guard !claimed else {
            while !armed {
                condition.wait()
            }
            condition.unlock()
            return
        }
        claimed = true
        condition.unlock()
        hooks.arm(Self.bound)
        condition.withLock {
            armed = true
            condition.broadcast()
        }
    }

    /// Whether the deadline is set.
    public var isArmed: Bool {
        condition.withLock { armed }
    }
}

/// Every way `watch` ends (code review r3 of #101, must 1; r4).
///
/// - The main path, once the flow has ended: the after readings ran their
///   course, a timeout or an early stop ended the run, the first signal
///   stopped it, or a write to the terminal failed. The main loop sees the
///   end and comes here. The probe's refusal after it registered for sleep
///   takes this path too.
/// - A second signal, at once, on a thread of its own.
///
/// Each arms the ending's watchdog first (``EndingWatchdog``). Then the
/// first path to arrive claims the end and settles it once for every path
/// (code review r4 of #101): the report's text and the exit status. Every
/// other path never decides a status or a report of its own: it waits,
/// bounded only by the watchdog, until the claimant has saved the report
/// and queued it for the console; then it gives the console its bounded
/// drain and exits with exactly the settled status. So every path exits
/// with the same status, and the saved report is the one that status came
/// from.
///
/// The claimant tears down (on the main path) and drains the sleep queue,
/// and a second signal's claimant queues its banner; then it closes
/// actionable output (``ManualCutSession/closeActionableOutput()``): the
/// closing boundary. Anything actionable queued before it, a second
/// signal's banner included, is in the console's queue; nothing actionable
/// is queued after it. Then it drains the console, so that every result of
/// that output is in (r3, should 3); only then reads the flow and the sleep
/// log once more (``ManualCutSession/reconciledFlow(drainSleepQueue:)``)
/// and decides the outcome; renders the report; queues the settled
/// outcome's own banner (r5: CHECK RECOVERY FIRST for exit 3), so that it
/// is on screen before the save starts; and takes the bounded end
/// (``BoundedEnd``): the save, which replaces the placeholder atomically
/// (``ReportFile``), then the console, then the exit. A second
/// signal that comes while another path settles the end queues its banner
/// only before the boundary, where its result counts; after it, it adds
/// nothing and only waits. So whatever means exit 3 (a failed or untaken
/// actionable write, an invalidated confirmation, a sleep queue that could
/// not be drained) is in the settled result, and nothing after the boundary
/// can change it. Each step is a part, so the tests drive the order and the
/// waits.
///
/// If the claimant itself hangs before the save has replaced the
/// placeholder (in the teardown or the save, say), the watchdog ends the
/// process, and the report file keeps its placeholder, which asks for the
/// recovery check.
///
/// A write of an actionable message that fails, at any point of the run,
/// the end's banners included, and a terminal that does not take the
/// output queued before the outcome is decided within its bound, mean that
/// the owner may not have seen it: after the CUT prompt, the run then ends
/// with 3 and CHECK RECOVERY FIRST, even after a confirmed restore
/// (``ManualCutFlow/outputProblem``).
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
        /// Saves the report (``ReportFile/persist(_:)``).
        public var persist: @Sendable (_ report: String) -> ReportFile.SaveOutcome
        /// The console's last line: where the report is, or that it could
        /// not be saved (``ManualCut/savedLine(_:fileName:)``).
        public var savedLine: @Sendable (_ saved: ReportFile.SaveOutcome) -> String

        public init(
            stopSleepNotifications: @escaping @Sendable () -> Void,
            sleepNotices: @escaping @Sendable () -> [ProbeRun.SleepNotice],
            render: @escaping @Sendable (_ outcome: ManualCutOutcome, _ flow: ManualCutFlow?, _ sleepNotices: [ProbeRun.SleepNotice]?) -> String,
            persist: @escaping @Sendable (_ report: String) -> ReportFile.SaveOutcome,
            savedLine: @escaping @Sendable (_ saved: ReportFile.SaveOutcome) -> String
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
    private let sleepDrain: BoundedOnce
    private let consoleDrainBound: Double
    private let condition = NSCondition()
    private var claimed = false
    /// The settled status, once the claimant has saved the report and
    /// queued it for the console.
    private var settledStatus: Int32?

    /// `sleepDrainBound` and `consoleDrainBound`: the most the end waits
    /// for the sleep queue's drain and for each of the console's; the tests
    /// shorten them.
    public init(
        session: ManualCutSession,
        watchdog: EndingWatchdog = EndingWatchdog(),
        sleepDrainBound: Double = EndingWatchdog.sleepDrainBound,
        consoleDrainBound: Double = BoundedEnd.drainBound,
        parts: Parts
    ) {
        self.session = session
        self.watchdog = watchdog
        self.parts = parts
        self.consoleDrainBound = consoleDrainBound
        sleepDrain = BoundedOnce(within: sleepDrainBound, parts.stopSleepNotifications)
    }

    /// Whether the end is settled: the report saved (or its save failed)
    /// and queued for the console.
    public var isSettled: Bool {
        condition.withLock { settledStatus != nil }
    }

    /// The main path's end, once the flow has ended; or, with `refusal`,
    /// the end of a probe that refused to start after it registered for
    /// sleep. `tearDown` releases what the run holds; it may block, so it
    /// comes after the watchdog is armed. Returns the settled status, and
    /// whether the console took everything (if not, `watch` exits at once).
    public func endMainPath(refusal: ManualCutOutcome? = nil, tearDown: () -> Void) -> (status: Int32, drained: Bool) {
        watchdog.arm()
        let isClaimant = claim()
        tearDown()
        guard isClaimant else {
            let status = awaitSettled()
            return (status, session.console.drain(timeout: consoleDrainBound))
        }
        let settled = settle(refusal: refusal, secondSignal: nil)
        var result = (status: settled.status, drained: false)
        finish(settled) { result = ($0, $1) }
        return result
    }

    /// A second signal's end: at once, on a thread of its own in `watch`.
    /// Before the closing boundary, the console shows again what the owner
    /// must do, if anything (``ManualCutFlow/secondSignal(_:)``). `exit`
    /// ends the process, with the settled status.
    public func endAtSecondSignal(_ number: Int32, exit: @escaping (Int32) -> Void) {
        watchdog.arm()
        guard claim() else {
            queueBanner(number)
            let status = awaitSettled()
            _ = session.console.drain(timeout: consoleDrainBound)
            exit(status)
            return
        }
        finish(settle(refusal: nil, secondSignal: number)) { status, _ in exit(status) }
    }

    /// Claims the end for the calling path, if no path has; the watchdog
    /// is armed first.
    private func claim() -> Bool {
        watchdog.arm()
        return condition.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// Waits, with no timeout of its own, until the claimant has settled
    /// the end; the watchdog bounds the wait. Returns the settled status.
    private func awaitSettled() -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        while settledStatus == nil {
            condition.wait()
        }
        return settledStatus ?? 3
    }

    /// A second signal's banner, while actionable output is open, from the
    /// flow after the sleep log's last read (a sleep may have made a
    /// confirmation not count). After the boundary it adds nothing.
    private func queueBanner(_ number: Int32) {
        guard !session.isActionableOutputClosed else { return }
        let drained = sleepDrain.run()
        if let banner = session.reconciledFlow(drainSleepQueue: { drained }).secondSignal(number).banner {
            session.announce("\n\(ManualCutFlow.signalName(number)) again: quitting. " + ManualCut.text(banner))
        }
    }

    /// The end as the claimant settles it, once.
    private struct Settled {
        /// The report.
        var text: String
        var status: Int32
        /// What the console shows before the save (``ManualCut/settledBanner(_:status:)``).
        var banner: String
    }

    /// The claimant's settlement: the report's text and the exit status,
    /// decided once. After the sleep queue's drain (once for the run) and a
    /// second signal's banner, the closing boundary; then the console's
    /// drain, so that every result of the actionable output queued before
    /// the boundary is in, a failed write's included; or, if the terminal
    /// did not take it all within its bound, that is recorded. Then the flow
    /// and the sleep log are read once more, and the sleep notices only if
    /// the sleep queue's drain completed: if not, the sleep watch's lock is
    /// never taken again (must 2).
    private func settle(refusal: ManualCutOutcome?, secondSignal: Int32?) -> Settled {
        if let secondSignal {
            queueBanner(secondSignal)
        }
        let drained = sleepDrain.run()
        session.closeActionableOutput()
        if !session.console.drain(timeout: consoleDrainBound) {
            session.outputNotTaken(within: consoleDrainBound)
        }
        let flow = session.reconciledFlow { drained }
        let notices = drained ? parts.sleepNotices() : nil
        let outcome = refusal ?? ManualCutOutcome.of(flow, sleepNotices: notices ?? [])
        var status = outcome.exitStatus
        if refusal == nil, let secondSignal {
            status = flow.secondSignal(secondSignal).exitStatus
        }
        return Settled(
            text: parts.render(outcome, refusal == nil ? flow : nil, notices),
            status: status,
            banner: ManualCut.settledBanner(outcome, status: status)
        )
    }

    /// The claimant's bounded end: the settled banner; the save; then the
    /// report and where it is, queued for the console; then the end is
    /// settled for every path; then the console's drain, then `exit`.
    private func finish(_ settled: Settled, exit: @escaping (Int32, Bool) -> Void) {
        let console = session.console
        let (text, status) = (settled.text, settled.status)
        // The settled result's own announcement, queued before the save
        // starts (code review r5 of #101): if the save hangs and the
        // watchdog ends the process, it, not an earlier banner it may have
        // overturned, is the last guidance on screen. It goes straight to
        // the console, not through the session, so the closing boundary
        // does not hold it back; and it has no result callback, so a failed
        // write of it cannot change the outcome already settled.
        console.enqueue(settled.banner)
        var saveOutcome = ReportFile.SaveOutcome.unconfirmed
        BoundedEnd.perform(status: status, bound: consoleDrainBound, steps: BoundedEnd.Steps(
            persist: { [parts] in
                saveOutcome = parts.persist(text)
                return saveOutcome == .saved
            },
            print: { [parts] _ in
                console.enqueue("\n" + text)
                console.enqueue(parts.savedLine(saveOutcome))
                self.publish(status)
            },
            drain: { console.drain(timeout: $0) },
            exit: exit
        ))
    }

    /// Settles the end for every path: the waiting ones exit with `status`.
    private func publish(_ status: Int32) {
        condition.withLock {
            settledStatus = status
            condition.broadcast()
        }
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
