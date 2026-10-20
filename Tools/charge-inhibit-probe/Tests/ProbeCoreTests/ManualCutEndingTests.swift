import Foundation
import ProbeCore
import Testing

/// What happened, in order, from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func add(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var values: [String] {
        lock.withLock { events }
    }

    func index(of event: String) -> Int? {
        values.firstIndex(of: event)
    }
}

extension ManualCutTests {
    @Suite("watch's endings: one watchdog armed first, one save, bounded waits (code review r3 of #101)")
    struct ManualCutEndingTests {
        static func temporaryPath() -> String {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("charge-inhibit-probe-manual-adapter-cut-\(UUID().uuidString).txt").path
        }

        /// A report file whose first write stops after 8 bytes and waits for
        /// `gate`, signalling `paused`; later writes go through. Each write
        /// is logged.
        static func pausingFile(path: String, paused: DispatchSemaphore, gate: DispatchSemaphore, events: EventLog) -> ReportFile? {
            let first = Counter()
            let hooks = ReportFile.Hooks { descriptor, bytes, offset in
                events.add("write")
                first.add()
                guard first.value == 1 else { return pwrite(descriptor, bytes.baseAddress, bytes.count, offset) }
                let written = pwrite(descriptor, bytes.baseAddress, min(8, bytes.count), offset)
                paused.signal()
                gate.wait()
                return written
            }
            return ReportFile(path: path, placeholder: "placeholder\n", hooks: hooks)
        }

        /// A watchdog that logs each arm instead of arming an alarm; with
        /// `pauseFirstArm`, the first arm waits for it, as an ending paused
        /// just before its alarm is armed.
        static func watchdog(_ events: EventLog, pauseFirstArm: DispatchSemaphore? = nil, paused: DispatchSemaphore? = nil) -> EndingWatchdog {
            let arms = Counter()
            return EndingWatchdog(hooks: EndingWatchdog.Hooks { seconds in
                arms.add()
                if arms.value == 1, let pauseFirstArm {
                    paused?.signal()
                    pauseFirstArm.wait()
                }
                events.add("arm \(seconds)")
            })
        }

        /// `watch`'s ending for `driver`'s session, saving to `file`. Each
        /// part logs when it runs; each report is numbered by its render,
        /// unless `report` renders it.
        static func ending(
            _ driver: SessionDriver,
            file: ReportFile,
            events: EventLog,
            watchdog: EndingWatchdog,
            sleepDrainBound: Double = EndingWatchdog.sleepDrainBound,
            stopSleepNotifications: @escaping @Sendable () -> Void = {},
            sleepNotices: @escaping @Sendable () -> [ProbeRun.SleepNotice] = { [] },
            report: (@Sendable (_ outcome: ManualCutOutcome, _ flow: ManualCutFlow?, _ sleepNotices: [ProbeRun.SleepNotice]?) -> String)? = nil
        ) -> ManualCutEnding {
            let renders = Counter()
            return ManualCutEnding(session: driver.session, watchdog: watchdog, sleepDrainBound: sleepDrainBound, parts: ManualCutEnding.Parts(
                stopSleepNotifications: {
                    events.add("drain")
                    stopSleepNotifications()
                },
                sleepNotices: {
                    events.add("notices")
                    return sleepNotices()
                },
                render: { outcome, flow, notices in
                    renders.add()
                    events.add("render")
                    if let report { return report(outcome, flow, notices) }
                    return "report \(renders.value): exit \(outcome.exitStatus)\n"
                        + String(repeating: "a line of the report\n", count: 40)
                },
                persist: { report in
                    events.add("persist")
                    return file.persist(report)
                },
                savedLine: { "saved: \($0)" }
            ))
        }

        /// A session stopped by a signal in the hold: the run ends with 3.
        static func stoppedInTheHold() -> SessionDriver {
            let driver = SessionDriver(console: ConsoleWriter { _ in true })
            driver.toHold()
            #expect(driver.session.signal(SIGINT) == .handled)
            #expect(driver.session.isEnded)
            driver.session.stopReminder()
            return driver
        }

