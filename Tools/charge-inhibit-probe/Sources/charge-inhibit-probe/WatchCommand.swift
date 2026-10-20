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
/// 3. Create the report file; register for sleep notifications (each
///    acknowledged at once, with no I/O on the sleep queue) and create the
///    public idle-sleep assertion; refuse if either fails.
/// 4. Run the flow (`ManualCutFlow`, pure): the first read, the baseline,
///    the CUT prompt, the cut mark and GO, the hold, the restore, the after
///    readings. The main loop feeds it the owner's lines, the clock, the
///    readings and the sleep notices; the reminder's own timer and the
///    signal handlers feed it too, all under one lock (`WatchSession`).
/// 5. Release the idle-sleep assertion, deregister, and write the report.
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

        // 3. The report file, in the current directory.
        let fileName = ManualCut.reportFileName(stamp: Clock.fileStamp())
        let placeholder = "CellKeeper manual adapter-cut probe report: run started \(startedAt), still in progress or stopped before it finished.\n"
        guard FileManager.default.createFile(atPath: fileName, contents: Data(placeholder.utf8)) else {
            Console.error("Refusing to run: cannot write \(fileName) in the current directory. Nothing was created.")
            return 1
        }

        let session = WatchSession(clock: clock, hold: hold)
        let idleSleep = IdleSleepAssertion(clock: clock, requiresRoot: false)
        let sleepWatch = SleepWatch(clock: clock)
        var sleepGuard = Report.SleepGuard(registered: false)
        let signalSources = installSignalHandlers(session: session)
        var tornDown = false
        func tearDown() {
            guard !tornDown else { return }
            tornDown = true
            session.stopReminder()
            idleSleep.release()
            sleepWatch.stop()
            if let released = idleSleep.released {
                sleepGuard.released = released
            }
        }
        defer {
            tearDown()
            signalSources.forEach { $0.cancel() }
        }

        func writeReport(outcome: ManualCutOutcome, flow: ManualCutFlow?, notes: [String] = []) {
            let text = ManualCutReport(
                startedAt: startedAt,
                machine: machine,
                hold: hold,
                preconditionChecks: checks,
                flow: flow,
                sleepGuard: sleepGuard,
                sleepNotices: sleepWatch.notices,
                restoreBy: session.restoreByText,
                outcome: outcome,
                notes: notes
            ).render()
            Console.out("")
            Console.out(text)
            do {
                try Data(text.utf8).write(to: URL(fileURLWithPath: fileName))
                Console.out("Report written to ./\(fileName). Please send it to the lead.")
            } catch {
                Console.error("Could not write ./\(fileName): \(error.localizedDescription). Copy the report above instead.")
            }
        }

        // Sleep: acknowledged at once, nothing released, no I/O on the sleep
        // queue; the sleep watch records the notice, and the main loop hands
        // it to the flow after the wake.
        sleepGuard.registered = sleepWatch.start(onWillSleep: ManualCut.willSleepHandler())
        var refusal: String?
        if !sleepGuard.registered {
            refusal = "IORegisterForSystemPower did not register the probe for sleep notifications"
        } else {
            let result = idleSleep.create(timeout: ManualCut.idleSleepTimeout(hold: hold))
            sleepGuard.created = (clock.now, result)
            Console.out("+\(seconds(clock.now)): IOPMAssertionCreateWithProperties (PreventUserIdleSystemSleep) returned \(IOReturnName.describe(result))")
            if result != kIOReturnSuccess {
                refusal = "creating the PreventUserIdleSystemSleep assertion returned \(IOReturnName.describe(result))"
            }
        }
        if let refusal {
            tearDown()
            Console.out("Refusing to run: \(refusal). Nothing was written, and you were asked nothing.")
            writeReport(outcome: ManualCutOutcome(verdict: nil, exitStatus: 1, recoveryReason: nil, refusal: refusal), flow: nil)
            return 1
        }

        // 4. The flow.
        session.run(sleepWatch: sleepWatch)

        // 5. Cleanup, then the report.
        tearDown()
        let flow = session.finalFlow
        let outcome = ManualCutOutcome.of(flow, sleepNotices: sleepWatch.notices)
        writeReport(outcome: outcome, flow: flow)
        return outcome.exitStatus
    }

    /// SIGINT, SIGTERM and SIGHUP go to the flow (`WatchSession.signal`): the
    /// first ends the run, with RESTORE CHIE NOW unless the restore was
    /// confirmed; a second quits at once.
    static func installSignalHandlers(session: WatchSession) -> [any DispatchSourceSignal] {
        let queue = DispatchQueue(label: "charge-inhibit-probe.signals")
        return [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { session.signal(number) }
            source.resume()
            return source
        }
    }
}

