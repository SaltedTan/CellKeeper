import Foundation
import ProbeCore
import Testing

/// Drives a ``ManualCutFlow`` as `watch`'s main loop does: a tick every
/// 0.5 s, a reading every 2 s while the flow wants readings (each its own
/// battery update), and the owner's lines when the test types them. The
/// battery's state follows the owner's marks: `baseline` before the cut
/// mark, `held` after it (seconds since the mark), `after` after the
/// restore time (seconds since it).
struct FlowDriver {
    static let epoch = Scenario.epoch

    var flow: ManualCutFlow
    /// Every action the flow returned, in order.
    var actions: [ManualCutFlow.Action] = []
    var now = 0.0
    var nextReading: Double?
    /// Whether the main loop ticks; off, only the reminder's own timer
    /// (``reminderTick()``) moves the flow along.
    var mainLoopTicks = true
    var baseline: (Double) -> Sample.Reading = { _ in .charging }
    var held: (Double) -> Sample.Reading = { $0 < 4 ? .charging : .cut }
    var after: (Double) -> Sample.Reading = { $0 < 6 ? .cut : .charging }

    init(hold: Int = 180) {
        flow = ManualCutFlow(hold: hold)
    }

    func state(at time: Double) -> Sample.Reading {
        if let restore = flow.restoreMark, time >= restore.time { return after(time - restore.time) }
        if let cut = flow.cutMark, time >= cut.time { return held(time - cut.time) }
        return baseline(time)
    }

    /// The sleep latch, as the flow reads it with every event.
    var latch = SleepLatch.Snapshot.none
    /// Whether the console writes every prompt at once, so that each new
    /// question is published within the same step.
    var publishesAtOnce = true

    @discardableResult
    mutating func send(_ event: ManualCutFlow.Event) -> [ManualCutFlow.Action] {
        var result = flow.handle(event, latch: latch)
        if publishesAtOnce {
            var index = 0
            while index < result.count {
                if case let .publish(_, generation) = result[index] {
                    result += flow.handle(.published(generation: generation, at: now), latch: latch)
                }
                index += 1
            }
        }
        actions += result
        return result
    }

    /// Latches a sleep that began at `time` (default: now), as the sleep
    /// notification does; the flow sees it with the next event, here a tick.
    @discardableResult
    mutating func sleep(at time: Double? = nil) -> [ManualCutFlow.Action] {
        latch = SleepLatch.Snapshot(sequence: latch.sequence + 1, time: time ?? now)
        return send(.tick(at: now, unixTime: Self.epoch + now))
    }

    mutating func begin() {
        send(.begin(at: now))
    }

    @discardableResult
    mutating func type(_ text: String) -> [ManualCutFlow.Action] {
        send(.line(text, at: now, unixTime: Self.epoch + now))
    }

    @discardableResult
    mutating func reminderTick() -> [ManualCutFlow.Action] {
        send(.reminderTick(at: now))
    }

    /// Runs the loop until `time`, or until the flow ends.
    mutating func advance(to time: Double) {
        while now < time - 1e-9, flow.stage != .ended {
            now = min(time, now + 0.5)
            if mainLoopTicks {
                send(.tick(at: now, unixTime: Self.epoch + now))
            }
            if flow.wantsReadings {
                let due = nextReading ?? now
                if now >= due - 1e-9 {
                    send(.reading(state(at: now).sample(at: now, .baseline)))
                    nextReading = due + 2
                } else {
                    nextReading = due
                }
            } else {
                nextReading = nil
            }
        }
    }

    mutating func advance(by seconds: Double) {
        advance(to: now + seconds)
    }

    /// Runs the loop until the flow reaches `stage` (or ends), at most
    /// `limit` seconds.
    mutating func run(until stage: ManualCutFlow.Stage, limit: Double = 400) {
        let end = now + limit
        while flow.stage != stage, flow.stage != .ended, now < end {
            advance(by: 0.5)
        }
    }

    /// Begins, answers the first read, and runs the baseline to the CUT
    /// prompt.
    mutating func toCutPrompt() {
        begin()
        advance(by: 5)
        type("start00")
        run(until: .cutPrompt)
    }

    /// Then waits 4 s at the CUT prompt and marks the cut.
    mutating func toGo() {
        toCutPrompt()
        advance(by: 4)
        type("cutnow")
    }

    /// Then confirms the cut's read-back 10 s after the mark.
    mutating func toHold() {
        toGo()
        advance(by: 10)
        type("cut08")
    }

    /// Then runs to the RESTORE prompt at the hold's end.
    mutating func toRestorePrompt() {
        toHold()
        run(until: .restorePrompt)
    }

    /// Then marks the restore and confirms its read-back 10 s later.
    mutating func toAfter() {
        toRestorePrompt()
        advance(by: 5)
        type("restorenow")
        advance(by: 10)
        type("restored00")
    }

    var outcome: ManualCutOutcome { ManualCutOutcome.of(flow, sleepNotices: []) }

    /// The questions published, in order (not reminders).
    var questionsAsked: [ManualCutQuestion] {
        actions.compactMap { if case let .publish(question, _) = $0 { question } else { nil } }
    }

    var banners: [ManualCutFlow.Banner] {
        actions.compactMap { if case let .banner(banner) = $0 { banner } else { nil } }
    }
}

/// Whether `actions` end with `question` published and then, once its
/// prompt was written, pending input discarded.
func endsPublishing(_ question: ManualCutQuestion, _ actions: [ManualCutFlow.Action]) -> Bool {
    guard actions.count >= 2, case let .publish(published, _) = actions[actions.count - 2] else { return false }
    return published == question && actions.last == .discardInput
}