        @Test("The watchdog's bound covers the ending's bounded steps")
        func watchdogBound() {
            // The sleep queue's drain, the console's before the outcome and
            // after the save, and the save.
            let steps = EndingWatchdog.sleepDrainBound + 2 * BoundedEnd.drainBound + EndingWatchdog.saveBound
            #expect(Double(EndingWatchdog.bound) >= steps + EndingWatchdog.margin)
            #expect(EndingWatchdog.saveBound == Double(EmergencyExit.deadline))
        }

        @Test("Every ending path arms the watchdog first: before the teardown, the sleep queue's drain and the save (must 1)")
        func watchdogArmedFirst() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
            let main = EventLog()
            let mainEnd = Self.ending(Self.stoppedInTheHold(), file: file, events: main, watchdog: Self.watchdog(main))
                .endMainPath(tearDown: { main.add("tearDown") })
            #expect(mainEnd.status == 3 && mainEnd.drained)
            #expect(main.values == ["arm \(EndingWatchdog.bound)", "tearDown", "drain", "notices", "render", "persist"])

            let second = EventLog()
            let exited = Counter()
            Self.ending(Self.stoppedInTheHold(), file: file, events: second, watchdog: Self.watchdog(second))
                .endAtSecondSignal(SIGINT) { status in
                    second.add("exit \(status)")
                    exited.add()
                }
            #expect(exited.value == 1)
            #expect(second.values == ["arm \(EndingWatchdog.bound)", "drain", "notices", "render", "persist", "exit 3"])
        }