/// The run's one lock around the flow, the terminal input and the
/// reminder: the main loop, the reminder's own timer and the signal
/// handlers each hand the flow an event and perform its actions, in order,
/// under this lock, so a question's change and the discard of input typed
/// before it can never interleave with an answer.
final class WatchSession: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: Clock
    private var flow: ManualCutFlow
    private let input = TerminalInput()
    private let reminderQueue = DispatchQueue(label: "charge-inhibit-probe.reminder")
    private var reminder: (any DispatchSourceTimer)?
    private var restoreBy: String?
    private var signals = 0
    private var sleepNoticesSeen = 0
    private var printedHeader = false

    init(clock: Clock, hold: Int) {
        self.clock = clock
        flow = ManualCutFlow(hold: hold)
    }

    /// The GO line's restore time, as shown.
    var restoreByText: String? {
        lock.withLock { restoreBy }
    }

    var finalFlow: ManualCutFlow {
        lock.withLock { flow }
    }

    /// The main loop: until the flow ends, it hands the flow the sleep
    /// notices found, the owner's lines, the clock and a reading every 2 s
    /// (never catching up), and waits for input up to 50 ms at a time.
    func run(sleepWatch: SleepWatch) {
        send(.begin(at: clock.now))
        var deadline: Double?
        while !lock.withLock({ flow.stage == .ended }) {
            deliverSleepNotices(sleepWatch.notices)
            readInput()
            send(.tick(at: clock.now, unixTime: Clock.unixNow))
            if lock.withLock({ flow.wantsReadings }) {
                let due = deadline ?? clock.now
                if clock.now >= due {
                    let sample = SystemReads.sample(time: clock.now, unixTime: Clock.unixNow, phase: .baseline)
                    takeReading(sample)
                    deadline = ProbeSchedule.nextDeadline(after: due, readAt: sample.time)
                } else {
                    deadline = due
                }
            } else {
                deadline = nil
            }
            TerminalInput.waitForInput(milliseconds: 50)
        }
    }

    func send(_ event: ManualCutFlow.Event) {
        lock.lock()
        defer { lock.unlock() }
        _ = perform(flow.handle(event))
    }

    private func takeReading(_ sample: Sample) {
        lock.lock()
        defer { lock.unlock() }
        _ = perform(flow.handle(.reading(sample)))
        // Sample lines are printed only while no question is open, so they
        // never break into the owner's typing; the report has every one.
        guard flow.openQuestion == nil, let recorded = flow.samples.last else { return }
        if !printedHeader {
            Console.out(ReportFormat.sampleHeader)
            printedHeader = true
        }
        Console.out(ReportFormat.sampleLine(recorded))
    }

    /// Hands the flow the owner's complete lines. A line read after a
    /// discard in the same batch was typed before it, and is dropped
    /// (`ManualCutFlow.handleLines`); the discard itself also flushes what
    /// the terminal still holds.
    private func readInput() {
        lock.lock()
        defer { lock.unlock() }
        let lines = input.availableLines()
        guard !lines.isEmpty else { return }
        _ = perform(flow.handleLines(lines, at: clock.now, unixTime: Clock.unixNow))
    }

    private func deliverSleepNotices(_ notices: [ProbeRun.SleepNotice]) {
        let new = lock.withLock { () -> [ProbeRun.SleepNotice] in
            defer { sleepNoticesSeen = notices.count }
            return Array(notices.dropFirst(sleepNoticesSeen))
        }
        for notice in new where notice.message == "kIOMessageSystemWillSleep" {
            send(.slept(at: notice.time))
        }
    }

    /// The first signal goes to the flow; a second quits at once, after
    /// printing again what the owner must do: RESTORE CHIE NOW before a
    /// confirmed restore, the check of recovery after one.
    func signal(_ number: Int32) {
        lock.lock()
        signals += 1
        if signals == 1 {
            _ = perform(flow.handle(.signal(number, at: clock.now)))
            lock.unlock()
            Console.error("\(signalName(number)): finishing the report; press Ctrl-C again to quit at once.")
            return
        }
        let second = flow.secondSignal(number)
        lock.unlock()
        Console.error("\n\(signalName(number)) again: quitting." + (second.banner.map { " " + ManualCut.text($0) } ?? ""))
        exit(second.exitStatus)
    }

    /// Performs `actions` in order; returns whether input was discarded.
    /// Called under the lock.
    private func perform(_ actions: [ManualCutFlow.Action]) -> Bool {
        var discarded = false
        for action in actions {
            switch action {
            case .discardInput:
                input.discard()
                discarded = true
            case let .ask(question, repeated):
                // Restore requests ring, every time they are shown.
                let bell = question.isRestoreRequest ? "\u{07}" : ""
                Console.out("")
                Console.out(bell + (repeated ? "(Reminder) " : "") + question.prompt)
                Console.out("Answer: \(question.words.joined(separator: " or "))")
            case let .say(text):
                Console.out(text)
            case let .banner(banner):
                Console.out("")
                Console.out(ManualCut.text(banner))
            case .armReminder:
                armReminder()
            case let .go(restoreByUnix):
                let time = Clock.wallTime(Date(timeIntervalSince1970: restoreByUnix))
                restoreBy = time
                Console.out("")
                Console.out("GO — run the cut now in terminal B. Restore by \(time).")
                Console.out("Write \(time) down, or set a phone timer for it, before you run the cut.")
            case .end:
                break
            }
        }
        return discarded
    }

    /// The reminder's own timer, apart from the sampling loop: once a
    /// second it hands the flow the time, which decides whether to make the
    /// restore request or show the open one again. Called under the lock.
    private func armReminder() {
        guard reminder == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: reminderQueue)
        timer.schedule(deadline: .now() + ManualCut.reminderTick, repeating: ManualCut.reminderTick)
        let clock = clock
        timer.setEventHandler { [weak self] in
            self?.send(.reminderTick(at: clock.now))
        }
        timer.resume()
        reminder = timer
    }

    func stopReminder() {
        lock.withLock {
            reminder?.cancel()
            reminder = nil
        }
    }
}