extension ManualCutTests {
    @Suite("The manual adapter cut's questions, marks and endings (research note 11 §4.4–§4.8)")
    struct ManualCutFlowTests {
        // MARK: The answer words

        @Test("Every question has its own answer words; no word answers two questions")
        func wordsAreDistinct() {
            let all = ManualCutQuestion.allCases.flatMap(\.words)
            #expect(Set(all).count == all.count)
            #expect(ManualCutQuestion.firstRead.words == ["start00"])
            #expect(ManualCutQuestion.cut.words == ["cutnow"])
            #expect(ManualCutQuestion.cutReadBack.words == ["cut08", "cutfail"])
            #expect(ManualCutQuestion.restore.words == ["restorenow"])
            #expect(ManualCutQuestion.restoreReadBack.words == ["restored00", "restorefail"])
            #expect(ManualCutQuestion.readFirst.words == ["08", "00", "other"])
            #expect(ManualCutQuestion.recheck.words == ["recheck00", "recheckfail"])
            for question in ManualCutQuestion.allCases {
                for word in question.words {
                    #expect(question.prompt.contains(word), "\(question.rawValue)'s prompt does not show \(word)")
                }
            }
        }

        @Test("Every prompt that names a tool command takes it from the one constant")
        func promptsUseTheToolConstants() {
            #expect(ManualCutQuestion.firstRead.prompt.contains(ManualCut.ToolCommand.read))
            #expect(ManualCutQuestion.cut.prompt.contains(ManualCut.ToolCommand.cut))
            #expect(ManualCutQuestion.cut.prompt.contains("Do not type the cut command yet"))
            #expect(ManualCutQuestion.restore.prompt.contains(ManualCut.ToolCommand.restore))
            #expect(ManualCutQuestion.readFirst.prompt.contains(ManualCut.ToolCommand.read))
            #expect(ManualCutQuestion.readFirst.prompt.contains("Never write before this read"))
            #expect(ManualCutQuestion.recheck.prompt.contains(ManualCut.ToolCommand.restore))
            #expect(ManualCut.ToolCommand.cut == "sudo ./smc -k CHIE -w 08")
            #expect(ManualCut.ToolCommand.restore == "sudo ./smc -k CHIE -w 00")
            #expect(ManualCut.ToolCommand.read == "./smc -k CHIE -r")
        }

        // MARK: The first read and the baseline

        @Test("start00 begins the baseline; the CUT prompt follows a good baseline, after a discard")
        func firstReadAndBaseline() {
            var driver = FlowDriver()
            driver.begin()
            #expect(driver.actions == [.publish(.firstRead, generation: 1), .discardInput])
            #expect(!driver.flow.wantsReadings)
            driver.advance(by: 5)
            driver.type("start00")
            #expect(driver.flow.stage == .baseline)
            driver.run(until: .cutPrompt)
            #expect(driver.flow.stage == .cutPrompt)
            let prompt = driver.flow.cutPromptAt ?? 0
            #expect(prompt >= 24 && prompt <= 27)
            #expect(endsPublishing(.cut, driver.actions))
            #expect(driver.flow.samples.allSatisfy { $0.phase == .baseline })
        }

        @Test("Anything but start00 at the first read refuses: exit 1, nothing written, no CUT prompt")
        func firstReadRefused() {
            for typed in ["start 00", "yes", "cutnow", "00"] {
                var driver = FlowDriver()
                driver.begin()
                driver.type(typed)
                #expect(driver.flow.stage == .ended)
                guard case .refused = driver.flow.ending else {
                    Issue.record("\(typed): not refused")
                    continue
                }
                #expect(driver.outcome.exitStatus == 1)
                #expect(driver.outcome.recoveryReason == nil)
                #expect(driver.flow.answers.last?.word == nil)
            }
        }

        @Test("No first read within 120 s refuses, exit 1; an empty line is not an answer")
        func firstReadTimeout() {
            var driver = FlowDriver()
            driver.begin()
            driver.type("")
            driver.type("   ")
            #expect(driver.flow.stage == .firstRead)
            driver.advance(to: 119.5)
            #expect(driver.flow.stage == .firstRead)
            driver.advance(to: 120.5)
            #expect(driver.flow.stage == .ended)
            #expect(driver.outcome.exitStatus == 1)
            #expect(driver.outcome.refusal?.contains("120 s") == true)
        }

        @Test("A baseline that is not charging ends the run before the CUT prompt: exit 2, nothing to restore")
        func baselineFails() {
            var driver = FlowDriver()
            driver.baseline = { $0 < 12 ? .charging : .stopped }
            driver.toCutPrompt()
            #expect(driver.flow.cutPromptAt == nil)
            guard case let .endedBeforeCut(reason) = driver.flow.ending else {
                Issue.record("not ended before the CUT prompt")
                return
            }
            #expect(reason.contains("baseline"))
            #expect(!reason.contains("assertion"))
            #expect(driver.outcome.exitStatus == 2)
            #expect(driver.outcome.recoveryReason == nil)
            #expect(!driver.banners.contains(.restoreChieNow))
        }

        // MARK: The CUT prompt, the mark and GO

