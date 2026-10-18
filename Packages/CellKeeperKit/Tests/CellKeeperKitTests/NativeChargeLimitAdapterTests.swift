@testable import CellKeeperKit
import CellKeeperCore
import Foundation
import Testing

/// Fixtures are the exact `pmset -g battlimit` output observed on macOS
/// 27.0.1 (26A434), Apple M4 (docs/research/08-native-charge-limit.md), with
/// the owner process ID replaced.
@Suite("Charge Limit report parsing")
struct ChargeLimitReportParserTests {
    static func report(_ limit: Int, reason: String = "manualChargeLimit", secondTerminated: Int = 0, secondLimit: Int? = nil) -> String {
        """
        Battery level limits:
        (
                {
                Terminated = 0;
                chargeSocLimitDrain = 1;
                chargeSocLimitIsEOC = 1;
                chargeSocLimitNoChargeToFull = 0;
                chargeSocLimitOwner = 12345;
                chargeSocLimitReason = \(reason);
                chargeSocLimitSoc = \(limit);
            },
                {
                Terminated = \(secondTerminated);
                chargeSocLimitDrain = 1;
                chargeSocLimitIsEOC = 1;
                chargeSocLimitNoChargeToFull = 0;
                chargeSocLimitOwner = 0;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = \(secondLimit ?? limit);
            }
        )

        """
    }

    @Test("Observed limits of 80–95% are read", arguments: [80, 85, 90, 95])
    func observedLimits(limit: Int) {
        #expect(ChargeLimitReportParser.parse(Self.report(limit)) == .limit(limit))
    }

    @Test("The observed report for a 100% limit means no limit")
    func noLimit() {
        let reading = ChargeLimitReportParser.parse("No battery level limits set\n")
        #expect(reading == .noLimit)
        #expect(reading.percent == 100)
    }

    @Test("Terminated entries are ignored")
    func terminatedIgnored() {
        #expect(ChargeLimitReportParser.parse(Self.report(85, secondTerminated: 1, secondLimit: 95)) == .limit(85))
    }

    @Test("Limits outside the Charge Limit's steps are read as reported, for the backend to judge", arguments: [60, 82, 99])
    func outOfStepLimits(limit: Int) {
        // The backend never records such a value as the user's own, and
        // keeps it as an adopted outside change (#12).
        #expect(ChargeLimitReportParser.parse(Self.report(limit)) == .limit(limit))
    }

    @Test("A report whose entries are all terminated has no active limit")
    func allTerminated() {
        let text = Self.report(80, secondTerminated: 1).replacingOccurrences(of: "Terminated = 0;", with: "Terminated = 1;")
        #expect(ChargeLimitReportParser.parse(text) == .unrecognized("no active limit"))
    }

    @Test("Keys other than those CellKeeper checks are ignored")
    func extraKeysIgnored() {
        // Owner decision (#14): only the observed flags are pinned, so a key
        // added by a macOS update does not make the backend unavailable.
        let text = Self.report(85).replacingOccurrences(of: "chargeSocLimitOwner = 0;", with: "chargeSocLimitOwner = 0;\n        chargeSocLimitSomethingNew = 1;")
        #expect(text.contains("chargeSocLimitSomethingNew"))
        #expect(ChargeLimitReportParser.parse(text) == .limit(85))
    }

    @Test("An active limit with any other value of an observed flag is unrecognised", arguments: [
        "chargeSocLimitDrain = 0", "chargeSocLimitIsEOC = 0", "chargeSocLimitNoChargeToFull = 1",
    ])
    func unexpectedFlagValue(flag: String) {
        // A temporary state might differ from the user's own limit only in
        // its flags (#14). One entry is enough.
        let key = String(flag.prefix { $0 != " " })
        let text = Self.report(85).replacingOne("\(key) = [0-9]+;", with: "\(flag);", options: .regularExpression)
        #expect(ChargeLimitReportParser.parse(text) == .unrecognized("a limit with \(flag)"))
    }