/// The owner's answers, read from standard input (a terminal, in its usual
/// line mode) without waiting and without changing its settings. Used only
/// under `WatchSession`'s lock.
final class TerminalInput {
    private var buffer: [UInt8] = []

    /// The complete lines the terminal has ready now, in order. A partial
    /// line stays in the terminal until the owner presses Return.
    func availableLines() -> [String] {
        while Self.ready(milliseconds: 0) {
            var chunk = [UInt8](repeating: 0, count: 1024)
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer += chunk[0..<count]
        }
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: buffer[..<newline], as: UTF8.self))
            buffer.removeSubrange(...newline)
        }
        return lines
    }

    /// Discards pending input: the terminal's unread input, including a line
    /// still being typed (`tcflush`, `TCIFLUSH`), and the probe's own buffer.
    func discard() {
        tcflush(STDIN_FILENO, TCIFLUSH)
        buffer.removeAll()
    }

    /// Waits until standard input has something to read, or `milliseconds`
    /// pass. A terminal that has gone away (its `SIGHUP` ends the run) is
    /// always "ready"; the wait then sleeps instead, so the loop never spins.
    static func waitForInput(milliseconds: Int32) {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, milliseconds) > 0, descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            usleep(UInt32(milliseconds) * 1000)
        }
    }

    static func ready(milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, milliseconds) > 0 && descriptor.revents & Int16(POLLIN) != 0
    }
}
