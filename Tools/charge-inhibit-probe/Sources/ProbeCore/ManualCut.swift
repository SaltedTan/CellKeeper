import Foundation

/// Research note 11's manual adapter cut: the owner reads and writes the
/// SMC key `CHIE` by hand, with an external tool in a second terminal, and
/// the probe only observes (docs/research/11-smc-adapter-cut.md).
///
/// The probe never touches the SMC and never runs the tool or any other
/// process for this test: it prints the tool's commands, from
/// ``ToolCommand``, for the owner to type, and asks the owner what each read
/// showed (``ManualCutQuestion``). What it knows of `CHIE` is only what the
/// owner types.
public enum ManualCut {
    /// The owner's tool (note 11 §4.1): smcFanControl's `smc` command,
    /// built outside the repository. The one place the probe keeps its
    /// commands. The probe prints them; it never runs them.
    public enum ToolCommand {
        /// Where the owner runs them (terminal B).
        public static let directory = "~/smc-test/smc-command"
        public static let read = "./smc -k CHIE -r"
        public static let cut = "sudo ./smc -k CHIE -w 08"
        public static let restore = "sudo ./smc -k CHIE -w 00"
    }

    /// The research note that describes the test.
    public static let note = "docs/research/11-smc-adapter-cut.md"

    /// Seconds the probe waits for the owner's first read (`start00`).
    public static let firstReadWait = 120.0
    /// Seconds the CUT prompt waits for `cutnow`.
    public static let cutPromptWait = 120.0
    /// Seconds from the cut mark that the probe waits for `cut08`; inside
    /// the hold, which is at least 165 s.
    public static let cutReadBackWait = 90.0
    /// Seconds between reminders of an open restore request.
    public static let reminderInterval = 20.0
    /// How often the reminder's own timer looks at the run.
    public static let reminderTick = 1.0

    /// The idle-sleep assertion's timeout: the run's bounded parts plus 30
    /// minutes for the owner's restore (note 11 §4.4 step 3).
    public static func idleSleepTimeout(hold: Int) -> Int {
        Int(firstReadWait) + ProbeSchedule.baselineLimit + Int(cutPromptWait) + hold
            + ProbeSchedule.after + ProbeSchedule.lateResumeWatch + 30 * 60
    }

    /// "charge-inhibit-probe-manual-adapter-cut-20261020-101500.txt";
    /// `.gitignore` covers `charge-inhibit-probe-*.txt`.
    public static func reportFileName(stamp: String) -> String {
        "charge-inhibit-probe-manual-adapter-cut-\(stamp).txt"
    }

    /// Why `watch` refuses to start, or nil (note 11 §4.3, §4.4 step 1):
    /// nothing in it needs privileges, so it refuses root; and it refuses
    /// unless its input and its output are a terminal, so that no script
    /// can answer for the owner and every prompt is shown to the owner.
    public static func refusal(effectiveUserIsRoot: Bool, inputIsTerminal: Bool, outputIsTerminal: Bool) -> String? {
        if effectiveUserIsRoot {
            return """
                charge-inhibit-probe watch must not run as root: nothing in it needs \
                privileges. Start it without sudo; only the tool's two writes use sudo, \
                in your other terminal. Nothing was created.
                """
        }
        if !inputIsTerminal || !outputIsTerminal {
            return """
                charge-inhibit-probe watch must be started from a terminal, with its \
                input and output on that terminal: only the owner may answer its \
                questions, and every prompt must reach the owner. Nothing was created.
                """
        }
        return nil
    }

    /// The read-first steps (note 11 §7.1, step 1), as the probe prints
    /// them whenever the state of `CHIE` is unknown.
    public static let readFirstSteps = """
        First clear anything typed but not run in terminal B (Ctrl-C at its \
        prompt). Then, in \(ToolCommand.directory), read CHIE: \(ToolCommand.read). \
        Never write before this read; if it has not returned within about 10 s, \
        press Ctrl-C and treat it as anything else. (bytes 08): run the restore \
        (\(ToolCommand.restore)) and read again. (bytes 00): nothing to restore; \
        write nothing. Anything else (another value, an error, a hang, output you \
        do not trust): write nothing.
        """

    /// The recovery steps (note 11 §7.1), for the report and the console.
    public static let recoverySteps = """
        \(readFirstSteps) Recovery counts only when a read shows (bytes 00) and \
        the battery menu shows the power adapter again. If CHIE reads 00 but \
        the Mac still runs from its battery, wait a minute and check the adapter \
        and its outlet; write nothing else. If adapter power still does not \
        show, save your work, then try, in order, unplugging and replugging the \
        adapter, restarting, and shutting down for about 30 seconds, reading \
        CHIE after each and restoring it if it reads 08 (none is known to clear \
        CHIE). If adapter power still does not come back, shut the Mac down \
        before the battery runs low, and send this report and what each read \
        printed to the lead (\(note) §7.1).
        """

    /// The will-sleep handler for `watch`: it records the sleep, and when it
    /// began, in the sleep log (lock-free, no I/O), then allows the sleep
    /// at once: the probe holds nothing that must be released before a
    /// sleep, and cannot restore `CHIE` (note 11 §4.7). It runs on the
    /// sleep queue.
    public static func willSleepHandler(log: SleepLog, now: @escaping @Sendable () -> Double) -> @Sendable (_ acknowledge: () -> Void) -> Void {
        { acknowledge in
            log.record(at: now())
            acknowledge()
        }
    }

    /// What the console shows for a banner.
    public static func text(_ banner: ManualCutFlow.Banner) -> String {
        switch banner {
        case .restoreChieNow:
            return """
                RESTORE CHIE NOW — if you ran the cut, or are not sure. The probe cannot know. \
                \(readFirstSteps) Then check recovery: a read shows (bytes 00) and the battery menu \
                shows the power adapter again (\(note) §7.1).
                """
        case .restoreChieFirst:
            return """
                RESTORE CHIE FIRST: the Mac slept after the CUT prompt, and the state of CHIE is \
                unknown. Follow the read-first steps below.
                """
        case let .withdrawn(reason):
            return "The CUT prompt is withdrawn: do not run the cut. (\(reason).)"
        case let .noGo(reason):
            return "NO GO — do not run the cut. (\(reason).)"
        case .afterReadingsEndedEarly:
            return """
                The after readings ended early. The restore was confirmed by your read; still \
                check recovery: the battery menu must show the power adapter, and charging, \
                again. If not, follow \(note) §7.1.
                """
        }
    }

