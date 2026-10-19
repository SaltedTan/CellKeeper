import Foundation
import ProbeCore
import Testing

/// Records, in order, what the fakes for the release, the acknowledgement,
/// the record, the emergency exit and the teardown steps were asked to do.
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var lines: [String] = []

    var log: [String] { lock.withLock { entries } }
    var recorded: [String] { lock.withLock { lines } }

    func note(_ call: String) { lock.withLock { entries.append(call) } }

    func record(_ line: String, as call: String = "record") {
        lock.withLock {
            lines.append(line)
            entries.append(call)
        }
    }
}

@Suite("System sleep, the emergency exit and the teardown")
struct SleepResponseTests {
    static let notFound = Int32(bitPattern: 0xE000_02F0)

    func willSleep(_ outcome: ReleaseOutcome, _ calls: Calls) -> ReleaseOutcome {
        SleepResponse.willSleep(
            assertion: .disableInflow,
            release: {
                calls.note("release")
                return outcome
            },
            writeReport: { calls.record($0, as: "report") },
            acknowledge: { calls.note("acknowledge") },
            console: { calls.record($0, as: "console") },
            // A fake that returns, unlike the probe's: nothing may follow it.
            emergencyExit: { line, status in calls.record(line, as: "emergency exit \(status)") }
        )
    }

    // MARK: The sleep notification

    @Test("A successful release: the report line, then the acknowledgement, and only then the console")
    func released() {
        let calls = Calls()
        #expect(willSleep(.released, calls) == .released)
        #expect(calls.log == ["release", "report", "acknowledge", "console"])
        #expect(calls.recorded.count == 2)
        #expect(calls.recorded.allSatisfy { $0.contains("released the DisableInflow assertion, then allowed the sleep") })
    }

    @Test("With nothing held, the sleep is allowed, the console still after the acknowledgement")
    func nothingHeld() {
        let calls = Calls()
        #expect(willSleep(.nothingHeld, calls) == .nothingHeld)
        #expect(calls.log == ["release", "report", "acknowledge", "console"])
        #expect(calls.recorded.first?.contains("no DisableInflow assertion was held") == true)
    }

    @Test("A failed release: the emergency exit with the recovery status, no acknowledgement, no console, no claim of a release")
    func failedRelease() throws {
        let calls = Calls()
        let outcome = willSleep(.failed(result: Self.notFound, attempts: 3), calls)
        #expect(outcome == .failed(result: Self.notFound, attempts: 3))
        // Even though the fake exit returned, nothing else happened.
        #expect(calls.log == ["release", "emergency exit 3"])
        #expect(!calls.log.contains("acknowledge"))
        #expect(!calls.log.contains("console"))
        #expect(SleepResponse.failedReleaseExitStatus == 3)
        let line = try #require(calls.recorded.first)
        #expect(calls.recorded.count == 1)
        #expect(!line.contains("released"))
        #expect(line.contains("release attempted (3 tries) and failed (0xe00002f0 (kIOReturnNotFound))"))
        #expect(line.contains("powerd releases it at its timeout or when the probe exits"))
        #expect(line.contains("does not allow the sleep and exits now"))
        #expect(line.contains("pmset -g assertions"))
        #expect(line.contains("docs/research/10-disable-inflow-probe.md §7"))
    }

    // MARK: The emergency exit (code reviews r2, r3)

    @Test("The emergency exit arms the deadline first, then writes the report line, then exits; nothing goes to the console")
    func emergencyOrder() {
        let calls = Calls()
        EmergencyExit.perform("the line", status: 3, steps: EmergencyExit.Steps(
            armDeadline: { calls.note("deadline") },
            writeReport: { calls.record($0, as: "report") },
            exit: { calls.note("exit \($0)") }
        ))
        #expect(calls.log == ["deadline", "report", "exit 3"])
        #expect(calls.recorded == ["the line"])
        #expect(EmergencyExit.deadline == 2)
    }