    @Test("An active limit without one of the observed flags is unrecognised", arguments: [
        "chargeSocLimitDrain", "chargeSocLimitIsEOC", "chargeSocLimitNoChargeToFull",
    ])
    func missingFlag(key: String) {
        let text = Self.report(85).replacingOne("\(key) = [0-9]+;", with: "", options: .regularExpression)
        #expect(ChargeLimitReportParser.parse(text) == .unrecognized("a limit without \(key)"))
    }

    @Test("The flags of terminated entries are not checked")
    func terminatedFlagsIgnored() {
        let text = Self.report(85, secondTerminated: 1, secondLimit: 95)
            .replacingOne("chargeSocLimitNoChargeToFull = 0;", with: "chargeSocLimitNoChargeToFull = 1;", options: .backwards)
        #expect(text.contains("chargeSocLimitNoChargeToFull = 1;"))
        #expect(ChargeLimitReportParser.parse(text) == .limit(85))
    }

    @Test("Anything else is unrecognised, never guessed", arguments: [
        "",
        "Battery level limits:\n()\n",
        "Battery level limits:\n(\n{\nchargeSocLimitSoc = 80;\n}\n)\n",
        "Some future format: 80",
        ChargeLimitReportParserTests.report(80, reason: "optimizedBatteryCharging"),
        ChargeLimitReportParserTests.report(80, secondLimit: 90),
        ChargeLimitReportParserTests.report(80, secondTerminated: 2),
        ChargeLimitReportParserTests.report(0),
        ChargeLimitReportParserTests.report(80).replacingOccurrences(of: "chargeSocLimitSoc = 80;", with: "chargeSocLimitSoc = eighty;"),
        ChargeLimitReportParserTests.report(80).replacingOccurrences(of: "    }\n)", with: "    }\n"),
        ChargeLimitReportParserTests.report(80).replacingOccurrences(of: "chargeSocLimitSoc = 80;", with: "chargeSocLimitSoc = 95;\n        chargeSocLimitSoc = 80;"),
        ChargeLimitReportParserTests.report(80).replacingOccurrences(of: "Terminated = 0;", with: "Terminated = 1;\n        Terminated = 0;"),
    ])
    func unrecognised(text: String) {
        guard case .unrecognized = ChargeLimitReportParser.parse(text) else {
            Issue.record("expected unrecognised for \(text.debugDescription)")
            return
        }
    }
}

private extension String {
    /// Replaces one occurrence, so a change affects one entry of a report:
    /// the first, or the last with `.backwards`.
    func replacingOne(_ target: String, with replacement: String, options: CompareOptions = []) -> String {
        guard let range = range(of: target, options: options) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}

@Suite("Command-line adapters")
struct CommandLineAdapterTests {
    /// A temporary directory with executable shell scripts standing in for
    /// `/usr/bin/shortcuts` and `/usr/bin/pmset`.
    final class FakeTools {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CellKeeperKitTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func script(_ name: String, _ body: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func path(_ name: String) -> String {
            directory.appendingPathComponent(name).path
        }
    }

    /// The timeout for a tool that finishes by itself, in a test not about
    /// timeouts: far beyond the production timeouts (5 s for pmset, 10 s and
    /// 20 s for shortcuts), as on a loaded machine a fake tool has taken
    /// longer than 5 s, and a pipeline longer than 10 s.
    static let toolTimeout: TimeInterval = 120

    // MARK: - Process runner

    /// Runs `operation`, and cancels it (recording an issue) if it is still
    /// running after `limit`, so a call that overruns ends in bounded time
    /// instead of hanging the test, as long as the runner notices the
    /// cancellation. The call is awaited either way.
    static func withWatchdog<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let call = Task { try await operation() }
        let watchdog = Task {
            try await Task.sleep(for: limit)
            Issue.record("still running after \(limit), so it was cancelled")
            call.cancel()
        }
        defer { watchdog.cancel() }
        return try await call.value
    }

    /// What the runner did, seen through its hooks: the tool it started,
    /// its passes and its stop signals; and the clock the test sets for it.
    final class RunnerTrace: @unchecked Sendable {
        // @unchecked Sendable: every property is behind `lock`.
        private let lock = NSLock()
        private var now: TimeInterval = 0
        private var passTotal = 0
        private var sent: [Int32] = []
        private var started: pid_t?
        private var watch: ExitWatch?