    /// What the console shows as soon as the end is settled, before the
    /// report is saved (code review r5 of #101), so that the settled
    /// guidance, not an earlier banner it may have overturned, is on screen
    /// even if the save hangs: for exit 3, CHECK RECOVERY FIRST with the
    /// reason and the recovery steps, which begin with the read-first steps;
    /// otherwise one line with the verdict and the exit status.
    public static func settledBanner(_ outcome: ManualCutOutcome, status: Int32) -> String {
        if status == 3 {
            let reason = outcome.recoveryReason ?? "The run ended with exit status 3."
            return "\nCHECK RECOVERY FIRST: \(reason) \(recoverySteps)"
        }
        let result: String
        if let verdict = outcome.verdict {
            result = "verdict: \(verdict.title)"
        } else if let refusal = outcome.refusal {
            result = "refused: \(refusal)"
        } else {
            result = "no verdict"
        }
        return "\nThe run is over (\(result)); exit status \(status). Saving the report."
    }
}

/// One of the owner's questions, and its answer words (note 11 §4.4, the
/// table "Questions and answer words"). No word answers more than one
/// question.
public enum ManualCutQuestion: String, Sendable, Equatable, CaseIterable {
    case firstRead = "first read"
    case cut = "CUT"
    case cutReadBack = "cut read-back"
    case restore = "RESTORE"
    case restoreReadBack = "restore read-back"
    case readFirst = "read-first"
    case recheck = "re-check"

    /// Every word that answers this question.
    public var words: [String] {
        switch self {
        case .firstRead: ["start00"]
        case .cut: ["cutnow"]
        case .cutReadBack: ["cut08", "cutfail"]
        case .restore: ["restorenow"]
        case .restoreReadBack: ["restored00", "restorefail"]
        case .readFirst: ["08", "00", "other"]
        case .recheck: ["recheck00", "recheckfail"]
        }
    }

    /// A restore request, which the reminder repeats until the owner has
    /// confirmed recovery.
    public var isRestoreRequest: Bool {
        switch self {
        case .restore, .restoreReadBack, .readFirst, .recheck: true
        case .firstRead, .cut, .cutReadBack: false
        }
    }

    /// The text the probe shows; a reminder shows it again, with its
    /// answer words.
    public var prompt: String {
        let commands = ManualCut.ToolCommand.self
        switch self {
        case .firstRead:
            return """
                FIRST READ. In terminal B (\(commands.directory)), run: \(commands.read)
                Type start00 here only if it printed [hex_] and (bytes 00). Anything else, or no \
                answer within \(Int(ManualCut.firstReadWait)) s, and the probe stops; nothing has been written.
                """
        case .cut:
            return """
                CUT. Do not type the cut command yet. Type cutnow here, then wait for the GO line.
                Only after GO: write down the restore time it shows (or set a phone timer), then in \
                terminal B run \(commands.cut), then \(commands.read).
                (Waiting up to \(Int(ManualCut.cutPromptWait)) s for cutnow.)
                """
        case .cutReadBack:
            return """
                After the cut, read it in terminal B: \(commands.read)
                Type cut08 if it shows (bytes 08); cutfail if it shows anything else.
                """
        case .restore:
            return """
                RESTORE CHIE NOW. First clear anything typed but not run in terminal B. Type \
                restorenow here, then at once run in terminal B: \(commands.restore)
                """
        case .restoreReadBack:
            return """
                Now read it back in terminal B: \(commands.read)
                Type restored00 if it shows (bytes 00); restorefail if it shows anything else.
                """
        case .readFirst:
            return """
                READ CHIE FIRST. \(ManualCut.readFirstSteps)
                Then type what the read showed: 08 for (bytes 08), 00 for (bytes 00), other for \
                anything else.
                """
        case .recheck:
            return """
                Run the restore now in terminal B: \(commands.restore)
                then read again: \(commands.read)
                Type recheck00 if that read shows (bytes 00); recheckfail if it shows anything else.
                """
        }
    }
}

/// The owner's manual adapter cut, as a pure state machine (note 11
/// §4.4–§4.8): the questions and their answer words, supersession, the
/// reminder, the GO/NO GO gate, the read-first path, sleep, signals, early
/// stops, timeouts, and how the run ends. The executable feeds it events
/// (``Event``) under one lock and performs the actions it returns
/// (``Action``), in order; nothing here does I/O.
public struct ManualCutFlow: Sendable {
    public enum Stage: String, Sendable, Equatable {
        case notStarted
        case firstRead
        case baseline
        case cutPrompt
        case cutReadBack
        /// The cut is confirmed; no question is open until the hold ends.
        case hold
        case restorePrompt
        case restoreReadBack
        case readFirst
        case recheck
        /// The restore is confirmed; the after readings run.
        case after
        case ended
    }

    /// A moment on the run's clock and the wall clock.
    public struct Moment: Sendable, Equatable {
        public var time: Double
        public var unixTime: Double

        public init(time: Double, unixTime: Double) {
            self.time = time
            self.unixTime = unixTime
        }
    }

    public enum Event: Sendable, Equatable {
        case begin(at: Double)
        /// A line the owner typed, read after the latest discard.
        case line(String, at: Double, unixTime: Double)
        /// The main loop's clock: timeouts, the hold's end, the after
        /// readings' end.
        case tick(at: Double, unixTime: Double)
        /// A reading; the flow sets its phase from the marks.
        case reading(Sample)
        /// The console has written the prompt of question `generation`
        /// (``Action/publish(_:generation:)``).
        case published(generation: UInt64, at: Double)
        /// The console could not write an actionable message in full: the
        /// terminal is unusable (code review r2 of #101, must E).
        case consoleFailed(at: Double)
        /// The first SIGINT, SIGTERM or SIGHUP.
        case signal(Int32, at: Double)
        /// The reminder's own timer.
        case reminderTick(at: Double)
    }

    /// What the console shows when the run ends or a sleep is found.
    public enum Banner: Sendable, Equatable {
        /// Any end after the CUT prompt without a confirmed restore.
        case restoreChieNow
        /// After a wake that follows the CUT prompt.
        case restoreChieFirst
        /// The CUT prompt withdrawn before the mark.
        case withdrawn(String)
        /// At the mark, freshness failed: do not run the cut.
        case noGo(String)
        /// A signal after a confirmed restore.
        case afterReadingsEndedEarly
    }

    public enum Action: Sendable, Equatable {
        /// Discard pending terminal input: the terminal's unread input,
        /// including an unfinished line, the probe's own buffer, and any
        /// line read but not yet handled. Comes once a new question's
        /// prompt has been written, just before input becomes eligible.
        case discardInput
        /// Publish a new question (code review r1 of #101, must 3): queue its
        /// prompt; input is not eligible until the console has written it
        /// and says so (``Event/published(generation:at:)``), and then
        /// pending input is discarded first.
        case publish(ManualCutQuestion, generation: UInt64)
        /// A reminder: the open question again, with the bell. Not a new
        /// question: it changes no generation and discards nothing.
        case remind(ManualCutQuestion)
        case say(String)
        case banner(Banner)
        /// Arm the reminder's own timer (``Event/reminderTick(at:)``).
        case armReminder
        /// The GO line, with the clock time (Unix) by which to restore.
        case go(restoreBy: Double)
        /// The run is over; ``ManualCutFlow/ending`` says why.
        case end
    }

