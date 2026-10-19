import Foundation
import ProbeCore
import Testing

/// Records, in order, what the fakes for the release, the notice, the
/// acknowledgement, the emergency exit and the teardown steps were asked to
/// do.
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
            recordNotice: { calls.note("notice") },
            acknowledge: { calls.note("acknowledge") },
            // A fake that returns, unlike the probe's: nothing may follow it.
            emergencyExit: { line, status in calls.record(line, as: "emergency exit \(status)") }
        )
    }

    // MARK: The sleep notification

    @Test("A successful release: the notice in memory, then the acknowledgement; no I/O")
    func released() {
        let calls = Calls()
        #expect(willSleep(.released, calls) == .released)
        #expect(calls.log == ["release", "notice", "acknowledge"])
        #expect(calls.recorded.isEmpty)
    }

    @Test("With nothing held, the sleep is allowed the same way")
    func nothingHeld() {
        let calls = Calls()
        #expect(willSleep(.nothingHeld, calls) == .nothingHeld)
        #expect(calls.log == ["release", "notice", "acknowledge"])
        #expect(calls.recorded.isEmpty)
    }

    @Test("A failed release: the emergency exit with the recovery status, no acknowledgement, no claim of a release")
    func failedRelease() throws {
        let calls = Calls()
        let outcome = willSleep(.failed(result: Self.notFound, attempts: 3), calls)
        #expect(outcome == .failed(result: Self.notFound, attempts: 3))
        // Even though the fake exit returned, nothing else happened.
        #expect(calls.log == ["release", "emergency exit 3"])
        #expect(!calls.log.contains("acknowledge"))
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

    // MARK: Nothing on the sleep queue blocks (code reviews r4, r5)

    /// The probe's sleep handler with every step recorded, the emergency
    /// exit inside it as the probe composes it, and `writeReport` as its
    /// report writer.
    func handler(
        _ outcome: ReleaseOutcome,
        _ calls: Calls,
        writeReport: @escaping @Sendable (String) -> Void
    ) -> @Sendable (_ acknowledge: () -> Void) -> Void {
        SleepResponse.willSleepHandler(
            assertion: .disableInflow,
            release: {
                calls.note("release")
                return outcome
            },
            recordNotice: { calls.note("notice") },
            emergencyExit: { line, status in
                EmergencyExit.perform(line, status: status, steps: EmergencyExit.Steps(
                    armDeadline: { calls.note("deadline") },
                    writeReport: writeReport,
                    exit: { calls.note("exit \($0)") }
                ))
            }
        )
    }

    @Test("Run on the sleep queue, the handler releases and acknowledges, or exits; it writes nothing to the console")
    func handlerOnSleepQueue() {
        let sleepQueue = SleepQueue(label: "test.sleep")
        // A console that fails the test if it is called from the sleep queue.
        let console = ProbeConsole(sink: { _ in
            if SleepQueue.isCurrent { Issue.record("the console was written from the sleep queue") }
        })
        for (outcome, expected) in [
            (ReleaseOutcome.released, ["release", "notice", "acknowledge"]),
            (.nothingHeld, ["release", "notice", "acknowledge"]),
            (.failed(result: Self.notFound, attempts: 3), ["release", "deadline", "report", "exit 3"]),
        ] {
            let calls = Calls()
            let handle = handler(outcome, calls, writeReport: { calls.record($0, as: "report") })
            sleepQueue.queue.sync { handle { calls.note("acknowledge") } }
            #expect(calls.log == expected)
        }
        #expect(console.droppedOnSleepQueue == 0)
    }

    @Test("After a release, or with nothing held, the handler acknowledges without touching the report file")
    func successWithoutReport() {
        let sleepQueue = SleepQueue(label: "test.sleep")
        let unblock = DispatchSemaphore(value: 0)
        for outcome in [ReleaseOutcome.released, .nothingHeld] {
            let calls = Calls()
            let acknowledged = DispatchSemaphore(value: 0)
            // A report writer that fails the test and blocks if it is called.
            let handle = handler(outcome, calls, writeReport: { _ in
                Issue.record("the report file was written after a successful release")
                unblock.wait()
            })
            sleepQueue.queue.async {
                handle {
                    calls.note("acknowledge")
                    acknowledged.signal()
                }
            }
            #expect(acknowledged.wait(timeout: .now() + 2) == .success, "no acknowledgement within 2 s")
            #expect(calls.log == ["release", "notice", "acknowledge"])
        }
        for _ in 0..<4 { unblock.signal() }
        sleepQueue.drain()
    }

    @Test("After a failed release, the deadline is armed before a report write that blocks")
    func deadlineBeforeBlockedReport() {
        let sleepQueue = SleepQueue(label: "test.sleep")
        let calls = Calls()
        let writing = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        // A report writer that blocks, as on a disk that does not answer.
        let handle = handler(.failed(result: Self.notFound, attempts: 3), calls, writeReport: { line in
            calls.record(line, as: "report")
            writing.signal()
            unblock.wait()
        })
        let done = DispatchSemaphore(value: 0)
        sleepQueue.queue.async {
            handle { calls.note("acknowledge") }
            done.signal()
        }
        #expect(writing.wait(timeout: .now() + 2) == .success)
        // While the write blocks, the deadline is already armed: in the
        // probe, SIGALRM's default action would end the process in 2 s.
        #expect(calls.log == ["release", "deadline", "report"])
        unblock.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(calls.log == ["release", "deadline", "report", "exit 3"])
        #expect(calls.recorded.first?.contains("release attempted (3 tries) and failed") == true)
    }

    @Test("A console write from the sleep queue never reaches the console; one from elsewhere does")
    func consoleGuard() {
        let sleepQueue = SleepQueue(label: "test.sleep")
        let calls = Calls()
        let console = ProbeConsole(sink: { line in
            if SleepQueue.isCurrent { Issue.record("the console was written from the sleep queue") }
            calls.record(line, as: "console")
        })
        sleepQueue.queue.sync { console.write("from the sleep queue") }
        console.write("from elsewhere")
        #expect(calls.recorded == ["from elsewhere"])
        #expect(console.droppedOnSleepQueue == 1)
        #expect(!SleepQueue.isCurrent)
        #expect(sleepQueue.queue.sync { SleepQueue.isCurrent })
    }

    @Test("The teardown, which drains the sleep queue, completes while a console writer is blocked")
    func teardownWithBlockedConsole() {
        let sleepQueue = SleepQueue(label: "test.sleep")
        let release = DispatchSemaphore(value: 0)
        let blocked = DispatchSemaphore(value: 0)
        // A console writer that blocks until the test lets it go, as stderr
        // does on a full pipe.
        let console = ProbeConsole(sink: { _ in
            blocked.signal()
            release.wait()
        })
        DispatchQueue.global().async { console.write("the main thread's line") }
        #expect(blocked.wait(timeout: .now() + 2) == .success)

        let calls = Calls()
        let handle = handler(.released, calls, writeReport: { calls.record($0, as: "report") })
        sleepQueue.queue.async { handle { calls.note("acknowledge") } }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Teardown(
                releasePrivate: { .nothingHeld },
                releaseIdleSleep: {},
                deregisterSleep: { sleepQueue.drain() }
            ).finish()
            finished.signal()
        }
        let completed = finished.wait(timeout: .now() + 2) == .success
        // Let every blocked writer go, so that nothing is left waiting.
        for _ in 0..<4 { release.signal() }
        #expect(completed, "the teardown waited on the sleep queue while the console was blocked")
        #expect(calls.log == ["release", "notice", "acknowledge"])
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
            recordNotice: { calls.note("notice") },
            acknowledge: { calls.note("acknowledge") },
            emergencyExit: { line, status in calls.record(line, as: "emergency exit \(status)") }
        )
        teardown.finish()
        #expect(calls.log == ["private", "notice", "acknowledge", "private", "idle sleep", "deregister"])
    }
}
