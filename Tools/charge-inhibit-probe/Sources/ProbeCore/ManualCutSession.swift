import Foundation

/// Where the owner's answers come from. Used only under the session's lock.
public protocol AnswerInput: AnyObject {
    /// The complete lines ready now, in order, without waiting.
    func availableLines() -> [String]
    /// Discards pending input: the terminal's unread input, including a line
    /// still being typed, and anything the probe has buffered.
    func discard()
}

/// The owner's answers, read from a terminal (in its usual line mode)
/// without waiting and without changing its settings: no descriptor flag is
/// ever changed (research note 10 §4), so reads are only made when `poll`
/// says a line is ready.
public final class TerminalInput: AnswerInput {
    public let descriptor: Int32
    private var buffer: [UInt8] = []

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public func availableLines() -> [String] {
        while Self.ready(descriptor, milliseconds: 0) {
            var chunk = [UInt8](repeating: 0, count: 1024)
            let count = read(descriptor, &chunk, chunk.count)
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

    /// `tcflush(TCIFLUSH)`, which drops what the terminal holds, a partial
    /// line included, and the probe's own buffer.
    public func discard() {
        tcflush(descriptor, TCIFLUSH)
        buffer.removeAll()
    }

    /// Waits until `descriptor` has something to read, or `milliseconds`
    /// pass. A terminal that has gone away is always "ready"; the wait then
    /// sleeps instead, so a loop never spins.
    public static func waitForInput(_ descriptor: Int32, milliseconds: Int32) {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        if poll(&entry, 1, milliseconds) > 0, entry.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            usleep(UInt32(milliseconds) * 1000)
        }
    }

    static func ready(_ descriptor: Int32, milliseconds: Int32) -> Bool {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, milliseconds) > 0 && entry.revents & Int16(POLLIN) != 0
    }