    /// Why the run ended.
    public enum Ending: Sendable, Equatable {
        /// Before the CUT prompt: the first read was not confirmed.
        case refused(String)
        /// Before the CUT prompt, without a refusal: a failed baseline, a
        /// signal or a sleep. Nothing was written.
        case endedBeforeCut(String)
        /// After the CUT prompt, without a confirmed restore.
        case unconfirmedRecovery(String)
        /// A signal after a confirmed restore ended the after readings.
        case afterReadingsEndedEarly(String)
        /// After the CUT prompt, the terminal could not show the probe's
        /// output, whether or not a restore was confirmed.
        case terminalUnusable(String)
        /// The after readings ran their course.
        case completed
    }

    /// An answer the owner typed, as the report records it: only answer
    /// words are kept verbatim; other text is never recorded.
    public struct Answer: Sendable, Equatable {
        public var time: Double
        public var question: ManualCutQuestion
        /// The word, or nil if the line was not one of the question's
        /// words, or no line came.
        public var word: String?
        /// What the probe did with it.
        public var outcome: String

        public init(time: Double, question: ManualCutQuestion, word: String?, outcome: String) {
            self.time = time
            self.question = question
            self.word = word
            self.outcome = outcome
        }
    }

    /// Something that happened, for the report.
    public struct LogEntry: Sendable, Equatable {
        public var time: Double
        public var text: String
    }

    public let hold: Int
    public let criteria: Criteria
    public private(set) var stage: Stage = .notStarted
    public private(set) var samples: [Sample] = []
    public private(set) var answers: [Answer] = []
    /// What happened, and when, for the report.
    public private(set) var log: [LogEntry] = []
    public private(set) var baselineStart: Double?
    public private(set) var cutPromptAt: Double?
    public private(set) var cutMark: Moment?
    public private(set) var cutConfirmedAt: Double?
    /// The latest restore time: `restorenow`, or read-first's `08` or `00`.
    public private(set) var restoreMark: Moment?
    /// When recovery was confirmed.
    public private(set) var restoreConfirmedAt: Double?
    /// The word that confirmed it: `restored00`, `00` or `recheck00`.
    public private(set) var restoreConfirmedBy: String?
    /// When an early stop ended the hold, and why.
    public private(set) var earlyStop: String?
    /// Will-sleep notices after the run began, on the run's clock.
    public private(set) var sleeps: [Double] = []
    /// Why the read-first steps were first shown, if they were.
    public private(set) var readFirstReason: String?
    /// How often, by the owner's answers, the restore command was run
    /// (`restorenow`, read-first `08`).
    public private(set) var restoreCommandsRun = 0
    /// Whether the owner answered read-first's `00`: nothing to restore.
    public private(set) var answeredNothingToRestore = false
    public private(set) var reminderArmed = false
    /// When the open restore request was last shown.
    public private(set) var lastShownAt: Double?
    public private(set) var ending: Ending?
    /// How many of the sleep log's occurrences the flow has seen.
    public private(set) var seenSleeps = 0
    /// Whether the sleep log overflowed: every confirmation is then
    /// invalid, and the run inconclusive.
    public private(set) var sleepLogOverflowed = false
    /// How many occurrences the flow had seen when the restore's
    /// confirmation was accepted.
    public private(set) var restoreConfirmedSleeps: Int?
    /// Why the end of the run found that a confirmation of recovery does
    /// not count (``reconcile(with:drained:)``), or nil.
    public private(set) var confirmationInvalidated: String?
    /// The first thing that kept the probe's output from the owner, if
    /// any: a write to the terminal that failed, at any point of the run,
    /// the run's end included, or, at the end, a terminal that did not take
    /// the last output within its bound (code review r3 of #101, should 3).
    /// After the CUT prompt it makes the run end with 3 and CHECK RECOVERY
    /// FIRST (``ManualCutOutcome``).
    public private(set) var outputProblem: String?
    /// The number of the latest question published.
    public private(set) var questionGeneration: UInt64 = 0
    /// Whether the owner's lines may answer the open question: only once
    /// its prompt has been written and pending input discarded.
    public private(set) var inputEligible = false
    /// How many occurrences the flow had seen when the open question was
    /// published: an answer counts only if no sleep came since.
    public private(set) var questionSleeps = 0
    private var askedAt: Double?
    /// Whether any held reading showed the battery discharging (for the
    /// after readings, as in note 10).
    private var discharged = false

    public init(hold: Int, criteria: Criteria = .standard) {
        self.hold = hold
        self.criteria = criteria
    }

    /// The question open now, if any.
    public var openQuestion: ManualCutQuestion? {
        switch stage {
        case .firstRead: .firstRead
        case .cutPrompt: .cut
        case .cutReadBack: .cutReadBack
        case .restorePrompt: .restore
        case .restoreReadBack: .restoreReadBack
        case .readFirst: .readFirst
        case .recheck: .recheck
        case .notStarted, .baseline, .hold, .after, .ended: nil
        }
    }

    /// Whether the probe takes readings now.
    public var wantsReadings: Bool {
        switch stage {
        case .notStarted, .firstRead, .ended: false
        default: true
        }
    }

    /// Whether the owner confirmed the cut's read-back (`cut08`).
    public var cutConfirmed: Bool { cutConfirmedAt != nil }

    /// Whether the owner confirmed recovery.
    public var restoreConfirmed: Bool { restoreConfirmedAt != nil }

    /// Whether a sleep came after the CUT prompt was shown.
    public var sleptAfterCutPrompt: Bool {
        guard let prompt = cutPromptAt else { return false }
        return sleeps.contains { $0 >= prompt }
    }

    /// The phase of a reading at `time`, from the marks.
    public func phase(at time: Double) -> Sample.Phase {
        if let restore = restoreMark, time >= restore.time { return .after }
        if let cut = cutMark, time >= cut.time { return .held }
        if let prompt = cutPromptAt, time >= prompt { return .preCut }
        return .baseline
    }