    @Test("The whole failed-release path writes nothing to the console, and the success path nothing before the acknowledgement")
    func consoleOrder() {
        // The probe's composition: the emergency exit inside the sleep
        // response, with every step recorded.
        func run(_ outcome: ReleaseOutcome) -> [String] {
            let calls = Calls()
            SleepResponse.willSleep(
                assertion: .disableInflow,
                release: {
                    calls.note("release")
                    return outcome
                },
                writeReport: { calls.record($0, as: "report") },
                acknowledge: { calls.note("acknowledge") },
                console: { calls.record($0, as: "console") },
                emergencyExit: { line, status in
                    EmergencyExit.perform(line, status: status, steps: EmergencyExit.Steps(
                        armDeadline: { calls.note("deadline") },
                        writeReport: { calls.record($0, as: "report") },
                        exit: { calls.note("exit \($0)") }
                    ))
                }
            )
            return calls.log
        }
        let failed = run(.failed(result: Self.notFound, attempts: 3))
        #expect(failed == ["release", "deadline", "report", "exit 3"])
        #expect(!failed.contains("console"))
        for outcome in [ReleaseOutcome.released, .nothingHeld] {
            let log = run(outcome)
            let acknowledged = log.firstIndex(of: "acknowledge")
            let console = log.firstIndex(of: "console")
            #expect(acknowledged != nil && console != nil)
            if let acknowledged, let console {
                #expect(acknowledged < console)
            }
            #expect(log.firstIndex(of: "report").map { $0 < (acknowledged ?? 0) } == true)
        }
    }

