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

    /// The timeout for a fake tool that finishes by itself, in an adapter
    /// test not about timeouts, instead of the production timeouts (5 s for
    /// pmset, 10 s and 20 s for shortcuts): a fake tool has taken longer than
    /// 5 s on a loaded machine.
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

    @Test("Exit status and both output streams are captured")
    func capturesOutput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf out; printf 'first\\nsecond' >&2; exit 3"], timeout: 10)
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

    @Test("A tool that ignores SIGTERM is killed after the grace period")
    func ignoresTerminate() async {
        // The tool marks that it ignores SIGTERM, and only then is it
        // stopped, so the stop provably meets a tool that ignores SIGTERM.
        // (A deadline could fire before a slow shell installs its trap.) A
        // cancellation and the deadline stop a tool the same way: SIGTERM,
        // then SIGKILL after the grace period.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeeper-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: marker.appendingPathExtension("tmp"))
        }
        let task = Task {
            // An ignored signal stays ignored across exec, so sleep ignores
            // SIGTERM; exec keeps the process ID the marker records.
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; echo $$ > \"$0.tmp\"; mv \"$0.tmp\" \"$0\"; exec /bin/sleep 30", marker.path], timeout: 600)
        }
        for _ in 0..<60_000 where !FileManager.default.fileExists(atPath: marker.path) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let recorded = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = recorded.flatMap({ pid_t($0) }), pid > 0 else {
            Issue.record("the tool did not record its process ID")
            task.cancel()
            return
        }
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let elapsed = Date().timeIntervalSince(started)
        // Not before the grace period: SIGTERM did not stop it.
        #expect(elapsed >= ProcessRunner.stopGracePeriod)
        #expect(elapsed < 20)
        // And it is gone: SIGKILL stopped it, not the runner giving up.
        // (Allow a moment for the exited process to be reaped.)
        var isGone = false
        for _ in 0..<5_000 {
            if kill(pid, 0) == -1, errno == ESRCH {
                isGone = true
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(isGone)
        if !isGone {
            kill(pid, SIGKILL)
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
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 600000 /dev/zero | tr '\\0' x"], timeout: 10)
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
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf done"], timeout: 10)
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

    @Test("Cancelling the calling task stops the tool promptly")
    func cancellation() async {
        // The tool marks that it runs, so the cancellation provably arrives
        // while it runs, not before it starts.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeeper-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "touch \"$0\"; exec /bin/sleep 30", marker.path], timeout: 30)
        }
        for _ in 0..<60_000 where !FileManager.default.fileExists(atPath: marker.path) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        // Well before the tool's own 30 s: the cancellation stopped it.
        #expect(Date().timeIntervalSince(started) < 20)
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
        // The tool lasts 30 s, longer than any timeout given here, so each
        // call ends in timedOut, naming the timeout it ran under rounded up
        // to whole seconds: 1 s or 2 s, where a production timeout would be
        // 5, 10 or 20 s. The list and the run get different timeouts, so a
        // swap would show.
        let tools = try FakeTools()
        let executable = try tools.script("tool", "exec /bin/sleep 30")
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 1)) {
            try await Self.pmset(executable, timeout: 0.2).readChargeLimit()
        }
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 1)) {
            try await Self.shortcuts(executable, listTimeout: 0.2, runTimeout: 1.2).shortcutNames()
        }
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 2)) {
            try await Self.shortcuts(executable, listTimeout: 0.2, runTimeout: 1.2).runShortcut(named: "Any", input: "80")
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