    /// Handles one event and returns the actions to perform, in order.
    ///
    /// `sleeps` is the sleep log as read inside the same critical section
    /// (code review r1 of #101, must 2; r2, must D). Each occurrence the
    /// flow has not seen is delivered first, in order, so it supersedes the
    /// open question before any answer, prompt or reminder of this event: an
    /// answer typed before a sleep is never accepted after it.
    public mutating func handle(_ event: Event, sleeps: SleepLog.Snapshot) -> [Action] {
        guard stage != .ended else {
            // An ended run takes no more events, but a write of its output
            // that failed still counts (code review r3 of #101, should 3).
            if case let .consoleFailed(time) = event {
                recordOutputProblem("a write of the probe's output to the terminal failed after the run ended", at: time)
            }
            return []
        }
        var actions: [Action] = []
        let now = Self.time(of: event)
        for time in sleeps.times.dropFirst(seenSleeps) {
            seenSleeps += 1
            actions += slept(at: time, now: max(now, time))
            guard stage != .ended else { return actions }
        }
        if sleeps.overflowed, !sleepLogOverflowed {
            sleepLogOverflowed = true
            actions += logOverflowed(now: now)
            guard stage != .ended else { return actions }
        }
        return actions + handleEvent(event)
    }

    /// When `event` happened, on the run's clock.
    static func time(of event: Event) -> Double {
        switch event {
        case let .begin(time), let .line(_, time, _), let .tick(time, _), let .published(_, time), let .consoleFailed(time),
             let .signal(_, time), let .reminderTick(time): time
        case let .reading(sample): sample.time
        }
    }

    private mutating func handleEvent(_ event: Event) -> [Action] {
        switch event {
        case let .begin(time):
            guard stage == .notStarted else { return [] }
            note(time, "watch started; the first read was asked for")
            return ask(.firstRead, at: time)
        case let .line(text, time, unixTime):
            return answer(text, at: time, unixTime: unixTime)
        case let .tick(time, unixTime):
            return tick(at: time, unixTime: unixTime)
        case let .reading(sample):
            return reading(sample)
        case let .published(generation, _):
            // Only the prompt of the open question makes input eligible;
            // pending input is discarded first, in the same critical section.
            guard generation == questionGeneration, openQuestion != nil, !inputEligible else { return [] }
            inputEligible = true
            return [.discardInput]
        case let .consoleFailed(time):
            // The question never becomes answerable; the run ends, and the
            // report is saved before the probe exits.
            let reason = "the terminal could not show the probe's output (a write to it failed)"
            recordOutputProblem(reason, at: time)
            if cutPromptAt == nil {
                return end(.endedBeforeCut(reason), at: time)
            }
            return end(.terminalUnusable(reason), at: time)
        case let .signal(number, time):
            return signal(number, at: time)
        case let .reminderTick(time):
            return reminderTick(at: time)
        }
    }

    /// Hands the flow the owner's lines read in one batch, in order. A line
    /// read after one that opened a new question meets that question before
    /// its prompt is written, while input is not eligible, and is dropped:
    /// an answer typed ahead, or meant for an earlier question, never
    /// carries over.
    public mutating func handleLines(_ lines: [String], at time: Double, unixTime: Double, sleeps: SleepLog.Snapshot) -> [Action] {
        var all: [Action] = []
        for line in lines {
            guard stage != .ended else { break }
            all += handle(.line(line, at: time, unixTime: unixTime), sleeps: sleeps)
        }
        return all
    }

    // MARK: Questions

    private mutating func ask(_ question: ManualCutQuestion, at time: Double) -> [Action] {
        stage = Self.stage(for: question)
        askedAt = time
        lastShownAt = time
        questionSleeps = seenSleeps
        questionGeneration += 1
        inputEligible = false
        return [.publish(question, generation: questionGeneration)]
    }

    static func stage(for question: ManualCutQuestion) -> Stage {
        switch question {
        case .firstRead: .firstRead
        case .cut: .cutPrompt
        case .cutReadBack: .cutReadBack
        case .restore: .restorePrompt
        case .restoreReadBack: .restoreReadBack
        case .readFirst: .readFirst
        case .recheck: .recheck
        }
    }

    private mutating func answer(_ text: String, at time: Double, unixTime: Double) -> [Action] {
        guard let question = openQuestion else { return [] }
        // A line read before the question's prompt was written, and pending
        // input discarded, answers nothing.
        guard inputEligible else { return [] }
        // An answer counts only for a question published since the latest
        // sleep (``handle(_:sleeps:)`` delivers a sleep first).
        guard questionSleeps == seenSleeps else { return [] }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty line (Return alone) is not an answer to anything.
        guard !typed.isEmpty else { return [] }
        let word = question.words.contains(typed) ? typed : nil
        func record(_ outcome: String) {
            answers.append(Answer(time: time, question: question, word: word, outcome: outcome))
        }
        switch question {
        case .firstRead:
            guard word == "start00" else {
                record("not start00: the probe refused to start")
                return end(.refused("the owner did not confirm that CHIE read [hex_] and (bytes 00) before the baseline"), at: time)
                    + [.say("Not start00: the probe stops. Nothing has been written.")]
            }
            record("CHIE read 00 at the start, by the owner's read")
            stage = .baseline
            baselineStart = time
            note(time, "the owner confirmed CHIE read [hex_] and (bytes 00) (start00); the baseline began")
            return [.discardInput, .say("""
                Baseline: at least \(ProbeSchedule.baseline) s of readings, until they show 2 battery updates \
                (at most \(ProbeSchedule.baselineLimit) s). Type nothing in terminal B.
                """)]
        case .cut:
            guard word == "cutnow" else {
                record("not an answer; the CUT prompt stays")
                return [.say("Not an answer: type cutnow, then wait for the GO line.")]
            }
            record("the cut mark")
            return markCut(at: time, unixTime: unixTime)
        case .cutReadBack:
            guard word == "cut08" else {
                record(word == "cutfail" ? "the cut's read-back did not show 08" : "taken as cutfail")
                return toReadFirst("the owner did not confirm the cut's read-back (\(word ?? "not cut08"))", at: time)
            }
            record("the cut read back 08, by the owner's read")
            cutConfirmedAt = time
            stage = .hold
            note(time, "the owner confirmed the cut read back (bytes 08) (cut08)")
            return [.discardInput, .say("""
                Cut confirmed by your read (cut08). The hold runs \(hold) s from your cutnow, and the \
                probe rings for the restore. Leave the adapter and everything else as it is.
                """)]
        case .restore:
            guard word == "restorenow" else {
                record("not an answer; the RESTORE prompt stays")
                return [.say("Not an answer: type restorenow, then run the restore at once.")]
            }
            record("the restore mark")
            restoreMark = Moment(time: time, unixTime: unixTime)
            restoreCommandsRun += 1
            note(time, "the restore mark (restorenow); the owner runs the restore now")
            return ask(.restoreReadBack, at: time)
        case .restoreReadBack:
            guard word == "restored00" else {
                record(word == "restorefail" ? "the restore's read-back did not show 00" : "taken as restorefail")
                return toReadFirst("the owner did not confirm the restore's read-back (\(word ?? "not restored00"))", at: time)
            }
            record("the restore read back 00, by the owner's read")
            return confirmRestore(at: time, word: "restored00")
        case .readFirst:
            switch word {
            case "08":
                record("CHIE read 08: the owner runs the restore now")
                restoreMark = Moment(time: time, unixTime: unixTime)
                restoreCommandsRun += 1
                note(time, "read-first: CHIE read (bytes 08); the owner runs the restore (08)")
                return ask(.recheck, at: time)
            case "00":
                record("CHIE read 00: nothing to restore, nothing written")
                restoreMark = Moment(time: time, unixTime: unixTime)
                answeredNothingToRestore = true
                note(time, "read-first: CHIE read (bytes 00); nothing to restore, nothing written (00)")
                return confirmRestore(at: time, word: "00")
            case "other":
                record("CHIE read neither 00 nor 08: write nothing, follow the recovery steps")
                return end(.unconfirmedRecovery("""
                    the owner's read of CHIE showed neither (bytes 00) nor (bytes 08), or could \
                    not be trusted (other)
                    """), at: time) + [.banner(.restoreChieNow)]
            default:
                record("not an answer; the read-first question stays")
                return [.say("Not an answer: type 08, 00 or other, as the read showed.")]
            }
        case .recheck:
            guard word == "recheck00" else {
                record(word == "recheckfail" ? "the re-check did not show 00" : "taken as recheckfail")
                return toReadFirst("the owner did not confirm the re-check after the restore (\(word ?? "not recheck00"))", at: time)
            }
            record("the re-check read 00, by the owner's read")
            return confirmRestore(at: time, word: "recheck00")
        }
    }