    @Test("The report line is appended to the report file")
    func reportLine() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("charge-inhibit-probe-emergency-\(UUID().uuidString).txt").path
        #expect(FileManager.default.createFile(atPath: path, contents: Data("placeholder\n".utf8)))
        let report = open(path, O_WRONLY | O_APPEND)
        defer {
            close(report)
            unlink(path)
        }
        #expect(EmergencyExit.writeReport("release attempted (3 tries) and failed", to: report) > 0)
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.hasPrefix("placeholder\n"))
        #expect(contents.contains("\nrelease attempted (3 tries) and failed\n"))
    }

    @Test("A report file that could not be opened does not stop the emergency exit")
    func noReportDescriptor() {
        #expect(EmergencyExit.writeReport("line", to: -1) == -1)
        let calls = Calls()
        EmergencyExit.perform("the line", status: 3, steps: EmergencyExit.Steps(
            armDeadline: { calls.note("deadline") },
            writeReport: { _ = EmergencyExit.writeReport($0, to: -1) },
            exit: { calls.note("exit \($0)") }
        ))
        #expect(calls.log == ["deadline", "exit 3"])
    }

    // MARK: "Released" only when confirmed (code review r2)

    @Test("After SIGINT with a failed release, the console line claims no release")
    func signalWithFailedRelease() {
        let failed = ReleaseWording.signalLine("SIGINT", outcome: .failed(result: Self.notFound, attempts: 3), assertion: .disableInflow)
        #expect(!failed.contains("released"))
        #expect(failed.contains("release attempted (3 tries) and failed"))
        #expect(failed.contains("powerd releases it at its timeout or when the probe exits"))
        #expect(ReleaseWording.signalLine("SIGINT", outcome: .released, assertion: .disableInflow).contains("released its DisableInflow assertion"))
        #expect(!ReleaseWording.signalLine("SIGINT", outcome: .nothingHeld, assertion: .disableInflow).contains("released"))
    }

    @Test("The report's stop note says released only when the release is confirmed")
    func stopNote() {
        func note(result: Int32, attempts: Int = 1, listed: Bool?, held: Bool = false) -> String {
            ReleaseWording.stopNote(
                "SIGINT", at: 90,
                release: ProbeRun.Release(time: 80, unixTime: Scenario.epoch + 80, result: result, attempts: attempts, stillListed: listed),
                stillHeld: held, assertion: .disableInflow
            )
        }
        let confirmed = note(result: 0, listed: false)
        #expect(confirmed.contains("released its DisableInflow assertion, and pmset -g assertions no longer listed it"))
        for unconfirmed in [
            note(result: Self.notFound, attempts: 3, listed: nil, held: true),
            note(result: 0, listed: true),
            note(result: 0, listed: nil),
        ] {
            #expect(!unconfirmed.contains("released"), "\(unconfirmed)")
            #expect(unconfirmed.contains("powerd releases"))
            #expect(unconfirmed.contains("Follow the recovery steps"))
        }
        #expect(note(result: Self.notFound, attempts: 3, listed: nil, held: true).contains("release attempted (3 tries) and failed"))
        let neverHeld = ReleaseWording.stopNote("SIGINT", at: 5, release: nil, stillHeld: false, assertion: .disableInflow)
        #expect(neverHeld == "Stopped by SIGINT at +5.0 s; no DisableInflow assertion was held.")
        let heldNoRecord = ReleaseWording.stopNote("SIGINT", at: 5, release: nil, stillHeld: true, assertion: .disableInflow)
        #expect(!heldNoRecord.contains("released"))
    }

    @Test("A failed release at the normal end: the report claims no release and opens with the recovery steps")
    func normalEndFailedRelease() {
        var scenario = Scenario()
        scenario.releaseResult = Self.notFound
        scenario.releaseAttempts = 3
        for stopped in [false, true] {
            let run = scenario.run
            let report = Report(
                assertion: .disableInflow, startedAt: "2026-10-20 10:00:00 +11:00",
                machine: .init(model: "Mac16,1", osVersion: "27.0.1", osBuild: "26A434", firmware: "mBoot-20457.1.29"),
                hold: 180, preconditionChecks: [], run: run, verdict: Verdict.evaluate(run),
                notes: stopped ? [ReleaseWording.stopNote("SIGINT", at: 300, release: run.release, stillHeld: true, assertion: .disableInflow)] : []
            )
            let text = report.render()
            #expect(!text.contains("released"))
            #expect(text.contains("CHECK RECOVERY FIRST"))
            #expect(text.contains("release attempted (3 tries) and failed"))
            #expect(report.needsRecovery())
        }
    }

    @Test("A release pmset still listed, or could not check, opens the report with the recovery steps")
    func unconfirmedReleaseRecovery() {
        for listed: Bool? in [true, nil] {
            var scenario = Scenario()
            scenario.stillListed = listed
            let run = scenario.run
            let report = Report(
                assertion: .disableInflow, startedAt: "2026-10-20 10:00:00 +11:00",
                machine: .init(model: "Mac16,1", osVersion: "27.0.1", osBuild: "26A434", firmware: "mBoot-20457.1.29"),
                hold: 180, preconditionChecks: [], run: run, verdict: Verdict.evaluate(run)
            )
            #expect(report.needsRecovery())
            let text = report.render()
            #expect(text.contains("CHECK RECOVERY FIRST"))
            #expect(text.contains("The release of the DisableInflow assertion is not confirmed"))
            #expect(!text.contains("released"))
        }
        // Confirmed, and charging at the end: no recovery block.
        let confirmed = Scenario().run
        #expect(!Report(
            assertion: .disableInflow, startedAt: "", machine: .init(model: "", osVersion: "", osBuild: "", firmware: ""),
            hold: 180, preconditionChecks: [], run: confirmed
        ).needsRecovery())
    }

    @Test("A sleep notice no longer claims a release in the verdict")
    func sleepNoticeWording() {
        var scenario = Scenario()
        scenario.sleepNotices = [.init(time: 90, message: "kIOMessageSystemWillSleep")]
        #expect(scenario.inconclusiveReason?.contains("released") == false)
        // A failed release is reported as such, before the sleep notice.
        scenario.releaseResult = Self.notFound
        #expect(scenario.inconclusiveReason?.contains("0xe00002f0") == true)
    }

    // MARK: The teardown

    func teardown(_ calls: Calls) -> Teardown {
        Teardown(
            releasePrivate: {
                calls.note("private")
                return .released
            },
            releaseIdleSleep: { calls.note("idle sleep") },
            deregisterSleep: { calls.note("deregister") }
        )
    }

    @Test("The normal end tears down the private assertion, then the idle-sleep assertion, then the sleep notifications")
    func normalTeardown() {
        let calls = Calls()
        teardown(calls).finish()
        #expect(calls.log == ["private", "idle sleep", "deregister"])
    }

    @Test("A stop signal releases the private assertion at once; the rest follows in order when the run finishes")
    func signalTeardown() {
        let calls = Calls()
        let teardown = teardown(calls)
        #expect(teardown.stop() == .released)
        #expect(calls.log == ["private"])
        teardown.finish()
        #expect(calls.log == ["private", "private", "idle sleep", "deregister"])
    }

    @Test("A sleep notice goes through the same first step")
    func sleepTeardown() {
        let calls = Calls()
        let teardown = teardown(calls)
        SleepResponse.willSleep(
            assertion: .disableInflow,
            release: { teardown.stop() },
            writeReport: { calls.record($0, as: "report") },
            acknowledge: { calls.note("acknowledge") },
            console: { calls.record($0, as: "console") },
            emergencyExit: { line, status in calls.record(line, as: "emergency exit \(status)") }
        )
        teardown.finish()
        #expect(calls.log == ["private", "report", "acknowledge", "console", "private", "idle sleep", "deregister"])
    }
}
