import Foundation
import ProbeCore

/// `charge-inhibit-probe watch --mechanism manual-adapter-cut [--hold
/// SECONDS]`: the owner's observer of research note 11's manual adapter
/// cut. The owner reads and writes the SMC key `CHIE` by hand, with an
/// external tool in a second terminal; this command never touches the SMC,
/// never runs that tool or any other process, and only reads the battery,
/// asks the owner what to type and when, and judges the readings.
///
/// Order, and why:
/// 1. Refuse as root, or unless standard input and output are a terminal
///    (`ManualCut.refusal`). Nothing else happens first.
/// 2. Check the preconditions (note 11 §5); refuse on any failure.
/// 3. Create the report file; start the console writer, which from now on
///    is the only thing that writes to the terminal; register for sleep
///    notifications (each acknowledged at once, with no I/O on the sleep
///    queue) and create the public idle-sleep assertion; refuse if either
///    fails.
/// 4. Run the flow (`ManualCutSession`): the main loop hands it the owner's
///    lines, the clock and the readings; the reminder's own timer and the
///    signal handlers hand it events too; every event reads the sleep log
///    first. None of them waits on the terminal.
/// 5. The end (`ManualCutEnding`): arm the ending's watchdog first
///    (`EndingWatchdog`: SIGALRM's default action ends the process if the
///    end outlasts its bound). The first ending path to get there (the main
///    path's, or a second signal's) settles the end once for both: release
///    the idle-sleep assertion; deregister from sleep notifications and
///    drain their queue (once, at most 2 s); close actionable output; give
///    the console at most 2 s, so that a failed write of the end's output
///    counts (after the CUT prompt, it makes the run end with 3); then read
///    the sleep log once more, so that a sleep that began before a
///    confirmation still makes it not count (`ManualCutFlow.reconcile`); if
///    the sleep queue's drain did not complete, never touch the sleep watch
///    again (its lock may be held) and render the report from the sleep log
///    alone; save the report, then queue it for the console, give the
///    console at most 2 s, and exit (`BoundedEnd`). The other path waits
///    for that, bounded only by the watchdog, and exits with the same
///    status.
enum WatchCommand {
    static func main(hold: Int) -> Int32 {
        // 1. Not as root, from a terminal.
        if let refusal = ManualCut.refusal(
            effectiveUserIsRoot: geteuid() == 0,
            inputIsTerminal: isatty(STDIN_FILENO) == 1,
            outputIsTerminal: isatty(STDOUT_FILENO) == 1
        ) {
            Console.error(refusal)
            return 1
        }

        let clock = Clock()
        let startedAt = Clock.wallDateTime()
        let machine = SystemReads.machineInfo()
        let names = SystemReads.namesToRedact()
        Console.out("CellKeeper manual adapter-cut probe: watch (hold \(hold) s)")
        Console.out("machine: \(machine.line)")
        Console.out("This probe reads no SMC key and runs no tool. You type every tool command yourself,")
        Console.out("in terminal B (\(ManualCut.ToolCommand.directory)); this terminal is A (\(ManualCut.note)).")
        Console.out("")

        // 2. Preconditions.
        let checks = Preconditions.evaluateManualCut(SystemReads.systemState(redacting: names))
        Console.out("Preconditions")
        for check in checks {
            Console.out(check.line)
        }
        Console.out("")
        guard !checks.contains(where: { $0.status == .fail }) else {
            Console.out(Preconditions.manualCutSummary(checks))
            Console.out("Refusing to run: fix the failed preconditions, then run `charge-inhibit-probe check --mechanism manual-adapter-cut` again. Nothing was created.")
            return 1
        }

        // 3. The report file, the console writer, sleep and idle sleep. If
        // the run dies before its report is saved (the ending watchdog, a
        // crash), only this placeholder is left, so it asks for the
        // recovery check: the probe cannot know whether CHIE was restored.
        // The save replaces it atomically (`ReportFile`), so a save that
        // hangs, stops part way or fails leaves it whole. The name is
        // reserved exclusively: if anything already has it (a leftover, a
        // link, another run started in the same second), the probe
        // refuses, and never opens, truncates or follows it.
        let fileName = ManualCut.reportFileName(stamp: Clock.fileStamp())
        let reportFile: ReportFile
        do {
            reportFile = try ReportFile(
                path: fileName,
                placeholder: """
                    CHECK RECOVERY FIRST: this run stopped before it finished its report, so whether CHIE was restored is unknown. Read CHIE first and follow the recovery steps (docs/research/11-smc-adapter-cut.md §7.1).
                    CellKeeper manual adapter-cut probe report: run started \(startedAt), still in progress or stopped before it finished.

                    """
            )
        } catch {
            Console.error(ManualCut.reportFileRefusal(error, fileName: fileName))
            return 1
        }
        // From here on, only the writer's thread writes to the terminal.
        let console = ConsoleWriter { TerminalInput.writeAll($0 + "\n", to: STDOUT_FILENO) }
        let sleepLog = SleepLog()
        let session = ManualCutSession(
            hold: hold,
            console: console,
            input: TerminalInput(descriptor: STDIN_FILENO),
            sleepLog: sleepLog,
            clock: ManualCutClock(
                now: { clock.now },
                unixNow: { Clock.unixNow },
                clockTime: { Clock.wallTime(Date(timeIntervalSince1970: $0)) }
            )
        )
        let idleSleep = IdleSleepAssertion(clock: clock, requiresRoot: false)
        let sleepWatch = SleepWatch(clock: clock)
        let guardState = SleepGuardState()

        // Every ending path (the main path's and a second signal's) goes
        // through `ending`, which arms its watchdog first (code review r3 of
        // #101, must 1) and saves the report once.
        let ending = ManualCutEnding(session: session, parts: ManualCutEnding.Parts(
            // Deregisters from sleep notifications and drains their queue,
            // so that a notification in flight has finished writing the
            // sleep log. Once per run, at most 2 s.
            stopSleepNotifications: { sleepWatch.stop() },
            // Takes the sleep watch's lock: read only after that drain
            // completed (must 2).
            sleepNotices: { sleepWatch.notices },
            render: { outcome, flow, notices in
                ManualCutReport(
                    startedAt: startedAt,
                    machine: machine,
                    hold: hold,
                    preconditionChecks: checks,
                    flow: flow,
                    sleepGuard: guardState.value,
                    sleepNotices: notices,
                    restoreBy: session.restoreByText,
                    outcome: outcome,
                    consoleSampleLinesDropped: console.droppedSampleLines
                ).render()
            },
            persist: { reportFile.persist($0) },
            savedLine: { ManualCut.savedLine($0, fileName: fileName) }
        ))

        let signalSources = installSignalHandlers { number in
            // The first signal only ends the flow (`session.signal`); it does
            // not arm the ending's watchdog. The main loop sees the end within
            // one pass (a wait for input of at most 50 ms, and at most one
            // reading), and the main path's end arms the watchdog as its first
            // action. Arming here would instead put a deadline on a main loop
            // that is stuck before it sees the end: the watchdog would end
            // the process with only the placeholder in the report file,
            // before a second Ctrl-C could take the bounded path below and
            // save the report.
            guard case .quit = session.signal(number) else { return }
            // A second signal: the bounded path, at once, on a thread of its
            // own, so that its waits (the sleep queue's drain, the save, the
            // console's 2 s) never hold a thread of the shared dispatch pool
            // that the reminder and the sleep queue run on.
            Thread {
                ending.endAtSecondSignal(number) { status in
                    _exit(status)
                }
            }.start()
        }
        var tornDown = false
        func tearDown() {
            guard !tornDown else { return }
            tornDown = true
            session.stopReminder()
            idleSleep.release()
            if let released = idleSleep.released {
                guardState.update { $0.released = released }
            }
        }
        // Every path from here on ends through `ending`, which tears down
        // and drains the sleep queue.
        defer {
            signalSources.forEach { $0.cancel() }
        }

        // Sleep: the notification appends to the sleep log, lock-free,
        // and allows the sleep at once; nothing is released and no I/O is
        // done on the sleep queue. Every event the flow handles reads the
        // log first, inside the run's lock.
        let registered = sleepWatch.start(onWillSleep: ManualCut.willSleepHandler(log: sleepLog, now: { clock.now }))
        guardState.update { $0.registered = registered }
        var refusal: String?
        if !registered {
            refusal = "IORegisterForSystemPower did not register the probe for sleep notifications"
        } else {
            let result = idleSleep.create(timeout: ManualCut.idleSleepTimeout(hold: hold))
            let created = (time: clock.now, result: result)
            guardState.update { $0.created = created }
            console.enqueue("+\(seconds(created.time)): IOPMAssertionCreateWithProperties (PreventUserIdleSystemSleep) returned \(IOReturnName.describe(result))")
            if result != kIOReturnSuccess {
                refusal = "creating the PreventUserIdleSystemSleep assertion returned \(IOReturnName.describe(result))"
            }
        }
        if let refusal {
            // Queuing never waits for the terminal.
            console.enqueue("Refusing to run: \(refusal). Nothing was written, and you were asked nothing.")
            let outcome = ManualCutOutcome(verdict: nil, exitStatus: 1, recoveryReason: nil, refusal: refusal)
            return endMainPath(ending.endMainPath(refusal: outcome, tearDown: tearDown))
        }

        // 4. The flow: the main loop.
        session.begin()
        var deadline: Double?
        while !session.isEnded {
            session.poll()
            if session.wantsReadings {
                let due = deadline ?? clock.now
                if clock.now >= due {
                    let sample = SystemReads.sample(time: clock.now, unixTime: Clock.unixNow, phase: .baseline)
                    session.record(sample)
                    deadline = ProbeSchedule.nextDeadline(after: due, readAt: sample.time)
                } else {
                    deadline = due
                }
            } else {
                deadline = nil
            }
            TerminalInput.waitForInput(STDIN_FILENO, milliseconds: 50)
        }

        // 5. The end: the watchdog first, then the cleanup, the last look at
        // the sleep log after its queue is drained, and the bounded end.
        return endMainPath(ending.endMainPath(tearDown: tearDown))
    }

    /// The main path's bounded end: if the console took everything, the
    /// status goes back to `main`; if not, the probe exits at once.
    static func endMainPath(_ end: (status: Int32, drained: Bool)) -> Int32 {
        if !end.drained { _exit(end.status) }
        return end.status
    }

    /// SIGINT, SIGTERM and SIGHUP go to `handle`, on their own queue.
    static func installSignalHandlers(_ handle: @escaping @Sendable (Int32) -> Void) -> [any DispatchSourceSignal] {
        let queue = DispatchQueue(label: "charge-inhibit-probe.signals")
        return [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { handle(number) }
            source.resume()
            return source
        }
    }
}

/// The run's sleep registration and idle-sleep assertion, for the report,
/// readable from the signal path too.
final class SleepGuardState: @unchecked Sendable {
    private let lock = NSLock()
    private var guardValue = Report.SleepGuard(registered: false)

    var value: Report.SleepGuard {
        lock.withLock { guardValue }
    }

    func update(_ change: (inout Report.SleepGuard) -> Void) {
        lock.withLock { change(&guardValue) }
    }
}