    // MARK: The cut and the restore

    private mutating func markCut(at time: Double, unixTime: Double) -> [Action] {
        let baseline = samples.filter { $0.phase == .baseline }
        let preCut = samples.filter { $0.phase == .preCut }
        if let problem = Verdict.cutFreshnessProblem(
            baseline: baseline, preCut: preCut, at: time, unixTime: unixTime, criteria: criteria, terms: .manualCut
        ) {
            note(time, "cutnow, then NO GO: \(problem)")
            return end(.unconfirmedRecovery("NO GO at the cut mark: \(problem)"), at: time)
                + [.banner(.noGo(problem)), .banner(.restoreChieNow)]
        }
        cutMark = Moment(time: time, unixTime: unixTime)
        note(time, "the cut mark (cutnow); the reminder armed, then GO")
        // The reminder first, and only then the GO line (note 11 §4.4 step 7).
        reminderArmed = true
        return [.armReminder, .go(restoreBy: unixTime + Double(hold))] + ask(.cutReadBack, at: time)
    }

    /// The restore request at the hold's end, or after an early stop: the
    /// RESTORE prompt only after a confirmed cut with no sleep since the CUT
    /// prompt; read-first otherwise.
    private mutating func restoreRequest(at time: Double, why: String) -> [Action] {
        if cutConfirmed, !sleptAfterCutPrompt {
            note(time, "\(why); the RESTORE prompt")
            return ask(.restore, at: time)
        }
        return toReadFirst(why, at: time)
    }

    private mutating func toReadFirst(_ reason: String, at time: Double) -> [Action] {
        if readFirstReason == nil { readFirstReason = reason }
        note(time, "\(reason); the read-first steps")
        var actions: [Action] = []
        if !reminderArmed {
            reminderArmed = true
            actions.append(.armReminder)
        }
        return actions + ask(.readFirst, at: time)
    }

    private mutating func confirmRestore(at time: Double, word: String) -> [Action] {
        restoreConfirmedAt = time
        restoreConfirmedBy = word
        restoreConfirmedSleeps = seenSleeps
        stage = .after
        note(time, "the owner confirmed recovery (\(word)); the after readings")
        return [.discardInput, .say("""
            Restore confirmed by your read (\(word)). Readings continue for \(ProbeSchedule.after) s or more; \
            Ctrl-C ends them early.
            """)]
    }

    // MARK: Time

    private mutating func tick(at time: Double, unixTime: Double) -> [Action] {
        switch stage {
        case .firstRead:
            guard let askedAt, time - askedAt >= ManualCut.firstReadWait else { return [] }
            answers.append(Answer(
                time: time, question: .firstRead, word: nil,
                outcome: "no answer in \(Int(ManualCut.firstReadWait)) s: the probe refused to start"
            ))
            return end(.refused("no answer to the first read within \(Int(ManualCut.firstReadWait)) s"), at: time)
                + [.say("No answer: the probe stops. Nothing has been written.")]
        case .baseline:
            guard let start = baselineStart, time > start + Double(ProbeSchedule.baselineLimit) + 0.001 else { return [] }
            return finishBaseline(at: time, unixTime: unixTime)
        case .cutPrompt:
            guard let shown = cutPromptAt, time - shown >= ManualCut.cutPromptWait else { return [] }
            let reason = "no cutnow within \(Int(ManualCut.cutPromptWait)) s of the CUT prompt"
            answers.append(Answer(time: time, question: .cut, word: nil, outcome: "no answer: the CUT prompt was withdrawn"))
            note(time, reason)
            return end(.unconfirmedRecovery(reason), at: time)
                + [.banner(.withdrawn(reason)), .banner(.restoreChieNow)]
        case .cutReadBack:
            guard let cut = cutMark, time - cut.time >= ManualCut.cutReadBackWait else { return [] }
            answers.append(Answer(
                time: time, question: .cutReadBack, word: nil,
                outcome: "no answer in \(Int(ManualCut.cutReadBackWait)) s: taken as cutfail"
            ))
            return toReadFirst("no cut08 within \(Int(ManualCut.cutReadBackWait)) s of the cut mark", at: time)
        case .hold:
            guard let cut = cutMark, time >= cut.time + Double(hold) else { return [] }
            return restoreRequest(at: time, why: "the hold ended")
        case .after:
            guard afterReadingsDone(at: time) else { return [] }
            note(time, "the after readings ended")
            return end(.completed, at: time)
        case .notStarted, .restorePrompt, .restoreReadBack, .readFirst, .recheck, .ended:
            return []
        }
    }

    /// Whether the after readings are over, as note 10's watch decides:
    /// 180 s after the restore time, and up to 120 s more while charging
    /// has not resumed (not after an early stop).
    public func afterReadingsDone(at time: Double) -> Bool {
        guard let restore = restoreMark, restoreConfirmed else { return false }
        let window = restore.time + Double(ProbeSchedule.after)
        let limit = window + (earlyStop == nil ? Double(ProbeSchedule.lateResumeWatch) : 0)
        if time >= limit { return true }
        guard time >= window else { return false }
        let after = samples.filter { $0.time >= restore.time }
        if case .pending = Verdict.analyzeResume(after, releasedAt: restore.unixTime, batteryAllowed: discharged, criteria: criteria) {
            return false
        }
        return true
    }

    // MARK: Readings

