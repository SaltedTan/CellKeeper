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
        /// part logs when it runs; each report is numbered by its render.
        static func ending(
            _ driver: SessionDriver,
            file: ReportFile,
            events: EventLog,
            watchdog: EndingWatchdog,
            drainSleepQueue: @escaping @Sendable () -> Bool = { true },
            sleepNotices: @escaping @Sendable () -> [ProbeRun.SleepNotice] = { [] }
        ) -> ManualCutEnding {
            let renders = Counter()
            return ManualCutEnding(session: driver.session, watchdog: watchdog, parts: ManualCutEnding.Parts(
                drainSleepQueue: {
                    events.add("drain")
                    return drainSleepQueue()
                },
                sleepNotices: {
                    events.add("notices")
                    return sleepNotices()
                },
                render: { outcome, _, _ in
                    renders.add()
                    events.add("render")
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
            let steps = EndingWatchdog.sleepDrainBound + EndingWatchdog.saveBound + BoundedEnd.drainBound
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
    }
}
