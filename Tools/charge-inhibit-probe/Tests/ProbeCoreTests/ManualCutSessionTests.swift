import Foundation
import ProbeCore
import Testing

/// A clock the tests set.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0

    var now: Double {
        lock.withLock { time }
    }

    func set(_ value: Double) {
        lock.withLock { time = value }
    }

    var portable: ManualCutClock {
        ManualCutClock(
            now: { self.now },
            unixNow: { Scenario.epoch + self.now },
            clockTime: { String(format: "%.0f", $0 - Scenario.epoch) }
        )
    }
}

/// Answers the tests type, without a terminal.
final class FakeInput: AnswerInput, @unchecked Sendable {
    private var pending: [String] = []
    private(set) var discards = 0

    func type(_ line: String) {
        pending.append(line)
    }

    func availableLines() -> [String] {
        defer { pending.removeAll() }
        return pending
    }

    func discard() {
        discards += 1
        pending.removeAll()
    }
}

/// A console sink that blocks until the test lets it go, as a terminal that
/// is not reading does; `then` sees each message once written.
final class BlockingSink: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: Bool
    private var lines: [String] = []
    private var calls = 0
    private let then: @Sendable (String) -> Void

    init(blocked: Bool = true, then: @escaping @Sendable (String) -> Void = { _ in }) {
        self.blocked = blocked
        self.then = then
    }

    var written: [String] {
        condition.withLock { lines }
    }

    /// How many messages the writer has handed the sink, written or not.
    var entered: Int {
        condition.withLock { calls }
    }

    lazy var sink: @Sendable (String) -> Bool = { [self] text in
        condition.lock()
        calls += 1
        while blocked {
            condition.wait()
        }
        lines.append(text)
        condition.unlock()
        then(text)
        return true
    }

    /// Lets the sink write from now on.
    func open() {
        condition.withLock {
            blocked = false
            condition.broadcast()
        }
    }

    /// Makes the sink block from now on, as a terminal that stops reading.
    func close() {
        condition.withLock { blocked = true }
    }
}

/// The console writer's results, in order.
final class ResultLog: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ConsoleWriter.Result] = []

    func add(_ result: ConsoleWriter.Result) {
        lock.withLock { results.append(result) }
    }

    var values: [ConsoleWriter.Result] {
        lock.withLock { results }
    }
}