        @Test("cutnow arms the reminder, then prints GO with the restore time, then asks for the read-back")
        func cutMarkThenGo() throws {
            var driver = FlowDriver()
            driver.toCutPrompt()
            driver.advance(by: 4)
            let actions = driver.type("cutnow")
            let mark = try #require(driver.flow.cutMark)
            #expect(actions == [
                .armReminder,
                .go(restoreBy: mark.unixTime + 180),
                .publish(.cutReadBack, generation: driver.flow.questionGeneration),
                .discardInput,
            ])
            #expect(driver.flow.reminderArmed)
            #expect(driver.flow.stage == .cutReadBack)
            #expect(driver.flow.samples.contains { $0.phase == .preCut })
        }

        @Test("Other text at the CUT prompt is not an answer: the prompt stays, nothing is discarded")
        func cutPromptOtherText() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            let actions = driver.type("cut08")
            #expect(driver.flow.stage == .cutPrompt)
            #expect(!actions.contains(.discardInput))
            #expect(driver.flow.cutMark == nil)
        }

        @Test("No cutnow within 120 s: the prompt is withdrawn, RESTORE CHIE NOW, exit 3")
        func cutPromptTimeout() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            let shown = driver.flow.cutPromptAt ?? 0
            driver.advance(to: shown + 119)
            #expect(driver.flow.stage == .cutPrompt)
            driver.advance(to: shown + 121)
            #expect(driver.flow.stage == .ended)
            #expect(driver.banners.contains(.restoreChieNow))
            #expect(driver.banners.contains { if case .withdrawn = $0 { true } else { false } })
            #expect(driver.outcome.exitStatus == 3)
            #expect(driver.outcome.recoveryReason != nil)
            #expect(!driver.actions.contains { if case .go = $0 { true } else { false } })
        }

        @Test("A pre-cut reading that is not charging withdraws the CUT prompt at once: exit 3")
        func withdrawnPrompt() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            let shown = driver.flow.cutPromptAt ?? 0
            driver.baseline = { $0 > shown + 5 ? .stopped : .charging }
            driver.advance(by: 10)
            #expect(driver.flow.stage == .ended)
            guard case let .unconfirmedRecovery(reason) = driver.flow.ending else {
                Issue.record("not ended without a confirmed restore")
                return
            }
            #expect(reason.contains("withdrawn"))
            #expect(reason.contains("the probe withdrew the CUT prompt"))
            #expect(driver.banners.first.map { if case .withdrawn = $0 { true } else { false } } == true)
            #expect(driver.banners.contains(.restoreChieNow))
            #expect(driver.outcome.exitStatus == 3)
            #expect(!driver.actions.contains(.armReminder))
        }

        @Test("NO GO: freshness fails at the mark, so no reminder and no GO line; RESTORE CHIE NOW, exit 3")
        func noGo() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            // The main loop stalled: no reading for 10 s before the mark.
            driver.mainLoopTicks = false
            driver.now += 10
            let actions = driver.type("cutnow")
            #expect(driver.flow.stage == .ended)
            #expect(!actions.contains(.armReminder))
            #expect(!actions.contains { if case .go = $0 { true } else { false } })
            #expect(actions.contains { if case let .banner(.noGo(reason)) = $0 { reason.contains("NO GO") } else { false } })
            #expect(actions.contains(.banner(.restoreChieNow)))
            #expect(driver.flow.cutMark == nil)
            #expect(driver.outcome.exitStatus == 3)
        }

        @Test("A 30 s wait at the CUT prompt does not make a good baseline stale (note 11 §4.5, check b), at GO or in the verdict")
        func waitAtCutPrompt() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            driver.advance(by: 30)
            driver.type("cutnow")
            #expect(driver.flow.stage == .cutReadBack)
            #expect(driver.flow.samples.filter { $0.phase == .preCut }.count >= 14)
            driver.advance(by: 10)
            driver.type("cut08")
            driver.run(until: .restorePrompt)
            driver.type("restorenow")
            driver.advance(by: 10)
            driver.type("restored00")
            driver.run(until: .ended, limit: 400)
            guard case .adapterCut = driver.outcome.verdict else {
                Issue.record("expected an adapter cut, got \(String(describing: driver.outcome.verdict))")
                return
            }
            #expect(driver.outcome.exitStatus == 0)
        }

        // MARK: The cut's read-back

        @Test("cut08 confirms the cut and opens no question until the hold ends")
        func cut08() {
            var driver = FlowDriver()
            driver.toHold()
            #expect(driver.flow.cutConfirmed)
            #expect(driver.flow.stage == .hold)
            #expect(driver.flow.openQuestion == nil)
            #expect(driver.flow.answers.last?.word == "cut08")
        }

        @Test("cutfail, or any other text, supersedes the read-back with the read-first steps, after a discard")
        func cutReadBackNotConfirmed() {
            for typed in ["cutfail", "cut 08", "08", "restorenow"] {
                var driver = FlowDriver()
                driver.toGo()
                driver.advance(by: 10)
                let actions = driver.type(typed)
                #expect(driver.flow.stage == .readFirst, "\(typed)")
                #expect(endsPublishing(.readFirst, actions), "\(typed)")
                #expect(!driver.flow.cutConfirmed)
                #expect(driver.flow.readFirstReason != nil)
            }
        }

        @Test("No cut08 within 90 s of the mark: the read-first steps")
        func cutReadBackTimeout() throws {
            var driver = FlowDriver()
            driver.toGo()
            let mark = try #require(driver.flow.cutMark)
            driver.advance(to: mark.time + 89)
            #expect(driver.flow.stage == .cutReadBack)
            driver.advance(to: mark.time + 91)
            #expect(driver.flow.stage == .readFirst)
            #expect(driver.flow.readFirstReason?.contains("90 s") == true)
        }

        @Test("An early stop while the read-back is pending uses the read-first steps, never the RESTORE prompt")
        func earlyStopWhilePending() {
            var driver = FlowDriver()
            driver.held = { $0 < 20 ? .charging : .full }
            driver.toGo()
            driver.run(until: .readFirst, limit: 60)
            #expect(driver.flow.stage == .readFirst)
            #expect(!driver.questionsAsked.contains(.restore))
            #expect(driver.flow.earlyStop?.contains("100%") == true)
        }

        @Test("An early stop after a confirmed cut shows the RESTORE prompt at once")
        func earlyStopAfterConfirmation() {
            var driver = FlowDriver()
            driver.held = { $0 < 40 ? .cut : .full }
            driver.toHold()
            driver.run(until: .restorePrompt, limit: 60)
            #expect(driver.flow.stage == .restorePrompt)
            #expect(driver.flow.earlyStop != nil)
        }

        @Test("Battery power is not a reason to stop early")
        func batteryPowerIsTheEffect() {
            var driver = FlowDriver()
            driver.held = { _ in .unplugged }
            driver.toHold()
            driver.advance(by: 100)
            #expect(driver.flow.stage == .hold)
            #expect(driver.flow.earlyStop == nil)
        }

        // MARK: The standard restore

        @Test("The hold's end shows the RESTORE prompt, after a discard; restorenow marks the restore time")
        func restorePrompt() throws {
            var driver = FlowDriver()
            driver.toRestorePrompt()
            let mark = try #require(driver.flow.cutMark)
            let restoreAsked = try #require(driver.flow.lastShownAt)
            #expect(restoreAsked >= mark.time + 180 && restoreAsked < mark.time + 181)
            #expect(endsPublishing(.restore, driver.actions))
            driver.advance(by: 3)
            let typedAt = driver.now
            let actions = driver.type("restorenow")
            #expect(driver.flow.restoreMark?.time == typedAt)
            #expect(actions == [.publish(.restoreReadBack, generation: driver.flow.questionGeneration), .discardInput])
            #expect(driver.flow.restoreCommandsRun == 1)
        }

        @Test("Other text at the RESTORE prompt is not an answer: the prompt stays and no mark moves")
        func restorePromptOtherText() {
            var driver = FlowDriver()
            driver.toRestorePrompt()
            let actions = driver.type("restored00")
            #expect(driver.flow.stage == .restorePrompt)
            #expect(driver.flow.restoreMark == nil)
            #expect(!actions.contains(.discardInput))
        }

        @Test("restored00 confirms recovery; the after readings run and end with the verdict: adapter cut, exit 0")
        func happyPath() {
            var driver = FlowDriver()
            driver.toAfter()
            #expect(driver.flow.restoreConfirmed)
            #expect(driver.flow.restoreConfirmedBy == "restored00")
            #expect(driver.flow.stage == .after)
            driver.run(until: .ended, limit: 400)
            #expect(driver.flow.ending == .completed)
            let outcome = driver.outcome
            guard case .adapterCut = outcome.verdict else {
                Issue.record("expected an adapter cut, got \(String(describing: outcome.verdict))")
                return
            }
            #expect(outcome.exitStatus == 0)
            #expect(outcome.recoveryReason == nil)
            #expect(driver.flow.readFirstReason == nil)
            let phases = Set(driver.flow.samples.map(\.phase))
            #expect(phases == [.baseline, .preCut, .held, .after])
            #expect(driver.flow.restoreWrittenSummary.contains("run once"))
        }

        @Test("restorefail, or other text, at the restore's read-back goes to the read-first steps")
        func restoreReadBackNotConfirmed() {
            for typed in ["restorefail", "00", "restored 00"] {
                var driver = FlowDriver()
                driver.toRestorePrompt()
                driver.type("restorenow")
                driver.advance(by: 5)
                driver.type(typed)
                #expect(driver.flow.stage == .readFirst, "\(typed)")
                #expect(!driver.flow.restoreConfirmed)
            }
        }

        @Test("No cut confirmation and no restore after a sleep: the RESTORE prompt is never used")
        func restorePromptOnlyAfterConfirmedCutAndNoSleep() {
            var driver = FlowDriver()
            driver.toHold()
            driver.advance(by: 10)
            driver.sleep()
            #expect(driver.flow.stage == .readFirst)
            driver.run(until: .ended, limit: 300)
            #expect(!driver.questionsAsked.contains(.restore))
        }

        // MARK: Read-first

        @Test("Read-first 08: the restore, then the re-check; recheck00 confirms recovery; the run is inconclusive")
        func readFirst08ThenRecheck00() {
            var driver = FlowDriver()
            driver.toGo()
            driver.type("cutfail")
            driver.advance(by: 5)
            let actions = driver.type("08")
            #expect(actions == [.publish(.recheck, generation: driver.flow.questionGeneration), .discardInput])
            #expect(driver.flow.restoreMark != nil)
            driver.advance(by: 10)
            driver.type("recheck00")
            #expect(driver.flow.restoreConfirmedBy == "recheck00")
            driver.run(until: .ended, limit: 400)
            let outcome = driver.outcome
            #expect(outcome.verdict?.title == "inconclusive")
            #expect(outcome.exitStatus == 2)
            #expect(outcome.recoveryReason == nil)
            #expect(driver.flow.restoreWrittenSummary.contains("run once"))
        }

        @Test("Read-first: recheckfail, or other text, brings the read-first steps back")
        func recheckNotConfirmed() {
            for typed in ["recheckfail", "restored00", "00"] {
                var driver = FlowDriver()
                driver.toGo()
                driver.type("cutfail")
                driver.type("08")
                driver.advance(by: 5)
                let actions = driver.type(typed)
                #expect(driver.flow.stage == .readFirst, "\(typed)")
                #expect(endsPublishing(.readFirst, actions), "\(typed)")
                #expect(!driver.flow.restoreConfirmed)
            }
        }

        @Test("Read-first 00: nothing to restore and nothing written; recovery confirmed; the report says so")
        func readFirst00() {
            var driver = FlowDriver()
            driver.held = { _ in .charging }
            driver.toGo()
            driver.advance(by: 30)
            driver.type("cutfail")
            driver.advance(by: 5)
            driver.type("00")
            #expect(driver.flow.restoreConfirmedBy == "00")
            #expect(driver.flow.answeredNothingToRestore)
            #expect(driver.flow.restoreCommandsRun == 0)
            #expect(driver.flow.restoreWrittenSummary.contains("no restore was written"))
            driver.run(until: .ended, limit: 400)
            #expect(driver.outcome.exitStatus == 2)
            #expect(driver.outcome.verdict?.title == "inconclusive")
        }

        @Test("Read-first other: write nothing, RESTORE CHIE NOW with the recovery steps, exit 3")
        func readFirstOther() {
            var driver = FlowDriver()
            driver.toGo()
            driver.type("cutfail")
            driver.type("other")
            #expect(driver.flow.stage == .ended)
            #expect(driver.banners.last == .restoreChieNow)
            #expect(driver.outcome.exitStatus == 3)
            #expect(driver.outcome.recoveryReason != nil)
            #expect(driver.flow.restoreWrittenSummary.contains("Unknown"))
        }

        @Test("Read-first: other text is not an answer, and a word of a superseded question never confirms recovery")
        func supersededWordsDoNotCount() {
            var driver = FlowDriver()
            driver.toRestorePrompt()
            driver.type("restorenow")
            driver.sleep()
            #expect(driver.flow.stage == .readFirst)
            // A delayed answer meant for the superseded read-back question.
            let actions = driver.type("restored00")
            #expect(driver.flow.stage == .readFirst)
            #expect(!driver.flow.restoreConfirmed)
            #expect(!actions.contains(.discardInput))
            driver.type("cut08")
            #expect(!driver.flow.restoreConfirmed)
        }

        // MARK: Sleep

        @Test("A sleep before the CUT prompt ends the run: inconclusive, exit 2, nothing to restore")
        func sleepBeforeCut() {
            var driver = FlowDriver()
            driver.begin()
            driver.type("start00")
            driver.advance(by: 6)
            driver.sleep()
            #expect(driver.flow.stage == .ended)
            #expect(driver.outcome.exitStatus == 2)
            #expect(driver.outcome.recoveryReason == nil)
            #expect(!driver.banners.contains(.restoreChieFirst))
        }

        @Test("A sleep after the CUT prompt and before recovery: RESTORE CHIE FIRST and the read-first question afresh")
        func sleepAfterCutBeforeRecovery() {
            for stage in [ManualCutFlow.Stage.cutPrompt, .cutReadBack, .hold, .restorePrompt, .restoreReadBack, .readFirst, .recheck] {
                var driver = FlowDriver()
                switch stage {
                case .cutPrompt: driver.toCutPrompt()
                case .cutReadBack: driver.toGo()
                case .hold: driver.toHold()
                case .restorePrompt: driver.toRestorePrompt()
                case .restoreReadBack:
                    driver.toRestorePrompt()
                    driver.type("restorenow")
                case .readFirst:
                    driver.toGo()
                    driver.type("cutfail")
                default:
                    driver.toGo()
                    driver.type("cutfail")
                    driver.type("08")
                }
                #expect(driver.flow.stage == stage)
                let actions = driver.sleep()
                #expect(actions.first == .banner(.restoreChieFirst), "\(stage)")
                #expect(endsPublishing(.readFirst, actions), "\(stage)")
                #expect(driver.flow.stage == .readFirst)
                #expect(driver.flow.sleptAfterCutPrompt)
                driver.type("00")
                driver.run(until: .ended, limit: 400)
                #expect(driver.outcome.verdict?.title == "inconclusive", "\(stage)")
            }
        }

        @Test("A sleep that begins after a confirmed restore asks nothing new; the run is inconclusive")
        func sleepAfterRecovery() {
            var driver = FlowDriver()
            driver.toAfter()
            driver.advance(by: 1)
            let actions = driver.sleep()
            #expect(!actions.contains(.discardInput))
            #expect(!actions.contains { if case .publish = $0 { true } else { false } })
            #expect(driver.flow.stage == .after)
            driver.run(until: .ended, limit: 400)
            let notices = [ProbeRun.SleepNotice(time: driver.flow.sleeps[0], message: "kIOMessageSystemWillSleep")]
            let outcome = ManualCutOutcome.of(driver.flow, sleepNotices: notices)
            #expect(outcome.verdict?.title == "inconclusive")
            #expect(outcome.exitStatus == 2)
        }

        @Test("Review r1's ordering: a sleep latched after the input was read, with restored00 queued, ends in read-first")
        func sleepLatchedBeforeQueuedAnswer() {
            var driver = FlowDriver()
            driver.toRestorePrompt()
            driver.type("restorenow")
            driver.advance(by: 5)
            // The owner typed restored00; then the Mac slept before the line was
            // handled. The latch moved, so the sleep is delivered first and the
            // queued answer meets the read-first question, which it does not
            // answer.
            driver.latch = SleepLatch.Snapshot(sequence: driver.latch.sequence + 1, time: driver.now - 1)
            let actions = driver.flow.handleLines(["restored00"], at: driver.now, unixTime: FlowDriver.epoch + driver.now, latch: driver.latch)
            #expect(actions.first == .banner(.restoreChieFirst))
            #expect(driver.flow.stage == .readFirst)
            #expect(!driver.flow.restoreConfirmed)
            #expect(driver.flow.restoreConfirmedBy == nil)
        }

        @Test("A sleep that began before a confirmation, but is seen only after it, makes the confirmation not count")
        func lateSleepNoticeUndoesConfirmation() {
            var driver = FlowDriver()
            driver.toRestorePrompt()
            driver.type("restorenow")
            driver.advance(by: 5)
            let sleepBegan = driver.now - 0.001
            driver.type("restored00")
            #expect(driver.flow.restoreConfirmed)
            // The notification recorded the sleep's start just before the answer
            // was accepted, but the latch's move became visible only after it.
            let actions = driver.sleep(at: sleepBegan)
            #expect(actions.first == .banner(.restoreChieFirst))
            #expect(driver.flow.stage == .readFirst)
            #expect(!driver.flow.restoreConfirmed)
            #expect(driver.flow.answers.last?.outcome.contains("does not count") == true)
            driver.run(until: .ended, limit: 60)
            #expect(driver.flow.stage == .readFirst)
        }

        @Test("A sleep latched while the reminder fires is delivered instead of repeating the stale question")
        func sleepLatchedAtReminder() throws {
            var driver = FlowDriver()
            driver.toRestorePrompt()
            driver.type("restorenow")
            let shown = try #require(driver.flow.lastShownAt)
            driver.now = shown + 20
            driver.latch = SleepLatch.Snapshot(sequence: driver.latch.sequence + 1, time: shown + 19)
            let actions = driver.reminderTick()
            #expect(!actions.contains(.remind(.restoreReadBack)))
            #expect(actions.first == .banner(.restoreChieFirst))
            #expect(endsPublishing(.readFirst, actions))
            #expect(driver.flow.questionLatch == driver.latch.sequence)
        }

        @Test("An answer to a question published before the latest sleep is never accepted")
        func answerNeedsCurrentQuestionLatch() {
            var driver = FlowDriver()
            driver.toGo()
            driver.type("cutfail")
            #expect(driver.flow.stage == .readFirst)
            let published = driver.flow.questionLatch
            driver.sleep()
            #expect(driver.flow.questionLatch == published + 1)
            driver.type("00")
            #expect(driver.flow.restoreConfirmed)
        }

        @Test("The will-sleep handler records the sleep in the latch, then acknowledges at once")
        func willSleepHandler() {
            let latch = SleepLatch()
            #expect(latch.snapshot == .none)
            let calls = Counter()
            ManualCut.willSleepHandler(latch: latch, now: { 42 })({
                // The latch is recorded before the sleep is allowed.
                #expect(latch.snapshot == SleepLatch.Snapshot(sequence: 1, time: 42))
                calls.add()
            })
            #expect(calls.value == 1)
            ManualCut.willSleepHandler(latch: latch, now: { 50 })({ calls.add() })
            #expect(latch.snapshot == SleepLatch.Snapshot(sequence: 2, time: 50))
        }

        // MARK: Signals

        @Test("A signal before the CUT prompt ends the run: exit 2, nothing to restore")
        func signalBeforeCut() {
            var driver = FlowDriver()
            driver.begin()
            driver.type("start00")
            driver.advance(by: 6)
            driver.send(.signal(SIGINT, at: driver.now))
            #expect(driver.flow.stage == .ended)
            #expect(driver.outcome.exitStatus == 2)
            #expect(!driver.banners.contains(.restoreChieNow))
        }

        @Test("A signal after the CUT prompt and before recovery: RESTORE CHIE NOW, CHECK RECOVERY FIRST, exit 3")
        func signalBeforeRecovery() {
            for setUp in [{ (driver: inout FlowDriver) in driver.toCutPrompt() }, { $0.toHold() }, { $0.toRestorePrompt() }] {
                var driver = FlowDriver()
                setUp(&driver)
                driver.send(.signal(SIGTERM, at: driver.now))
                #expect(driver.flow.stage == .ended)
                #expect(driver.banners.last == .restoreChieNow)
                #expect(driver.outcome.exitStatus == 3)
                #expect(driver.outcome.recoveryReason != nil)
            }
        }

        @Test("A signal after a confirmed restore ends the after readings early: exit 2 if the last reading charges")
        func signalAfterRecoveryCharging() {
            var driver = FlowDriver()
            driver.toAfter()
            driver.advance(by: 20)
            driver.send(.signal(SIGINT, at: driver.now))
            #expect(driver.banners.last == .afterReadingsEndedEarly)
            #expect(!driver.banners.contains(.restoreChieNow))
            let outcome = driver.outcome
            #expect(outcome.verdict?.title == "inconclusive")
            #expect(outcome.exitStatus == 2)
            #expect(outcome.recoveryReason == nil)
        }

        @Test("A signal after a confirmed restore, the last reading not charging: CHECK RECOVERY FIRST, exit 3")
        func signalAfterRecoveryNotCharging() {
            var driver = FlowDriver()
            driver.after = { _ in .cut }
            driver.toAfter()
            driver.advance(by: 20)
            driver.send(.signal(SIGHUP, at: driver.now))
            #expect(driver.banners.last == .afterReadingsEndedEarly)
            #expect(driver.outcome.exitStatus == 3)
            #expect(driver.outcome.recoveryReason?.contains("did not show charging") == true)
        }

        @Test("A second signal quits at once: as note 10 before the CUT prompt, else with the banner again and the run's status")
        func secondSignal() {
            var before = FlowDriver()
            before.begin()
            before.type("start00")
            before.send(.signal(SIGINT, at: before.now))
            #expect(before.flow.secondSignal(SIGINT) == (nil, 128 + SIGINT))

            var during = FlowDriver()
            during.toHold()
            during.send(.signal(SIGINT, at: during.now))
            #expect(during.flow.secondSignal(SIGINT) == (.restoreChieNow, 3))

            var afterCharging = FlowDriver()
            afterCharging.toAfter()
            afterCharging.advance(by: 20)
            afterCharging.send(.signal(SIGINT, at: afterCharging.now))
            #expect(afterCharging.flow.secondSignal(SIGINT) == (.afterReadingsEndedEarly, 2))

            var afterCut = FlowDriver()
            afterCut.after = { _ in .cut }
            afterCut.toAfter()
            afterCut.send(.signal(SIGTERM, at: afterCut.now))
            #expect(afterCut.flow.secondSignal(SIGTERM) == (.afterReadingsEndedEarly, 3))
        }

        // MARK: The reminder

        @Test("The reminder makes the restore request at the hold's end, even if the main loop is late")
        func reminderAtHoldEnd() throws {
            var driver = FlowDriver()
            driver.toHold()
            let mark = try #require(driver.flow.cutMark)
            driver.mainLoopTicks = false
            driver.now = mark.time + 179.5
            #expect(driver.reminderTick().isEmpty)
            driver.now = mark.time + 180
            let actions = driver.reminderTick()
            #expect(endsPublishing(.restore, actions) && actions.count == 2)
        }

        @Test("With the main loop stuck since GO, the reminder makes the read-first request at the hold's end, never the RESTORE prompt")
        func reminderAtHoldEndWithReadBackPending() throws {
            var driver = FlowDriver()
            driver.toGo()
            let mark = try #require(driver.flow.cutMark)
            driver.mainLoopTicks = false
            driver.now = mark.time + 180
            let actions = driver.reminderTick()
            #expect(endsPublishing(.readFirst, actions))
            #expect(driver.flow.stage == .readFirst)
            #expect(!driver.questionsAsked.contains(.restore))
            #expect(driver.flow.answers.last?.outcome == "superseded at the hold's end")
        }

        @Test("A reminder repeats the open question every 20 s, ringing, without a discard, a new question or a moved mark")
        func reminderRepeats() throws {
            var driver = FlowDriver()
            driver.toRestorePrompt()
            driver.type("restorenow")
            let shown = try #require(driver.flow.lastShownAt)
            let mark = driver.flow.restoreMark
            let stage = driver.flow.stage
            let answers = driver.flow.answers
            driver.now = shown + 19
            #expect(driver.reminderTick().isEmpty)
            driver.now = shown + 20
            let generation = driver.flow.questionGeneration
            #expect(driver.reminderTick() == [.remind(.restoreReadBack)])
            #expect(driver.flow.questionGeneration == generation)
            #expect(driver.flow.inputEligible)
            #expect(driver.flow.restoreMark == mark)
            #expect(driver.flow.stage == stage)
            #expect(driver.flow.answers == answers)
            driver.now = shown + 30
            #expect(driver.reminderTick().isEmpty)
            driver.now = shown + 40
            #expect(driver.reminderTick() == [.remind(.restoreReadBack)])
            // An answer typed before the reminder still counts: a repeat discards nothing.
            driver.type("restored00")
            #expect(driver.flow.restoreConfirmed)
            driver.now += 60
            #expect(driver.reminderTick().isEmpty)
        }

        @Test("The reminder repeats the read-first question; it is armed even when read-first comes before any cut mark")
        func reminderReadFirst() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            let actions = driver.sleep()
            #expect(actions.contains(.armReminder))
            driver.now += 20
            #expect(driver.reminderTick() == [.remind(.readFirst)])
        }

        @Test("The reminder is not armed before the cut mark, and never repeats the CUT or read-back questions")
        func reminderNotBeforeMark() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            driver.now += 60
            #expect(driver.reminderTick().isEmpty)
            var marked = FlowDriver()
            marked.toGo()
            marked.now += 40
            #expect(marked.reminderTick().isEmpty)
        }

        // MARK: Discards and phases

        @Test("Every published question makes input eligible only after its prompt is written, with a discard first; reminders never discard")
        func discardAfterEveryPublication() {
            var driver = FlowDriver()
            driver.toAfter()
            driver.now += 0
            for (index, action) in driver.actions.enumerated() {
                switch action {
                case .publish:
                    #expect(index + 1 < driver.actions.count && driver.actions[index + 1] == .discardInput)
                case .remind:
                    #expect(index + 1 == driver.actions.count || driver.actions[index + 1] != .discardInput)
                default:
                    break
                }
            }
        }

        @Test("Until its prompt is written, a question takes no answer; then pending input is discarded first")
        func publicationGatesAnswers() throws {
            var driver = FlowDriver()
            driver.toGo()
            driver.type("cutfail")
            driver.type("08")
            #expect(driver.flow.stage == .recheck)
            // The console is not writing: recheckfail opens read-first, whose
            // prompt is not written yet.
            driver.publishesAtOnce = false
            let opened = driver.type("recheckfail")
            guard case let .publish(.readFirst, generation)? = opened.last else {
                Issue.record("read-first not published: \(opened)")
                return
            }
            #expect(!driver.flow.inputEligible)
            // 00 typed before the question appeared is not accepted.
            #expect(driver.type("00").isEmpty)
            #expect(!driver.flow.restoreConfirmed)
            // A stale publication does nothing.
            #expect(driver.send(.published(generation: generation - 1, at: driver.now)).isEmpty)
            #expect(!driver.flow.inputEligible)
            // The prompt is written: pending input is discarded, then answers count.
            #expect(driver.send(.published(generation: generation, at: driver.now)) == [.discardInput])
            #expect(driver.flow.inputEligible)
            #expect(driver.send(.published(generation: generation, at: driver.now)).isEmpty)
            driver.type("00")
            #expect(driver.flow.restoreConfirmed)
        }

        @Test("Readings take their phase from the marks: baseline, pre-cut, held, after")
        func phases() throws {
            var driver = FlowDriver()
            driver.toAfter()
            let prompt = try #require(driver.flow.cutPromptAt)
            let cut = try #require(driver.flow.cutMark)
            let restore = try #require(driver.flow.restoreMark)
            // A reading taken at the very moment of a mark was taken before the
            // mark was made, and keeps the earlier phase.
            for sample in driver.flow.samples where ![prompt, cut.time, restore.time].contains(sample.time) {
                let expected: Sample.Phase = sample.time > restore.time ? .after
                    : sample.time > cut.time ? .held : sample.time > prompt ? .preCut : .baseline
                #expect(sample.phase == expected, "at +\(sample.time)")
            }
            #expect(driver.flow.phase(at: cut.time) == .held)
            #expect(driver.flow.phase(at: cut.time - 0.1) == .preCut)
            #expect(driver.flow.phase(at: restore.time) == .after)
            #expect(driver.flow.phase(at: prompt - 0.1) == .baseline)
        }

        @Test("Lines typed ahead in one batch never carry over a question's change")
        func typedAheadLinesAreDropped() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            // The owner typed cutnow and, ahead of GO, cut08: the second line was
            // typed before the read-back question was shown, and is dropped.
            let actions = driver.flow.handleLines(["cutnow", "cut08"], at: driver.now, unixTime: FlowDriver.epoch + driver.now, latch: driver.latch)
            #expect(actions.contains(.armReminder))
            #expect(driver.flow.stage == .cutReadBack)
            #expect(!driver.flow.cutConfirmed)
            #expect(driver.flow.answers.map(\.word) == ["start00", "cutnow"])

            // Lines that open no new question are all handled.
            var restore = FlowDriver()
            restore.toRestorePrompt()
            _ = restore.flow.handleLines(["", "nonsense", "restorenow", "restored00"], at: restore.now, unixTime: FlowDriver.epoch + restore.now, latch: restore.latch)
            #expect(restore.flow.stage == .restoreReadBack)
            #expect(!restore.flow.restoreConfirmed)
        }

        @Test("Only answer words are recorded; any other text the owner types is never kept")
        func answersKeepNoOtherText() {
            var driver = FlowDriver()
            driver.toCutPrompt()
            driver.type("/Users/someone/secret")
            driver.type("cutnow")
            let recorded = driver.flow.answers.map { "\($0.word ?? "-") \($0.outcome)" }.joined(separator: "\n")
            #expect(!recorded.contains("secret"))
            #expect(!recorded.contains("/Users"))
            #expect(driver.flow.answers.contains { $0.word == nil })
        }

        @Test("Nothing happens after the end")
        func nothingAfterTheEnd() {
            var driver = FlowDriver()
            driver.toGo()
            driver.type("cutfail")
            driver.type("other")
            #expect(driver.flow.stage == .ended)
            #expect(driver.type("00").isEmpty)
            #expect(driver.sleep().isEmpty)
            #expect(driver.send(.signal(SIGINT, at: driver.now)).isEmpty)
            #expect(driver.reminderTick().isEmpty)
        }

        // MARK: The outcome

        @Test("A cut that does not end after the restore: CHECK RECOVERY FIRST and exit 3")
        func didNotResume() {
            var driver = FlowDriver()
            driver.after = { _ in .cut }
            driver.toAfter()
            driver.run(until: .ended, limit: 400)
            let outcome = driver.outcome
            #expect(outcome.verdict?.title == "discharging, did not resume")
            #expect(outcome.exitStatus == 3)
            #expect(outcome.recoveryReason != nil)
        }

        @Test("No effect while the cut is held: no effect observed, exit 0")
        func noEffect() {
            var driver = FlowDriver()
            driver.held = { _ in .charging }
            driver.after = { _ in .charging }
            driver.toAfter()
            driver.run(until: .ended, limit: 400)
            #expect(driver.outcome.verdict?.title == "no effect observed")
            #expect(driver.outcome.exitStatus == 0)
        }

        @Test("The refusal function: root, or no terminal for input or output")
        func refusal() {
            #expect(ManualCut.refusal(effectiveUserIsRoot: false, inputIsTerminal: true, outputIsTerminal: true) == nil)
            #expect(ManualCut.refusal(effectiveUserIsRoot: true, inputIsTerminal: true, outputIsTerminal: true)?.contains("root") == true)
            #expect(ManualCut.refusal(effectiveUserIsRoot: false, inputIsTerminal: false, outputIsTerminal: true)?.contains("terminal") == true)
            #expect(ManualCut.refusal(effectiveUserIsRoot: false, inputIsTerminal: true, outputIsTerminal: false)?.contains("terminal") == true)
        }

        @Test("The banners: RESTORE CHIE NOW reads first; after a confirmed restore, never RESTORE CHIE NOW")
        func bannerText() {
            let now = ManualCut.text(.restoreChieNow)
            #expect(now.hasPrefix("RESTORE CHIE NOW"))
            #expect(now.contains(ManualCut.ToolCommand.read))
            #expect(now.contains("Never write before this read"))
            let early = ManualCut.text(.afterReadingsEndedEarly)
            #expect(!early.contains("RESTORE CHIE NOW"))
            #expect(early.contains("ended early"))
            #expect(early.contains("check recovery"))
            #expect(ManualCut.text(.restoreChieFirst).hasPrefix("RESTORE CHIE FIRST"))
            #expect(ManualCut.text(.noGo("x")).hasPrefix("NO GO"))
        }
    }
}

/// A thread-safe counter for closures the tests hand out.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