        /// The real clock and signals, or with `recordingStops`, the
        /// clock the test sets (from 0) and signals that are recorded
        /// instead of sent, so the tool runs on.
        func hooks(recordingStops: Bool) -> ProcessRunner.Hooks {
            var hooks = ProcessRunner.Hooks.system
            hooks.observe = { [self] event in
                switch event {
                case .launched(let pid):
                    // Started as the runner starts the tool, which exits
                    // only once released, signalled or unable to start
                    // reading: so on the tool's own process.
                    let watch = ExitWatch(pid)
                    lock.withLock {
                        started = pid
                        self.watch = watch
                    }
                case .passed:
                    lock.withLock { passTotal += 1 }
                }
            }
            if recordingStops {
                hooks.uptime = { [self] in lock.withLock { now } }
                hooks.signal = { [self] _, number in lock.withLock { sent.append(number) } }
            }
            return hooks
        }

        var passes: Int { lock.withLock { passTotal } }
        var signals: [Int32] { lock.withLock { sent } }
        var processID: pid_t? { lock.withLock { started } }
        var exitWatch: ExitWatch? { lock.withLock { watch } }

        /// Sets the runner's clock, and returns the passes so far.
        @discardableResult
        func setUptime(_ uptime: TimeInterval) -> Int {
            lock.withLock {
                now = uptime
                return passTotal
            }
        }
    }

    /// A call of the runner, with a deadline an hour away, on a tool for
    /// the tests that stop it. `/bin/sh` runs `setup`, opens the hold FIFO,
    /// publishes its process ID, and reads the FIFO until the test releases
    /// it; then it exits with status 0. It is one process using only
    /// builtins, and exits at once if its directory is gone. It opens the
    /// FIFO for reading and writing, then for reading only, and closes the
    /// first, so neither open waits, and its read ends at the release or
    /// once the test's descriptor is closed, as when the test process
    /// exits. A release written before the tool reads still reaches it.
    final class HeldTool {
        let task: Task<ProcessResult, any Error>
        let trace = RunnerTrace()
        private let directory: URL
        private let hold: Int32
        private let finished = Flag()

