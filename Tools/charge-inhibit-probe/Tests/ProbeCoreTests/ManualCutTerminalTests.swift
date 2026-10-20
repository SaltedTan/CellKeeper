import Darwin
import Foundation
import ProbeCore
import Testing

/// A pseudo-terminal for the tests: the probe reads the owner's lines from
/// its slave side, in the usual line mode, and its console writes there;
/// the test types into the master side, as the owner types into terminal A.
/// Echo is off and a thread drains the master side, so the console's writes
/// never wait on it; the tests hold the console back with a gate instead.
final class PseudoTerminal: @unchecked Sendable {
    let master: Int32
    let slave: Int32
    private let lock = NSLock()
    private var shown = ""

    init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw POSIXError(.ENXIO)
        }
        self.master = master
        self.slave = slave
        var settings = termios()
        tcgetattr(slave, &settings)
        settings.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(slave, TCSANOW, &settings)
        let thread = Thread { [master] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(master, &buffer, buffer.count)
                guard count > 0 else { return }
                let text = String(decoding: buffer[0..<count], as: UTF8.self)
                self.lock.withLock { self.shown += text }
            }
        }
        thread.start()
    }

    /// What the owner types.
    func type(_ text: String) {
        TerminalInput.writeAll(text, to: master)
    }

    /// What the terminal has shown.
    var output: String {
        lock.withLock { shown }
    }
}

/// A session on a pseudo-terminal, with a console the test can hold back.
struct TerminalDriver {
    let terminal: PseudoTerminal
    let gate: BlockingSink
    let clock = FakeClock()
    let sleepLog = SleepLog()
    let session: ManualCutSession

    init() throws {
        let terminal = try PseudoTerminal()
        self.terminal = terminal
        let slave = terminal.slave
        gate = BlockingSink(blocked: false) { TerminalInput.writeAll($0 + "\n", to: slave) }
        session = ManualCutSession(
            hold: 180, console: ConsoleWriter(sink: gate.sink), input: TerminalInput(descriptor: slave),
            sleepLog: sleepLog, clock: clock.portable, reminderTick: 0.02
        )
    }

    /// Waits until the open question takes answers, types `word` and a
    /// Return, and polls until the session has read and recorded it; unless
    /// `isWord` is false, as one of the question's answer words.
    func answer(_ word: String, at time: Double, isWord: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
        clock.set(time)
        #expect(eventually { session.inputEligible }, "\(word): the question never took answers", sourceLocation: sourceLocation)
        let before = session.snapshot.answers.count
        terminal.type(word + "\n")
        let read = eventually {
            session.poll()
            return session.snapshot.answers.count > before
        }
        #expect(read, "\(word) was never read", sourceLocation: sourceLocation)
        #expect(session.snapshot.answers.last?.word == (isWord ? word : nil), "\(word) was not recorded as expected", sourceLocation: sourceLocation)
    }

    /// Runs the baseline until the CUT prompt is on the terminal and takes
    /// answers; returns the time of the last reading.
    func toCutPrompt() -> Double {
        session.begin()
        answer("start00", at: 5)
        #expect(session.snapshot.stage == .baseline)
        var time = 5.5
        while session.snapshot.stage == .baseline, time < 200 {
            read(.charging, at: time)
            time += 2
        }
        #expect(session.snapshot.stage == .cutPrompt)
        #expect(eventually { session.inputEligible }, "the CUT prompt never took answers")
        return time
    }

