import Foundation

/// The clocks a guided calibration is timed with (research note 12 §7.3).
/// CellKeeperKit provides the system's; tests use fakes.
public struct CalibrationClock: Sendable {
    /// Seconds on a clock that keeps counting during sleep and starts again
    /// at boot.
    public var monotonic: @Sendable () -> TimeInterval
    /// Identifies the current boot; nil if it cannot be read.
    public var bootSession: @Sendable () -> String?
    /// When the Mac last started, if known; for the owner's account of a rest.
    public var bootTime: @Sendable () -> Date?

    public init(monotonic: @escaping @Sendable () -> TimeInterval, bootSession: @escaping @Sendable () -> String?, bootTime: @escaping @Sendable () -> Date? = { nil }) {
        self.monotonic = monotonic
        self.bootSession = bootSession
        self.bootTime = bootTime
    }
}

/// A guided calibration as the controller holds it, for the UI (§7.5).
public struct CalibrationStatus: Sendable, Equatable {
    /// False when the controller has no calibration store: calibration is
    /// not offered.
    public var isAvailable: Bool
    /// The session in progress, if any.
    public var session: CalibrationSession?
    /// The session was found at launch and waits for the owner to choose
    /// "continue" or cancel; meanwhile CellKeeper's normal policy applies.
    public var isPaused: Bool
    /// Paused in step 5 after a restart, once the time shown has come: the
    /// owner is asked whether the Mac stayed shut down and unplugged.
    public var needsRestAnswer: Bool
    /// When the current step ends at the latest, estimated at the latest
    /// evaluation (``CalibrationSession/stepEndEstimate(at:)``).
    public var stepEndsAt: Date?
    /// When the 72-hour cap ends the session, estimated likewise.
    public var capEndsAt: Date?
    /// macOS's Charge Limit at 100% is confirmed for the session's step.
    public var isFullLimitConfirmed: Bool
    /// The report of the latest session that ended, as stored: Settings
    /// shows when it finished.
    public var last: CalibrationReport?
    /// The report of a session that ended in this run, until the owner
    /// dismisses it.
    public var outcome: CalibrationReport?
    /// How many sessions ended in this run, so each end is noticed once.
    /// Only grows.
    public var endedCount: Int
    /// The end of a session could not be saved: until a later write is read
    /// back, the stopped session may come back at the next launch (paused).
    public var isEndUnsaved: Bool
    /// Why the latest start or "continue" was refused.
    public var refusal: String?
    /// A session ended at launch because macOS's Charge Limit was not the
    /// one CellKeeper left, but what keeps that change from being
    /// overwritten (the backend's adoption marker) is not stored yet: the
    /// session's record is kept in storage as evidence until it is, and
    /// CellKeeper writes nothing meanwhile.
    public var isEvidenceRetained: Bool

    public init(
        isAvailable: Bool = false,
        session: CalibrationSession? = nil,
        isPaused: Bool = false,
        needsRestAnswer: Bool = false,
        stepEndsAt: Date? = nil,
        capEndsAt: Date? = nil,
        isFullLimitConfirmed: Bool = false,
        last: CalibrationReport? = nil,
        outcome: CalibrationReport? = nil,
        endedCount: Int = 0,
        isEndUnsaved: Bool = false,
        refusal: String? = nil,
        isEvidenceRetained: Bool = false
    ) {
        self.isAvailable = isAvailable
        self.session = session
        self.isPaused = isPaused
        self.needsRestAnswer = needsRestAnswer
        self.stepEndsAt = stepEndsAt
        self.capEndsAt = capEndsAt
        self.isFullLimitConfirmed = isFullLimitConfirmed
        self.last = last
        self.outcome = outcome
        self.endedCount = endedCount
        self.isEndUnsaved = isEndUnsaved
        self.refusal = refusal
        self.isEvidenceRetained = isEvidenceRetained
    }

    /// True while a session exists, running or paused: full charges and
    /// their schedules are excluded (§7.4).
    public var isInProgress: Bool { session != nil }

