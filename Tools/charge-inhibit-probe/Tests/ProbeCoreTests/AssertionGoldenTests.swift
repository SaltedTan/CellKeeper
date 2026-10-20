import Foundation
import ProbeCore
import Testing

/// The assertion probes' output (research notes 09–10), rendered for a
/// corpus of synthetic runs and compared, byte for byte, with what the
/// probe printed before research note 11's manual adapter cut was added
/// (`AssertionGolden.text`). The manual cut shares the verdict, the
/// preconditions and the report helpers; this proves it changed nothing
/// that the assertion probes print.
///
/// To regenerate the golden text after a deliberate change to the
/// assertion probes' wording, run the tests with
/// `PROBE_WRITE_ASSERTION_GOLDEN=/path/to/file` and paste the file into
/// `AssertionGolden.swift`.
@Suite("The assertion probes' output is unchanged")
struct AssertionGoldenTests {
    static let machine = Report.MachineInfo(model: "Mac16,1", osVersion: "27.0.1", osBuild: "26A434", firmware: "mBoot-20457.1.29")

    static var ready: SystemState {
        SystemState(
            reading: Sample.Reading.charging.sample(at: 0, .baseline),
            chargeLimit: .noLimit,
            aldenteHelperFiles: [],
            aldenteService: .notFound,
            aldenteProcesses: ProcessScan(matches: [], unreadable: 0),
            otherBatteryDaemons: [],
            assertions: AssertionListing()
        )
    }

    /// Named scenarios covering every verdict and most reasons a run is
    /// inconclusive.
    static var scenarios: [(String, Scenario)] {
        var list: [(String, Scenario)] = []
        func add(_ name: String, _ change: (inout Scenario) -> Void) {
            var scenario = Scenario()
            change(&scenario)
            list.append((name, scenario))
        }
        add("inhibited") { _ in }
        add("charge-inhibit inhibited") { $0.assertion = .chargeInhibit }
        add("inhibited, resumed late") { $0.after = { $0 < 140 ? .stopped : .charging } }
        add("inhibited, did not resume") { $0.after = { _ in .stopped } }
        add("adapter cut") {
            $0.held = { $0 < 4 ? .charging : .cut }
            $0.after = { $0 < 6 ? .cut : .charging }
        }
        add("adapter cut on AC") {
            $0.held = { $0 < 4 ? .charging : .cutOnAC }
            $0.after = { $0 < 6 ? .cutOnAC : .charging }
        }
        add("adapter cut, resumed late") {
            $0.held = { $0 < 4 ? .charging : .cut }
            $0.after = { $0 < 140 ? .cut : .charging }
        }
        add("discharging, did not resume") {
            $0.held = { $0 < 4 ? .charging : .cut }
            $0.after = { _ in .cut }
        }
        add("discharging with adapter attached") {
            $0.held = { $0 < 4 ? .charging : .weakAdapter }
            $0.after = { $0 < 6 ? .weakAdapter : .charging }
        }
        add("one high input") {
            $0.held = { $0 < 4 ? .charging : ($0 == 50 ? .weakAdapter : .cut) }
            $0.after = { $0 < 6 ? .cut : .charging }
        }
        add("unplugged while held") {
            $0.held = { $0 < 4 ? .charging : .unplugged }
            $0.after = { $0 < 6 ? .unplugged : .charging }
        }
        add("unplugged, never ends") {
            $0.held = { $0 < 4 ? .charging : .unplugged }
            $0.after = { _ in .unplugged }
        }
        add("flag-only cut") { $0.held = { $0 < 4 ? .charging : .flagOnlyCut } }
        add("cut ends while held") { $0.held = { $0 < 4 ? .charging : ($0 < 100 ? .cut : .charging) } }
        add("stop turns into discharge") { $0.held = { $0 < 4 ? .charging : ($0 < 100 ? .stopped : .cut) } }
        add("battery power after the release after a stop") { $0.after = { $0 < 6 ? .unplugged : .charging } }
        add("no effect") { $0.held = { _ in .charging } }
        add("refused") { $0.creationResult = Scenario.notPrivileged }
        add("once-a-minute updates") { $0.updateInterval = 60 }
        add("no effect, once a minute") {
            $0.held = { _ in .charging }
            $0.updateInterval = 60
        }
        add("stale update while held") { $0.updatesStopAt = 40 }
        add("baseline of one update") {
            $0.updateInterval = 60
            $0.updatePhase = 15
        }
        add("sleep notice") { $0.sleepNotices = [ProbeRun.SleepNotice(time: 60, message: "kIOMessageSystemWillSleep")] }
        add("failed release") {
            $0.releaseResult = Scenario.notFound
            $0.releaseAttempts = 3
        }
        add("still listed") { $0.stillListed = true }
        add("listing not checkable") { $0.stillListed = nil }
        add("baseline not charging") { $0.baseline = { _ in .stopped } }
        add("baseline too few readings") { $0.baselineTimes = [0, 2] }
        add("baseline gap") { $0.baselineTimes = [0, 2, 4, 12, 14, 16, 18, 20] }
        add("creation long after the baseline") { $0.creationTime = 40 }
        add("full while held") { $0.held = { $0 < 50 ? .charging : .full } }
        add("after readings end early") {
            $0.after = { _ in .stopped }
            $0.afterDuration = 60
        }
        add("effect later than 90 s") { $0.held = { $0 < 100 ? .charging : .stopped } }
        add("hold shorter than the window") { $0.hold = 60 }
        add("flag disagrees") { $0.held = { _ in .flagOnly } }
        add("unreadable while held") { $0.held = { $0 < 50 ? .charging : .unreadable } }
        add("gap after the release") {
            $0.afterReadings = [(2, .stopped), (4, .stopped), (30, .charging), (32, .charging), (34, .charging), (36, .charging), (38, .charging)]
        }
        add("resume of one reading") { $0.afterReadings = [(2, .stopped), (6, .charging)] }
        return list
    }

