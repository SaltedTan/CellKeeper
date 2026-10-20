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
            #expect(!ending.saveFinished)
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
            // The watchdog was armed before the save began.
            let armed = try #require(events.index(of: "arm \(EndingWatchdog.bound)"))
            let persisted = try #require(events.index(of: "persist"))
            #expect(armed < persisted)
        }

        @Test("An ending paused just before its watchdog is armed has claimed nothing: the other ending saves the whole report itself, then exits (must 1)")
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
            // A second signal's end: it is not left waiting on a save that no
            // watchdog bounds. It saves the whole report, then exits.
            let exited = Counter()
            let savedAtExit = EventLog()
            Thread {
                ending.endAtSecondSignal(SIGINT) { _ in
                    savedAtExit.add((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                    exited.add()
                }
            }.start()
            #expect(eventually(timeout: 2) { exited.value == 1 })
            let saved = try #require(savedAtExit.values.first)
            #expect(saved.hasPrefix("report 1: exit 3\n"))
            #expect(saved.hasSuffix("a line of the report\n"))
            // The main path resumes, finds the save done, and never saves.
            resumeArm.signal()
            #expect(eventually { mainEnded.value == 1 })
            #expect(events.values.filter { $0 == "persist" }.count == 1)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == saved)
        }

        @Test("The save arms the watchdog before it is claimed, if no ending path has; a waiter waits for the save however long it takes")
        func oneShotSaveArmsFirst() {
            let events = EventLog()
            let save = OneShotSave(watchdog: Self.watchdog(events))
            let gate = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            Thread {
                _ = save.save {
                    events.add("save")
                    started.signal()
                    gate.wait()
                    return true
                }
            }.start()
            #expect(started.wait(timeout: .now() + 2) == .success)
            #expect(events.values == ["arm \(EndingWatchdog.bound)", "save"])
            let waited = Counter()
            Thread {
                if save.save({ events.add("second save"); return false }) { waited.add() }
            }.start()
            Thread.sleep(forTimeInterval: 3)
            #expect(waited.value == 0)
            gate.signal()
            #expect(eventually { waited.value == 1 })
            #expect(!events.values.contains("second save"))
            // The second path found the watchdog armed and did not arm it again.
            #expect(events.values.filter { $0.hasPrefix("arm") }.count == 1)
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
    }
}