        init(setup: String, recordingStops: Bool) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeeper-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let fifo = directory.appendingPathComponent("hold").path
            // Read and write, so the open does not wait. No tool may inherit
            // the descriptor, or its own copy would keep its read from ending.
            let hold = mkfifo(fifo, 0o600) == 0 ? open(fifo, O_RDWR | O_CLOEXEC) : -1
            guard hold >= 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                try? FileManager.default.removeItem(at: directory)
                throw POSIXError(code)
            }
            self.hold = hold
            let script = "\(setup) exec 5<>\"$0/hold\" 4<\"$0/hold\" 5>&- && echo $$ > \"$0/ready\" || exit 3; read line <&4; exit 0"
            let arguments = ["-c", script, directory.path]
            let hooks = trace.hooks(recordingStops: recordingStops)
            let finished = finished
            task = Task {
                defer { finished.set() }
                return try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: arguments, timeout: 3600, hooks: hooks)
            }
        }

        var callEnded: Bool { finished.value }

        /// Waits up to 300 s for the tool to publish its process ID, and
        /// checks that it is the one the runner started and the exit watch
        /// follows. False, with an issue, if the call ends first or the ID
        /// does not come.
        func isReady() async -> Bool {
            let ready = directory.appendingPathComponent("ready")
            var line: String?
            // The guard below checks what the wait found.
            _ = await eventually(within: 300) {
                // `echo` may write in parts; the line is whole with its newline.
                if let text = try? String(contentsOf: ready, encoding: .utf8), text.hasSuffix("\n") {
                    line = String(text.dropLast())
                }
                return line != nil || finished.value
            }
            let started = trace.processID
            guard !finished.value, let line, let started, pid_t(line) == started, trace.exitWatch != nil else {
                Issue.record("the tool is not ready: it published \(line ?? "nothing"), the runner started \(started.map(String.init) ?? "nothing"), the call \(finished.value ? "ended" : "runs")")
                return false
            }
            return true
        }

        /// The tool reads the line and exits by itself.
        func release() {
            var newline = UInt8(ascii: "\n")
            _ = write(hold, &newline, 1)
        }

        /// The call's result once it has ended, waiting up to 60 s; nil,
        /// with an issue, if it still runs.
        func result() async -> Result<ProcessResult, any Error>? {
            let ended = await eventually(within: 60) { finished.value }
            guard ended else {
                Issue.record("the call still ran after 60 s")
                return nil
            }
            return await task.result
        }

        /// How the tool ended, waiting up to 60 s; nil if it still runs.
        func outcome() async -> ExitWatch.Outcome? {
            guard let watch = trace.exitWatch else { return nil }
            // Nil if the wait ran out, which the caller's check then fails on.
            _ = await eventually(within: 60) { watch.outcome() != nil }
            return watch.outcome()
        }

        /// Releases the tool and ends the call, waits for both, recording
        /// an issue if either still runs after 60 s, and then removes the
        /// directory, which an exited tool can no longer write to.
        func end() async {
            release()
            task.cancel()
            _ = await result()
            if let watch = trace.exitWatch {
                let exited = await eventually(within: 60) { watch.outcome() != nil }
                if !exited {
                    Issue.record("the tool still ran 60 s after its release")
                }
            }
            close(hold)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Runs `body` with a held tool, then ends the call and the tool and
    /// removes the tool's directory, whether or not `body` throws.
    static func withHeldTool(setup: String = "", recordingStops: Bool = false, _ body: (HeldTool) async throws -> Void) async throws {
        let tool = try HeldTool(setup: setup, recordingStops: recordingStops)
        do {
            try await body(tool)
        } catch {
            await tool.end()
            throw error
        }
        await tool.end()
    }

    /// Waits up to 60 s until the runner has run `count` more passes than
    /// `mark`. With two, at least one pass began after whatever the test
    /// changed when it took `mark`, and has taken its step. False, with an
    /// issue, if the call ends first or the passes do not come.
    static func passes(_ count: Int, after mark: Int, of tool: HeldTool) async -> Bool {
        let done = await eventually(within: 60) { tool.callEnded || tool.trace.passes >= mark + count }
        guard done, tool.trace.passes >= mark + count else {
            Issue.record("the runner ran \(tool.trace.passes - mark) of \(count) passes, and the call \(tool.callEnded ? "ended" : "runs")")
            return false
        }
        return true
    }

    /// Sets the runner's clock and waits for two more passes.
    static func advance(_ tool: HeldTool, to uptime: TimeInterval) async -> Bool {
        let mark = tool.trace.setUptime(uptime)
        return await passes(2, after: mark, of: tool)
    }

    /// How a process ended, as the kernel reports it to a kqueue watch
    /// (with the exit status, for a child of the test process, as the
    /// runner's tools are). The watch follows the process it was started
    /// on, whatever later takes its ID, and nothing is sent to that ID.
    final class ExitWatch: @unchecked Sendable {
        // @unchecked Sendable: `queue` never changes; `reported` is behind
        // `lock`.
        enum Outcome: Equatable {
            case exited(status: Int32)
            case killed(signal: Int32)
        }

        private let queue: Int32
        private let lock = NSLock()
        private var reported: Outcome?

        /// Nil if no process has that ID.
        init?(_ pid: pid_t) {
            guard pid > 0 else { return nil }
            let queue = kqueue()
            guard queue >= 0 else { return nil }
            var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD), fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
            guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
                close(queue)
                return nil
            }
            self.queue = queue
        }

        deinit {
            close(queue)
        }

        /// How the process ended, or nil if the kernel has not reported
        /// its exit.
        func outcome() -> Outcome? {
            lock.withLock {
                if reported == nil {
                    var event = kevent()
                    var noWait = timespec()
                    if kevent(queue, nil, 0, &event, 1, &noWait) == 1, event.fflags & UInt32(NOTE_EXIT) != 0 {
                        // A wait status: the signal that killed the process in
                        // the low 7 bits, or else its exit status in the next 8.
                        let status = Int32(truncatingIfNeeded: event.data)
                        reported = status & 0x7f == 0 ? .exited(status: (status >> 8) & 0xff) : .killed(signal: status & 0x7f)
                    }
                }
                return reported
            }
        }
    }

    @Test("Exit status and both output streams are captured")
    func capturesOutput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf out; printf 'first\\nsecond' >&2; exit 3"], timeout: Self.toolTimeout)
        #expect(result.status == 3)
        #expect(result.standardOutput == "out")
        #expect(result.standardError == "first\nsecond")
        #expect(result.errorSummary == "first")
    }

    @Test("A tool that does not finish in time is stopped")
    func timeout() async {
        let started = Date()
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 1)) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)
        }
        // Well before the tool's own 30 s: the deadline stopped it, rather
        // than the runner waiting it out and then reporting a timeout.
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test("A tool that ignores SIGTERM is killed with SIGKILL")
    func ignoresTerminate() async throws {
        // With the real clock and signals. The tool ignores SIGTERM from
        // before it publishes its process ID, and is stopped only after
        // that, by the cancellation, so the stop meets a tool that ignores
        // SIGTERM. Until it is released, which happens only after the
        // checks, a signal is all that ends it. The order and timing of the
        // signals are shown with the test's own clock below.
        try await Self.withHeldTool(setup: "trap '' TERM;") { tool in
            guard await tool.isReady() else { return }
            tool.task.cancel()
            guard let result = await tool.result() else { return }
            #expect(throws: CancellationError.self) { try result.get() }
            let outcome = await tool.outcome()
            #expect(outcome == .killed(signal: SIGKILL))
        }
    }

    @Test("A missing tool is a launch failure")
    func missingTool() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 5)
        }
    }

    @Test("Large output neither blocks the tool nor is kept beyond the limit")
    func largeOutput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 600000 /dev/zero | tr '\\0' x"], timeout: Self.toolTimeout)
        #expect(result.status == 0)
        #expect(result.standardOutput.utf8.count == ProcessRunner.outputLimit)
        #expect(!result.isOutputComplete)
    }

    @Test("A tool flooding its output still stops at the deadline")
    func floodingToolTimesOut() async {
        // The tool writes four times the output limit, which it can finish
        // only once the runner has read more than the limit (a pipe holds
        // far less), marks that, then floods without end. So a mark after
        // the call shows the runner read past its limit from the tool before
        // the deadline ended the call. If a slow start let the deadline come
        // first, there is no mark, and the call is repeated with a longer
        // deadline. The watchdog cancels a call still running 20 s past its
        // deadline, which then fails as a cancellation instead of timedOut.
        let flood = "head -c \(4 * ProcessRunner.outputLimit) /dev/zero; touch \"$0\"; exec /usr/bin/yes"
        for deadline in [1.0, 4, 16] {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeeper-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: marker) }
            await #expect(throws: ProcessRunnerError.timedOut(seconds: Int(deadline.rounded(.up)))) {
                try await Self.withWatchdog(.seconds(deadline + 20)) {
                    try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", flood, marker.path], timeout: deadline)
                }
            }
            if FileManager.default.fileExists(atPath: marker.path) { return }
        }
        Issue.record("the runner never read past its output limit before the deadline")
    }

    @Test("Ordinary output is complete")
    func completeOutput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf done"], timeout: Self.toolTimeout)
        #expect(result.isOutputComplete)
    }

    @Test("A descendant holding the output open neither hides what was written nor delays the result")
    func descendantHoldsPipe() async throws {
        // A descendant holds the output open while the hold file exists,
        // checking every 0.1 s, and gives up by itself after 300 checks (at
        // least 30 s). Removing the file afterwards releases it at its next
        // check, and if the removal fails it still gives up.
        // A runner that waited for the output to close would return only
        // then. The deadline is far beyond that, leaving ample headroom for a
        // slow start, and a call that never notices the shell exit is
        // cancelled by the watchdog after a minute instead.
        let hold = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeeper-test-\(UUID().uuidString)")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        let descendant = "i=0; while [ -e \"$0\" ] && [ $i -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done"
        let started = Date()
        let result = try await Self.withWatchdog(.seconds(60)) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf already_written; \(descendant) & exit 0", hold.path], timeout: 120)
        }
        #expect(result.status == 0)
        #expect(result.standardOutput == "already_written")
        // The output was still open when the result came, so the result did
        // not wait for the descendant.
        #expect(!result.isOutputComplete)
        // And well before the descendant would give up by itself.
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test("Cancelling the calling task stops the tool with SIGTERM")
    func cancellation() async throws {
        // With the real clock and signals. The cancellation meets a running
        // tool, which, until it is released after the checks, only a signal
        // ends.
        try await Self.withHeldTool { tool in
            guard await tool.isReady() else { return }
            tool.task.cancel()
            guard let result = await tool.result() else { return }
            #expect(throws: CancellationError.self) { try result.get() }
            let outcome = await tool.outcome()
            #expect(outcome == .killed(signal: SIGTERM))
        }
    }

    // In the next three tests the runner reads the test's clock, which
    // stands at 0 until the test moves it, never near the deadline an hour
    // on, and its signals are recorded instead of sent, so the tool runs
    // until the test releases it. Each counts passes from after the change
    // it waits on (a cancellation or a clock move), so the second of the two
    // passes it waits for began after that change.

    @Test("A cancellation sends SIGTERM at the next pass, and the call then waits for the tool to exit")
    func cancellationWaitsForExit() async throws {
        try await Self.withHeldTool(recordingStops: true) { tool in
            guard await tool.isReady() else { return }
            tool.task.cancel()
            let mark = tool.trace.passes
            guard await Self.passes(2, after: mark, of: tool) else { return }
            #expect(tool.trace.signals == [SIGTERM])
            // Passes go on after SIGTERM, without SIGKILL as the clock stands
            // still, and the call has not ended, with the tool running.
            guard await Self.passes(2, after: tool.trace.passes, of: tool) else { return }
            #expect(!tool.callEnded)
            #expect(tool.trace.signals == [SIGTERM])
            // Released, the tool exits by itself, and then the call ends.
            tool.release()
            guard let result = await tool.result() else { return }
            #expect(throws: CancellationError.self) { try result.get() }
            let outcome = await tool.outcome()
            #expect(outcome == .exited(status: 0))
        }
    }

    @Test("SIGKILL follows SIGTERM once the grace period has passed on the runner's clock")
    func killAfterGracePeriod() async throws {
        // The stop is requested at 0 on the runner's clock.
        let grace = ProcessRunner.stopGracePeriod
        try await Self.withHeldTool(recordingStops: true) { tool in
            guard await tool.isReady() else { return }
            tool.task.cancel()
            let mark = tool.trace.passes
            guard await Self.passes(2, after: mark, of: tool) else { return }
            #expect(tool.trace.signals == [SIGTERM])
            guard await Self.advance(tool, to: grace.nextDown) else { return }
            #expect(tool.trace.signals == [SIGTERM])
            guard await Self.advance(tool, to: grace) else { return }
            #expect(tool.trace.signals == [SIGTERM, SIGKILL])
        }
    }

    @Test("After SIGKILL the call waits for the tool to exit until twice the grace period, then gives up")
    func givesUpAfterKill() async throws {
        let grace = ProcessRunner.stopGracePeriod
        try await Self.withHeldTool(recordingStops: true) { tool in
            guard await tool.isReady() else { return }
            tool.task.cancel()
            let mark = tool.trace.passes
            guard await Self.passes(2, after: mark, of: tool), await Self.advance(tool, to: grace) else { return }
            #expect(tool.trace.signals == [SIGTERM, SIGKILL])
            // Just before twice the grace period, passes go on and the call
            // has not ended; at twice the grace period it ends, though the
            // tool still runs.
            guard await Self.advance(tool, to: (2 * grace).nextDown) else { return }
            #expect(!tool.callEnded)
            tool.trace.setUptime(2 * grace)
            guard let result = await tool.result() else { return }
            #expect(throws: CancellationError.self) { try result.get() }
            let watch = try #require(tool.trace.exitWatch)
            #expect(watch.outcome() == nil)
            #expect(tool.trace.signals == [SIGTERM, SIGKILL])
        }
    }

    @Test("An already-cancelled task does not start the tool")
    func cancelledBeforeStart() async throws {
        let tools = try FakeTools()
        let marker = tools.path("started")
        let executable = try tools.script("tool", "touch '\(marker)'")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run(executable, arguments: [], timeout: 5)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    // MARK: - Record file

    @Test("The record file is saved, read back, replaced and removed")
    func recordFile() throws {
        let tools = try FakeTools()
        let store = FileOwnershipRecordStore(url: tools.directory.appendingPathComponent("nested/record.json"))
        #expect(try store.load() == nil)
        try store.save(Data("first".utf8))
        #expect(try store.load() == Data("first".utf8))
        try store.save(Data("second".utf8))
        #expect(try store.load() == Data("second".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tools.path("nested"))
        #expect(leftovers == ["record.json"])
        try store.remove()
        #expect(try store.load() == nil)
        try store.remove()
    }

    @Test("A record that exists but cannot be reached is an error, never \"no record\"")
    func recordFileUnreachable() throws {
        let tools = try FakeTools()
        let directory = tools.directory.appendingPathComponent("hidden", isDirectory: true)
        let store = FileOwnershipRecordStore(url: directory.appendingPathComponent("record.json"))
        try store.save(Data("owned".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: (any Error).self) {
            try store.load()
        }
        #expect(throws: (any Error).self) {
            try store.remove()
        }
        #expect(NativeChargeLimitBackend.hasOutstandingRecord(in: store))
    }

    @Test("A record file that cannot be written is an error, not a silent success")
    func recordFileUnwritable() throws {
        let tools = try FakeTools()
        let directory = tools.directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let store = FileOwnershipRecordStore(url: directory.appendingPathComponent("record.json"))
        #expect(throws: (any Error).self) {
            try store.save(Data("x".utf8))
        }
    }

    // MARK: - Adapter timeouts

    /// A runner of `executable` with `toolTimeout` for each command, unless
    /// the test gives its own.
    static func shortcuts(_ executable: URL, listTimeout: TimeInterval = toolTimeout, runTimeout: TimeInterval = toolTimeout) -> ShortcutsCommandRunner {
        var runner = ShortcutsCommandRunner(executable: executable)
        runner.listTimeout = listTimeout
        runner.runTimeout = runTimeout
        return runner
    }

    /// A reader of `executable` with `toolTimeout`, unless the test gives its
    /// own.
    static func pmset(_ executable: URL, timeout: TimeInterval = toolTimeout) -> PmsetChargeLimitReader {
        var reader = PmsetChargeLimitReader(executable: executable)
        reader.timeout = timeout
        return reader
    }

    @Test("Each adapter runs its tool under the timeout it was given, by default the production one")
    func adapterTimeouts() async throws {
        #expect(PmsetChargeLimitReader().timeout == PmsetChargeLimitReader.timeout)
        #expect(ShortcutsCommandRunner().listTimeout == ShortcutsCommandRunner.listTimeout)
        #expect(ShortcutsCommandRunner().runTimeout == ShortcutsCommandRunner.runTimeout)
        // The tool runs while the hold file exists, which it does until the
        // calls are over, checking every 0.1 s, and gives up by itself after
        // 1200 checks (at least 120 s). A tool exit the runner observes
        // before the call's deadline would end the call some other way than
        // timedOut, failing the test; with the hold, that takes a call that
        // sets its deadline roughly 120 s or more after starting the tool.
        // The watchdog cancels a call still running after 60 s. timedOut
        // names the timeout the call ran under, rounded up to whole seconds:
        // 1 s or 2 s here, where a production timeout would be 5, 10 or 20 s.
        // The list and the run get different timeouts, so a swap would show.
        let tools = try FakeTools()
        let hold = tools.path("hold")
        try Data().write(to: URL(fileURLWithPath: hold))
        defer { try? FileManager.default.removeItem(atPath: hold) }
        let executable = try tools.script("tool", "i=0; while [ -e '\(hold)' ] && [ $i -lt 1200 ]; do /bin/sleep 0.1; i=$((i + 1)); done")
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 1)) {
            try await Self.withWatchdog(.seconds(60)) {
                try await Self.pmset(executable, timeout: 0.2).readChargeLimit()
            }
        }
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 1)) {
            try await Self.withWatchdog(.seconds(60)) {
                try await Self.shortcuts(executable, listTimeout: 0.2, runTimeout: 1.2).shortcutNames()
            }
        }
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 2)) {
            try await Self.withWatchdog(.seconds(60)) {
                try await Self.shortcuts(executable, listTimeout: 0.2, runTimeout: 1.2).runShortcut(named: "Any", input: "80")
            }
        }
    }

    // MARK: - shortcuts

    @Test("Shortcut names are listed one per line")
    func listsShortcuts() async throws {
        let tools = try FakeTools()
        let executable = try tools.script("shortcuts", #"[ "$1" = list ] && printf 'CellKeeper Set Charge Limit\nMorning  Briefing \nOther\n'"#)
        let names = try await Self.shortcuts(executable).shortcutNames()
        #expect(names == ["CellKeeper Set Charge Limit", "Morning  Briefing ", "Other"])
    }

    @Test("A shortcut runs by name with its input in a text file, which is then removed")
    func runsWithInputFile() async throws {
        let tools = try FakeTools()
        let log = tools.path("log")
        let executable = try tools.script("shortcuts", """
        printf '%s|%s|%s|' "$1" "$2" "$3" > '\(log)'
        cat "$4" >> '\(log)'
        printf '|%s' "$4" >> '\(log)'
        """)
        try await Self.shortcuts(executable).runShortcut(named: "CellKeeper Set Charge Limit", input: "85")
        let parts = try String(contentsOfFile: log, encoding: .utf8).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(parts.prefix(4)) == ["run", "CellKeeper Set Charge Limit", "-i", "85"])
        #expect(parts.count == 5)
        #expect(parts.last?.hasSuffix(".txt") == true)
        #expect(!FileManager.default.fileExists(atPath: parts.last ?? ""))
    }

    @Test("An incomplete shortcut list is an error, not a shorter list")
    func incompleteShortcutList() async throws {
        let tools = try FakeTools()
        let executable = try tools.script("shortcuts", "head -c 300000 /dev/zero | tr '\\0' x")
        await #expect(throws: ShortcutsCommandError.failed(command: "list", message: "incomplete output")) {
            try await Self.shortcuts(executable).shortcutNames()
        }
    }

    @Test("A shortcut error is reported with the tool's message")
    func runFailure() async throws {
        let tools = try FakeTools()
        let executable = try tools.script("shortcuts", "echo 'Error: The operation couldn’t be completed. Couldn’t find shortcut' >&2; exit 1")
        await #expect(throws: ShortcutsCommandError.failed(command: "run", message: "Error: The operation couldn’t be completed. Couldn’t find shortcut")) {
            try await Self.shortcuts(executable).runShortcut(named: "Missing", input: "80")
        }
    }

    // MARK: - pmset

    @Test("pmset is only ever asked for the battlimit report, which is parsed")
    func readsBattlimit() async throws {
        let tools = try FakeTools()
        let log = tools.path("args")
        let report = ChargeLimitReportParserTests.report(85)
        let executable = try tools.script("pmset", "printf '%s ' \"$@\" > '\(log)'\ncat <<'EOF'\n\(report)EOF")
        let reading = try await Self.pmset(executable).readChargeLimit()
        #expect(reading == .limit(85))
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "-g battlimit ")
    }

    @Test("Incomplete pmset output is an error, never parsed")
    func pmsetIncompleteOutput() async throws {
        let tools = try FakeTools()
        let executable = try tools.script("pmset", "head -c 300000 /dev/zero | tr '\\0' x")
        await #expect(throws: PmsetChargeLimitError.failed("incomplete output")) {
            try await Self.pmset(executable).readChargeLimit()
        }
    }

    @Test("A failing pmset is an error, not a reading")
    func pmsetFailure() async throws {
        let tools = try FakeTools()
        let executable = try tools.script("pmset", "echo 'pmset: unknown option' >&2; exit 1")
        await #expect(throws: PmsetChargeLimitError.failed("pmset: unknown option")) {
            try await Self.pmset(executable).readChargeLimit()
        }
    }
}
