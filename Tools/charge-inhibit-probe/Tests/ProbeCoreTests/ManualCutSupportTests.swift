import Foundation
import ProbeCore
import Testing

@Suite("The manual adapter cut's command line, preconditions, verdict, report and sources (research note 11)")
struct ManualCutSupportTests {
    static let machine = Report.MachineInfo(model: "Mac16,1", osVersion: "27.0.1", osBuild: "26A434", firmware: "mBoot-20457.1.29")

    var ready: SystemState { AssertionGoldenTests.ready }

    // MARK: The command line

    @Test("check and watch take --mechanism manual-adapter-cut; run never does; --assertion is unchanged")
    func commandLine() throws {
        #expect(try Command.parse(["check", "--mechanism", "manual-adapter-cut"]) == .checkManualCut)
        #expect(try Command.parse(["check", "--mechanism=manual-adapter-cut"]) == .checkManualCut)
        #expect(try Command.parse(["watch", "--mechanism", "manual-adapter-cut"]) == .watchManualCut(hold: 180))
        #expect(try Command.parse(["watch", "--hold", "240", "--mechanism", "manual-adapter-cut"]) == .watchManualCut(hold: 240))
        #expect(try Command.parse(["check", "--mechanism", "assertion", "--assertion", "disable-inflow"]) == .check(assertion: .disableInflow))
        #expect(try Command.parse(["run", "--assertion", "charge-inhibit", "--mechanism", "assertion"]) == .run(assertion: .chargeInhibit, hold: 180))
        #expect(throws: Command.ParseError.runWithManualCut) { try Command.parse(["run", "--mechanism", "manual-adapter-cut"]) }
        #expect(throws: Command.ParseError.runWithManualCut) {
            try Command.parse(["run", "--mechanism", "manual-adapter-cut", "--assertion", "disable-inflow"])
        }
        #expect(throws: Command.ParseError.assertionWithManualCut) {
            try Command.parse(["check", "--mechanism", "manual-adapter-cut", "--assertion", "disable-inflow"])
        }
        #expect(throws: Command.ParseError.assertionWithManualCut) {
            try Command.parse(["watch", "--mechanism", "manual-adapter-cut", "--assertion", "disable-inflow"])
        }
        #expect(throws: Command.ParseError.watchNeedsManualCut) { try Command.parse(["watch"]) }
        #expect(throws: Command.ParseError.watchNeedsManualCut) { try Command.parse(["watch", "--mechanism", "assertion"]) }
        #expect(throws: Command.ParseError.invalidMechanism("smc-adapter-cut")) { try Command.parse(["check", "--mechanism", "smc-adapter-cut"]) }
        #expect(throws: Command.ParseError.invalidHold("164")) { try Command.parse(["watch", "--mechanism", "manual-adapter-cut", "--hold", "164"]) }
        #expect(throws: Command.ParseError.unexpectedArgument("--hold")) { try Command.parse(["check", "--mechanism", "manual-adapter-cut", "--hold", "180"]) }
        #expect(throws: Command.ParseError.unexpectedArgument("--mechanism")) {
            try Command.parse(["watch", "--mechanism", "manual-adapter-cut", "--mechanism", "manual-adapter-cut"])
        }
        #expect(throws: Command.ParseError.missingAssertion) { try Command.parse(["check", "--mechanism", "assertion"]) }
        #expect(Command.usage.contains("watch --mechanism manual-adapter-cut [--hold SECONDS]"))
        #expect(Command.usage.contains("WITHOUT sudo"))
        #expect(Command.usage.contains("reads no SMC key and runs no tool"))
        #expect(!Command.usage.contains("sudo charge-inhibit-probe watch"))
    }

    // MARK: Preconditions

    @Test("Ready for the manual cut: note 10's checks, and a warning that the probe reads no SMC key")
    func manualPreconditionsReady() {
        let checks = Preconditions.evaluateManualCut(ready)
        #expect(!checks.contains { $0.status == .fail })
        #expect(checks.filter { $0.status == .warn }.map(\.title) == ["Optimized Battery Charging off", "CHIE reads 00 (the owner's read)"])
        let chie = checks.first { $0.title == "CHIE reads 00 (the owner's read)" }
        #expect(chie?.detail.contains("the probe reads no SMC key") == true)
        #expect(chie?.detail.contains(ManualCut.ToolCommand.read) == true)
        // The disable-inflow checks apply too.
        let inflow = Preconditions.evaluate(ready, assertion: .disableInflow).map(\.title)
        #expect(Array(checks.map(\.title).prefix(inflow.count)) == inflow)
        let summary = Preconditions.manualCutSummary(checks)
        #expect(summary.hasPrefix("READY"))
        #expect(summary.contains("watch --mechanism manual-adapter-cut"))
        #expect(summary.contains("without sudo"))
    }

    @Test("An adapter not reported attached fails for the manual cut, and only warns for DisableInflow")
    func adapterAttachedFails() {
        var state = ready
        state.reading.rawExternalConnected = false
        state.reading.adapterAttached = false
        let manual = Preconditions.evaluateManualCut(state).first { $0.title == "Adapter reported attached" }
        #expect(manual?.status == .fail)
        #expect(manual?.detail.contains("note 11 §5") == true)
        let inflow = Preconditions.evaluate(state, assertion: .disableInflow).first { $0.title == "Adapter reported attached" }
        #expect(inflow?.status == .warn)
        #expect(Preconditions.manualCutSummary(Preconditions.evaluateManualCut(state)).hasPrefix("NOT READY"))
        // Either read is enough.
        state.reading.adapterAttached = true
        #expect(Preconditions.evaluateManualCut(state).first { $0.title == "Adapter reported attached" }?.status == .pass)
    }

    @Test("A charge below 40% and a native limit fail for the manual cut, as for DisableInflow")
    func chargeAndLimit() {
        var state = ready
        state.reading.percent = 39
        state.chargeLimit = .limits([80])
        let failures = Preconditions.evaluateManualCut(state).filter { $0.status == .fail }.map(\.title)
        #expect(failures.contains("Charge at least 40%"))
        #expect(failures.contains("macOS's Charge Limit is 100%"))
    }

    // MARK: Freshness at the cut, and the verdict's words

    /// Baseline readings every 2 s from 0 to 20 s, each its own update.
    static func baseline(through end: Double = 20) -> [Sample] {
        stride(from: 0.0, through: end, by: 2).map { Sample.Reading.charging.sample(at: $0, .baseline) }
    }

    static func preCut(from start: Double, through end: Double, _ reading: Sample.Reading = .charging) -> [Sample] {
        stride(from: start, through: end, by: 2).map { reading.sample(at: $0, .preCut) }
    }

    @Test("With no pre-cut readings, freshness at the cut is exactly the assertions' baseline freshness")
    func emptyPreCutIsUnchanged() {
        let baseline = Self.baseline()
        for at in [20.5, 23.9, 24.5, 40, 95] {
            let unix = Scenario.epoch + at
            #expect(Verdict.cutFreshnessProblem(baseline: baseline, preCut: [], at: at, unixTime: unix)
                == Verdict.baselineFreshnessProblem(baseline, at: at, unixTime: unix))
        }
        #expect(Verdict.cutFreshnessProblem(baseline: [], preCut: [], at: 1, unixTime: Scenario.epoch + 1)
            == "there was no baseline reading before the assertion")
    }

    @Test("A 30 s wait at the CUT prompt keeps the cut fresh, where the baseline alone would be stale")
    func preCutKeepsFresh() {
        let baseline = Self.baseline()
        let preCut = Self.preCut(from: 22, through: 50)
        let at = 51.0
        #expect(Verdict.baselineFreshnessProblem(baseline, at: at, unixTime: Scenario.epoch + at) != nil)
        #expect(Verdict.cutFreshnessProblem(baseline: baseline, preCut: preCut, at: at, unixTime: Scenario.epoch + at, terms: .manualCut) == nil)
    }

    @Test("Freshness at the cut fails on a pre-cut reading that is not charging, a gap, a stale mark or update, or a clock jump")
    func preCutFailures() throws {
        let baseline = Self.baseline()
        func problem(_ preCut: [Sample], at: Double, unix: Double? = nil) -> String? {
            Verdict.cutFreshnessProblem(baseline: baseline, preCut: preCut, at: at, unixTime: unix ?? Scenario.epoch + at, terms: .manualCut)
        }
        var stopped = Self.preCut(from: 22, through: 30)
        stopped[2] = Sample.Reading.stopped.sample(at: 26, .preCut)
        let notCharging = try #require(problem(stopped, at: 31))
        #expect(notCharging.contains("not charging steadily after the CUT prompt"))
        #expect(notCharging.contains("the probe printed NO GO"))

        let gap = Self.preCut(from: 22, through: 24) + Self.preCut(from: 30, through: 34)
        #expect(try #require(problem(gap, at: 35)).contains("gap of 6.0 s"))

        // The last reading more than 4 s before the mark.
        #expect(try #require(problem(Self.preCut(from: 22, through: 30), at: 35)).contains("gap of 5.0 s"))

        // No battery update for more than 70 s before the mark.
        var stale = Self.preCut(from: 22, through: 80)
        for index in stale.indices { stale[index].updateTime = Int(Scenario.epoch + 4) }
        var oldBaseline = baseline
        for index in oldBaseline.indices { oldBaseline[index].updateTime = min(oldBaseline[index].updateTime ?? 0, Int(Scenario.epoch + 4)) }
        let staleProblem = try #require(Verdict.cutFreshnessProblem(
            baseline: oldBaseline, preCut: stale, at: 81, unixTime: Scenario.epoch + 81, terms: .manualCut
        ))
        #expect(staleProblem.contains("latest battery update was 77.0 s old"))

        // The wall clock jumped at the mark.
        #expect(try #require(problem(Self.preCut(from: 22, through: 30), at: 31, unix: Scenario.epoch + 40)).contains("wall clock"))
    }

    @Test("Pre-cut readings never count toward the baseline: its 152 s limit holds after a long CUT prompt")
    func baselineLimitUnaffected() {
        let baseline = Self.baseline(through: 140)
        let preCut = Self.preCut(from: 142, through: 260)
        #expect(Verdict.baselineProblem(baseline, terms: .manualCutPrompt) == nil)
        #expect(Verdict.cutFreshnessProblem(baseline: baseline, preCut: preCut, at: 261, unixTime: Scenario.epoch + 261, terms: .manualCut) == nil)
        // Counted together they would break it.
        #expect(Verdict.baselineProblem(baseline + preCut.map { var sample = $0; sample.phase = .baseline; return sample }) != nil)
    }

    @Test("A manual run's reasons speak of the cut mark and the restore, never of an assertion")
    func manualWording() {
        var driver = FlowDriver()
        driver.held = { $0 < 100 ? .charging : .cut }
        driver.toAfter()
        driver.run(until: .ended, limit: 400)
        guard case let .inconclusive(reason) = driver.outcome.verdict else {
            Issue.record("expected inconclusive, got \(String(describing: driver.outcome.verdict))")
            return
        }
        #expect(reason.contains("after the owner's cut mark"))
        #expect(!reason.contains("assertion"))
        #expect(VerdictTerms.manualCut.release == "the restore")
        for terms in [VerdictTerms.manualCut, .manualCutPrompt] {
            let words = [terms.notCreated, terms.notReleased, terms.onSleep, terms.created, terms.held, terms.itsCreation,
                         terms.creation, terms.release, terms.baselineBefore, terms.toBeCreated, terms.aboutToBeCreated, terms.nothingCreated]
            #expect(!words.joined(separator: " ").contains("assertion"))
        }
        #expect(Verdict.baselineProblem(Array(Self.baseline().prefix(3)), terms: .manualCutPrompt)?.contains("before the CUT prompt") == true)
    }

    @Test("The manual explanation says the read-backs are owner-confirmed, for every verdict")
    func manualExplanation() {
        let verdicts: [Verdict] = [
            .adapterCut(cutAfter: 4, powerBackAfter: 6, resumedAfter: 6),
            .adapterCutResumedLate(cutAfter: 4, powerBackAfter: nil, resumedAfter: 130),
            .inhibited(stoppedAfter: 4, resumedAfter: 6),
            .inhibitedDidNotResume(stoppedAfter: 4, watchedFor: 300),
            .dischargingWithAdapter(dischargedAfter: 4, resumedAfter: 6),
            .dischargingDidNotResume(dischargedAfter: 4, powerBackAfter: nil, watchedFor: 300, looksLikeCut: true),
            .noEffect(heldFor: 180),
        ]
        for verdict in verdicts {
            let text = verdict.manualCutExplanation()
            #expect(text.contains("owner's read"), "\(verdict.title)")
            #expect(!text.contains("assertion"), "\(verdict.title)")
            #expect(!text.contains("powerd"), "\(verdict.title)")
        }
        #expect(Verdict.dischargingDidNotResume(dischargedAfter: 4, powerBackAfter: nil, watchedFor: 300, looksLikeCut: true)
            .manualCutExplanation().contains("§7.1"))
    }

    // MARK: The report

    func report(_ driver: FlowDriver, notices: [ProbeRun.SleepNotice] = []) -> String {
        ManualCutReport(
            startedAt: "2026-10-20 12:00:00 +11:00",
            machine: Self.machine,
            hold: driver.flow.hold,
            preconditionChecks: Preconditions.evaluateManualCut(ready),
            flow: driver.flow,
            sleepGuard: Report.SleepGuard(registered: true, created: (0, 0), released: (400, 0)),
            sleepNotices: notices,
            restoreBy: driver.flow.cutMark == nil ? nil : "12:03:30",
            outcome: ManualCutOutcome.of(driver.flow, sleepNotices: notices)
        ).render()
    }

    @Test("A completed run's report: owner-confirmed marks, the answers with times, the restore written, the verdict")
    func reportCompleted() {
        var driver = FlowDriver()
        driver.toAfter()
        driver.run(until: .ended, limit: 400)
        let text = report(driver)
        #expect(!text.contains("CHECK RECOVERY FIRST"))
        #expect(text.contains("owner-confirmed, not"))
        #expect(text.contains("this probe reads no SMC key, runs no tool"))
        #expect(text.contains("The owner's answers (owner-confirmed; the probe observed no read and no write)"))
        for word in ["start00", "cutnow", "cut08", "restorenow", "restored00"] {
            #expect(text.contains("typed \(word)"), "\(word)")
        }
        #expect(text.contains("restore written: By the owner's answers, the restore command was run once"))
        #expect(text.contains("GO line: restore by 12:03:30"))
        #expect(text.contains("pre-cut"))
        #expect(text.contains("Verdict: adapter cut"))
        #expect(text.contains("By the owner's reads, CHIE read back (bytes 08)"))
        #expect(!text.contains("pmset -g assertions listed"))
        #expect(!text.contains("IOPMAssertionCreateWithProperties (DisableInflow)"))
        #expect(text.hasSuffix("This report contains no serial numbers, user names or home paths.\n"))
    }

    @Test("A run that ended without a confirmed restore opens with CHECK RECOVERY FIRST and the read-first steps")
    func reportUnconfirmed() {
        var driver = FlowDriver()
        driver.toHold()
        driver.send(.signal(SIGINT, at: driver.now))
        let text = report(driver)
        let lines = text.split(separator: "\n").map(String.init)
        let recovery = lines.firstIndex(of: "CHECK RECOVERY FIRST")
        let preconditions = lines.firstIndex(of: "Preconditions")
        #expect(recovery != nil && preconditions != nil && recovery! < preconditions!)
        #expect(text.contains("The owner has not confirmed that CHIE was restored"))
        #expect(text.contains("Never write before this read"))
        #expect(text.contains("Verdict: inconclusive"))
    }

    @Test("The report never records text the owner typed that is not an answer word")
    func reportPrivacy() {
        var driver = FlowDriver()
        driver.toCutPrompt()
        driver.type("/Users/someone/Documents secret-name")
        driver.type("cutnow")
        driver.type("cutfail")
        driver.type("other")
        let text = report(driver)
        for secret in ["/Users", "someone", "secret-name", "Documents"] {
            #expect(!text.contains(secret), "\(secret) leaked into the report")
        }
        #expect(text.contains("(no answer word)"))
    }

    @Test("A refusal before any question: no answers, exit 1, the reason")
    func reportRefusal() {
        let text = ManualCutReport(
            startedAt: "2026-10-20 12:00:00 +11:00", machine: Self.machine, hold: 180,
            preconditionChecks: Preconditions.evaluateManualCut(ready),
            outcome: ManualCutOutcome(verdict: nil, exitStatus: 1, recoveryReason: nil, refusal: "IORegisterForSystemPower did not register the probe")
        ).render()
        #expect(text.contains("Refused to start: IORegisterForSystemPower did not register the probe"))
        #expect(!text.contains("CHECK RECOVERY FIRST"))
        #expect(!text.contains("The owner's answers"))
    }

    @Test("The report file name is covered by .gitignore's charge-inhibit-probe-*.txt")
    func reportFileName() {
        let name = ManualCut.reportFileName(stamp: "20261020-120000")
        #expect(name == "charge-inhibit-probe-manual-adapter-cut-20261020-120000.txt")
        #expect(name.hasPrefix("charge-inhibit-probe-") && name.hasSuffix(".txt"))
        #expect(ManualCut.idleSleepTimeout(hold: 180) == 120 + 150 + 120 + 180 + 180 + 120 + 1800)
    }

    // MARK: The sources

    /// The probe's source files, read from the package.
    static func source(_ path: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
    }

    static let sourceFiles = [
        "Sources/ProbeCore/Command.swift", "Sources/ProbeCore/EmergencyExit.swift", "Sources/ProbeCore/IOReturnName.swift",
        "Sources/ProbeCore/ManualCut.swift", "Sources/ProbeCore/ManualCutReport.swift", "Sources/ProbeCore/PmsetOutput.swift",
        "Sources/ProbeCore/Preconditions.swift", "Sources/ProbeCore/ProbeSchedule.swift", "Sources/ProbeCore/Report.swift",
        "Sources/ProbeCore/ReportFormat.swift", "Sources/ProbeCore/Sample.swift", "Sources/ProbeCore/SleepQueue.swift",
        "Sources/ProbeCore/SleepResponse.swift", "Sources/ProbeCore/Verdict.swift", "Sources/ProbeCore/VerdictTerms.swift",
        "Sources/charge-inhibit-probe/AssertionHolder.swift", "Sources/charge-inhibit-probe/CheckCommand.swift",
        "Sources/charge-inhibit-probe/Clock.swift", "Sources/charge-inhibit-probe/RunCommand.swift",
        "Sources/charge-inhibit-probe/SleepWatch.swift", "Sources/charge-inhibit-probe/SystemReads.swift",
        "Sources/charge-inhibit-probe/WatchCommand.swift", "Sources/charge-inhibit-probe/main.swift",
    ]

    /// The manual cut's own code paths.
    static let manualCutFiles = [
        "Sources/ProbeCore/ManualCut.swift", "Sources/ProbeCore/ManualCutReport.swift", "Sources/ProbeCore/VerdictTerms.swift",
        "Sources/charge-inhibit-probe/WatchCommand.swift", "Sources/charge-inhibit-probe/CheckCommand.swift",
    ]

    /// Code only: comments are dropped, so that the rules below can be
    /// explained in them.
    static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    @Test("Nothing in the probe touches the SMC: no AppleSMC matching, no user-client calls, no SMC structures")
    func noSMCCode() throws {
        let packageFiles = try FileManager.default.contentsOfDirectory(
            atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/ProbeCore").path
        )
        // Every source file is checked: a new one must be added to the list.
        for file in packageFiles where file.hasSuffix(".swift") {
            #expect(Self.sourceFiles.contains("Sources/ProbeCore/\(file)"), "\(file) is not in the list the tests check")
        }
        for path in Self.sourceFiles {
            let text = Self.code(try Self.source(path))
            for forbidden in ["AppleSMC", "IOServiceOpen", "IOConnectCall", "IOConnectMap", "SMCParamStruct", "SMCKeyData", "kSMC", "SMCVal"] {
                #expect(!text.contains(forbidden), "\(path) contains \(forbidden)")
            }
        }
    }

    @Test("The manual cut's code paths start no process: no Process, posix_spawn, system, popen, exec or new command")
    func manualCutStartsNoProcess() throws {
        for path in Self.manualCutFiles {
            let text = Self.code(try Self.source(path))
            for forbidden in ["Process(", "NSTask", "posix_spawn", "system(", "popen(", "execv", "execl", "fork(", "ReadOnlyCommand(", "NSWorkspace", "NSAppleScript", "osascript"] {
                #expect(!text.contains(forbidden), "\(path) contains \(forbidden)")
            }
        }
        // The probe's only commands stay the three fixed, read-only getters.
        let reads = Self.code(try Self.source("Sources/charge-inhibit-probe/SystemReads.swift"))
        #expect(reads.components(separatedBy: "ReadOnlyCommand(").count - 1 == 3)
        #expect(!reads.contains("smc"))
        // The tool's commands are written in one place only.
        for path in Self.sourceFiles where path != "Sources/ProbeCore/ManualCut.swift" {
            #expect(!(try Self.source(path)).contains("smc -k"), "\(path) spells out a tool command")
        }
    }
}