    /// Types without waiting for the question, and polls for a while, as
    /// the main loop does.
    func typeEarly(_ text: String) {
        terminal.type(text)
        for _ in 0..<20 {
            session.poll()
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func read(_ reading: Sample.Reading, at time: Double) {
        clock.set(time)
        session.record(reading.sample(at: time, .baseline))
        session.poll()
    }

    /// The first read, the baseline, the cut and its read-back; returns
    /// the cut mark's time.
    func toHold() -> Double {
        let time = toCutPrompt()
        read(.charging, at: time)
        answer("cutnow", at: time + 0.5)
        // The milestones: the cut mark, the GO line, the read-back question.
        #expect(session.snapshot.cutMark != nil)
        #expect(session.restoreByText != nil)
        #expect(session.snapshot.stage == .cutReadBack)
        read(.cut, at: time + 2)
        answer("cut08", at: time + 6)
        #expect(session.snapshot.stage == .hold)
        #expect(session.snapshot.cutConfirmed)
        return session.snapshot.cutMark?.time ?? 0
    }

    /// On to the RESTORE prompt at the hold's end.
    func toRestorePrompt() -> Double {
        let mark = toHold()
        clock.set(mark + 180)
        session.poll()
        #expect(session.snapshot.stage == .restorePrompt)
        return mark
    }
}

extension ManualCutTests {
    @Suite("watch takes an answer only once its question is on the terminal (code review r1 of #101, must 3)")
    struct ManualCutTerminalTests {
        @Test("Review r1's case: 00 typed after recheckfail, before the read-first question appears, confirms nothing")
        func zeroTypedBeforeReadFirstAppears() throws {
            let driver = try TerminalDriver()
            let mark = driver.toRestorePrompt()
            #expect(driver.session.snapshot.stage == .restorePrompt)
            driver.answer("restorenow", at: mark + 182)
            driver.answer("restorefail", at: mark + 186)
            #expect(driver.session.snapshot.stage == .readFirst)
            driver.answer("08", at: mark + 190)
            #expect(driver.session.snapshot.stage == .recheck)
            #expect(eventually { driver.session.inputEligible })

            // The terminal stops taking output; recheckfail opens read-first,
            // whose prompt is queued but not written.
            driver.gate.close()
            driver.answer("recheckfail", at: mark + 195)
            #expect(driver.session.snapshot.stage == .readFirst)
            #expect(!driver.session.inputEligible)
            // The owner types 00, and half of another answer, before the
            // question is visible.
            driver.typeEarly("00\n")
            driver.typeEarly("0")
            #expect(!driver.session.snapshot.restoreConfirmed)
            #expect(driver.session.snapshot.answers.last?.word == "recheckfail")

            // The terminal takes the prompt: pending input, the partial line
            // included, is discarded, and only then do answers count.
            driver.gate.open()
            #expect(eventually { driver.session.inputEligible })
            driver.answer("0", at: mark + 200, isWord: false)
            let flow = driver.session.snapshot
            #expect(!flow.restoreConfirmed, "the partial 0 typed early joined the 0 typed after")
            #expect(flow.stage == .readFirst)
            // Typed after the question appeared, 00 counts.
            driver.answer("00", at: mark + 205)
            #expect(driver.session.snapshot.restoreConfirmed)
            driver.session.stopReminder()
        }

        @Test("Review r2's case: output to the terminal opened read-only; no prompt appears and start00 is not taken (must E)")
    func readOnlyTerminalOutput() throws {
        let terminal = try PseudoTerminal()
        // The probe's output: the same terminal, opened read-only, so every
        // write fails while isatty still says it is a terminal.
        let name = String(cString: ttyname(terminal.slave))
        let output = open(name, O_RDONLY | O_NOCTTY)
        try #require(output >= 0)
        defer { close(output) }
        #expect(isatty(output) == 1)
        let console = ConsoleWriter { TerminalInput.writeAll($0 + "\n", to: output) }
        let clock = FakeClock()
        let session = ManualCutSession(
            hold: 180, console: console, input: TerminalInput(descriptor: terminal.slave),
            sleepLog: SleepLog(), clock: clock.portable, reminderTick: 0.05
        )
        session.begin()
        #expect(eventually { session.isEnded })
        terminal.type("start00\n")
        for _ in 0..<20 {
            session.poll()
            usleep(5000)
        }
        let flow = session.snapshot
        #expect(flow.answers.isEmpty)
        #expect(flow.baselineStart == nil)
        #expect(!flow.inputEligible)
        #expect(!terminal.output.contains("FIRST READ"))
        let outcome = ManualCutOutcome.of(flow, sleepNotices: [])
        #expect(outcome.exitStatus == 2)
        #expect(outcome.recoveryReason == nil)
        #expect(outcome.verdict?.title == "inconclusive")
    }

    @Test("After the CUT prompt, a prompt the terminal cannot take ends the run with CHECK RECOVERY FIRST and exit 3")
    func failedWriteAfterTheCutPrompt() {
        let failing = Counter()
        let console = ConsoleWriter { _ in failing.value == 0 }
        let driver = SessionDriver(console: console)
        driver.toHold()
        let mark = driver.session.snapshot.cutMark?.time ?? 0
        failing.add()
        driver.at(mark + 180)
        driver.session.poll()
        #expect(eventually { driver.session.isEnded })
        let flow = driver.session.snapshot
        guard case .terminalUnusable = flow.ending else {
            Issue.record("expected the terminal to be unusable, got \(String(describing: flow.ending))")
            return
        }
        #expect(!flow.inputEligible)
        let outcome = ManualCutOutcome.of(flow, sleepNotices: [])
        #expect(outcome.exitStatus == 3)
        #expect(outcome.recoveryReason != nil)
        driver.session.stopReminder()
    }

    @Test("writeAll reports a write it could not finish")
    func writeAllReportsFailure() throws {
        var pipeEnds: [Int32] = [0, 0]
        try #require(pipe(&pipeEnds) == 0)
        defer { close(pipeEnds[0]) }
        #expect(TerminalInput.writeAll("fine\n", to: pipeEnds[1]))
        close(pipeEnds[1])
        #expect(!TerminalInput.writeAll("closed\n", to: pipeEnds[1]))
        #expect(!TerminalInput.writeAll("not a descriptor\n", to: -1))
    }

    @Test("restorenow typed before the RESTORE prompt appears marks nothing")
        func restorenowTypedBeforeThePrompt() throws {
            let driver = try TerminalDriver()
            let mark = driver.toHold()
            driver.gate.close()
            driver.clock.set(mark + 180)
            driver.session.poll()
            #expect(driver.session.snapshot.stage == .restorePrompt)
            #expect(!driver.session.inputEligible)
            #expect(!driver.terminal.output.contains(ManualCutQuestion.restore.prompt.prefix(30)))
            driver.typeEarly("restorenow\n")
            #expect(driver.session.snapshot.restoreMark == nil)
            driver.gate.open()
            #expect(eventually { driver.session.inputEligible })
            for _ in 0..<20 {
                driver.session.poll()
            }
            #expect(driver.session.snapshot.restoreMark == nil)
            #expect(driver.session.snapshot.stage == .restorePrompt)
            driver.answer("restorenow", at: mark + 190)
            #expect(driver.session.snapshot.restoreMark != nil)
            driver.session.stopReminder()
        }

        @Test("cut08 typed ahead, before GO and the read-back question, never confirms the cut")
        func cut08TypedAhead() throws {
            let driver = try TerminalDriver()
            // The CUT prompt is on the terminal and takes answers.
            let time = driver.toCutPrompt()
            let generation = driver.session.snapshot.questionGeneration
            driver.gate.close()
            // cutnow and, at once, cut08: the second line meets the read-back
            // question before its prompt is written.
            driver.clock.set(time + 1)
            driver.terminal.type("cutnow\ncut08\n")
            let reached = eventually {
                driver.session.poll()
                return driver.session.snapshot.stage == .cutReadBack
            }
            // The milestones: cutnow was taken, the cut is marked, GO was
            // queued, and the read-back question was published but is not yet
            // on the terminal.
            #expect(reached)
            #expect(driver.session.snapshot.cutMark?.time == time + 1)
            #expect(driver.session.restoreByText != nil)
            #expect(driver.session.snapshot.questionGeneration == generation + 1)
            #expect(!driver.session.inputEligible)
            #expect(driver.session.snapshot.answers.map(\.word).last == "cutnow")
            driver.typeEarly("")
            #expect(!driver.session.snapshot.cutConfirmed)
            driver.gate.open()
            #expect(eventually { driver.session.inputEligible })
            #expect(eventually { driver.terminal.output.contains("GO — run the cut now") })
            for _ in 0..<20 {
                driver.session.poll()
            }
            // The early cut08 was dropped, never taken.
            #expect(!driver.session.snapshot.cutConfirmed)
            #expect(!driver.session.snapshot.answers.contains { $0.word == "cut08" })
            #expect(driver.session.snapshot.stage == .cutReadBack)
            driver.session.stopReminder()
        }
    }
}
