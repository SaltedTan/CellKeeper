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
///    end outlasts its bound); release the idle-sleep assertion; deregister
///    from sleep notifications and drain their queue (at most 2 s), then
///    read the sleep log once more, so that a sleep that began before a
///    confirmation still makes it not count (`ManualCutFlow.reconcile`);
///    save the report, then queue it for the console, give the console at
///    most 2 s, and exit (`BoundedEnd`). A second signal takes the same
///    bounded path at once. The report is saved once (`OneShotSave`):
///    whichever ending path comes first saves it, and the other waits for
///    that save, bounded only by the watchdog, before it exits.
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

        // 3. The report file, the console writer, sleep and idle sleep.
        let fileName = ManualCut.reportFileName(stamp: Clock.fileStamp())
        guard let reportFile = ReportFile(
            path: fileName,
            placeholder: "CellKeeper manual adapter-cut probe report: run started \(startedAt), still in progress or stopped before it finished.\n"
        ) else {
            Console.error("Refusing to run: cannot write \(fileName) in the current directory. Nothing was created.")
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
            // sleep log.
            drainSleepQueue: { runBounded(within: EndingWatchdog.sleepDrainBound) { sleepWatch.stop() } },
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
            savedLine: { saved in
                saved
                    ? "Report written to ./\(fileName). Please send it to the lead."
                    : "Could not write ./\(fileName). Copy the report above instead."
            }
        ))

        let signalSources = installSignalHandlers { number in
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