    private mutating func reading(_ sample: Sample) -> [Action] {
        guard wantsReadings else { return [] }
        var sample = sample
        sample.phase = phase(at: sample.time)
        samples.append(sample)
        let unixTime = sample.unixTime ?? 0
        switch stage {
        case .baseline:
            let baseline = samples.filter { $0.phase == .baseline }
            // As note 10's baseline: stop at once on a reading that is not
            // steady charging, or clocks that cannot be trusted; otherwise
            // once it is long enough and shows 2 updates.
            if !Verdict.isChargingOnAdapter(sample, criteria: criteria)
                || Verdict.clockProblem(samples: baseline, events: [], criteria: criteria) != nil
                || Verdict.baselineReady(baseline, minimumSpan: Double(ProbeSchedule.baseline) - ProbeSchedule.lateness, criteria: criteria) {
                return finishBaseline(at: sample.time, unixTime: unixTime)
            }
            return []
        case .cutPrompt:
            guard sample.phase == .preCut else { return [] }
            if let problem = Verdict.cutFreshnessProblem(
                baseline: samples.filter { $0.phase == .baseline },
                preCut: samples.filter { $0.phase == .preCut },
                at: sample.time, unixTime: unixTime, criteria: criteria, terms: Self.withdrawTerms
            ) {
                note(sample.time, "the CUT prompt was withdrawn: \(problem)")
                return end(.unconfirmedRecovery("the CUT prompt was withdrawn before the cut mark: \(problem)"), at: sample.time)
                    + [.banner(.withdrawn(problem)), .banner(.restoreChieNow)]
            }
            return []
        case .cutReadBack, .hold:
            guard sample.phase == .held else { return [] }
            if Verdict.state(of: sample, criteria: criteria) == .discharging { discharged = true }
            guard let problem = Verdict.holdProblem(of: sample, criteria: criteria), let cut = cutMark else { return [] }
            let why = "the hold ended early, \(seconds(sample.time - cut.time)) after the cut mark, because \(problem)"
            earlyStop = why
            if stage == .cutReadBack {
                answers.append(Answer(time: sample.time, question: .cutReadBack, word: nil, outcome: "superseded by an early stop"))
                return toReadFirst("\(why), before the cut was confirmed", at: sample.time)
            }
            return restoreRequest(at: sample.time, why: why)
        case .restorePrompt, .restoreReadBack, .readFirst, .recheck:
            if sample.phase == .held, Verdict.state(of: sample, criteria: criteria) == .discharging { discharged = true }
            return []
        case .after:
            guard afterReadingsDone(at: sample.time) else { return [] }
            note(sample.time, "the after readings ended")
            return end(.completed, at: sample.time)
        case .notStarted, .firstRead, .ended:
            return []
        }
    }

    /// The freshness check's words while the CUT prompt waits: a failure
    /// withdraws the prompt.
    static let withdrawTerms: VerdictTerms = {
        var terms = VerdictTerms.manualCut
        terms.nothingCreated = "the probe withdrew the CUT prompt"
        return terms
    }()

    private mutating func finishBaseline(at time: Double, unixTime: Double) -> [Action] {
        let baseline = samples.filter { $0.phase == .baseline }
        if let problem = Verdict.baselineProblem(baseline, criteria: criteria, terms: .manualCutPrompt)
            ?? Verdict.baselineFreshnessProblem(baseline, at: time, unixTime: unixTime, criteria: criteria, terms: .manualCutPrompt) {
            note(time, "no CUT prompt: \(problem)")
            return end(.endedBeforeCut(problem), at: time)
                + [.say("No CUT prompt: \(problem). Nothing has been written; nothing to restore.")]
        }
        cutPromptAt = time
        note(time, "the CUT prompt was shown")
        return ask(.cut, at: time)
    }

    // MARK: Sleep, signals, the reminder

    /// A sleep that began at `time`, delivered at `now` from the log. A
    /// notice that arrives late is judged by when the sleep began: one that
    /// began before the owner's confirmation was accepted makes that
    /// confirmation not count.
    private mutating func slept(at time: Double, now: Double) -> [Action] {
        sleeps.append(time)
        let reason = """
            the system slept (kIOMessageSystemWillSleep at +\(seconds(time))) after the CUT \
            prompt, before a confirmed restore
            """
        switch stage {
        case .notStarted, .firstRead, .baseline:
            let reason = "the system slept (kIOMessageSystemWillSleep at +\(seconds(time))) before the CUT prompt"
            note(time, reason)
            return end(.endedBeforeCut(reason), at: now)
                + [.say("The Mac slept before the CUT prompt: the run ends. Nothing has been written; nothing to restore.")]
        case .after:
            if let confirmed = restoreConfirmedAt, time <= confirmed {
                // The sleep began before the confirmation was accepted.
                answers.append(Answer(
                    time: now, question: restoreConfirmedBy == "restored00" ? .restoreReadBack : restoreConfirmedBy == "00" ? .readFirst : .recheck,
                    word: nil, outcome: "the confirmation at +\(seconds(confirmed)) does not count: a sleep began before it"
                ))
                restoreConfirmedAt = nil
                restoreConfirmedBy = nil
                restoreConfirmedSleeps = nil
                return [.banner(.restoreChieFirst)] + toReadFirst(reason, at: now)
            }
            note(time, "the system slept after the restore was confirmed; the run is inconclusive")
            return [.say("The Mac slept after the restore was confirmed: the run is inconclusive. Check recovery when it ends.")]
        case .cutPrompt, .cutReadBack, .hold, .restorePrompt, .restoreReadBack, .readFirst, .recheck:
            if let question = openQuestion {
                answers.append(Answer(time: now, question: question, word: nil, outcome: "superseded by a sleep"))
            }
            return [.banner(.restoreChieFirst)] + toReadFirst(reason, at: now)
        case .ended:
            return []
        }
    }

    /// More sleeps than the log holds: their times are lost, so no
    /// confirmation can be trusted; a confirmation already given no longer
    /// counts, and the run is inconclusive (``ManualCutOutcome``).
    private mutating func logOverflowed(now: Double) -> [Action] {
        let reason = "more than \(SleepLog.capacity) sleeps came, so when they began is lost"
        note(now, reason)
        switch stage {
        case .notStarted, .firstRead, .baseline:
            return end(.endedBeforeCut(reason), at: now)
        case .after:
            restoreConfirmedAt = nil
            restoreConfirmedBy = nil
            restoreConfirmedSleeps = nil
            return [.banner(.restoreChieFirst)] + toReadFirst(reason, at: now)
        case .cutPrompt, .cutReadBack, .hold, .restorePrompt, .restoreReadBack, .readFirst, .recheck:
            return [.banner(.restoreChieFirst)] + toReadFirst(reason, at: now)
        case .ended:
            return []
        }
    }