    /// Returning to the normal limit after a 100% step, not yet confirmed.
    public var isReturning: Bool { session?.isReturning == true && !isPaused }
}

/// What the controller knows when a calibration is checked.
struct CalibrationContext {
    var settings: ChargingSettings
    var capabilities: ControlCapabilities
    var isBackendFaulted: Bool
    var hasPendingBackend: Bool
    var hasSchedule: Bool
    /// An outside change was adopted in this evaluation.
    var hasAdoptedChange: Bool
    /// The latest reading, if the policy accepts it.
    var reading: BatterySnapshot?
}

/// What the first evaluation after a session was found at launch reads
/// before anything is written (§7.6 step 1), and each later one while the
/// limit read could not be judged.
struct CalibrationStartupEvidence {
    /// The native backend held a record of the owner's limit (a crash).
    var hadRecord: Bool
    /// macOS's Charge Limit as read in that evaluation, before any write.
    var limitRead: Int?
    /// The read can be judged: it was not taken on battery power, before
    /// power settled, or with the power source unknown (note 08, O20).
    /// Otherwise only the owner's own limit, shown as an active limit,
    /// accounts for the limit; anything else, "no limit" included, waits
    /// for a read that can be judged.
    var isLimitJudged: Bool
}

/// The controller's guided calibration (note 12 §7): the session, its
/// store and its clocks, and the rules that apply it around an evaluation.
/// A value the controller owns and changes only under its lock; it never
/// calls a backend. Each method leaves what it did in ``log``, which the
/// controller records.
///
/// - **Startup** (§7.6): a stored session is loaded paused. The first
///   evaluation, given what it read before writing, ends it if the backend's
///   recovery adopted an outside change, if (without a record) the limit
///   read differs from the owner's limit recorded in the session, if a
///   one-shot full charge is scheduled, or, as at every evaluation, on a
///   passed bound or a failed condition. Only "continue" unpauses it.
/// - **Every evaluation**: before the policy, the session ends if
///   management is off, the control is no longer macOS's Charge Limit (or a
///   switch is pending), the backend is unavailable or faulted, and
///   otherwise observes the evaluation (``CalibrationSession/advanced(by:)``).
///   After the requests, a return to the normal limit is confirmed by the
///   read-back, or, if the request failed or was refused for any reason but
///   the rate limit, the session ends.
/// - **Storage**: every change is written and read back; a failure stops the
///   session in memory at once. Its end is retried until it is saved.
struct CalibrationRunner {
    let store: (any CalibrationStoring)?
    let clock: CalibrationClock
    /// This run of CellKeeper.
    let run: UUID
    private var hasLoaded = false
    private(set) var session: CalibrationSession?
    private(set) var isPaused = false
    /// A session found at launch waits for the first evaluation's checks.
    private(set) var needsStartupCheck = false
    /// A session found at launch, with no record held, whose limit read
    /// could not be judged yet: the comparison with the owner's own limit
    /// (§7.6 step 3) waits for a read that can be, at a later evaluation.
    /// Nothing is recorded or written meanwhile, so it is still the limit
    /// CellKeeper left.
    private(set) var isLimitCheckPending = false
    /// 100% was confirmed for the session at the end of the last
    /// evaluation.
    private(set) var isFullLimitHeld = false
    private var last: CalibrationReport?
    private var outcome: CalibrationReport?
    private var endedCount = 0
    private var isEndUnsaved = false
    private var needsRestAnswer = false
    private var stepEndsAt: Date?
    private var capEndsAt: Date?
    var refusal: String?
    /// What happened since the controller last took it, for the activity
    /// log.
    private(set) var log: [String] = []
    /// At launch the limit was not accounted for (§7.6 step 3): the
    /// controller keeps it as the owner's change, then ends the session
    /// (``endUnaccounted(isRecorded:at:reading:)``).
    private var unaccountedLimit: (found: Int?, ownerLimit: Int)?
    /// A session ended for an unaccounted limit whose record stays in
    /// storage, as evidence for the next launch, until the change is
    /// recorded where it keeps CellKeeper from writing.
    private(set) var retainedEvidence: RetainedEvidence?

