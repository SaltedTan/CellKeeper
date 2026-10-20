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
///    signal handlers hand it events too; every event reads the sleep latch
///    first. None of them waits on the terminal.
/// 5. Release the idle-sleep assertion and deregister; save the report,
///    then queue it for the console, give the console at most 2 s, and
///    exit (`BoundedEnd`). A second signal takes the same bounded path at
///    once.
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
            name: fileName,
            placeholder: "CellKeeper manual adapter-cut probe report: run started \(startedAt), still in progress or stopped before it finished.\n"
        ) else {
            Console.error("Refusing to run: cannot write \(fileName) in the current directory. Nothing was created.")
            return 1
        }
        // From here on, only the writer's thread writes to the terminal.
        let console = ConsoleWriter { TerminalInput.writeAll($0 + "\n", to: STDOUT_FILENO) }
        let latch = SleepLatch()
        let session = ManualCutSession(
            hold: hold,
            console: console,
            input: TerminalInput(descriptor: STDIN_FILENO),
            latch: latch,
            clock: ManualCutClock(
                now: { clock.now },
                unixNow: { Clock.unixNow },
                clockTime: { Clock.wallTime(Date(timeIntervalSince1970: $0)) }
            )
        )
        let idleSleep = IdleSleepAssertion(clock: clock, requiresRoot: false)
        let sleepWatch = SleepWatch(clock: clock)
        let guardState = SleepGuardState()

        /// The report as it stands; safe to call from any thread.
        @Sendable func render(outcome: ManualCutOutcome, flow: ManualCutFlow?) -> String {
            ManualCutReport(
                startedAt: startedAt,
                machine: machine,
                hold: hold,
                preconditionChecks: checks,
                flow: flow,
                sleepGuard: guardState.value,
                sleepNotices: sleepWatch.notices,
                restoreBy: session.restoreByText,
                outcome: outcome,
                consoleSampleLinesDropped: console.droppedSampleLines
            ).render()
        }

        /// The bounded end: save the report first, then queue it, then give
        /// the console at most 2 s.
        @Sendable func finish(_ text: String, status: Int32, exit: @escaping (Int32, Bool) -> Void) {
            BoundedEnd.perform(status: status, steps: BoundedEnd.Steps(
                persist: { reportFile.persist(text) },
                print: { persisted in
                    console.enqueue("\n" + text)
                    console.enqueue(persisted
                        ? "Report written to ./\(fileName). Please send it to the lead."
                        : "Could not write ./\(fileName). Copy the report above instead.")
                },
                drain: { console.drain(timeout: $0) },
                exit: exit
            ))
        }

        let signalSources = installSignalHandlers { number in
            guard case let .quit(banner, status) = session.signal(number) else { return }
            // A second signal: the bounded path, at once, on a thread of its
            // own, so that its waits (the save, the console's 2 s) never hold
            // a thread of the shared dispatch pool that the reminder and the
            // sleep queue run on.
            if let banner {
                console.enqueue("\n\(signalName(number)) again: quitting. " + ManualCut.text(banner))
            }
            let flow = session.snapshot
            let text = render(outcome: ManualCutOutcome.of(flow, sleepNotices: sleepWatch.notices), flow: flow)
            Thread {
                finish(text, status: status) { status, _ in
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
            sleepWatch.stop()
            if let released = idleSleep.released {
                guardState.update { $0.released = released }
            }
        }
        defer {
            tearDown()
            signalSources.forEach { $0.cancel() }
        }

        // Sleep: the notification records into the sleep latch, lock-free,
        // and allows the sleep at once; nothing is released and no I/O is
        // done on the sleep queue. Every event the flow handles reads the
        // latch first, inside the run's lock.
        let registered = sleepWatch.start(onWillSleep: ManualCut.willSleepHandler(latch: latch, now: { clock.now }))
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
            tearDown()
            console.enqueue("Refusing to run: \(refusal). Nothing was written, and you were asked nothing.")
            let outcome = ManualCutOutcome(verdict: nil, exitStatus: 1, recoveryReason: nil, refusal: refusal)
            return endMainPath(render(outcome: outcome, flow: nil), status: 1, finish: finish)
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

        // 5. Cleanup, then the bounded end.
        tearDown()
        let flow = session.snapshot
        let outcome = ManualCutOutcome.of(flow, sleepNotices: sleepWatch.notices)
        return endMainPath(render(outcome: outcome, flow: flow), status: outcome.exitStatus, finish: finish)
    }

    /// The main path's bounded end: if the console took everything, the
    /// status goes back to `main`; if not, the probe exits at once.
    static func endMainPath(_ text: String, status: Int32, finish: (String, Int32, @escaping (Int32, Bool) -> Void) -> Void) -> Int32 {
        finish(text, status) { status, drained in
            if !drained { _exit(status) }
        }
        return status
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

/// The report file, kept open from the start. `persist` replaces its
/// contents under a deadline that needs no lock, queue or output (SIGALRM's
/// default action, as in `EmergencyExit`), one save at a time: a save that
/// finds another under way leaves it to finish.
final class ReportFile: @unchecked Sendable {
    let name: String
    private let descriptor: Int32
    private let lock = NSLock()

    init?(name: String, placeholder: String) {
        let descriptor = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { return nil }
        self.name = name
        self.descriptor = descriptor
        guard Self.write(placeholder, to: descriptor) else { return nil }
    }

    deinit {
        close(descriptor)
    }

    /// Saves `text` as the whole report; returns whether it was saved.
    func persist(_ text: String) -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        signal(SIGALRM, SIG_DFL)
        alarm(EmergencyExit.deadline)
        defer { alarm(0) }
        guard ftruncate(descriptor, 0) == 0 else { return false }
        return Self.write(text, to: descriptor)
    }

    static func write(_ text: String, to descriptor: Int32) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