    /// Everything the assertion probes print for the corpus.
    static func corpus() -> String {
        var out: [String] = []
        for (name, scenario) in scenarios {
            let verdict = scenario.verdict
            out.append("## \(name)")
            out.append("title: \(verdict.title)")
            out.append("exit: \(verdict.exitStatus)")
            out.append("explanation: \(verdict.explanation(assertion: scenario.assertion))")
            let run = scenario.run
            let baseline = run.samples.filter { $0.phase == .baseline }
            out.append("baselineProblem: \(Verdict.baselineProblem(baseline) ?? "nil")")
            if let creation = run.creation {
                out.append("freshness: \(Verdict.baselineFreshnessProblem(baseline, at: creation.time, unixTime: creation.unixTime) ?? "nil")")
            }
        }
        for (name, scenario) in scenarios where ["inhibited", "adapter cut", "discharging, did not resume", "refused", "failed release", "listing not checkable", "sleep notice"].contains(name) {
            out.append("## report: \(name)")
            out.append(Report(
                assertion: scenario.assertion,
                startedAt: "2026-10-19 12:00:00 +11:00",
                machine: machine,
                hold: scenario.hold,
                preconditionChecks: Preconditions.evaluate(ready, assertion: scenario.assertion),
                run: scenario.run,
                sleepGuard: Report.SleepGuard(registered: true, created: (0, 0), released: (400, 0)),
                verdict: scenario.verdict,
                notes: ["A note."]
            ).render())
        }
        for kind in AssertionKind.allCases {
            out.append("## preconditions: \(kind.rawValue)")
            var states = [ready]
            var notReady = ready
            notReady.reading = Sample.Reading.stopped.sample(at: 0, .baseline)
            notReady.reading.adapterAttached = false
            notReady.reading.rawExternalConnected = nil
            notReady.reading.percent = 30
            notReady.chargeLimit = .limits([80])
            notReady.otherBatteryDaemons = ["batt-helper"]
            states.append(notReady)
            for state in states {
                let checks = Preconditions.evaluate(state, assertion: kind)
                out.append(contentsOf: checks.map(\.line))
                out.append(Preconditions.summary(checks, assertion: kind))
            }
            out.append("recovery: \(Verdict.recoverySteps(kind))")
            out.append("signal: \(ReleaseWording.signalLine("SIGINT", outcome: .released, assertion: kind))")
        }
        return out.joined(separator: "\n") + "\n"
    }

    @Test("Verdicts, explanations, preconditions and reports match the golden text")
    func unchanged() throws {
        let text = Self.corpus()
        if let path = ProcessInfo.processInfo.environment["PROBE_WRITE_ASSERTION_GOLDEN"] {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let golden = AssertionGolden.text
        if text != golden {
            let ours = text.split(separator: "\n", omittingEmptySubsequences: false)
            let theirs = golden.split(separator: "\n", omittingEmptySubsequences: false)
            let first = zip(ours, theirs).enumerated().first { $0.element.0 != $0.element.1 }
            Issue.record("""
                The assertion probes' output changed (\(ours.count) lines now, \(theirs.count) golden). \
                First difference at line \((first?.offset ?? min(ours.count, theirs.count)) + 1):
                now:    \(first.map { String($0.element.0) } ?? "(end)")
                golden: \(first.map { String($0.element.1) } ?? "(end)")
                """)
        }
    }
}