    struct RetainedEvidence {
        /// The limit read at launch; nil if it could not be read.
        var found: Int?
        var ownerLimit: Int
        var report: CalibrationReport
    }

    init(store: (any CalibrationStoring)?, clock: CalibrationClock, run: UUID = UUID()) {
        self.store = store
        self.clock = clock
        self.run = run
    }

    var status: CalibrationStatus {
        CalibrationStatus(
            isAvailable: store != nil,
            session: session,
            isPaused: isPaused,
            needsRestAnswer: session != nil && needsRestAnswer,
            stepEndsAt: session == nil ? nil : stepEndsAt,
            capEndsAt: session == nil ? nil : capEndsAt,
            isFullLimitConfirmed: session != nil && isFullLimitHeld,
            last: last,
            outcome: outcome,
            endedCount: endedCount,
            isEndUnsaved: isEndUnsaved,
            refusal: refusal,
            isEvidenceRetained: retainedEvidence != nil
        )
    }

    /// True while a session exists, running or paused.
    var isInProgress: Bool { session != nil }

    /// The session asks for macOS's Charge Limit at 100% now: in steps 1, 2
    /// and 7, not returning, and not paused.
    var wantsFullLimit: Bool {
        guard let session, !isPaused else { return false }
        return session.asksForFullLimit
    }

    mutating func takeLog() -> [String] {
        defer { log = [] }
        return log
    }

    /// The limit found at launch that is not the one CellKeeper left, with
    /// the owner's own limit recorded in the session, once. The controller
    /// keeps it as the owner's change, writing nothing (§7.6), then ends the
    /// session with ``endUnaccounted(isRecorded:at:reading:)``.
    mutating func takeUnaccountedLimit() -> (found: Int?, ownerLimit: Int)? {
        defer { unaccountedLimit = nil }
        return unaccountedLimit
    }

    /// Ends the session for the unaccounted limit taken last. Only once the
    /// change is recorded where it keeps CellKeeper from writing at the next
    /// launch (`isRecorded`: the backend's marker, stored and read back) is
    /// the session replaced in storage by its report; until then the
    /// session's record stays there as the evidence a next launch needs,
    /// and only memory says the session ended.
    mutating func endUnaccounted(found: Int?, ownerLimit: Int, isRecorded: Bool, at stamp: CalibrationStamp, reading: BatterySnapshot?) {
        let end = CalibrationEnd.unaccountedLimit(found: found, expected: ownerLimit)
        guard isRecorded else {
            guard let report = endInMemory(end, at: stamp, reading: reading) else { return }
            retainedEvidence = RetainedEvidence(found: found, ownerLimit: ownerLimit, report: report)
            log.append("CellKeeper keeps the calibration's record in storage, as evidence that the limit was changed while it was not running, until it can record that change; it writes nothing meanwhile.")
            return
        }
        finish(end, at: stamp, reading: reading)
    }

    /// The change behind ``retainedEvidence`` is recorded, or nothing is
    /// left to protect: the session's record is replaced by its report.
    mutating func releaseEvidence() {
        guard let retained = retainedEvidence else { return }
        retainedEvidence = nil
        if write(CalibrationStored(last: retained.report)) {
            log.append("CellKeeper replaced the calibration's record with its report.")
        } else {
            isEndUnsaved = true
            log.append("CellKeeper could not save the end of the calibration; it tries again at its next check. Until then, the calibration may come back, paused, if CellKeeper opens again.")
        }
    }

    /// A stamp for `wall`, read together with the monotonic clock. Without a
    /// boot identifier, this run stands for the boot: nothing outside it
    /// counts as the same boot.
    func stamp(at wall: Date) -> CalibrationStamp {
        CalibrationStamp(wall: wall, monotonic: clock.monotonic(), boot: clock.bootSession() ?? "run-\(run.uuidString)")
    }

