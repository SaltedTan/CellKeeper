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

        /// Removes the report file at `path` and its partial files.
        static func remove(_ path: String) {
            for entry in [path] + ReportFile.partialPaths(for: path) {
                try? FileManager.default.removeItem(atPath: entry)
            }
        }

        static func contents(_ path: String) -> String? {
            try? String(contentsOfFile: path, encoding: .utf8)
        }

        /// A report file whose first write stops after 8 bytes and waits for
        /// `gate`, signalling `paused`; later writes go through. Each write
        /// is logged.
        static func pausingFile(path: String, paused: DispatchSemaphore, gate: DispatchSemaphore, events: EventLog) -> ReportFile? {
            let first = Counter()
            let hooks = ReportFile.Hooks(write: { descriptor, bytes, offset in
                events.add("write")
                first.add()
                guard first.value == 1 else { return pwrite(descriptor, bytes.baseAddress, bytes.count, offset) }
                let written = pwrite(descriptor, bytes.baseAddress, min(8, bytes.count), offset)
                paused.signal()
                gate.wait()
                return written
            })
            return try? ReportFile(path: path, placeholder: "placeholder\n", hooks: hooks)
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
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
            defer { Self.remove(path) }
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
            // The placeholder is whole; the save's 8 bytes are in the
            // partial file beside it.
            #expect(Self.contents(path) == "placeholder\n")
            #expect(Self.contents(ReportFile.partialPaths(for: path)[0]) == "report 1")
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
            defer { Self.remove(path) }
            let events = EventLog()
            let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
            defer { Self.remove(path) }
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
            defer { Self.remove(path) }
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
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
                defer { Self.remove(path) }
                let file = try ReportFile(path: path, placeholder: "placeholder\n")
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
            defer { Self.remove(path) }
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

        // MARK: The report's atomic save, and the settled banner first (code review r5 of #101)

        /// `watch`'s placeholder, as far as these tests need it.
        static let placeholder = """
            CHECK RECOVERY FIRST: this run stopped before it finished its report, so whether CHIE was restored is unknown.
            CellKeeper manual adapter-cut probe report: run started 2026-10-20 12:00:00 +11:00, still in progress or stopped before it finished.

            """

        static let report = String(repeating: "a line of the final report\n", count: 40)

        @Test("A save writes the whole report to the partial file, syncs it, then renames it over the placeholder: the file is exactly the report, and no partial file is left")
        func atomicSave() throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let events = EventLog()
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                write: { descriptor, bytes, offset in
                    events.add("write")
                    return ReportFile.Hooks.pwrite(descriptor, bytes, offset)
                },
                sync: { descriptor in
                    events.add("sync")
                    return ReportFile.Hooks.fsync(descriptor)
                },
                rename: { from, to in
                    events.add("rename \(from == ReportFile.partialPaths(for: path)[0] && to == path)")
                    return ReportFile.Hooks.rename(from, to)
                }
            ))
            #expect(Self.contents(path) == Self.placeholder)
            #expect(events.values.isEmpty)
            let directory = (path as NSString).deletingLastPathComponent
            #expect(file.partialPaths.count == ReportFile.partialNames)
            #expect(file.partialPaths.allSatisfy { ($0 as NSString).deletingLastPathComponent == directory })
            #expect(file.persist(Self.report) == .saved)
            #expect(events.values == ["write", "sync", "rename true"])
            #expect(Self.contents(path) == Self.report)
            #expect(!file.partialPaths.contains { FileManager.default.fileExists(atPath: $0) })
            // Every name is matched by .gitignore's charge-inhibit-probe-*.txt.
            let names = ReportFile.partialPaths(for: "charge-inhibit-probe-manual-adapter-cut-20261020-101500.txt")
            #expect(names.first == "charge-inhibit-probe-manual-adapter-cut-20261020-101500.partial.txt")
            #expect(names.dropFirst().first == "charge-inhibit-probe-manual-adapter-cut-20261020-101500.partial-2.txt")
            #expect(names.last == "charge-inhibit-probe-manual-adapter-cut-20261020-101500.partial-10.txt")
            #expect(names.allSatisfy { $0.hasPrefix("charge-inhibit-probe-") && $0.hasSuffix(".txt") })
            #expect(Set(names).count == ReportFile.partialNames)
        }

        @Test(
            "A save whose write stops part way or fails, or whose sync or rename fails, leaves the whole placeholder",
            arguments: ["write fails", "sync fails", "rename fails"]
        )
        func failedSaveKeepsThePlaceholder(failing step: String) throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                write: { descriptor, bytes, offset in
                    guard step == "write fails" else { return ReportFile.Hooks.pwrite(descriptor, bytes, offset) }
                    // Some of it, then an error.
                    if offset == 0 { return ReportFile.Hooks.pwrite(descriptor, UnsafeRawBufferPointer(rebasing: bytes.prefix(8)), offset) }
                    errno = EIO
                    return -1
                },
                sync: { descriptor in
                    guard step == "sync fails" else { return ReportFile.Hooks.fsync(descriptor) }
                    errno = EIO
                    return -1
                },
                rename: { from, to in
                    guard step == "rename fails" else { return ReportFile.Hooks.rename(from, to) }
                    errno = EXDEV
                    return -1
                }
            ))
            #expect(file.persist(Self.report) == .placeholderKept)
            #expect(Self.contents(path) == Self.placeholder)
        }

        @Test("A save whose write pauses after 8 bytes leaves the whole placeholder while it waits")
        func pausedSaveKeepsThePlaceholder() throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let paused = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let first = Counter()
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                write: { descriptor, bytes, offset in
                    first.add()
                    guard first.value == 1 else { return ReportFile.Hooks.pwrite(descriptor, bytes, offset) }
                    let written = ReportFile.Hooks.pwrite(descriptor, UnsafeRawBufferPointer(rebasing: bytes.prefix(8)), offset)
                    paused.signal()
                    gate.wait()
                    return written
                }
            ))
            let saved = Counter()
            Thread {
                if file.persist(Self.report) == .saved { saved.add() }
            }.start()
            #expect(paused.wait(timeout: .now() + 2) == .success)
            #expect(Self.contents(path) == Self.placeholder)
            #expect(Self.contents(file.partialPaths[0]) == "a line o")
            gate.signal()
            #expect(eventually { saved.value == 1 })
            #expect(Self.contents(path) == Self.report)
        }

        @Test("Review r5's case: a delayed sleep overturns a confirmed restore at settlement, and the save's first write hangs; the settled CHECK RECOVERY FIRST was queued before the save and is the last guidance on screen, and the file keeps the whole placeholder")
        func hungSaveAfterTheSettledBanner() throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let events = EventLog()
            let handed = EventLog()
            let console = ConsoleWriter { text in
                handed.add(text)
                return true
            }
            let driver = Self.stoppedAfterAConfirmedRestore(console: console)
            #expect(console.drain(timeout: 3))
            // The confirmed restore's banner is on screen.
            #expect(handed.values.contains { $0.contains(ManualCut.text(.afterReadingsEndedEarly)) })
            // A sleep that began before the confirmation, logged late: the
            // end will find it, and the confirmation will not count.
            let confirmed = try #require(driver.session.snapshot.restoreConfirmedAt)
            driver.sleepLog.record(at: confirmed - 1)
            let hang = DispatchSemaphore(value: 0)
            defer { hang.signal() }
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                write: { _, _, _ in
                    // The save has started: what had been queued by now?
                    _ = console.drain(timeout: 2)
                    let shown = handed.values.contains { $0.contains("CHECK RECOVERY FIRST") }
                    events.add(shown ? "save started after the settled banner" : "save started before it")
                    hang.wait()
                    errno = EIO
                    return -1
                }
            ))
            let ending = ManualCutEnding(session: driver.session, watchdog: Self.watchdog(events), parts: ManualCutEnding.Parts(
                stopSleepNotifications: {}, sleepNotices: { [] }, render: Self.realReport,
                persist: { file.persist($0) }, savedLine: { "saved: \($0)" }
            ))
            let statuses = EventLog()
            Thread {
                statuses.add("\(ending.endMainPath(tearDown: {}).status)")
            }.start()
            // The save hangs; in watch, the watchdog armed first would end
            // the process within its bound.
            #expect(eventually { events.values.contains { $0.hasPrefix("save started") } })
            #expect(events.values.first == "arm \(EndingWatchdog.bound)")
            #expect(events.values.contains("save started after the settled banner"))
            let last = try #require(handed.values.last)
            #expect(last.contains("CHECK RECOVERY FIRST"))
            #expect(last.contains("in a way that counts: a sleep began at"))
            #expect(last.contains(ManualCut.readFirstSteps))
            #expect(Self.contents(path) == Self.placeholder)
            #expect(statuses.values.isEmpty)
            // The write fails at last: the save fails, and the file is still
            // the placeholder.
            hang.signal()
            #expect(eventually { statuses.values == ["3"] })
            #expect(Self.contents(path) == Self.placeholder)
        }

        @Test("The settled banner: CHECK RECOVERY FIRST with the reason and the recovery steps for exit 3; otherwise the verdict and the exit status")
        func settledBannerText() {
            let recovery = ManualCut.settledBanner(
                ManualCutOutcome(verdict: .inconclusive(reason: "r"), exitStatus: 3, recoveryReason: "The owner has not confirmed that CHIE was restored."),
                status: 3
            )
            #expect(recovery.contains("CHECK RECOVERY FIRST: The owner has not confirmed that CHIE was restored."))
            #expect(recovery.contains(ManualCut.recoverySteps))
            let inconclusive = ManualCut.settledBanner(
                ManualCutOutcome(verdict: .inconclusive(reason: "r"), exitStatus: 2, recoveryReason: nil),
                status: 2
            )
            #expect(inconclusive == "\nThe run is over (verdict: inconclusive); exit status 2. Saving the report.")
            #expect(!inconclusive.contains("CHECK RECOVERY FIRST"))
            let refused = ManualCut.settledBanner(
                ManualCutOutcome(verdict: nil, exitStatus: 1, recoveryReason: nil, refusal: "no read"),
                status: 1
            )
            #expect(refused == "\nThe run is over (refused: no read); exit status 1. Saving the report.")
            #expect(ManualCut.settledBanner(ManualCutOutcome(verdict: nil, exitStatus: 2, recoveryReason: nil), status: 130)
                == "\nThe run is over (no verdict); exit status 130. Saving the report.")
        }

        // MARK: Exclusive creation of the report and its partial file (code review r6 of #101)

        static func isSymbolicLink(_ path: String) -> Bool {
            (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
        }

        static func isRegularFile(_ path: String) -> Bool {
            (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular
        }

        @Test(
            "A report name that is taken (a leftover report, a link to another file, a dangling link) is never opened, truncated or followed: watch refuses, and nothing is created",
            arguments: ["regular file", "symbolic link", "dangling symbolic link"]
        )
        func takenReportNameRefuses(entry: String) throws {
            let path = Self.temporaryPath()
            let other = path + ".other"
            defer {
                Self.remove(path)
                try? FileManager.default.removeItem(atPath: other)
            }
            switch entry {
            case "regular file":
                try "someone else's report\n".write(toFile: path, atomically: false, encoding: .utf8)
            case "symbolic link":
                try "someone else's report\n".write(toFile: other, atomically: false, encoding: .utf8)
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: other)
            default:
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: other)
            }
            #expect(throws: ReportFile.CreateError.exists) {
                try ReportFile(path: path, placeholder: Self.placeholder)
            }
            switch entry {
            case "regular file":
                #expect(Self.contents(path) == "someone else's report\n")
            case "symbolic link":
                #expect(Self.isSymbolicLink(path))
                #expect(Self.contents(other) == "someone else's report\n")
            default:
                #expect(Self.isSymbolicLink(path))
                #expect(!FileManager.default.fileExists(atPath: other))
            }
            #expect(!ReportFile.partialPaths(for: path).contains { FileManager.default.fileExists(atPath: $0) })
            let refusal = ManualCut.reportFileRefusal(.exists, fileName: "charge-inhibit-probe-manual-adapter-cut-20261020-101500.txt")
            #expect(refusal.hasPrefix("Refusing to run: ./charge-inhibit-probe-manual-adapter-cut-20261020-101500.txt already exists"))
            #expect(refusal.hasSuffix("Nothing was created."))
        }

        @Test("Two report files with the same name: the second refuses, and the first keeps its placeholder and still saves")
        func sameNameTwice() throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let first = try ReportFile(path: path, placeholder: Self.placeholder)
            #expect(throws: ReportFile.CreateError.exists) {
                try ReportFile(path: path, placeholder: "another run's placeholder\n")
            }
            #expect(Self.contents(path) == Self.placeholder)
            #expect(first.persist(Self.report) == .saved)
            #expect(Self.contents(path) == Self.report)
        }

        @Test(
            "A leftover partial file (a symbolic link or a hard link to the placeholder, or a regular file) is never opened: the save uses the next name, and the leftover is untouched",
            arguments: ["symbolic link", "hard link", "regular file"], [false, true]
        )
        func leftoverPartialFile(leftover: String, writeFails: Bool) throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                write: { descriptor, bytes, offset in
                    guard writeFails else { return ReportFile.Hooks.pwrite(descriptor, bytes, offset) }
                    if offset == 0 { return ReportFile.Hooks.pwrite(descriptor, UnsafeRawBufferPointer(rebasing: bytes.prefix(8)), offset) }
                    errno = EIO
                    return -1
                }
            ))
            let partial = file.partialPaths[0]
            switch leftover {
            case "symbolic link":
                try FileManager.default.createSymbolicLink(atPath: partial, withDestinationPath: path)
            case "hard link":
                #expect(link(path, partial) == 0)
            default:
                try "a leftover\n".write(toFile: partial, atomically: false, encoding: .utf8)
            }
            #expect(file.persist(Self.report) == (writeFails ? .placeholderKept : .saved))
            // The report file is a regular file: the report, or else the
            // whole placeholder.
            #expect(Self.isRegularFile(path))
            #expect(Self.contents(path) == (writeFails ? Self.placeholder : Self.report))
            // The next name was used; it is gone once renamed into place.
            #expect(FileManager.default.fileExists(atPath: file.partialPaths[1]) == writeFails)
            // The leftover is untouched.
            switch leftover {
            case "symbolic link":
                #expect(Self.isSymbolicLink(partial))
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: partial) == path)
            case "hard link":
                #expect(Self.isRegularFile(partial))
                #expect(Self.contents(partial) == Self.placeholder)
            default:
                #expect(Self.contents(partial) == "a leftover\n")
            }
        }

        @Test("Every partial name taken: the save fails without opening any of them, and the placeholder is whole")
        func everyPartialNameTaken() throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: Self.placeholder)
            for partial in file.partialPaths {
                try "taken\n".write(toFile: partial, atomically: false, encoding: .utf8)
            }
            #expect(file.persist(Self.report) == .placeholderKept)
            #expect(Self.contents(path) == Self.placeholder)
            #expect(file.partialPaths.allSatisfy { Self.contents($0) == "taken\n" })
            // One more name than the bound would have been free.
            let stem = String(path.dropLast(".txt".count))
            #expect(!FileManager.default.fileExists(atPath: "\(stem).partial-\(ReportFile.partialNames + 1).txt"))
        }

        // MARK: Identity checks around the rename, and no cleanup (code review r7 of #101)

        /// Replaces the entry at `path` with a regular file holding `text`,
        /// as another process might.
        static func replace(_ path: String, with text: String) {
            let other = path + ".replacement"
            try? text.write(toFile: other, atomically: false, encoding: .utf8)
            _ = rename(other, path)
        }

        @Test("Review r7's first swap: the written partial is replaced by a link to an obsolete report before the rename; nothing is renamed, and the placeholder, still the probe's, is kept")
        func partialSwappedBeforeTheRename() throws {
            let path = Self.temporaryPath()
            let obsolete = path + ".obsolete"
            defer {
                Self.remove(path)
                try? FileManager.default.removeItem(atPath: obsolete)
            }
            try "an obsolete report\n".write(toFile: obsolete, atomically: false, encoding: .utf8)
            let renames = Counter()
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                sync: { descriptor in
                    let partial = ReportFile.partialPaths(for: path)[0]
                    _ = unlink(partial)
                    _ = symlink(obsolete, partial)
                    return ReportFile.Hooks.fsync(descriptor)
                },
                rename: { from, to in
                    renames.add()
                    return ReportFile.Hooks.rename(from, to)
                }
            ))
            let outcome = file.persist(Self.report)
            #expect(outcome == .placeholderKept)
            #expect(renames.value == 0)
            #expect(Self.isRegularFile(path))
            #expect(Self.contents(path) == Self.placeholder)
            #expect(Self.contents(obsolete) == "an obsolete report\n")
            #expect(ManualCut.savedLine(outcome, fileName: "r.txt").contains("still says CHECK RECOVERY FIRST"))
        }

        @Test(
            "Review r7's second swap: the reservation is moved aside and another file put at the report's name; nothing is renamed, the other file is untouched, and the console claims nothing about it",
            arguments: [false, true]
        )
        func reservationMovedAside(syncFails: Bool) throws {
            let path = Self.temporaryPath()
            let aside = path + ".aside"
            defer {
                Self.remove(path)
                try? FileManager.default.removeItem(atPath: aside)
            }
            let renames = Counter()
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                sync: { descriptor in
                    _ = rename(path, aside)
                    try? "another run's placeholder\n".write(toFile: path, atomically: false, encoding: .utf8)
                    guard !syncFails else {
                        errno = EIO
                        return -1
                    }
                    return ReportFile.Hooks.fsync(descriptor)
                },
                rename: { from, to in
                    renames.add()
                    return ReportFile.Hooks.rename(from, to)
                }
            ))
            let outcome = file.persist(Self.report)
            #expect(outcome == .unconfirmed)
            #expect(renames.value == 0)
            #expect(Self.contents(path) == "another run's placeholder\n")
            #expect(Self.contents(aside) == Self.placeholder)
            let line = ManualCut.savedLine(outcome, fileName: "r.txt")
            #expect(!line.contains("CHECK RECOVERY FIRST"))
            #expect(line.hasPrefix("Could not save or confirm the report: the probe could not verify that ./r.txt"))
            #expect(line.contains("Copy the report above instead"))
        }

        @Test("After the rename, the report's name is not the file the probe wrote: the save is reported as not confirmed")
        func mismatchAfterTheRename() throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                rename: { from, to in
                    let result = ReportFile.Hooks.rename(from, to)
                    Self.replace(path, with: "someone else's file\n")
                    return result
                }
            ))
            #expect(file.persist(Self.report) == .unconfirmed)
            #expect(Self.contents(path) == "someone else's file\n")
        }

        @Test("A create of the partial file that fails with anything but EEXIST (EMFILE, say) ends the save at once, though a later create would succeed; the placeholder is kept")
        func transientCreateFailureEndsTheSave() throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            let creates = Counter()
            let file = try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                create: { partial in
                    creates.add()
                    guard creates.value > 1 else {
                        errno = EMFILE
                        return -1
                    }
                    return ReportFile.Hooks.create(partial)
                }
            ))
            #expect(file.persist(Self.report) == .placeholderKept)
            #expect(creates.value == 1)
            #expect(Self.contents(path) == Self.placeholder)
            #expect(!file.partialPaths.contains { FileManager.default.fileExists(atPath: $0) })
        }

        @Test("A placeholder that cannot be written: the probe refuses, names the file it created and left, and removes nothing")
        func placeholderNotWrittenIsLeftAndNamed() throws {
            let path = Self.temporaryPath()
            defer { Self.remove(path) }
            #expect(throws: ReportFile.CreateError.placeholderNotWritten(ENOSPC)) {
                try ReportFile(path: path, placeholder: Self.placeholder, hooks: ReportFile.Hooks(
                    writePlaceholder: { descriptor, bytes, offset in
                        guard offset == 0 else {
                            errno = ENOSPC
                            return -1
                        }
                        return ReportFile.Hooks.pwrite(descriptor, UnsafeRawBufferPointer(rebasing: bytes.prefix(8)), offset)
                    }
                ))
            }
            // The file the probe created is left as it is.
            #expect(Self.isRegularFile(path))
            #expect(Self.contents(path) == String(Self.placeholder.prefix(8)))
            #expect(!ReportFile.partialPaths(for: path).contains { FileManager.default.fileExists(atPath: $0) })
            let refusal = ManualCut.reportFileRefusal(.placeholderNotWritten(ENOSPC), fileName: "r.txt")
            #expect(refusal.hasPrefix("Refusing to run: ./r.txt was created, but its placeholder could not be written"))
            #expect(refusal.contains("The probe left that file as it is"))
            #expect(!refusal.contains("Nothing was created"))
            #expect(ManualCut.reportFileRefusal(.notCreated(EACCES), fileName: "r.txt").hasSuffix("Nothing was created."))
        }
    }
}
