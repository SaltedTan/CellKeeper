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
/// is not reading does.
final class BlockingSink: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var lines: [String] = []

    var written: [String] {
        lock.withLock { lines }
    }

    lazy var sink: @Sendable (String) -> Void = { [self] text in
        gate.wait()
        lock.withLock { lines.append(text) }
        gate.signal()
    }

    /// Lets the sink write from now on.
    func open() {
        gate.signal()
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
    let session: ManualCutSession

    init(console: ConsoleWriter, reminderTick: Double = 0.02) {
        session = ManualCutSession(hold: 180, console: console, input: input, clock: clock.portable, reminderTick: reminderTick)
    }

    func at(_ time: Double) {
        clock.set(time)
    }

    func type(_ line: String, at time: Double) {
        clock.set(time)
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

    @Test("With a console that never writes, the reminder still makes the restore request and repeats it")
    func reminderFiresWhileConsoleBlocked() {
        let blocked = BlockingSink()
        let driver = SessionDriver(console: ConsoleWriter(sink: blocked.sink))
        driver.toHold()
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
        #expect(blocked.written.isEmpty)
    }

    @Test("With a console that never writes, a signal and the teardown return at once")
    func signalAndTeardownWhileConsoleBlocked() {
        let blocked = BlockingSink()
        let driver = SessionDriver(console: ConsoleWriter(sink: blocked.sink))
        driver.toHold()
        let start = Date()
        #expect(driver.session.signal(SIGINT) == .handled)
        #expect(driver.session.isEnded)
        #expect(driver.session.signal(SIGINT) == .quit(banner: .restoreChieNow, status: 3))
        driver.session.stopReminder()
        #expect(!driver.session.reminderIsArmed)
        #expect(Date().timeIntervalSince(start) < 0.5)
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
            startedAt: "2026-10-20 12:00:00 +11:00", machine: ManualCutSupportTests.machine, hold: 180,
            preconditionChecks: [], flow: driver.flow, outcome: driver.outcome, consoleSampleLinesDropped: 7
        ).render()
        #expect(text.contains("The console did not keep up: 7 sample lines were not shown there."))
        let quiet = ManualCutReport(
            startedAt: "2026-10-20 12:00:00 +11:00", machine: ManualCutSupportTests.machine, hold: 180,
            preconditionChecks: [], flow: driver.flow, outcome: driver.outcome
        ).render()
        #expect(!quiet.contains("did not keep up"))
    }
}