    /// Writes all of `text` to `descriptor`, retrying after an interruption;
    /// returns true only if every byte was written. Any other error, or a
    /// write that makes no progress, is a failure (code review r2 of #101,
    /// must E). For the console writer's thread only: it may block on a
    /// terminal that is not reading.
    @discardableResult
    public static func writeAll(_ text: String, to descriptor: Int32) -> Bool {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written > 0 {
                bytes = bytes.dropFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

/// The clock and the clock-time format the session uses; `watch` gives the
/// real ones, the tests their own.
public struct ManualCutClock: Sendable {
    /// Run seconds.
    public var now: @Sendable () -> Double
    /// Seconds since 1970.
    public var unixNow: @Sendable () -> Double
    /// A Unix time as the console shows it: "10:18:02".
    public var clockTime: @Sendable (Double) -> String

    public init(now: @escaping @Sendable () -> Double, unixNow: @escaping @Sendable () -> Double, clockTime: @escaping @Sendable (Double) -> String) {
        self.now = now
        self.unixNow = unixNow
        self.clockTime = clockTime
    }
}

/// `watch`'s run: one lock around the flow (``ManualCutFlow``), the owner's
/// input and the reminder's timer. The main loop, the reminder's own timer
/// and the signal handlers each hand the flow an event and perform its
/// actions under this lock, with the sleep log read inside it
/// (``SleepLog``). Performing an action never waits on the terminal:
/// console output is only queued (``ConsoleWriter``).
public final class ManualCutSession: @unchecked Sendable {
    /// What a signal does.
    public enum SignalResponse: Sendable, Equatable {
        /// The first: the flow has ended the run; the main loop finishes it.
        case handled
        /// A later one: quit at once, by the bounded path, with this banner
        /// (if any) and status.
        case quit(banner: ManualCutFlow.Banner?, status: Int32)
    }

    private let lock = NSLock()
    private var flow: ManualCutFlow
    public let console: ConsoleWriter
    private let input: any AnswerInput
    private let sleepLog: SleepLog
    private let clock: ManualCutClock
    private let reminderTick: Double
    private let reminderQueue = DispatchQueue(label: "charge-inhibit-probe.reminder")
    private var reminder: (any DispatchSourceTimer)?
    private var restoreBy: String?
    private var signals = 0
    private var printedHeader = false

    public init(
        hold: Int,
        console: ConsoleWriter,
        input: any AnswerInput,
        sleepLog: SleepLog,
        clock: ManualCutClock,
        reminderTick: Double = ManualCut.reminderTick
    ) {
        flow = ManualCutFlow(hold: hold)
        self.console = console
        self.input = input
        self.sleepLog = sleepLog
        self.clock = clock
        self.reminderTick = reminderTick
    }

    /// The flow as it stands.
    public var snapshot: ManualCutFlow {
        lock.withLock { flow }
    }

    /// The flow for the report, on every ending path (code review r2 of
    /// #101, must C): `drainSleepQueue` deregisters from sleep notifications
    /// and drains their queue, within its bound, and says whether it did;
    /// then the sleep log is read once more and reconciled
    /// (``ManualCutFlow/reconcile(with:drained:)``).
    public func reconciledFlow(drainSleepQueue: () -> Bool) -> ManualCutFlow {
        let drained = drainSleepQueue()
        var final = snapshot
        final.reconcile(with: sleepLog.snapshot, drained: drained)
        return final
    }

    /// The GO line's restore time, as shown.
    public var restoreByText: String? {
        lock.withLock { restoreBy }
    }

    public var isEnded: Bool {
        lock.withLock { flow.stage == .ended }
    }

    public var wantsReadings: Bool {
        lock.withLock { flow.wantsReadings }
    }

    /// Whether the reminder's timer is armed.
    public var reminderIsArmed: Bool {
        lock.withLock { reminder != nil }
    }

    public func begin() {
        send(.begin(at: clock.now()))
    }

    /// One pass of the main loop: the owner's lines, then the clock.
    public func poll() {
        readInput()
        send(.tick(at: clock.now(), unixTime: clock.unixNow()))
    }

    /// A reading: handed to the flow, which sets its phase. Its line goes
    /// to the console only while no question is open, so readings never
    /// break into the owner's typing; the report has every one.
    public func record(_ sample: Sample) {
        lock.lock()
        defer { lock.unlock() }
        _ = perform(flow.handle(.reading(sample), sleeps: sleepLog.snapshot))
        guard flow.openQuestion == nil, flow.stage != .ended, let recorded = flow.samples.last else { return }
        if !printedHeader {
            console.enqueue(ReportFormat.sampleHeader, kind: .sample)
            printedHeader = true
        }
        console.enqueue(ReportFormat.sampleLine(recorded), kind: .sample)
    }

    /// The first signal goes to the flow; a later one quits.
    public func signal(_ number: Int32) -> SignalResponse {
        lock.lock()
        defer { lock.unlock() }
        signals += 1
        guard signals == 1 else {
            let second = flow.secondSignal(number)
            return .quit(banner: second.banner, status: second.exitStatus)
        }
        _ = perform(flow.handle(.signal(number, at: clock.now()), sleeps: sleepLog.snapshot))
        console.enqueue("\(ManualCutFlow.signalName(number)): finishing the report; press Ctrl-C again to quit at once.")
        return .handled
    }

    /// The console wrote the prompt of question `generation`: on the
    /// writer's thread, which holds no lock of its own here.
    private func published(_ generation: UInt64) {
        send(.published(generation: generation, at: clock.now()))
    }

    /// The console could not write an actionable message: the terminal is
    /// unusable, and the run ends (code review r2 of #101, must E).
    private func consoleFailed() {
        send(.consoleFailed(at: clock.now()))
    }

    /// What the writer reports for an actionable message: a failure ends
    /// the run.
    private func onActionable() -> @Sendable (ConsoleWriter.Result) -> Void {
        { [weak self] result in
            if result == .failed { self?.consoleFailed() }
        }
    }

    /// Whether the open question's prompt has been written and the owner's
    /// lines may answer it.
    public var inputEligible: Bool {
        lock.withLock { flow.inputEligible }
    }

    /// Stops the reminder's timer; never waits for a handler that runs.
    public func stopReminder() {
        lock.withLock {
            reminder?.cancel()
            reminder = nil
        }
    }

    func send(_ event: ManualCutFlow.Event) {
        lock.lock()
        defer { lock.unlock() }
        _ = perform(flow.handle(event, sleeps: sleepLog.snapshot))
    }

    /// Hands the flow the owner's complete lines (``ManualCutFlow/handleLines(_:at:unixTime:)``).
    private func readInput() {
        lock.lock()
        defer { lock.unlock() }
        let lines = input.availableLines()
        guard !lines.isEmpty else { return }
        _ = perform(flow.handleLines(lines, at: clock.now(), unixTime: clock.unixNow(), sleeps: sleepLog.snapshot))
    }

    /// Performs `actions` in order, under the lock; output is only queued.
    /// Returns whether input was discarded.
    ///
    /// Every actionable message (prompt, reminder, GO, instructions and
    /// banners) is queued under the question generation the flow has
    /// reached with this event, which the console writer is told first:
    /// anything queued for an earlier generation and not yet written is
    /// then dropped, so the superseding text (RESTORE CHIE FIRST and the
    /// read-first question, say) is the next actionable text to appear
    /// (code review r2 of #101, must B).
    private func perform(_ actions: [ManualCutFlow.Action]) -> Bool {
        let generation = flow.questionGeneration
        console.setCurrentGeneration(generation)
        var discarded = false
        for action in actions {
            switch action {
            case .discardInput:
                input.discard()
                discarded = true
            case let .publish(question, questionGeneration):
                // Input stays ineligible until the writer has written this
                // prompt; then the flow discards pending input and only
                // then takes answers. Nobody waits for the writer: it calls
                // back.
                // Only a prompt written in full makes input eligible; one
                // that could not be written ends the run.
                console.enqueue(Self.text(question, repeated: false), generation: generation) { [weak self] result in
                    switch result {
                    case .written: self?.published(questionGeneration)
                    case .failed: self?.consoleFailed()
                    case .superseded: break
                    }
                }
            case let .remind(question):
                console.enqueue(Self.text(question, repeated: true), generation: generation, onWritten: onActionable())
            case let .say(text):
                console.enqueue(text, generation: generation, onWritten: onActionable())
            case let .banner(banner):
                console.enqueue("\n" + ManualCut.text(banner), generation: generation, onWritten: onActionable())
            case .armReminder:
                armReminder()
            case let .go(restoreByUnix):
                let time = clock.clockTime(restoreByUnix)
                restoreBy = time
                console.enqueue("""

                    GO — run the cut now in terminal B. Restore by \(time).
                    Write \(time) down, or set a phone timer for it, before you run the cut.
                    """, generation: generation, onWritten: onActionable())
            case .end:
                break
            }
        }
        return discarded
    }

    /// A question as the console shows it; restore requests ring.
    static func text(_ question: ManualCutQuestion, repeated: Bool) -> String {
        let bell = question.isRestoreRequest ? "\u{07}" : ""
        return "\n" + bell + (repeated ? "(Reminder) " : "") + question.prompt
            + "\nAnswer: \(question.words.joined(separator: " or "))"
    }

    /// The reminder's own timer, apart from the sampling loop: every
    /// `reminderTick` seconds it hands the flow the time. Called under the
    /// lock.
    private func armReminder() {
        guard reminder == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: reminderQueue)
        timer.schedule(deadline: .now() + reminderTick, repeating: reminderTick)
        let clock = clock
        timer.setEventHandler { [weak self] in
            self?.send(.reminderTick(at: clock.now()))
        }
        timer.resume()
        reminder = timer
    }
}

/// Runs `work` on a thread of its own and waits for it at most `seconds`;
/// returns whether it finished. The thread is left to finish on its own if
/// it does not.
public func runBounded(within seconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
    let finished = DispatchSemaphore(value: 0)
    Thread {
        work()
        finished.signal()
    }.start()
    return finished.wait(timeout: .now() + seconds) == .success
}

/// How `watch` ends (code review r1 of #101, must 1): the report is saved
/// first, under its own deadline; then it is queued for the console; then
/// the console gets at most ``drainBound`` seconds; then the probe exits,
/// whether or not the terminal took it all. Each step is a closure, so the
/// tests drive the order and the bound.
public enum BoundedEnd {
    /// The most the end waits for the console.
    public static let drainBound = 2.0

    public struct Steps {
        /// Saves the report; returns whether it was saved.
        public var persist: () -> Bool
        /// Queues the report, and where it was saved, for the console.
        public var print: (_ persisted: Bool) -> Void
        /// Waits for the console, at most the bound; returns whether it
        /// took everything.
        public var drain: (_ timeout: Double) -> Bool
        /// Ends the process (or, for the main path, returns the status).
        public var exit: (_ status: Int32, _ drained: Bool) -> Void

        public init(
            persist: @escaping () -> Bool,
            print: @escaping (_ persisted: Bool) -> Void,
            drain: @escaping (_ timeout: Double) -> Bool,
            exit: @escaping (_ status: Int32, _ drained: Bool) -> Void
        ) {
            self.persist = persist
            self.print = print
            self.drain = drain
            self.exit = exit
        }
    }

    public static func perform(status: Int32, steps: Steps) {
        let persisted = steps.persist()
        steps.print(persisted)
        let drained = steps.drain(drainBound)
        steps.exit(status, drained)
    }
}
