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

    // MARK: - Process runner

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
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 1)) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)
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

    @Test("Ordinary output is complete")
    func completeOutput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf done"], timeout: 10)
        #expect(result.isOutputComplete)
    }

    @Test("A descendant holding the output open neither hides what was written nor delays the result")
    func descendantHoldsPipe() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf already_written; sleep 5 & exit 0"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.standardOutput == "already_written")
        #expect(!result.isOutputComplete)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("Cancelling the calling task stops the tool promptly")
    func cancellation() async {
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 30)
        }
        try? await Task.sleep(for: .milliseconds(200))
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(Date().timeIntervalSince(started) < 3)
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

    // MARK: - shortcuts

    @Test("Shortcut names are listed one per line")
    func listsShortcuts() async throws {
        let tools = try FakeTools()
        let executable = try tools.script("shortcuts", #"[ "$1" = list ] && printf 'CellKeeper Set Charge Limit\nMorning  Briefing \nOther\n'"#)
        let names = try await ShortcutsCommandRunner(executable: executable).shortcutNames()
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
        try await ShortcutsCommandRunner(executable: executable).runShortcut(named: "CellKeeper Set Charge Limit", input: "85")
        let parts = try String(contentsOfFile: log, encoding: .utf8).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(parts.prefix(4)) == ["run", "CellKeeper Set Charge Limit", "-i", "85"])
        #expect(parts.count == 5)
        #expect(parts.last?.hasSuffix(".txt") == true)
        #expect(!FileManager.default.fileExists(atPath: parts.last ?? ""))
    }

    @Test("A shortcut error is reported with the tool's message")
    func runFailure() async throws {
        let tools = try FakeTools()
        let executable = try tools.script("shortcuts", "echo 'Error: The operation couldn’t be completed. Couldn’t find shortcut' >&2; exit 1")
        await #expect(throws: ShortcutsCommandError.failed(command: "run", message: "Error: The operation couldn’t be completed. Couldn’t find shortcut")) {
            try await ShortcutsCommandRunner(executable: executable).runShortcut(named: "Missing", input: "80")
        }
    }

    // MARK: - pmset

    @Test("pmset is only ever asked for the battlimit report, which is parsed")
    func readsBattlimit() async throws {
        let tools = try FakeTools()
        let log = tools.path("args")
        let report = ChargeLimitReportParserTests.report(85)
        let executable = try tools.script("pmset", "printf '%s ' \"$@\" > '\(log)'\ncat <<'EOF'\n\(report)EOF")
        let reading = try await PmsetChargeLimitReader(executable: executable).readChargeLimit()
        #expect(reading == .limit(85))
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "-g battlimit ")
    }

    @Test("A failing pmset is an error, not a reading")
    func pmsetFailure() async throws {
        let tools = try FakeTools()
        let executable = try tools.script("pmset", "echo 'pmset: unknown option' >&2; exit 1")
        await #expect(throws: PmsetChargeLimitError.failed("pmset: unknown option")) {
            try await PmsetChargeLimitReader(executable: executable).readChargeLimit()
        }
    }
}