    private mutating func signal(_ number: Int32, at time: Double) -> [Action] {
        let name = Self.signalName(number)
        switch stage {
        case .notStarted, .firstRead, .baseline:
            return end(.endedBeforeCut("stopped by \(name) at +\(seconds(time)), before the CUT prompt"), at: time)
                + [.say("\(name): stopping. Nothing has been written; nothing to restore.")]
        case .after:
            return end(.afterReadingsEndedEarly("\(name) at +\(seconds(time)) ended the after readings early, after a confirmed restore"), at: time)
                + [.banner(.afterReadingsEndedEarly)]
        case .cutPrompt, .cutReadBack, .hold, .restorePrompt, .restoreReadBack, .readFirst, .recheck:
            return end(.unconfirmedRecovery("stopped by \(name) at +\(seconds(time)), after the CUT prompt and before a confirmed restore"), at: time)
                + [.banner(.restoreChieNow)]
        case .ended:
            return []
        }
    }

    /// The reminder's own timer: at the hold's end it makes the restore
    /// request, even if the main loop is late; then it shows the open
    /// restore request again, with the bell, every
    /// ``ManualCut/reminderInterval`` seconds until the owner has confirmed
    /// recovery. A repeat is not a new question: it discards nothing and
    /// moves no mark.
    private mutating func reminderTick(at time: Double) -> [Action] {
        guard reminderArmed, !restoreConfirmed else { return [] }
        if stage == .hold || stage == .cutReadBack, let cut = cutMark, time >= cut.time + Double(hold) {
            if stage == .cutReadBack {
                answers.append(Answer(time: time, question: .cutReadBack, word: nil, outcome: "superseded at the hold's end"))
            }
            return restoreRequest(at: time, why: "the hold ended")
        }
        guard let question = openQuestion, question.isRestoreRequest,
              let shown = lastShownAt, time - shown >= ManualCut.reminderInterval
        else { return [] }
        lastShownAt = time
        return [.remind(question)]
    }

    // MARK: The end

    private mutating func end(_ ending: Ending, at time: Double) -> [Action] {
        self.ending = ending
        stage = .ended
        inputEligible = false
        // Prompts still queued for the console are superseded by the end.
        questionGeneration += 1
        note(time, "the run ended")
        return [.end]
    }

    private mutating func note(_ time: Double, _ text: String) {
        log.append(LogEntry(time: time, text: text))
    }

    /// The end's drain of the console did not complete within `bound`
    /// seconds: the terminal did not take the probe's last output, and the
    /// owner may not have seen it (code review r3 of #101, should 3). It
    /// works on an ended flow.
    public mutating func outputNotTaken(at time: Double, within bound: Double) {
        recordOutputProblem("the terminal did not take the probe's last output within \(seconds(bound))", at: time)
    }

    private mutating func recordOutputProblem(_ problem: String, at time: Double) {
        note(time, problem)
        if outputProblem == nil {
            outputProblem = problem
        }
    }

    static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        default: "signal \(number)"
        }
    }

    /// What a second signal does: the probe quits at once. Before the CUT
    /// prompt, as note 10's `run`: nothing to print, status 128 plus the
    /// signal. After it, the console shows again what the owner must do —
    /// RESTORE CHIE NOW before a confirmed restore, the check of recovery
    /// after one — and the status is the run's (``ManualCutOutcome``).
    public func secondSignal(_ number: Int32) -> (banner: Banner?, exitStatus: Int32) {
        guard cutPromptAt != nil else { return (nil, 128 + number) }
        let status = ManualCutOutcome.of(self, sleepNotices: []).exitStatus
        return (restoreConfirmed ? .afterReadingsEndedEarly : .restoreChieNow, status)
    }

    /// Whether, by the owner's answers, a restore was written. The probe
    /// observes no write; this is only what the answers say.
    public var restoreWrittenSummary: String {
        if restoreCommandsRun > 0 {
            let times = restoreCommandsRun == 1 ? "once" : "\(restoreCommandsRun) times"
            return """
                By the owner's answers, the restore command was run \(times) \
                (restorenow, or read-first 08). The probe observed no write.
                """
        }
        if answeredNothingToRestore {
            return "By the owner's answers, no restore was written: the owner's read showed (bytes 00) (read-first 00)."
        }
        if cutPromptAt == nil {
            return "Nothing was written: the run ended before the CUT prompt."
        }
        return "Unknown: no answer of the owner's says whether a restore was written."
    }

    /// The run as the verdict sees it: the cut mark only if the owner
    /// confirmed `cut08`, and the restore only once the owner confirmed
    /// recovery.
    public func probeRun(sleepNotices: [ProbeRun.SleepNotice]) -> ProbeRun {
        let cut: ProbeRun.Creation? = cutConfirmed ? cutMark.map {
            ProbeRun.Creation(time: $0.time, unixTime: $0.unixTime, result: 0, timeout: hold)
        } : nil
        let restore: ProbeRun.Release? = restoreConfirmed ? restoreMark.map {
            ProbeRun.Release(time: $0.time, unixTime: $0.unixTime, result: 0, attempts: 1, stillListed: false)
        } : nil
        return ProbeRun(manualCutSamples: samples, cutMark: cut, restore: restore, sleepNotices: sleepNotices)
    }

    /// The end of the run's last look at the sleep log (code review r2 of
    /// #101, must C), on every ending path, after the sleep queue has been
    /// drained, so that a notification in flight has finished: `drained`
    /// says whether that drain completed within its bound. It works on an
    /// ended flow too, which takes no more events.
    ///
    /// Occurrences the flow had not seen are recorded. A confirmation of
    /// recovery does not count, and the run ends with CHECK RECOVERY FIRST
    /// (``ManualCutOutcome``), if a sleep it had not seen when it accepted
    /// the confirmation began at or before that acceptance; if the log
    /// overflowed; or if the drain did not complete, since a notification
    /// may still be writing the log.
    public mutating func reconcile(with sleeps: SleepLog.Snapshot, drained: Bool) {
        let unseen = Array(sleeps.times.dropFirst(seenSleeps))
        if !unseen.isEmpty {
            self.sleeps += unseen
            for time in unseen {
                note(time, "a sleep found at the end of the run (kIOMessageSystemWillSleep at +\(seconds(time)))")
            }
        }
        seenSleeps = max(seenSleeps, sleeps.times.count)
        if sleeps.overflowed { sleepLogOverflowed = true }
        guard let confirmed = restoreConfirmedAt else { return }
        let seenAtAcceptance = restoreConfirmedSleeps ?? 0
        let reason: String?
        if !drained {
            reason = "the sleep queue could not be drained at the end, so a sleep may have begun before the confirmation"
        } else if sleeps.overflowed {
            reason = "more than \(SleepLog.capacity) sleeps came, so when they began is lost"
        } else if let time = sleeps.times.dropFirst(seenAtAcceptance).first(where: { $0 <= confirmed }) {
            reason = """
                a sleep began at +\(seconds(time)), before the confirmation at \
                +\(seconds(confirmed)) was accepted, and was found only at the end
                """
        } else {
            reason = nil
        }
        guard let reason else { return }
        confirmationInvalidated = reason
        answers.append(Answer(
            time: confirmed, question: restoreConfirmedBy == "restored00" ? .restoreReadBack : restoreConfirmedBy == "00" ? .readFirst : .recheck,
            word: nil, outcome: "the confirmation does not count: \(reason)"
        ))
        restoreConfirmedAt = nil
        restoreConfirmedBy = nil
        restoreConfirmedSleeps = nil
    }
}