/// Polls `condition` until it holds or `timeout` seconds pass.
func eventually(timeout: Double = 3, _ condition: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// Runs a session from the first read to the hold, on a fake clock, with
/// charging readings, then a cut.
struct SessionDriver {
    let clock = FakeClock()
    let input = FakeInput()
    let sleepLog = SleepLog()
    let session: ManualCutSession

    init(console: ConsoleWriter, reminderTick: Double = 0.02) {
        session = ManualCutSession(hold: 180, console: console, input: input, sleepLog: sleepLog, clock: clock.portable, reminderTick: reminderTick)
    }

    func at(_ time: Double) {
        clock.set(time)
    }

    /// Waits until the open question's prompt has been written, then types
    /// `line`.
    func type(_ line: String, at time: Double) {
        clock.set(time)
        _ = eventually { session.inputEligible }
        input.type(line)
        session.poll()
    }

    func read(_ reading: Sample.Reading, at time: Double) {
        clock.set(time)
        session.record(reading.sample(at: time, .baseline))
        session.poll()
    }

    /// The first read, the baseline, the CUT prompt, the mark at +34, the
    /// read-back at +40; then the hold, with the battery cut.
    func toHold() {
        session.begin()
        type("start00", at: 5)
        var time = 5.5
        while session.snapshot.stage == .baseline {
            read(.charging, at: time)
            time += 2
        }
        read(.charging, at: time)
        type("cutnow", at: time + 0.5)
        read(.cut, at: time + 2)
        type("cut08", at: time + 6)
    }
}

extension ManualCutTests {
    @Suite("watch's console, reminder, signals and end never wait on the terminal (code review r1 of #101, must 1)")
    struct ManualCutSessionTests {
        @Test("Enqueuing never waits for a terminal that is not reading")
        func enqueueNeverBlocks() {
            let blocked = BlockingSink()
            let console = ConsoleWriter(sink: blocked.sink)
            let start = Date()
            for index in 0..<200 {
                console.enqueue("line \(index)")
            }
            #expect(Date().timeIntervalSince(start) < 0.5)
            #expect(blocked.written.isEmpty)
            #expect(!console.drain(timeout: 0.1))
            blocked.open()
            #expect(console.drain(timeout: 3))
            #expect(blocked.written.count == 200)
            #expect(blocked.written.first == "line 0" && blocked.written.last == "line 199")
        }

        @Test("Under back-pressure, sample lines are coalesced; prompts and recovery text are never dropped")
        func samplesCoalesced() {
            let blocked = BlockingSink()
            let console = ConsoleWriter(maximumQueuedSamples: 3, sink: blocked.sink)
            console.enqueue("first prompt")
            for index in 0..<20 {
                console.enqueue("sample \(index)", kind: .sample)
            }
            console.enqueue("RESTORE CHIE NOW")
            for index in 20..<30 {
                console.enqueue("sample \(index)", kind: .sample)
            }
            console.enqueue("last prompt")
            blocked.open()
            #expect(console.drain(timeout: 3))
            let written = blocked.written
            #expect(written.contains("first prompt"))
            #expect(written.contains("RESTORE CHIE NOW"))
            #expect(written.contains("last prompt"))
            let samples = written.filter { $0.hasPrefix("sample") }
            #expect(samples.count <= 4)
            #expect(samples.last == "sample 29")
            #expect(console.droppedSampleLines == 30 - samples.count)
            // Order is kept.
            #expect(written.firstIndex(of: "RESTORE CHIE NOW")! < written.firstIndex(of: "last prompt")!)
        }

        @Test("With a console that stops writing, the reminder still makes the restore request and repeats it")
        func reminderFiresWhileConsoleBlocked() {
            let blocked = BlockingSink(blocked: false)
            let driver = SessionDriver(console: ConsoleWriter(sink: blocked.sink))
            driver.toHold()
            blocked.close()
            let before = blocked.written.count
            let flow = driver.session.snapshot
            #expect(flow.stage == .hold)
            #expect(driver.session.reminderIsArmed)
            let mark = flow.cutMark?.time ?? 0
            // The main loop is stuck: only the reminder's own timer runs.
            driver.at(mark + 180)
            #expect(eventually { driver.session.snapshot.stage == .restorePrompt })
            let shown = driver.session.snapshot.lastShownAt ?? 0
            driver.at(shown + 20)
            #expect(eventually { driver.session.snapshot.lastShownAt == shown + 20 })
            // The terminal took nothing more, and the restore question is not
            // answerable until it does.
            #expect(blocked.written.count <= before + 1)
            #expect(!driver.session.inputEligible)
            driver.session.stopReminder()
        }

        @Test("With a console that stops writing, a signal and the teardown return at once")
        func signalAndTeardownWhileConsoleBlocked() {
            let blocked = BlockingSink(blocked: false)
            let driver = SessionDriver(console: ConsoleWriter(sink: blocked.sink))
            driver.toHold()
            blocked.close()
            driver.session.console.enqueue("a prompt the terminal does not take")
            let start = Date()
            #expect(driver.session.signal(SIGINT) == .handled)
            #expect(driver.session.isEnded)
            #expect(driver.session.signal(SIGINT) == .quit(banner: .restoreChieNow, status: 3))
            driver.session.stopReminder()
            #expect(!driver.session.reminderIsArmed)
            #expect(Date().timeIntervalSince(start) < 0.5)
        }

        @Test("A sleep logged after restored00 was typed, before it was handled, leaves recovery unconfirmed (must 2)")
        func sessionSleepBeforeQueuedAnswer() {
            let console = ConsoleWriter { _ in true }
            let driver = SessionDriver(console: console)
            driver.toHold()
            let mark = driver.session.snapshot.cutMark?.time ?? 0
            driver.at(mark + 180)
            driver.session.poll()
            #expect(driver.session.snapshot.stage == .restorePrompt)
            driver.type("restorenow", at: mark + 182)
            #expect(driver.session.snapshot.stage == .restoreReadBack)
            // The read-back question is on the terminal; restored00 is typed;
            // the Mac sleeps before the main loop reads it.
            #expect(eventually { driver.session.inputEligible })
            driver.at(mark + 190)
            driver.input.type("restored00")
            ManualCut.willSleepHandler(log: driver.sleepLog, now: { mark + 189 })({})
            driver.session.poll()
            let flow = driver.session.snapshot
            #expect(flow.stage == .readFirst)
            #expect(!flow.restoreConfirmed)
            #expect(flow.sleeps == [mark + 189])
            // The answer was never taken: the sleep came first, inside the same
            // critical section, not after it to undo it.
            #expect(!flow.answers.contains { $0.word == "restored00" })
            driver.session.stopReminder()
        }

        @Test("A sleep logged while the main loop is stuck is delivered by the reminder, not repeated over")
        func reminderDeliversLatchedSleep() {
            let console = ConsoleWriter { _ in true }
            let driver = SessionDriver(console: console)
            driver.toHold()
            let mark = driver.session.snapshot.cutMark?.time ?? 0
            driver.at(mark + 180)
            #expect(eventually { driver.session.snapshot.stage == .restorePrompt })
            // The Mac sleeps; only the reminder's timer runs after the wake.
            ManualCut.willSleepHandler(log: driver.sleepLog, now: { mark + 185 })({})
            driver.at(mark + 205)
            #expect(eventually { driver.session.snapshot.stage == .readFirst })
            #expect(driver.session.snapshot.sleeps == [mark + 185])
            driver.session.stopReminder()
        }

        /// A session at the restore's read-back question, on the terminal, at
        /// mark + 182; returns the cut mark's time.
        static func atRestoreReadBack(_ driver: SessionDriver) -> Double {
            driver.toHold()
            let mark = driver.session.snapshot.cutMark?.time ?? 0
            driver.at(mark + 180)
            driver.session.poll()
            driver.type("restorenow", at: mark + 182)
            #expect(eventually { driver.session.inputEligible })
            return mark
        }

        @Test("Review r2's sequence: a sleep notification paused after taking its time, a confirmation, a signal; the end still finds the sleep (must C)")
        func lateSleepFoundAtTheEnd() {
            let driver = SessionDriver(console: ConsoleWriter { _ in true })
            let mark = Self.atRestoreReadBack(driver)
            // The real handler, on a real sleep queue, paused after it took
            // the sleep's time and before it logged it.
            let sleepQueue = SleepQueue(label: "test.sleep")
            let sampled = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            let handler = ManualCut.willSleepHandler(log: driver.sleepLog, now: {
                sampled.signal()
                resume.wait()
                return mark + 189
            })
            sleepQueue.queue.async { handler {} }
            #expect(sampled.wait(timeout: .now() + 2) == .success)
            // The log is still empty: restored00 is accepted.
            driver.type("restored00", at: mark + 190)
            #expect(driver.session.snapshot.restoreConfirmed)
            #expect(driver.session.signal(SIGINT) == .handled)
            #expect(driver.session.isEnded)
            // The notification resumes while the end drains the sleep queue.
            Thread {
                usleep(200_000)
                resume.signal()
            }.start()
            let flow = driver.session.reconciledFlow { runBounded(within: 2) { sleepQueue.drain() } }
            #expect(!flow.restoreConfirmed)
            #expect(flow.confirmationInvalidated?.contains("+\(seconds(mark + 189))") == true)
            #expect(flow.sleeps == [mark + 189])
            let outcome = ManualCutOutcome.of(flow, sleepNotices: [])
            #expect(outcome.exitStatus == 3)
            #expect(outcome.recoveryReason != nil)
            #expect(flow.secondSignal(SIGINT) == (.restoreChieNow, 3))
            driver.session.stopReminder()
        }

        @Test("If the sleep queue cannot be drained within its bound, the confirmation does not count")
        func undrainedSleepQueue() {
            let driver = SessionDriver(console: ConsoleWriter { _ in true })
            let mark = Self.atRestoreReadBack(driver)
            let sleepQueue = SleepQueue(label: "test.sleep")
            let sampled = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            let handler = ManualCut.willSleepHandler(log: driver.sleepLog, now: {
                sampled.signal()
                resume.wait()
                return mark + 195
            })
            sleepQueue.queue.async { handler {} }
            #expect(sampled.wait(timeout: .now() + 2) == .success)
            driver.type("restored00", at: mark + 190)
            #expect(driver.session.signal(SIGINT) == .handled)
            let start = Date()
            let flow = driver.session.reconciledFlow { runBounded(within: 0.3) { sleepQueue.drain() } }
            #expect(Date().timeIntervalSince(start) < 1)
            #expect(!flow.restoreConfirmed)
            #expect(flow.confirmationInvalidated?.contains("could not be drained") == true)
            #expect(ManualCutOutcome.of(flow, sleepNotices: []).exitStatus == 3)
            resume.signal()
            driver.session.stopReminder()
        }

        @Test("A sleep found at the end that began after the confirmation leaves it standing, and the run is inconclusive")
        func laterSleepFoundAtTheEnd() {
            let driver = SessionDriver(console: ConsoleWriter { _ in true })
            let mark = Self.atRestoreReadBack(driver)
            driver.type("restored00", at: mark + 190)
            #expect(driver.session.signal(SIGINT) == .handled)
            driver.sleepLog.record(at: mark + 191)
            let flow = driver.session.reconciledFlow { true }
            #expect(flow.restoreConfirmed)
            #expect(flow.confirmationInvalidated == nil)
            #expect(flow.sleeps == [mark + 191])
            #expect(ManualCutOutcome.of(flow, sleepNotices: []).verdict?.title == "inconclusive")
            driver.session.stopReminder()
        }

        /// A report file whose first write stops after 8 bytes and waits for
        /// `gate`, signalling `paused`; later writes go through.
        static func pausingFile(path: String, paused: DispatchSemaphore, gate: DispatchSemaphore, armed: Counter) -> ReportFile? {
            let first = Counter()
            let hooks = ReportFile.Hooks(
                arm: { seconds in if seconds == EmergencyExit.deadline { armed.add() } },
                disarm: {},
                write: { descriptor, bytes, offset in
                    first.add()
                    guard first.value == 1 else { return pwrite(descriptor, bytes.baseAddress, bytes.count, offset) }
                    let written = pwrite(descriptor, bytes.baseAddress, min(8, bytes.count), offset)
                    paused.signal()
                    gate.wait()
                    return written
                }
            )
            return ReportFile(path: path, placeholder: "placeholder\n", hooks: hooks)
        }

        static func temporaryPath() -> String {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("charge-inhibit-probe-manual-adapter-cut-\(UUID().uuidString).txt").path
        }

        @Test("Review r2's case: a second ending waits for the first ending's save, paused after 8 bytes, before it exits (must A)")
        func secondEndingWaitsForTheSave() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let paused = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let armed = Counter()
            let file = try #require(Self.pausingFile(path: path, paused: paused, gate: gate, armed: armed))
            let oneSave = OneShotSave()
            let report = String(repeating: "the main path's report line\n", count: 40)
            // The main path's end: its save's first write pauses after 8 bytes.
            Thread { _ = oneSave.save { file.persist(report) } }.start()
            #expect(paused.wait(timeout: .now() + 2) == .success)
            // A second signal's bounded end, on its own thread.
            let exited = Counter()
            let exitedAfterRelease = Counter()
            let released = Counter()
            let console = ConsoleWriter { _ in true }
            Thread {
                BoundedEnd.perform(status: 3, steps: BoundedEnd.Steps(
                    persist: { oneSave.save { file.persist("the second ending's report\n") } },
                    print: { _ in console.enqueue("the report") },
                    drain: { console.drain(timeout: $0) },
                    exit: { _, _ in
                        if released.value > 0 { exitedAfterRelease.add() }
                        exited.add()
                    }
                ))
            }.start()
            Thread.sleep(forTimeInterval: 0.4)
            // It has not exited: the save is not complete.
            #expect(exited.value == 0)
            released.add()
            gate.signal()
            #expect(eventually { exited.value == 1 })
            #expect(exitedAfterRelease.value == 1)
            #expect(oneSave.isFinished)
            // The first save, complete; the second ending never wrote.
            #expect(try String(contentsOfFile: path, encoding: .utf8) == report)
            #expect(armed.value == 1)
        }

        @Test("If the first save hangs, a second ending waits only until its deadline, and never saves itself")
        func secondEndingBoundedByTheDeadline() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let paused = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let file = try #require(Self.pausingFile(path: path, paused: paused, gate: gate, armed: Counter()))
            let oneSave = OneShotSave(deadline: 0.4, margin: 0.1)
            Thread { _ = oneSave.save { file.persist(String(repeating: "x", count: 100)) } }.start()
            #expect(paused.wait(timeout: .now() + 2) == .success)
            let start = Date()
            let saved = oneSave.save { file.persist("the second ending's report") }
            let waited = Date().timeIntervalSince(start)
            #expect(!saved)
            #expect(waited >= 0.3 && waited < 1.5)
            // In watch, the first save's alarm would have ended the process by
            // now; here the file holds only the first save's 8 bytes.
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "xxxxxxxx")
            gate.signal()
        }

        @Test("The writer drops an actionable message whose generation is no longer current, and writes the rest")
        func writerDropsSuperseded() {
            let blocked = BlockingSink()
            let console = ConsoleWriter(sink: blocked.sink)
            let results = ResultLog()
            console.setCurrentGeneration(1)
            console.enqueue("in flight", generation: 1)
            #expect(eventually { blocked.entered == 1 })
            console.enqueue("old prompt", generation: 1) { results.add($0) }
            console.enqueue("a sample", kind: .sample)
            console.enqueue("report line")
            console.setCurrentGeneration(2)
            console.enqueue("new prompt", generation: 2) { results.add($0) }
            blocked.open()
            #expect(console.drain(timeout: 3))
            #expect(blocked.written == ["in flight", "a sample", "report line", "new prompt"])
            #expect(results.values == [.superseded, .written])
            #expect(console.supersededMessages == 1)
        }

        @Test("Review r2's sequence: RESTORE queued behind a blocked terminal, then a sleep; the old restore text never appears (must B)")
        func supersededRestorePromptNeverAppears() {
            let blocked = BlockingSink(blocked: false)
            let driver = SessionDriver(console: ConsoleWriter(sink: blocked.sink))
            driver.toHold()
            let mark = driver.session.snapshot.cutMark?.time ?? 0
            // The terminal stops taking output while a sample line is being
            // written.
            blocked.close()
            driver.read(.cut, at: mark + 100)
            // The hold ends: the RESTORE prompt is queued behind it.
            driver.at(mark + 180)
            driver.session.poll()
            #expect(driver.session.snapshot.stage == .restorePrompt)
            // A sleep: RESTORE CHIE FIRST and the read-first question.
            driver.sleepLog.record(at: mark + 181)
            driver.at(mark + 182)
            driver.session.poll()
            #expect(driver.session.snapshot.stage == .readFirst)
            blocked.open()
            #expect(driver.session.console.drain(timeout: 3))
            let written = blocked.written.joined(separator: "\n")
            #expect(!written.contains(ManualCutQuestion.restore.prompt), "the superseded RESTORE prompt appeared")
            let first = written.range(of: "RESTORE CHIE FIRST")
            let readFirst = written.range(of: "READ CHIE FIRST")
            #expect(first != nil && readFirst != nil)
            if let first, let readFirst { #expect(first.lowerBound < readFirst.lowerBound) }
            #expect(driver.session.console.supersededMessages >= 1)
            #expect(eventually { driver.session.inputEligible })
            driver.session.stopReminder()
        }

        @Test("The bounded end saves the report first, then queues it, then waits at most 2 s, then exits")
        func boundedEndOrder() {
            var steps: [String] = []
            BoundedEnd.perform(status: 3, steps: BoundedEnd.Steps(
                persist: { steps.append("persist"); return true },
                print: { steps.append("print \($0)") },
                drain: { steps.append("drain \($0)"); return true },
                exit: { steps.append("exit \($0) \($1)") }
            ))
            #expect(steps == ["persist", "print true", "drain 2.0", "exit 3 true"])
        }

        @Test("With a console that never writes, the bounded end has saved the report and exits within its bound")
        func boundedEndWhileConsoleBlocked() {
            let blocked = BlockingSink()
            let console = ConsoleWriter(sink: blocked.sink)
            console.enqueue("a prompt the terminal never takes")
            var saved: String?
            var exited: (Int32, Bool)?
            let start = Date()
            BoundedEnd.perform(status: 3, steps: BoundedEnd.Steps(
                persist: { saved = "the report"; return true },
                print: { _ in console.enqueue("the report") },
                drain: { console.drain(timeout: $0) },
                exit: { exited = ($0, $1) }
            ))
            let elapsed = Date().timeIntervalSince(start)
            #expect(saved == "the report")
            #expect(exited?.0 == 3)
            #expect(exited?.1 == false)
            #expect(elapsed >= 1.9 && elapsed < 3)
        }

        @Test("The report says when sample lines were dropped from the console")
        func reportSaysDropped() {
            var driver = FlowDriver()
            driver.toAfter()
            let text = ManualCutReport(
                startedAt: "2026-10-20 12:00:00 +11:00", machine: ManualCutTests.ManualCutSupportTests.machine, hold: 180,
                preconditionChecks: [], flow: driver.flow, outcome: driver.outcome, consoleSampleLinesDropped: 7
            ).render()
            #expect(text.contains("The console did not keep up: 7 sample lines were not shown there."))
            let quiet = ManualCutReport(
                startedAt: "2026-10-20 12:00:00 +11:00", machine: ManualCutTests.ManualCutSupportTests.machine, hold: 180,
                preconditionChecks: [], flow: driver.flow, outcome: driver.outcome
            ).render()
            #expect(!quiet.contains("did not keep up"))
        }
    }
}