        @Test("Review r3's case: while the first save is paused, a competing ending waits past the old 2.5 s and exits only after the save completes (must 1)")
        func competingEndingWaitsForTheSave() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let events = EventLog()
            let paused = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let file = try #require(Self.pausingFile(path: path, paused: paused, gate: gate, events: events))
            let ending = Self.ending(Self.stoppedInTheHold(), file: file, events: events, watchdog: Self.watchdog(events))
            // The main path's end: its save's first write pauses after 8 bytes.
            let mainEnded = Counter()
            Thread {
                _ = ending.endMainPath(tearDown: {})
                mainEnded.add()
            }.start()
            #expect(paused.wait(timeout: .now() + 2) == .success)
            // A second signal's end, on its own thread.
            let released = Counter()
            let exited = Counter()
            let exitedAfterRelease = Counter()
            Thread {
                ending.endAtSecondSignal(SIGINT) { _ in
                    if released.value > 0 { exitedAfterRelease.add() }
                    exited.add()
                }
            }.start()
            // Longer than the 2.5 s a waiter used to give the save: it has
            // not exited, and the save is not complete.
            Thread.sleep(forTimeInterval: 3)
            #expect(exited.value == 0)
            #expect(!ending.isSettled)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "report 1")
            released.add()
            gate.signal()
            #expect(eventually { exited.value == 1 && mainEnded.value == 1 })
            #expect(exitedAfterRelease.value == 1)
            // The first save, complete; the second ending never saved.
            let saved = try String(contentsOfFile: path, encoding: .utf8)
            #expect(saved.hasPrefix("report 1: exit 3\n"))
            #expect(saved.hasSuffix("a line of the report\n"))
            #expect(events.values.filter { $0 == "persist" }.count == 1)
            // The watchdog was armed before the save began, and only once:
            // the second ending's arm did not move the deadline.
            let armed = try #require(events.index(of: "arm \(EndingWatchdog.bound)"))
            let persisted = try #require(events.index(of: "persist"))
            #expect(armed < persisted)
            #expect(events.values.filter { $0.hasPrefix("arm") }.count == 1)
        }

        @Test("The first arm wins: later arms, from any path or thread, never move the deadline")
        func firstArmWins() {
            let events = EventLog()
            let watchdog = Self.watchdog(events)
            #expect(!watchdog.isArmed)
            watchdog.arm()
            #expect(watchdog.isArmed)
            let returned = Counter()
            for _ in 0..<8 {
                Thread {
                    watchdog.arm()
                    returned.add()
                }.start()
            }
            #expect(eventually { returned.value == 8 })
            watchdog.arm()
            #expect(events.values == ["arm \(EndingWatchdog.bound)"])
        }

        @Test("An ending paused just before its watchdog is armed: the other ending's arm waits for it, claims nothing and never exits on the placeholder; then one save, and both exit (must 1)")
        func pausedBeforeArmingClaimsNothing() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let events = EventLog()
            let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
            let pausedInArm = DispatchSemaphore(value: 0)
            let resumeArm = DispatchSemaphore(value: 0)
            let ending = Self.ending(
                Self.stoppedInTheHold(), file: file, events: events,
                watchdog: Self.watchdog(events, pauseFirstArm: resumeArm, paused: pausedInArm)
            )
            // The main path's end pauses inside its arm.
            let mainEnded = Counter()
            Thread {
                _ = ending.endMainPath(tearDown: {})
                mainEnded.add()
            }.start()
            #expect(pausedInArm.wait(timeout: .now() + 2) == .success)
            // A second signal's end: its arm waits for the first to set the
            // deadline, so it neither claims the save nor exits.
            let exited = Counter()
            let savedAtExit = EventLog()
            Thread {
                ending.endAtSecondSignal(SIGINT) { _ in
                    savedAtExit.add((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                    exited.add()
                }
            }.start()
            Thread.sleep(forTimeInterval: 0.5)
            #expect(exited.value == 0)
            #expect(!events.values.contains("persist"))
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "placeholder\n")
            // The first arm sets the deadline: one save, and both exit.
            resumeArm.signal()
            #expect(eventually { exited.value == 1 && mainEnded.value == 1 })
            let saved = try #require(savedAtExit.values.first)
            #expect(saved.hasPrefix("report "))
            #expect(saved.contains(": exit 3\n"))
            #expect(saved.hasSuffix("a line of the report\n"))
            #expect(events.values.filter { $0 == "persist" }.count == 1)
            #expect(events.values.filter { $0.hasPrefix("arm") }.count == 1)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == saved)
        }

        /// A run whose restore was confirmed and whose last reading charges,
        /// stopped by a signal in the after readings: without a sleep, it
        /// ends with 2.
        static func stoppedAfterAConfirmedRestore(console: ConsoleWriter = ConsoleWriter { _ in true }) -> SessionDriver {
            let driver = SessionDriver(console: console)
            let mark = ManualCutTests.ManualCutSessionTests.atRestoreReadBack(driver)
            driver.type("restored00", at: mark + 190)
            driver.read(.charging, at: mark + 191)
            #expect(driver.session.signal(SIGINT) == .handled)
            #expect(ManualCutOutcome.of(driver.session.snapshot, sleepNotices: []).exitStatus == 2)
            driver.session.stopReminder()
            return driver
        }

        /// The report as `watch` renders it.
        static func realReport(_ outcome: ManualCutOutcome, _ flow: ManualCutFlow?, _ notices: [ProbeRun.SleepNotice]?) -> String {
            ManualCutReport(
                startedAt: "2026-10-20 12:00:00 +11:00", machine: ManualCutTests.ManualCutSupportTests.machine, hold: 180,
                preconditionChecks: [], flow: flow, sleepNotices: notices, outcome: outcome
            ).render()
        }

        @Test(
            "Review r3's case: the sleep watch's lock is held forever and the drain times out; each ending never reads the notices, saves the report from the sleep log and exits (must 2)",
            arguments: ["main path", "second signal"]
        )
        func lockHeldAfterTheDrainTimesOut(path endingPath: String) throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
            let events = EventLog()
            // The sleep watch's lock, held by a teardown or an acknowledgement
            // that never finishes: the drain and the notices both need it.
            let held = DispatchSemaphore(value: 0)
            defer { held.signal() }
            let ending = Self.ending(
                Self.stoppedAfterAConfirmedRestore(), file: file, events: events, watchdog: Self.watchdog(events),
                sleepDrainBound: 0.3,
                stopSleepNotifications: {
                    held.wait()
                    held.signal()
                },
                sleepNotices: {
                    held.wait()
                    held.signal()
                    return []
                },
                report: Self.realReport
            )
            let statuses = EventLog()
            let ended = Counter()
            let start = Date()
            Thread {
                if endingPath == "main path" {
                    statuses.add("\(ending.endMainPath(tearDown: {}).status)")
                } else {
                    ending.endAtSecondSignal(SIGINT) { statuses.add("\($0)") }
                }
                ended.add()
            }.start()
            #expect(eventually(timeout: 3) { ended.value == 1 }, "the ending blocked on the sleep watch's lock")
            #expect(Date().timeIntervalSince(start) < 3)
            #expect(!events.values.contains("notices"))
            #expect(statuses.values == ["3"])
            let report = try String(contentsOfFile: path, encoding: .utf8)
            #expect(report.contains("sleep notices unavailable: the drain timed out"))
            #expect(report.contains("CHECK RECOVERY FIRST"))
            #expect(report.contains("could not be drained"))
        }

        @Test("After a drain that completed, the notices are read and reported; the report says nothing is unavailable")
        func noticesAfterACompletedDrain() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
            let events = EventLog()
            let notice = ProbeRun.SleepNotice(time: 400, message: "kIOMessageCanSystemSleep")
            let end = Self.ending(
                Self.stoppedAfterAConfirmedRestore(), file: file, events: events, watchdog: Self.watchdog(events),
                sleepNotices: { [notice] }, report: Self.realReport
            ).endMainPath(tearDown: {})
            #expect(end.status == 2)
            #expect(events.values.filter { $0 == "notices" }.count == 1)
            let report = try String(contentsOfFile: path, encoding: .utf8)
            #expect(report.contains("+400.0 s: the system sent kIOMessageCanSystemSleep"))
            #expect(!report.contains("unavailable"))
        }

        @Test("The sleep queue's drain runs once: a later call waits only until the first call's deadline, then returns at once")
        func drainRunsOnceWithOneDeadline() {
            let runs = Counter()
            let gate = DispatchSemaphore(value: 0)
            let once = BoundedOnce(within: 0.6) {
                runs.add()
                gate.wait()
            }
            let start = Date()
            let first = Counter()
            Thread {
                if !once.run() { first.add() }
            }.start()
            Thread.sleep(forTimeInterval: 0.3)
            #expect(!once.run())
            let second = Date().timeIntervalSince(start)
            #expect(second >= 0.55 && second < 0.85, "waited until \(second) s, not the first call's deadline")
            let later = Date()
            #expect(!once.run())
            #expect(Date().timeIntervalSince(later) < 0.1)
            #expect(eventually { first.value == 1 })
            #expect(runs.value == 1)
            gate.signal()
            #expect(eventually { once.run() })
            #expect(runs.value == 1)
        }

        @Test("A drain returns only once each message's result has been delivered, superseded or written (should 3)")
        func drainWaitsForResults() {
            let console = ConsoleWriter { _ in true }
            let delivered = EventLog()
            console.setCurrentGeneration(2)
            console.enqueue("a prompt the end superseded", generation: 1) { result in
                Thread.sleep(forTimeInterval: 0.3)
                delivered.add("\(result)")
            }
            console.enqueue("the end's banner") { result in
                Thread.sleep(forTimeInterval: 0.3)
                delivered.add("\(result)")
            }
            #expect(console.drain(timeout: 3))
            #expect(delivered.values == ["superseded", "written"])
        }

        @Test("An ended run keeps an output problem: after the CUT prompt, 3 and CHECK RECOVERY FIRST, even after a confirmed restore; before it, the outcome stands (should 3)")
        func outputProblemAfterTheEnd() {
            var stopped = FlowDriver()
            stopped.toAfter()
            stopped.advance(by: 20)
            stopped.send(.signal(SIGINT, at: stopped.now))
            #expect(stopped.outcome.exitStatus == 2)
            stopped.send(.consoleFailed(at: stopped.now + 1))
            #expect(stopped.flow.stage == .ended)
            #expect(stopped.outcome.exitStatus == 3)
            #expect(stopped.outcome.recoveryReason?.contains("a write of the probe's output to the terminal failed after the run ended") == true)
            #expect(stopped.flow.log.last?.text.contains("failed after the run ended") == true)
            #expect(stopped.flow.secondSignal(SIGINT) == (.afterReadingsEndedEarly, 3))

            var completed = FlowDriver()
            completed.toAfter()
            completed.run(until: .ended)
            #expect(completed.flow.ending == .completed)
            let before = completed.outcome
            #expect(before.exitStatus != 3)
            completed.flow.outputNotTaken(at: completed.now, within: 2)
            #expect(completed.outcome.exitStatus == 3)
            #expect(completed.outcome.verdict == before.verdict)
            #expect(completed.outcome.recoveryReason?.contains("the terminal did not take the probe's last output within 2.0 s") == true)

            var beforeCut = FlowDriver()
            beforeCut.begin()
            beforeCut.type("start00")
            beforeCut.send(.signal(SIGINT, at: beforeCut.now))
            #expect(beforeCut.outcome.exitStatus == 2)
            beforeCut.send(.consoleFailed(at: beforeCut.now))
            beforeCut.flow.outputNotTaken(at: beforeCut.now, within: 2)
            #expect(beforeCut.flow.outputProblem != nil)
            #expect(beforeCut.outcome.exitStatus == 2)
            #expect(beforeCut.outcome.recoveryReason == nil)
        }

        /// A console whose terminal fails to write any message containing
        /// `text`, after `delay` seconds; it writes the rest.
        static func failing(_ text: String, after delay: Double) -> ConsoleWriter {
            ConsoleWriter { message in
                guard message.contains(text) else { return true }
                Thread.sleep(forTimeInterval: delay)
                return false
            }
        }

        @Test("Review r3's case: after a confirmed restore and a charging reading, SIGINT, and the end banner's write fails late; the end waits for that result, exits 3, and the report opens with CHECK RECOVERY FIRST (should 3)")
        func failedEndBanner() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
            let events = EventLog()
            let driver = Self.stoppedAfterAConfirmedRestore(console: Self.failing(ManualCut.text(.afterReadingsEndedEarly), after: 0.5))
            let end = Self.ending(driver, file: file, events: events, watchdog: Self.watchdog(events), report: Self.realReport)
                .endMainPath(tearDown: {})
            #expect(end.status == 3)
            let report = try String(contentsOfFile: path, encoding: .utf8)
            #expect(report.contains("CHECK RECOVERY FIRST"))
            #expect(report.contains("failed after the run ended"))
        }

        @Test("A second signal's banner that the terminal cannot write: exit 3 and CHECK RECOVERY FIRST, even after a confirmed restore (should 3)")
        func failedSecondSignalBanner() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
            let events = EventLog()
            let driver = Self.stoppedAfterAConfirmedRestore(console: Self.failing("again: quitting", after: 0.3))
            let statuses = EventLog()
            Self.ending(driver, file: file, events: events, watchdog: Self.watchdog(events), report: Self.realReport)
                .endAtSecondSignal(SIGINT) { statuses.add("\($0)") }
            #expect(statuses.values == ["3"])
            let report = try String(contentsOfFile: path, encoding: .utf8)
            #expect(report.contains("CHECK RECOVERY FIRST"))
            #expect(report.contains("failed after the run ended"))
        }

        @Test("A terminal that does not take the end's output within its bound: after a confirmed restore, 3 and CHECK RECOVERY FIRST; the report is saved and the end keeps to its bounds (should 3)")
        func terminalNotTakingTheEnd() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
            let events = EventLog()
            let blocked = BlockingSink(blocked: false)
            defer { blocked.open() }
            let console = ConsoleWriter(sink: blocked.sink)
            let driver = SessionDriver(console: console)
            let mark = ManualCutTests.ManualCutSessionTests.atRestoreReadBack(driver)
            driver.type("restored00", at: mark + 190)
            driver.read(.charging, at: mark + 191)
            #expect(console.drain(timeout: 3))
            // The terminal stops taking output; the signal's banner waits.
            blocked.close()
            #expect(driver.session.signal(SIGINT) == .handled)
            driver.session.stopReminder()
            let start = Date()
            let end = ManualCutEnding(
                session: driver.session, watchdog: Self.watchdog(events), consoleDrainBound: 0.3,
                parts: ManualCutEnding.Parts(
                    stopSleepNotifications: {}, sleepNotices: { [] }, render: Self.realReport,
                    persist: { file.persist($0) }, savedLine: { "saved: \($0)" }
                )
            ).endMainPath(tearDown: {})
            #expect(Date().timeIntervalSince(start) < 1.5)
            #expect(end.status == 3)
            #expect(!end.drained)
            let report = try String(contentsOfFile: path, encoding: .utf8)
            #expect(report.contains("CHECK RECOVERY FIRST"))
            #expect(report.contains("the terminal did not take the probe's last output within 0.3 s"))
        }

        // MARK: One settled end for overlapping endings (code review r4 of #101)

        /// A second signal's banner, as the console shows it.
        static let secondBanner = "again: quitting"

        /// A console that logs each message it is handed in `handed`, and
        /// fails any that contains `failing`.
        static func recordingConsole(_ handed: EventLog, failing: String) -> ConsoleWriter {
            ConsoleWriter { text in
                handed.add(text)
                return !text.contains(failing)
            }
        }

        @Test("Review r4's case: the main path has claimed the end; a second signal's banner, queued before the boundary, fails; the main save is paused; both exit 3, and the saved report opens with CHECK RECOVERY FIRST")
        func bannerBeforeTheBoundaryCounts() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let events = EventLog()
            let paused = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let file = try #require(Self.pausingFile(path: path, paused: paused, gate: gate, events: events))
            let handed = EventLog()
            let driver = Self.stoppedAfterAConfirmedRestore(console: Self.recordingConsole(handed, failing: Self.secondBanner))
            let ending = Self.ending(driver, file: file, events: events, watchdog: Self.watchdog(events), report: Self.realReport)
            // The main path claims the end, then waits in its teardown,
            // before its boundary.
            let inTearDown = DispatchSemaphore(value: 0)
            let resumeTearDown = DispatchSemaphore(value: 0)
            let statuses = EventLog()
            Thread {
                let end = ending.endMainPath(tearDown: {
                    inTearDown.signal()
                    resumeTearDown.wait()
                })
                statuses.add("main \(end.status)")
            }.start()
            #expect(inTearDown.wait(timeout: .now() + 2) == .success)
            // A second signal: its banner goes out, and the terminal fails it.
            Thread {
                ending.endAtSecondSignal(SIGINT) { statuses.add("second \($0)") }
            }.start()
            #expect(eventually { handed.values.contains { $0.contains(Self.secondBanner) } })
            resumeTearDown.signal()
            // The main path settles and saves; its save pauses; nobody exits.
            #expect(paused.wait(timeout: .now() + 3) == .success)
            Thread.sleep(forTimeInterval: 0.3)
            #expect(statuses.values.isEmpty)
            gate.signal()
            #expect(eventually { statuses.values.count == 2 })
            #expect(Set(statuses.values) == ["main 3", "second 3"])
            let report = try String(contentsOfFile: path, encoding: .utf8)
            #expect(report.contains("CHECK RECOVERY FIRST"))
            #expect(report.contains("failed after the run ended"))
            #expect(events.values.filter { $0 == "persist" }.count == 1)
        }

        @Test("Review r4's case, after the boundary: the main path has settled on 2 and its save is paused when a second signal comes; it adds no banner, and both exit 2, the saved report's status")
        func secondSignalAfterTheBoundary() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let events = EventLog()
            let paused = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let file = try #require(Self.pausingFile(path: path, paused: paused, gate: gate, events: events))
            let handed = EventLog()
            let driver = Self.stoppedAfterAConfirmedRestore(console: Self.recordingConsole(handed, failing: Self.secondBanner))
            let ending = Self.ending(driver, file: file, events: events, watchdog: Self.watchdog(events), report: Self.realReport)
            let statuses = EventLog()
            Thread {
                statuses.add("main \(ending.endMainPath(tearDown: {}).status)")
            }.start()
            #expect(paused.wait(timeout: .now() + 3) == .success)
            #expect(driver.session.isActionableOutputClosed)
            Thread {
                ending.endAtSecondSignal(SIGINT) { statuses.add("second \($0)") }
            }.start()
            Thread.sleep(forTimeInterval: 0.5)
            #expect(statuses.values.isEmpty)
            gate.signal()
            #expect(eventually { statuses.values.count == 2 })
            #expect(Set(statuses.values) == ["main 2", "second 2"])
            #expect(!handed.values.contains { $0.contains(Self.secondBanner) })
            let report = try String(contentsOfFile: path, encoding: .utf8)
            #expect(!report.contains("CHECK RECOVERY FIRST"))
            #expect(events.values.filter { $0 == "persist" }.count == 1)
        }

        @Test("The boundary comes before the claimant's drain of the console: a second signal while that drain waits on a slow terminal adds no banner, and both exit with the settled status")
        func boundaryBeforeTheDrain() throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
            let events = EventLog()
            let handed = EventLog()
            let slow = DispatchSemaphore(value: 0)
            let slowEntered = DispatchSemaphore(value: 0)
            defer { slow.signal() }
            let console = ConsoleWriter { text in
                handed.add(text)
                if text == "a slow line" {
                    slowEntered.signal()
                    slow.wait()
                }
                return !text.contains(Self.secondBanner)
            }
            let driver = Self.stoppedAfterAConfirmedRestore(console: console)
            #expect(console.drain(timeout: 3))
            // The terminal is slow to take a line queued before the end.
            console.enqueue("a slow line")
            #expect(slowEntered.wait(timeout: .now() + 2) == .success)
            let ending = Self.ending(driver, file: file, events: events, watchdog: Self.watchdog(events))
            let statuses = EventLog()
            Thread {
                statuses.add("main \(ending.endMainPath(tearDown: {}).status)")
            }.start()
            // The main path has drained the sleep queue and waits on the
            // console.
            #expect(eventually { events.values.contains("drain") })
            Thread.sleep(forTimeInterval: 0.1)
            Thread {
                ending.endAtSecondSignal(SIGINT) { statuses.add("second \($0)") }
            }.start()
            Thread.sleep(forTimeInterval: 0.3)
            slow.signal()
            #expect(eventually { statuses.values.count == 2 })
            #expect(!handed.values.contains { $0.contains(Self.secondBanner) })
            #expect(Set(statuses.values) == ["main 2", "second 2"])
            #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("report 1: exit 2\n"))
        }

        @Test("Whatever the order of the two endings, both exit with the one settled status, the saved report's; a second signal's banner went out only if it counted")
        func endingsAgree() throws {
            for _ in 0..<20 {
                let path = Self.temporaryPath()
                defer { try? FileManager.default.removeItem(atPath: path) }
                let file = try #require(ReportFile(path: path, placeholder: "placeholder\n"))
                let events = EventLog()
                let handed = EventLog()
                let driver = Self.stoppedAfterAConfirmedRestore(console: Self.recordingConsole(handed, failing: Self.secondBanner))
                let ending = Self.ending(driver, file: file, events: events, watchdog: Self.watchdog(events))
                let statuses = EventLog()
                let mainDelay = UInt32.random(in: 0...3_000)
                let secondDelay = UInt32.random(in: 0...3_000)
                Thread {
                    usleep(mainDelay)
                    statuses.add("\(ending.endMainPath(tearDown: {}).status)")
                }.start()
                Thread {
                    usleep(secondDelay)
                    ending.endAtSecondSignal(SIGINT) { statuses.add("\($0)") }
                }.start()
                #expect(eventually { statuses.values.count == 2 })
                let values = statuses.values
                let status = values.first ?? "none"
                #expect(values == [status, status])
                #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("report 1: exit \(status)\n"))
                let bannerWentOut = handed.values.contains { $0.contains(Self.secondBanner) }
                #expect(bannerWentOut == (status == "3"), "banner out: \(bannerWentOut), status \(status)")
                #expect(events.values.filter { $0 == "persist" }.count == 1)
            }
        }

        @Test(
            "Before the CUT prompt, the path that waits exits with the settling path's status: 2 from the main path, or 128 plus the signal from a second signal's",
            arguments: [true, false]
        )
        func waiterTakesTheSettledStatus(mainSettles: Bool) throws {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let events = EventLog()
            let paused = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let file = try #require(Self.pausingFile(path: path, paused: paused, gate: gate, events: events))
            let driver = SessionDriver(console: ConsoleWriter { _ in true })
            driver.session.begin()
            driver.type("start00", at: 5)
            #expect(driver.session.signal(SIGINT) == .handled)
            driver.session.stopReminder()
            #expect(ManualCutOutcome.of(driver.session.snapshot, sleepNotices: []).exitStatus == 2)
            #expect(driver.session.snapshot.secondSignal(SIGINT) == (nil, 128 + SIGINT))
            let ending = Self.ending(driver, file: file, events: events, watchdog: Self.watchdog(events))
            let statuses = EventLog()
            let main = Thread {
                statuses.add("main \(ending.endMainPath(tearDown: {}).status)")
            }
            let second = Thread {
                ending.endAtSecondSignal(SIGINT) { statuses.add("second \($0)") }
            }
            // The settling path's save pauses; then the other path comes.
            (mainSettles ? main : second).start()
            #expect(paused.wait(timeout: .now() + 3) == .success)
            (mainSettles ? second : main).start()
            Thread.sleep(forTimeInterval: 0.3)
            #expect(statuses.values.isEmpty)
            gate.signal()
            #expect(eventually { statuses.values.count == 2 })
            let status = mainSettles ? 2 : 128 + SIGINT
            #expect(Set(statuses.values) == ["main \(status)", "second \(status)"])
        }

        @Test("Once actionable output is closed, the session queues nothing actionable: the flow's reminder is not shown, and an announcement is refused")
        func closedOutputQueuesNothingActionable() {
            let handed = EventLog()
            let driver = SessionDriver(console: ConsoleWriter { text in
                handed.add(text)
                return true
            })
            driver.toHold()
            let mark = driver.session.snapshot.cutMark?.time ?? 0
            driver.at(mark + 180)
            driver.session.poll()
            #expect(driver.session.snapshot.stage == .restorePrompt)
            #expect(eventually { handed.values.contains { $0.contains(ManualCutQuestion.restore.prompt) } })
            driver.session.closeActionableOutput()
            #expect(driver.session.isActionableOutputClosed)
            #expect(!driver.session.announce("an announcement"))
            // The reminder is due: the flow reminds, and nothing is queued.
            let shown = driver.session.snapshot.lastShownAt ?? 0
            driver.at(shown + ManualCut.reminderInterval)
            #expect(eventually { driver.session.snapshot.lastShownAt == shown + ManualCut.reminderInterval })
            #expect(driver.session.console.drain(timeout: 3))
            #expect(!handed.values.contains { $0.contains("(Reminder)") || $0 == "an announcement" })
            driver.session.stopReminder()
        }
    }
}