    // MARK: - Loading and storing

    /// Loads the stored session once. One found is paused: it never resumes
    /// on its own (§7.6).
    mutating func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let store else { return }
        switch store.loadCalibration() {
        case .none:
            break
        case .stored(let stored):
            last = stored.last
            if let found = stored.session {
                session = found
                isPaused = true
                needsStartupCheck = true
                log.append("A calibration in step \(found.step.rawValue) (\(found.step)) was found from an earlier run. It is paused, with CellKeeper's normal policy, until you choose to continue or cancel it.")
            }
        case .unusable(let reason):
            log.append("A saved calibration could not be used and is removed: \(reason). Your charging settings are not affected.")
            write(CalibrationStored())
        }
    }

    /// Writes `stored` and reads it back. A failure of an end is retried at
    /// every check until it is saved.
    @discardableResult
    private mutating func write(_ stored: CalibrationStored) -> Bool {
        guard let store else { return true }
        do {
            try store.saveCalibration(stored)
            if isEndUnsaved, stored.session == nil {
                isEndUnsaved = false
                log.append("CellKeeper saved the end of the calibration.")
            }
            return true
        } catch {
            CellKeeperLog.settings.error("Could not save the calibration: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// Saves the session after a change; a failure stops it at once.
    private mutating func saveSession(at stamp: CalibrationStamp, reading: BatterySnapshot?) {
        guard write(CalibrationStored(session: session, last: last)) else {
            finish(.storageFailed, at: stamp, reading: reading)
            return
        }
    }

    // MARK: - The owner's commands

    /// Starts `new` and saves it; a failed save starts nothing. Returns
    /// whether it started.
    mutating func start(_ new: CalibrationSession) -> Bool {
        loadIfNeeded()
        guard session == nil else { return false }
        session = new
        guard write(CalibrationStored(session: new, last: last)) else {
            session = nil
            refusal = "CellKeeper could not save the calibration, so it did not start it."
            log.append("Calibration not started: CellKeeper could not save it.")
            return false
        }
        isPaused = false
        needsStartupCheck = false
        isLimitCheckPending = false
        isFullLimitHeld = false
        outcome = nil
        refusal = nil
        log.append("Calibration started: step 1 (\(CalibrationStep.chargeToFull)). CellKeeper asks for macOS's Charge Limit at 100% in steps 1, 2 and 7 only; your own limit is \(new.ownerLimit)%.")
        return true
    }

    mutating func cancel(at stamp: CalibrationStamp, reading: BatterySnapshot?) {
        guard session != nil else { return }
        finish(.cancelled, at: stamp, reading: reading)
    }

    /// The owner chose "continue" for a paused session, with `reading`, a
    /// usable one, taken in the evaluation just run.
    mutating func continueSession(restAnswer: Bool?, reading: BatterySnapshot?, at stamp: CalibrationStamp) {
        guard let current = session, isPaused, !needsStartupCheck else { return }
        switch current.continued(at: stamp, reading: reading, run: run, restAnswer: restAnswer, bootTime: clock.bootTime()) {
        case .refused(let reason):
            refusal = reason
            log.append("Calibration not continued: \(reason)")
        case .progress(let progress):
            refusal = nil
            note(progress.changes)
            if let end = progress.end {
                finish(end, at: stamp, reading: reading)
                return
            }
            session = progress.session
            isPaused = false
            saveSession(at: stamp, reading: reading)
        }
        refreshDisplay(at: stamp)
    }

    mutating func dismissOutcome() {
        outcome = nil
    }

    /// Ends the session for a reason outside the evaluation, such as a
    /// backend switch.
    mutating func endIfInProgress(_ end: CalibrationEnd, at stamp: CalibrationStamp, reading: BatterySnapshot?) {
        guard session != nil else { return }
        finish(end, at: stamp, reading: reading)
    }

    // MARK: - Around an evaluation

    /// Before the policy: the startup checks for a session found at launch,
    /// the conditions that hold throughout (§7.4), then the session's own
    /// observation.
    mutating func check(event: CalibrationObservation.Event, observedMode: ChargeControlMode?, context: CalibrationContext, startup: CalibrationStartupEvidence?, at stamp: CalibrationStamp) {
        if isEndUnsaved, session == nil, retainedEvidence == nil {
            write(CalibrationStored(last: last))
        }
        guard let current = session else { return }
        if needsStartupCheck || isLimitCheckPending {
            let isFirst = needsStartupCheck
            needsStartupCheck = false
            if let end = startupEnd(current, startup: startup, context: context, isFirst: isFirst) {
                if case .unaccountedLimit(let found, let expected) = end {
                    // Ended by the controller once it has kept the change,
                    // so the evidence is not consumed first.
                    unaccountedLimit = (found, expected)
                    return
                }
                finish(end, at: stamp, reading: context.reading)
                return
            }
        }
        if let end = Self.conditionEnd(context) {
            finish(end, at: stamp, reading: context.reading)
            return
        }
        let observation = CalibrationObservation(
            now: stamp,
            event: event,
            reading: context.reading,
            isFullLimitHeld: isFullLimitHeld && observedMode == .nativeLimit(percent: 100),
            run: run,
            isPaused: isPaused
        )
        let progress = current.advanced(by: observation)
        note(progress.changes)
        if let end = progress.end {
            finish(end, at: stamp, reading: context.reading)
            return
        }
        if progress.session != current {
            session = progress.session
            saveSession(at: stamp, reading: context.reading)
        }
        refreshDisplay(at: stamp)
    }

    /// After the requests: the conditions again (a request may have kept an
    /// outside change and turned management off), whether 100% is held for
    /// the session, and a return to the normal limit, confirmed by the
    /// read-back (`currentMode` is what it showed) or, if `requestFailed`
    /// or the policy refused for a reason other than the rate limit, failed.
    mutating func afterRequests(wantedFull: Bool, decision: PolicyDecision, currentMode: ChargeControlMode?, requestFailed: Bool, context: CalibrationContext, at stamp: CalibrationStamp) {
        guard let current = session else {
            isFullLimitHeld = false
            return
        }
        if let end = Self.conditionEnd(context) {
            finish(end, at: stamp, reading: context.reading)
            return
        }
        isFullLimitHeld = wantedFull && currentMode == .nativeLimit(percent: 100) && decision.desiredMode == currentMode
        defer { refreshDisplay(at: stamp) }
        guard current.isReturning, !wantedFull, !isPaused else { return }
        if let currentMode, currentMode == decision.desiredMode, !requestFailed {
            let progress = current.returnConfirmed(at: stamp)
            note(progress.changes)
            if let end = progress.end {
                finish(end, at: stamp, reading: context.reading)
                return
            }
            session = progress.session
            saveSession(at: stamp, reading: context.reading)
            return
        }
        if requestFailed {
            finish(.returnFailed, at: stamp, reading: context.reading)
            return
        }
        if case .refuse(let reason) = decision.action {
            if case .rateLimited = reason { return }
            finish(.returnFailed, at: stamp, reading: context.reading)
        }
    }

    /// §7.6 step 3: what the first evaluation after a launch found, and
    /// (not `isFirst`) a limit check that waited for a read that can be
    /// judged. With no record held, the limit must be the owner's own
    /// recorded in the session; a read that cannot be judged shows only
    /// whether macOS's limit is active, so the comparison waits for one
    /// that can (note 08, O20), however long that takes.
    private mutating func startupEnd(_ current: CalibrationSession, startup: CalibrationStartupEvidence?, context: CalibrationContext, isFirst: Bool) -> CalibrationEnd? {
        if isFirst, context.hasAdoptedChange { return .outsideChange }
        let wasPending = isLimitCheckPending
        isLimitCheckPending = false
        if let startup, !startup.hadRecord {
            // Below 100% the owner's own limit can only have been read as
            // an active limit, which is evidence on any power.
            let isOwnShown = startup.limitRead == current.ownerLimit && current.ownerLimit < 100
            if startup.isLimitJudged || isOwnShown {
                if startup.limitRead != current.ownerLimit {
                    return .unaccountedLimit(found: startup.limitRead, expected: current.ownerLimit)
                }
            } else {
                isLimitCheckPending = true
                if !wasPending {
                    log.append("CellKeeper checks that macOS's Charge Limit is still your own \(current.ownerLimit)% once your Mac has been on power for a minute; until then macOS may not show its limit.")
                }
            }
        }
        if isFirst, context.hasSchedule { return .scheduleFound }
        return nil
    }

    /// The conditions of §7.4 that hold throughout a session.
    static func conditionEnd(_ context: CalibrationContext) -> CalibrationEnd? {
        if !context.settings.isManagementEnabled {
            return context.hasAdoptedChange ? .outsideChange : .managementOff
        }
        if !context.capabilities.isEnforcedByMacOS || context.hasPendingBackend { return .controlChanged }
        if case .unavailable = context.capabilities.availability { return .controlUnavailable }
        if context.isBackendFaulted { return .backendFaulted }
        return nil
    }

    private mutating func refreshDisplay(at stamp: CalibrationStamp) {
        guard let session else {
            needsRestAnswer = false
            stepEndsAt = nil
            capEndsAt = nil
            return
        }
        needsRestAnswer = isPaused && session.needsRestAnswer(at: stamp)
        stepEndsAt = session.stepEndEstimate(at: stamp)
        capEndsAt = session.capEstimate(at: stamp)
    }

    // MARK: - Ending

    /// Ends the session: its report replaces it in the store (the ended
    /// mark), and CellKeeper's normal policy applies from this evaluation.
    private mutating func finish(_ end: CalibrationEnd, at stamp: CalibrationStamp, reading: BatterySnapshot?) {
        guard let report = endInMemory(end, at: stamp, reading: reading) else { return }
        if !write(CalibrationStored(last: report)) {
            isEndUnsaved = true
            log.append("CellKeeper could not save the end of the calibration; it tries again at its next check. Until then, the calibration may come back, paused, if CellKeeper opens again.")
        }
    }

    /// Ends the session in memory and returns its report, writing nothing.
    private mutating func endInMemory(_ end: CalibrationEnd, at stamp: CalibrationStamp, reading: BatterySnapshot?) -> CalibrationReport? {
        guard let ended = session else { return nil }
        let report = CalibrationReport(ended, end: end, at: stamp.wall, after: reading.map { CalibrationCapacities($0.health) })
        session = nil
        isPaused = false
        needsStartupCheck = false
        isLimitCheckPending = false
        isFullLimitHeld = false
        last = report
        outcome = report
        endedCount += 1
        refreshDisplay(at: stamp)
        // No line promises a read-back: none follows when nothing is asked
        // (Manage charging off with nothing held, or the limit already in
        // effect). Each request logs its own.
        if end.isCompleted {
            log.append("Calibration finished. CellKeeper asks for its normal limit again. \(CalibrationWording.reportSummary(report))")
        } else if end.keepsLimitAsItIs {
            log.append("Calibration ended in step \(ended.step.rawValue) (\(ended.step)): \(end). Manage charging is off, so CellKeeper asks macOS for nothing and leaves its Charge Limit as it is. \(CalibrationWording.reportSummary(report))")
        } else if end == .managementOff {
            log.append("Calibration ended in step \(ended.step.rawValue) (\(ended.step)): \(end). CellKeeper gives your own Charge Limit back. \(CalibrationWording.reportSummary(report))")
        } else {
            log.append("Calibration ended in step \(ended.step.rawValue) (\(ended.step)): \(end). CellKeeper asks for its normal limit again. \(CalibrationWording.reportSummary(report))")
        }
        return report
    }

    private mutating func note(_ changes: [CalibrationChange]) {
        log.append(contentsOf: changes.compactMap(CalibrationWording.logLine))
    }
}
