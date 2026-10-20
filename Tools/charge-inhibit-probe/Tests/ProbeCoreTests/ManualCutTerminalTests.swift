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
    /// Return, and polls until the session has read it.
    func answer(_ word: String, at time: Double) {
        clock.set(time)
        #expect(eventually { session.inputEligible }, "\(word): the question never took answers")
        let before = session.snapshot.answers.count
        terminal.type(word + "\n")
        _ = eventually {
            session.poll()
            return session.snapshot.answers.count > before
        }
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
        session.begin()
        answer("start00", at: 5)
        var time = 5.5
        while session.snapshot.stage == .baseline {
            read(.charging, at: time)
            time += 2
        }
        read(.charging, at: time)
        answer("cutnow", at: time + 0.5)
        read(.cut, at: time + 2)
        answer("cut08", at: time + 6)
        return session.snapshot.cutMark?.time ?? 0
    }

    /// On to the RESTORE prompt at the hold's end.
    func toRestorePrompt() -> Double {
        let mark = toHold()
        clock.set(mark + 180)
        session.poll()
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
            driver.answer("0", at: mark + 200)
            let flow = driver.session.snapshot
            #expect(!flow.restoreConfirmed, "the partial 0 typed early joined the 0 typed after")
            #expect(flow.stage == .readFirst)
            // Typed after the question appeared, 00 counts.
            driver.answer("00", at: mark + 205)
            #expect(driver.session.snapshot.restoreConfirmed)
            driver.session.stopReminder()
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
            driver.session.begin()
            driver.answer("start00", at: 5)
            var time = 5.5
            while driver.session.snapshot.stage == .baseline {
                driver.read(.charging, at: time)
                time += 2
            }
            driver.gate.close()
            // cutnow and, at once, cut08: the second line meets the read-back
            // question before its prompt is written.
            driver.clock.set(time + 1)
            driver.terminal.type("cutnow\ncut08\n")
            _ = eventually {
                driver.session.poll()
                return driver.session.snapshot.stage == .cutReadBack
            }
            driver.typeEarly("")
            #expect(!driver.session.snapshot.cutConfirmed)
            driver.gate.open()
            #expect(eventually { driver.session.inputEligible })
            for _ in 0..<20 {
                driver.session.poll()
            }
            #expect(!driver.session.snapshot.cutConfirmed)
            driver.session.stopReminder()
        }
    }
}