/// How a manual adapter-cut run ends: its verdict, exit status, and
/// whether the report opens with CHECK RECOVERY FIRST (note 11 §4.4, exit
/// status; §4.6).
public struct ManualCutOutcome: Sendable, Equatable {
    /// Nil when the probe refused to start.
    public var verdict: Verdict?
    public var exitStatus: Int32
    /// Why the report opens with CHECK RECOVERY FIRST, or nil.
    public var recoveryReason: String?
    /// Why the probe refused to start, or nil.
    public var refusal: String?

    public init(verdict: Verdict?, exitStatus: Int32, recoveryReason: String?, refusal: String? = nil) {
        self.verdict = verdict
        self.exitStatus = exitStatus
        self.recoveryReason = recoveryReason
        self.refusal = refusal
    }

    /// The outcome of `flow` once it has ended (or, for a second signal,
    /// as it stands). Pure.
    ///
    /// - 1: refused before the CUT prompt (the first read).
    /// - 2: inconclusive, for a run that ended before the CUT prompt
    ///   without a refusal, or whose restore was confirmed and whose last
    ///   reading shows charging on adapter power.
    /// - 3: any end after the CUT prompt without a confirmed restore; and a
    ///   run with a confirmed restore whose last reading does not show
    ///   charging on adapter power (the report then opens with CHECK
    ///   RECOVERY FIRST), including note 10's "did not resume"; and, after
    ///   the CUT prompt, any run whose output the owner may not have seen
    ///   (``ManualCutFlow/outputProblem``), even after a confirmed restore.
    /// - 0: a verdict reached, recovery confirmed, and charging seen again.
    public static func of(_ flow: ManualCutFlow, sleepNotices: [ProbeRun.SleepNotice]) -> ManualCutOutcome {
        let outcome = ofRun(flow, sleepNotices: sleepNotices)
        // After the CUT prompt, output the owner may not have seen leaves the
        // report as the only channel: 3 and CHECK RECOVERY FIRST, even after
        // a confirmed restore (code review r3 of #101, should 3; decision E
        // of r2). The verdict on the readings stands.
        guard flow.cutPromptAt != nil, let problem = flow.outputProblem,
              outcome.exitStatus != 3 || outcome.recoveryReason == nil
        else { return outcome }
        return ManualCutOutcome(
            verdict: outcome.verdict, exitStatus: 3,
            recoveryReason: "The owner may not have seen the probe's last output: \(problem)."
        )
    }

    /// The outcome from the run's ending, readings and confirmations.
    private static func ofRun(_ flow: ManualCutFlow, sleepNotices: [ProbeRun.SleepNotice]) -> ManualCutOutcome {
        let criteria = flow.criteria
        let lastCharging = flow.samples.max(by: { $0.time < $1.time })
            .map { Verdict.isChargingOnAdapter($0, criteria: criteria) } ?? false
        let notCharging = "The last reading did not show charging on adapter power."
        let unconfirmed = "The owner has not confirmed that CHIE was restored"
        // After the CUT prompt, a sleep log that overflowed lost when sleeps
        // began, so no confirmation counts (code review r2 of #101, must D).
        if flow.sleepLogOverflowed, flow.cutPromptAt != nil {
            let reason = "more than \(SleepLog.capacity) sleeps came, so when they began is lost"
            return ManualCutOutcome(
                verdict: .inconclusive(reason: reason), exitStatus: 3,
                recoveryReason: "\(unconfirmed) in a way that counts: \(reason)."
            )
        }
        // The end found that a confirmation does not count (must C).
        if let reason = flow.confirmationInvalidated {
            return ManualCutOutcome(
                verdict: .inconclusive(reason: "the confirmation of recovery does not count: \(reason)"), exitStatus: 3,
                recoveryReason: "\(unconfirmed) in a way that counts: \(reason)."
            )
        }
        switch flow.ending {
        case let .refused(reason):
            return ManualCutOutcome(verdict: nil, exitStatus: 1, recoveryReason: nil, refusal: reason)
        case let .endedBeforeCut(reason):
            return ManualCutOutcome(verdict: .inconclusive(reason: reason), exitStatus: 2, recoveryReason: nil)
        case let .unconfirmedRecovery(reason):
            return ManualCutOutcome(
                verdict: .inconclusive(reason: reason), exitStatus: 3,
                recoveryReason: "\(unconfirmed) (\(reason)). The probe cannot know whether the cut or the restore was run."
            )
        case let .afterReadingsEndedEarly(reason):
            return ManualCutOutcome(
                verdict: .inconclusive(reason: reason), exitStatus: lastCharging ? 2 : 3,
                recoveryReason: lastCharging ? nil : notCharging
            )
        case let .terminalUnusable(reason):
            return ManualCutOutcome(
                verdict: .inconclusive(reason: reason), exitStatus: 3,
                recoveryReason: "The run ended because \(reason), so the owner may not have seen its questions or recovery text."
            )
        case nil where flow.cutPromptAt == nil:
            return ManualCutOutcome(verdict: .inconclusive(reason: "the run had not ended"), exitStatus: 2, recoveryReason: nil)
        case nil where !flow.restoreConfirmed:
            return ManualCutOutcome(
                verdict: .inconclusive(reason: "the run had not ended"), exitStatus: 3,
                recoveryReason: "\(unconfirmed)."
            )
        case .completed, nil:
            let verdict: Verdict
            if let reason = flow.readFirstReason {
                verdict = .inconclusive(reason: "the restore went through the read-first steps: \(reason)")
            } else {
                // The sleep log's occurrences count as sleep notices too.
                let logged = flow.sleeps.map { ProbeRun.SleepNotice(time: $0, message: "kIOMessageSystemWillSleep") }
                verdict = Verdict.evaluate(flow.probeRun(sleepNotices: sleepNotices + logged), criteria: criteria)
            }
            guard lastCharging else {
                return ManualCutOutcome(verdict: verdict, exitStatus: 3, recoveryReason: notCharging)
            }
            return ManualCutOutcome(verdict: verdict, exitStatus: verdict.exitStatus, recoveryReason: nil)
        }
    }
}
