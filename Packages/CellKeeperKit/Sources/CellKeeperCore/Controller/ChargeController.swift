import Foundation
import os

/// Connects telemetry, the charging policy, and a control backend.
///
/// Each evaluation reads telemetry, asks the backend for its capabilities and
/// current mode, runs ``ChargingPolicy``, and executes the resulting action.
/// Every public command runs under one FIFO lock, so commands and backend
/// requests never interleave and each returned status reflects one complete
/// operation.
///
/// Safety behaviour:
/// - Every request is read back; an error, an unknown mode, or a mismatch
///   counts as a failure. Backends that accept requests must report their mode.
/// - After a failed restricting request, `.normal` is requested immediately
///   and must itself be confirmed by read-back.
/// - Mode-read failures count as failures. After
///   ``maximumConsecutiveFailures`` failures (a failure-free hour or a
///   successful request resets the count) the backend is faulted: only
///   `.normal` is requested (actively, until confirmed) until
///   ``resetBackendFault()``.
/// - A backend whose availability does not affect hardware can never report
///   an action as applied to hardware.
/// - ``shutdown(reason:)`` restores `.normal` and turns every later command
///   into a no-op, so nothing queued behind it can re-apply a restriction.
/// - If the backend's mode changes without CellKeeper requesting it, another
///   tool may be controlling charging: the backend is faulted immediately.
///   Native-limit backends instead adopt a changed Charge Limit as the
///   user's own (usually the user changed it in System Settings): nothing is
///   written, and management is turned off so CellKeeper does not override
///   the change. A hold the backend ended itself under its own safety rules
///   (a helper's lapsed lease or interlock) is not an outside change: it is
///   logged and the evaluation goes on as usual.
/// - At the end of every evaluation in which CellKeeper holds a confirmed
///   non-normal mode that the policy still wants, the hold is renewed
///   (``ChargingBackend/renewHold(_:)``), and at no other time, so a stalled
///   loop lets a helper's lease lapse. A failed renewal counts as a failure
///   and `.normal` is requested at once.
/// - Switching backends requires a confirmed restore of `.normal` first. If
///   it cannot be confirmed, the old backend is kept and the switch stays
///   pending: `.normal` keeps being requested until it is confirmed, and the
///   switch then completes.
/// - If CellKeeper holds a non-normal state and cannot read it back, it
///   requests `.normal`, and it keeps comparing later readings with the
///   state it last confirmed.
/// - Restricting requests are recorded on a monotonic clock for rate limiting.
///   After a failed restore of `.normal`, automatic evaluations wait
///   ``ChargingPolicy/minimumRestoreRetryInterval`` before retrying it.
/// - While macOS's own Charge Limit is on, or its report cannot be read, a
///   backend that switches charging itself is asked for nothing but
///   `.normal` (the policy defers to macOS; safety precondition 7). If that
///   starts while CellKeeper holds a restriction, the evaluation asks for
///   its release and a safety event says whether a read-back confirmed it;
///   if not, a later one says when a read-back shows it ended. Other changes
///   of macOS's limit are logged as notices, which never claim more than
///   the report: in particular, macOS's limit going off does not mean that
///   CellKeeper manages charging again.
/// - With a native-limit backend, `.normal` means the user's own macOS Charge
///   Limit, so every path above restores exactly that value. If the backend
///   remembers a limit it set in an earlier session (which a normal quit
///   never leaves behind), that limit counts as CellKeeper's own, so a change
///   made while CellKeeper was not running is detected like any other
///   external change, and the user's limit is restored before anything
///   else.
/// - A scheduled full charge (``FullChargeSchedule``) only starts the
///   existing temporary full charge, inside an evaluation and after the
///   backend's mode was read: the schedule is removed from its store, then
///   the override is installed, with no suspension point between them, and
///   the same evaluation runs the policy. It never shortens a running full
///   charge. Its guarantees assume one controlling instance.
/// - A weekly full charge (``WeeklyFullChargeSchedule``) starts the same
///   full charge by the same rules, after the one-shot schedule in the same
///   evaluation. Its record of the occurrence handled is moved in memory
///   first, where the rest of the run reads it, so no occurrence starts or
///   passes twice in a run; the store is then brought in line and read
///   back, and a write that fails delays nothing and is retried at every
///   evaluation.
/// - A guided calibration (``CalibrationSession``, research note 12 §7) is
///   checked inside an evaluation after the backend's mode was read and
///   before the schedules: while a session exists, running or paused, no
///   full charge starts, from the menu, Settings, a Shortcuts action or a
///   schedule, and a weekly occurrence that falls due is recorded as
///   skipped. The session asks for macOS's Charge Limit at 100% only in
///   steps 1, 2 and 7, and leaves those steps only once a read-back
///   confirms the normal limit. A session found at launch is checked
///   against what the first evaluation read before writing, and stays
///   paused, with the normal policy, until the owner continues it.
public actor ChargeController {
    public static let maximumConsecutiveFailures = 3
    /// A failure-free period of this length resets the failure count.
    public static let failureMemory: TimeInterval = 60 * 60
    /// How long a will-sleep announcement keeps sleep precautions active if
    /// no wake notification follows (the monotonic clock keeps counting
    /// during sleep, so a real sleep always exceeds it).
    public static let sleepAnnouncementWindow: TimeInterval = 120
    public static let eventLimit = 200

    private let telemetry: any TelemetryProvider
    private var backend: any ChargingBackend
    /// Where a native backend keeps its adoption marker, so turning
    /// management on can remove it whichever backend is in use.
    private let adoptionMarkerStore: (any OwnershipRecordStore)?
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    /// Where the scheduled full charge is kept; nil turns scheduling off.
    private let scheduleStore: (any FullChargeScheduleStoring)?
    /// Where the weekly full charge is kept; nil turns it off.
    private let weeklyStore: (any WeeklyFullChargeStoring)?
    /// The time zone weekly occurrences are computed in, read at every
    /// evaluation together with ``now``.
    private let timeZone: @Sendable () -> TimeZone

    private var settings: ChargingSettings
    private var activeOverride: ChargeOverride?
    /// Whether ``schedule`` has been loaded from ``scheduleStore``. Loading
    /// waits for the first command, so that it is logged at the right time.
    private var hasLoadedSchedule = false
    /// The armed scheduled full charge.
    private var schedule: FullChargeSchedule?
    /// Why the armed schedule, now due, cannot start yet; nil while it is
    /// not due.
    private var scheduleWait: FullChargeScheduleWait?
    /// Why the armed schedule last waited in this run, for the outcome if
    /// its window passes; never persisted.
    private var lastScheduleWait: FullChargeScheduleWait?
    private var scheduleOutcome: FullChargeScheduleOutcome?
    /// Whether ``weekly`` has been loaded from ``weeklyStore``, at the first
    /// command.
    private var hasLoadedWeekly = false
    /// The weekly full charge in use and its record. Authoritative for this
    /// run: what the store holds matters only at the next launch.
    private var weekly: WeeklyFullChargeSchedule?
    /// The latest record handled in this run, loaded or made here. It only
    /// moves forward and outlives a removal, so no occurrence on or before
    /// its day starts again in this run, whatever the store or the clock
    /// does.
    private var weeklyHandledInRun: WeeklyFullChargeRecord?
    /// The occurrence that is due and cannot start yet; nil when none is.
    private var weeklyDue: WeeklyFullChargeDue?
    /// Why an occurrence last waited, with its nominal day, never
    /// persisted: a passed outcome names the reason only for that same
    /// occurrence. Replaced when another occurrence waits; dropped once one
    /// is handled.
    private var weeklyWaitEvidence: (day: LocalDay, wait: FullChargeScheduleWait)?
    /// Set while the store does not hold what is in use, until a later
    /// write is read back as made; every evaluation tries again.
    private var weeklyStoreProblem: WeeklyFullChargeStoreProblem?
    /// True from a change to the weekly full charge in use until the store
    /// has been brought in line with it.
    private var isWeeklyStoreDirty = false
    /// The next occurrence as of the latest evaluation.
    private var weeklyNext: WeeklyFullChargeOccurrence?
    private var weeklyOutcome: WeeklyFullChargeOutcome?
    /// The guided calibration, its store and its clocks.
    private var calibration: CalibrationRunner
    /// Requests sent to the backend, so an evaluation can tell whether one
    /// of its own failed.
    private var requestsMade = 0
    private var memory = PolicyMemory()
    private var snapshot: BatterySnapshot?
    private var telemetryError: String?
    private var capabilities: ControlCapabilities = .unavailable("Not evaluated yet.")
    private var currentMode: ChargeControlMode?
    /// The mode CellKeeper last requested and confirmed on this backend.
    private var ownedMode: ChargeControlMode?
    /// Modes the backend accepted since the last confirmation but that could
    /// not be confirmed. Any of them may have taken effect, so finding one
    /// later is not an outside change. Requests the backend rejected are not
    /// included.
    private var unconfirmedRequests: Set<ChargeControlMode> = []
    /// A restore of `.normal` was attempted and not confirmed. Until it is,
    /// the policy is told to release whatever the settings say.
    private var isRestoreOutstanding = false
    /// Whether ``ownedMode`` has been seeded from what the current backend
    /// remembers from an earlier session.
    private var hasSeededOwnership = false
    private var nativeLimit: NativeLimitStatus?
    /// When a request for `.normal` last failed, for retry spacing.
    private var lastFailedRestoreUptime: TimeInterval?
    /// A backend the user switched to, waiting for `.normal` to be confirmed
    /// on the current one.
    private var pendingBackend: (any ChargingBackend)?
    /// Set for an evaluation in which a non-normal state could not be read.
    private var isOwnedStateUnverified = false
    /// The fault the backend keeps reporting
    /// (``ReportedModeOrigin/changedOutside(_:)`` or
    /// ``ReportedModeOrigin/needsAcknowledgement(_:)``) has faulted it
    /// already.
    private var didLastReadReportFault = false
    /// The faults the backend reported (thrown, or with a read) since its
    /// reads last reported none, so each kind is logged once and counted
    /// once: an outside change by its detail, so a different one, or an
    /// escalation from a problem needing acknowledgement, is logged again.
    private var handledFaults = HandledFaults()
    private var decision: PolicyDecision?
    private var lastExecution: ExecutionRecord?
    private var consecutiveFailures = 0 {
        didSet {
            if oldValue < Self.maximumConsecutiveFailures, consecutiveFailures >= Self.maximumConsecutiveFailures {
                faultsRaised += 1
            }
        }
    }
    /// How many times the backend in use became faulted in this session
    /// (``ControllerStatus/faultsRaised``).
    private var faultsRaised = 0
    /// Reads that showed normal charging and so ended ``responsibleMode``,
    /// with a backend that switches charging itself
    /// (``ControllerStatus/releasesConfirmed``).
    private var releasesConfirmed = 0
    /// The override that most recently ended by itself, with how, and how
    /// many have (``ControllerStatus/lastEndedOverride``).
    private var lastEndedOverride: EndedOverride?
    private var overridesEnded = 0
    private var lastFailureUptime: TimeInterval?
    private var sleepAnnouncedAtUptime: TimeInterval?
    private var isShutDown = false
    /// Recent restricting requests, for rate limiting. Those sent to a
    /// backend that touches no hardware are dropped when the backend changes,
    /// so simulated activity never delays a real backend's first change.
    private var restrictingRequests: [(uptime: TimeInterval, touchedHardware: Bool)] = []
    /// The latest outside change adopted as the user's own limit, until
    /// management is turned on again.
    private var adoptedChange: AdoptedLimitChange?
    private var adoptionCount = 0
    /// macOS's own Charge Limit as the current backend last reported it
    /// (``ControlCapabilities/macOSChargeLimit``), for logging its changes;
    /// nil if the backend does not check it, or has not reported it yet.
    private var macOSLimitGate: MacOSLimitGate?
    /// A restriction CellKeeper asked to end when macOS's Charge Limit
    /// started to apply, whose end no read-back has shown yet.
    private var macOSLimitReleaseUnconfirmed: ChargeControlMode?
    /// The non-normal mode CellKeeper may have put into effect and has not
    /// seen end: set before a non-normal request is sent, and cleared only by
    /// a read taken after it that shows normal charging, or by the backend's
    /// records showing positively that nothing in effect is CellKeeper's
    /// (``ChargingBackend/isReportedModeOwn()`` false; nil, unknown, keeps
    /// it). Faults, ownership bookkeeping (``ownedMode``), a restarted helper
    /// and attempted restores never clear it.
    private var responsibleMode: ChargeControlMode?
    /// What the last successful read's backend records say about who set
    /// the mode in effect (``ChargingBackend/isReportedModeOwn()``); nil
    /// after a failed read or a request that may have changed it.
    private var reportedModeIsOwn: Bool?
    private var managementRefusal: String?
    private var events: [ControlEvent] = []
    private var nextEventID = 0
    private var lastEvaluation: Date?

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - adoptionMarkerStore: the native backend's record store, if any.
    ///   - scheduleStore: where a scheduled full charge is kept; nil turns
    ///     scheduling off.
    ///   - weeklyStore: where a weekly full charge is kept; nil turns it off.
    ///   - now: wall-clock time, for telemetry age, display, and a scheduled
    ///     full charge's window.
    ///   - timeZone: the time zone a weekly full charge's local times are
    ///     read in. Called at every evaluation, and when a weekly schedule
    ///     is saved, together with `now`; never captured once.
    ///   - uptime: monotonic seconds that keep counting during sleep, for
    ///     override expiry and rate limiting. Defaults to `ContinuousClock`.
    ///   - calibrationStore: where a guided calibration is kept; nil turns
    ///     calibration off.
    ///   - calibrationClock: the boot-wide monotonic clock and boot identity
    ///     a calibration is timed with. Defaults to `uptime`, with no boot
    ///     identity: then only this run counts as the same boot.
    public init(
        telemetry: any TelemetryProvider,
        backend: any ChargingBackend,
        settings: ChargingSettings,
        adoptionMarkerStore: (any OwnershipRecordStore)? = nil,
        scheduleStore: (any FullChargeScheduleStoring)? = nil,
        weeklyStore: (any WeeklyFullChargeStoring)? = nil,
        calibrationStore: (any CalibrationStoring)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        uptime: (@Sendable () -> TimeInterval)? = nil,
        calibrationClock: CalibrationClock? = nil
    ) {
        self.telemetry = telemetry
        self.backend = backend
        self.adoptionMarkerStore = adoptionMarkerStore
        self.scheduleStore = scheduleStore
        self.weeklyStore = weeklyStore
        self.settings = settings
        self.now = now
        self.timeZone = timeZone
        let uptime = uptime ?? Self.continuousUptime()
        self.uptime = uptime
        calibration = CalibrationRunner(store: calibrationStore, clock: calibrationClock ?? CalibrationClock(monotonic: uptime, bootSession: { nil }))
    }

    private static func continuousUptime() -> @Sendable () -> TimeInterval {
        let clock = ContinuousClock()
        let origin = clock.now
        return {
            let elapsed = origin.duration(to: clock.now).components
            return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
        }
    }

    private var isBackendFaulted: Bool {
        consecutiveFailures >= Self.maximumConsecutiveFailures
    }

    public var status: ControllerStatus {
        ControllerStatus(
            snapshot: snapshot,
            telemetryError: telemetryError,
            settings: settings,
            activeOverride: activeOverride,
            backend: backend.descriptor,
            capabilities: capabilities,
            currentMode: currentMode,
            ownRestrictionMode: responsibleMode,
            isReportedModeOwn: reportedModeIsOwn,
            nativeLimit: nativeLimit,
            adoptedChange: adoptedChange,
            adoptionCount: adoptionCount,
            managementRefusal: managementRefusal,
            pendingBackend: pendingBackend?.descriptor,
            decision: decision,
            lastExecution: lastExecution,
            consecutiveFailures: consecutiveFailures,
            isBackendFaulted: isBackendFaulted,
            faultsRaised: faultsRaised,
            releasesConfirmed: releasesConfirmed,
            events: events,
            lastEvaluation: lastEvaluation,
            fullChargeSchedule: schedule,
            fullChargeScheduleWait: schedule == nil ? nil : scheduleWait,
            fullChargeScheduleOutcome: scheduleOutcome,
            weeklyFullCharge: weekly,
            weeklyFullChargeDue: weekly == nil ? nil : weeklyDue,
            weeklyFullChargeNext: weekly == nil ? nil : weeklyNext,
            weeklyFullChargeOutcome: weeklyOutcome,
            weeklyFullChargeStoreProblem: weeklyStoreProblem,
            lastEndedOverride: lastEndedOverride,
            overridesEnded: overridesEnded,
            calibration: calibration.status
        )
    }

    // MARK: - Commands

    /// Reads telemetry, runs the policy, and acts on the decision.
    @discardableResult
    public func evaluate(_ trigger: EvaluationTrigger) async -> ControllerStatus {
        await exclusively {
            await performEvaluation(trigger)
        }
    }

    /// Validates and applies new settings, then re-evaluates. Invalid settings
    /// are rejected and the current settings are kept.
    ///
    /// - Parameter adoptionsSeen: the ``ControllerStatus/adoptionCount`` the
    ///   caller knew when the user made this change. Settings made before
    ///   CellKeeper kept a limit changed outside it cannot turn management
    ///   back on, because the user had not seen that yet; nil skips the check.
    @discardableResult
    public func apply(settings newSettings: ChargingSettings, adoptionsSeen: Int? = nil) async throws -> ControllerStatus {
        let checkedSettings: ChargingSettings
        do {
            checkedSettings = try newSettings.validated()
        } catch {
            _ = await exclusively {
                record(.settings, "Rejected invalid settings: \(error)", level: .error)
            }
            throw error
        }
        return await exclusively {
            var validSettings = checkedSettings
            var refusal: String?
            if let adoptionsSeen, adoptionsSeen < adoptionCount, validSettings.isManagementEnabled, !settings.isManagementEnabled {
                validSettings.isManagementEnabled = false
                refusal = "Manage charging stays off: CellKeeper has just kept a Charge Limit changed outside it. Turn it on again to let CellKeeper manage the limit."
                record(.settings, "Manage charging stays off: this change was made before CellKeeper kept a Charge Limit changed outside it.")
            }
            if validSettings.isManagementEnabled, !settings.isManagementEnabled, await !retireAdoption() {
                validSettings.isManagementEnabled = false
                refusal = "Manage charging stays off: CellKeeper could not remove its record of the Charge Limit it kept, so it leaves the limit as it is. Try again later."
                record(.safety, "Manage charging stays off: CellKeeper could not remove what records the Charge Limit it kept, so it leaves the limit as it is. Try again later.", level: .error)
            }
            managementRefusal = refusal
            guard validSettings != settings else { return }
            let previous = settings
            settings = validSettings
            if validSettings.isManagementEnabled {
                adoptedChange = nil
            }
            record(.settings, Self.describeChange(from: previous, to: validSettings))
            if !validSettings.isManagementEnabled, let ended = activeOverride {
                activeOverride = nil
                record(.override, "\(Self.describe(ended)) cancelled because charge management was turned off.")
            }
            await performEvaluation(.settingsChanged)
        }
    }

    /// Starts a temporary full charge. It ends at 100%, when fully charged, on
    /// unplug, or when `duration` elapses, whichever comes first.
    ///
    /// While an override is live (its monotonic deadline not passed), a full
    /// charge or a discharge, started by the user or a schedule, this changes
    /// nothing: the override keeps its deadline. Several starts queued behind
    /// one another therefore give one full charge, with the first one's
    /// deadline. An override whose deadline has passed is replaced, as the
    /// next evaluation would have ended it. Schedules start their full charge
    /// by their own rule (``setFullChargeSchedule(_:)``).
    @discardableResult
    public func startFullCharge(duration: TimeInterval = ChargeOverride.defaultFullChargeDuration) async -> ControllerStatus {
        await exclusively {
            guard settings.isManagementEnabled else {
                record(.override, "Temporary full charge not started: charge management is off.")
                return
            }
            calibration.loadIfNeeded()
            recordCalibrationLog()
            guard !calibration.isInProgress else {
                record(.override, "Temporary full charge not started: \(CalibrationWording.inProgress.lowercased())")
                return
            }
            let startUptime = uptime()
            if let running = activeOverride, running.isLive(atUptime: startUptime) {
                let what = running.kind == .fullCharge ? "a temporary full charge is already running" : "a discharge to the limit is running"
                record(.override, "Temporary full charge not started: \(what).")
                return
            }
            let override = ChargeOverride.fullCharge(at: now(), uptime: startUptime, duration: duration)
            activeOverride = override
            record(.override, "Temporary full charge requested (expires \(override.expiresAt.formatted(date: .omitted, time: .shortened))).")
            await performEvaluation(.overrideChanged)
        }
    }

    /// Starts a one-shot discharge session down to the charge limit. It ends
    /// at the limit, on unplug, before sleep, on temperature pause, on lost
    /// telemetry, or when `duration` elapses. Requires management to be on
    /// and a limit within ``ChargingPolicy/dischargeTargetRange``.
    ///
    /// Admission follows ``startFullCharge(duration:)``: while an override
    /// is live (its monotonic deadline not passed), a full charge or a
    /// discharge, started by the user or a schedule, this changes nothing
    /// and logs that: the override keeps its deadline. Several starts queued
    /// behind one another therefore give one discharge, with the first one's
    /// deadline, and a start confirmed after a full charge began meanwhile
    /// leaves that full charge running. An override whose deadline has
    /// passed is replaced, as the next evaluation would have ended it. A
    /// schedule that starts its full charge while a discharge is live
    /// replaces the discharge by its own rule (``setFullChargeSchedule(_:)``).
    @discardableResult
    public func startDischargeToLimit(duration: TimeInterval = ChargeOverride.defaultDischargeDuration) async -> ControllerStatus {
        await exclusively {
            guard settings.isManagementEnabled, ChargingPolicy.dischargeTargetRange.contains(settings.chargeLimit) else {
                record(.override, "Discharge not started: requires charge management on and a limit of \(ChargingPolicy.dischargeTargetRange.lowerBound)–\(ChargingPolicy.dischargeTargetRange.upperBound)%.", level: .default)
                return
            }
            calibration.loadIfNeeded()
            recordCalibrationLog()
            guard !calibration.isInProgress else {
                record(.override, "Discharge not started: \(CalibrationWording.inProgress.lowercased())")
                return
            }
            let startUptime = uptime()
            if let running = activeOverride, running.isLive(atUptime: startUptime) {
                let what = running.kind == .fullCharge ? "a temporary full charge is running" : "a discharge to the limit is already running"
                record(.override, "Discharge not started: \(what).")
                return
            }
            let override = ChargeOverride.dischargeToLimit(target: settings.chargeLimit, at: now(), uptime: startUptime, duration: duration)
            activeOverride = override
            record(.override, "Discharge to \(settings.chargeLimit)% requested (expires \(override.expiresAt.formatted(date: .omitted, time: .shortened))).")
            await performEvaluation(.overrideChanged)
        }
    }

    @discardableResult
    public func cancelOverride() async -> ControllerStatus {
        await exclusively {
            guard let cancelled = activeOverride else { return }
            activeOverride = nil
            record(.override, "\(Self.describe(cancelled)) cancelled.")
            await performEvaluation(.overrideChanged)
        }
    }

    // MARK: - Scheduled full charge

    /// Arms `newSchedule`, replacing any armed schedule, and evaluates. It is
    /// rejected unless its window is valid and it starts in the future, at
    /// most ``FullChargeSchedule/maximumLeadTime`` ahead, judged when the
    /// command is made. Without a schedule store nothing is armed.
    @discardableResult
    public func setFullChargeSchedule(_ newSchedule: FullChargeSchedule) async throws -> ControllerStatus {
        let issues = newSchedule.issues(settingAt: now())
        guard issues.isEmpty else {
            let error = FullChargeScheduleError(issues: issues)
            _ = await exclusively {
                record(.override, "Scheduled full charge rejected: \(error)", level: .error)
            }
            throw error
        }
        var refusal: FullChargeScheduleError?
        let status = await exclusively {
            loadScheduleIfNeeded()
            calibration.loadIfNeeded()
            recordCalibrationLog()
            guard !calibration.isInProgress else {
                refusal = FullChargeScheduleError(issues: [.calibrationInProgress])
                record(.override, "Scheduled full charge not set: \(CalibrationWording.inProgress.lowercased())")
                return
            }
            guard let scheduleStore else {
                record(.override, "Scheduled full charge not set: scheduling is not available.", level: .error)
                return
            }
            do {
                try scheduleStore.saveSchedule(newSchedule)
            } catch {
                record(.failure, "Could not save the scheduled full charge: \(error)", level: .error)
                return
            }
            let replaced = schedule != nil
            schedule = newSchedule
            scheduleWait = nil
            lastScheduleWait = nil
            scheduleOutcome = nil
            record(.override, "Scheduled full charge \(replaced ? "changed" : "set"): \(Self.describeWindow(newSchedule)).")
            await performEvaluation(.scheduleChanged)
        }
        if let refusal { throw refusal }
        return status
    }

    /// Removes the armed schedule, if any, and evaluates. A full charge it
    /// already started is not affected; ``cancelOverride()`` ends that.
    @discardableResult
    public func cancelFullChargeSchedule() async -> ControllerStatus {
        await exclusively {
            loadScheduleIfNeeded()
            guard let cancelled = schedule else { return }
            scheduleStore?.removeSchedule()
            schedule = nil
            scheduleWait = nil
            lastScheduleWait = nil
            record(.override, "Scheduled full charge cancelled: \(Self.describeWindow(cancelled)).")
            await performEvaluation(.scheduleChanged)
        }
    }

    /// Forgets the latest schedule's outcome once the user has seen it.
    @discardableResult
    public func dismissFullChargeScheduleOutcome() async -> ControllerStatus {
        await exclusively {
            scheduleOutcome = nil
        }
    }

    /// Loads the armed schedule once, at the first command. A stored record
    /// that cannot be used is removed, with a notice; it never affects the
    /// settings. A schedule whose window has passed is left to the first
    /// check, which reports it.
    private func loadScheduleIfNeeded() {
        guard !hasLoadedSchedule else { return }
        hasLoadedSchedule = true
        guard let scheduleStore else { return }
        switch scheduleStore.loadSchedule() {
        case .none:
            break
        case .schedule(let stored):
            schedule = stored
            record(.override, "Scheduled full charge loaded: \(Self.describeWindow(stored)).")
        case .unusable(let reason):
            scheduleStore.removeSchedule()
            scheduleOutcome = .discarded(reason: reason)
            record(.override, "A saved full-charge schedule was removed: \(reason). Your charging settings are not affected.", level: .error)
        }
    }

    // MARK: - Weekly full charge

    /// Saves `pattern` as the weekly full charge, replacing any in use, and
    /// evaluates. It counts from now, read inside this command together with
    /// the time zone: an occurrence that started before it, or a day already
    /// handled in this run or recorded before, does not start
    /// (``WeeklyFullChargeSchedule/saving(_:handledAtLeast:now:timeZone:)``).
    /// It is in use at once; the store is then brought in line and read
    /// back, and while that fails, ``ControllerStatus/weeklyFullChargeStoreProblem``
    /// says so and every evaluation tries again. A full charge already
    /// running is not changed.
    @discardableResult
    public func setWeeklyFullCharge(_ pattern: WeeklyFullChargePattern) async throws -> ControllerStatus {
        let issues = pattern.issues
        guard issues.isEmpty else {
            let error = WeeklyFullChargeError.invalid(issues)
            _ = await exclusively {
                record(.override, "Weekly full charge rejected: \(error)", level: .error)
            }
            throw error
        }
        var failure: WeeklyFullChargeError?
        let status = await exclusively {
            loadWeeklyIfNeeded()
            calibration.loadIfNeeded()
            recordCalibrationLog()
            guard !calibration.isInProgress else {
                failure = .calibrationInProgress
                record(.override, "Weekly full charge not saved: \(CalibrationWording.inProgress.lowercased())")
                return
            }
            guard weeklyStore != nil else {
                failure = .notAvailable
                record(.override, "Weekly full charge not saved: it is not available.", level: .error)
                return
            }
            let saved: WeeklyFullChargeSchedule
            do {
                saved = try WeeklyFullChargeSchedule.saving(pattern, handledAtLeast: weeklyHandledInRun, now: now(), timeZone: timeZone())
            } catch {
                failure = error as? WeeklyFullChargeError ?? .invalid(issues)
                record(.override, "Weekly full charge rejected: \(error)", level: .error)
                return
            }
            let replaced = weekly != nil
            weekly = saved
            weeklyHandledInRun = saved.handled
            weeklyDue = nil
            weeklyWaitEvidence = nil
            weeklyNext = nil
            weeklyOutcome = nil
            record(.override, "Weekly full charge \(replaced ? "changed" : "saved"): \(Self.describe(pattern)). It counts from now.")
            isWeeklyStoreDirty = true
            await performEvaluation(.scheduleChanged)
        }
        if let failure { throw failure }
        return status
    }

    /// Stops using the weekly full charge and evaluates; its removal from
    /// the store is then made and read back, and retried at every
    /// evaluation while it fails. Days handled in this run stay handled, so
    /// a weekly schedule saved again in this run does not start them again.
    /// A full charge it already started is not affected;
    /// ``cancelOverride()`` ends that.
    @discardableResult
    public func removeWeeklyFullCharge() async -> ControllerStatus {
        await exclusively {
            loadWeeklyIfNeeded()
            guard let removed = weekly else { return }
            weekly = nil
            weeklyDue = nil
            weeklyWaitEvidence = nil
            weeklyNext = nil
            record(.override, "Weekly full charge removed: \(Self.describe(removed.pattern)).")
            isWeeklyStoreDirty = true
            await performEvaluation(.scheduleChanged)
        }
    }

    /// Forgets the latest weekly outcome once the user has seen it.
    @discardableResult
    public func dismissWeeklyFullChargeOutcome() async -> ControllerStatus {
        await exclusively {
            weeklyOutcome = nil
        }
    }

    /// Loads the weekly full charge once, at the first command. A stored
    /// value that cannot be used is not used, never affects the settings,
    /// and is removed, with a notice; while that removal cannot be read
    /// back, every evaluation tries again.
    private func loadWeeklyIfNeeded() {
        guard !hasLoadedWeekly else { return }
        hasLoadedWeekly = true
        guard let weeklyStore else { return }
        switch weeklyStore.loadWeeklyFullCharge() {
        case .none:
            break
        case .schedule(let stored):
            weekly = stored
            weeklyHandledInRun = stored.handled
            record(.override, "Weekly full charge loaded: \(Self.describe(stored.pattern)); last handled \(stored.handled.day) (\(Self.describe(stored.handled.result))).")
        case .unusable(let reason):
            weeklyOutcome = .discarded(reason: reason)
            record(.override, "A saved weekly full charge could not be used and is removed: \(reason). Your charging settings are not affected.", level: .error)
            isWeeklyStoreDirty = true
        }
    }

    /// Brings the store in line with the weekly full charge in use (or its
    /// absence) and reads it back. A failure is noted once, with the error
    /// only in the unified log, and ``weeklyStoreProblem`` and
    /// ``isWeeklyStoreDirty`` stay set until a later attempt is read back as
    /// made.
    private func syncWeeklyStore() {
        guard let weeklyStore else {
            isWeeklyStoreDirty = false
            return
        }
        let problem: WeeklyFullChargeStoreProblem = weekly == nil ? .notRemoved : .notSaved
        do {
            if let weekly {
                try weeklyStore.saveWeeklyFullCharge(weekly)
            } else {
                try weeklyStore.removeWeeklyFullCharge()
            }
        } catch {
            if weeklyStoreProblem != problem {
                let what = problem == .notRemoved ? "the removal of the weekly full charge" : "the weekly full charge and its record"
                record(.failure, "CellKeeper could not save \(what); it keeps using what is shown and tries again at its next check.", level: .error)
                CellKeeperLog.settings.error("Could not save the weekly full charge: \(String(describing: error), privacy: .private)")
            }
            weeklyStoreProblem = problem
            return
        }
        if weeklyStoreProblem != nil {
            record(.override, "CellKeeper saved \(problem == .notRemoved ? "the removal of the weekly full charge" : "the weekly full charge and its record").")
        }
        weeklyStoreProblem = nil
        isWeeklyStoreDirty = false
    }

    /// Checks the weekly full charge in use against `input` in `timeZone`.
    /// A start or a passed occurrence moves the record in memory first, so
    /// that it is never eligible again in this run; then the full charge is
    /// installed (with no suspension point in between) or the outcome set,
    /// and the store is brought in line. A failed write delays nothing: it
    /// is retried at later evaluations. Returns how it met the override
    /// running, if it started. Updates the next occurrence.
    private func applyWeekly(to input: inout PolicyInput, timeZone: TimeZone, isCalibrating: Bool) -> ScheduledStart? {
        // Once per evaluation, after anything this evaluation handled.
        defer {
            if isWeeklyStoreDirty { syncWeeklyStore() }
        }
        guard let armed = weekly else {
            weeklyDue = nil
            weeklyNext = nil
            return nil
        }
        var start: ScheduledStart?
        var isHandled = false
        switch armed.check(input: input, timeZone: timeZone) {
        case .start(let occurrence, _) where isCalibrating, .waiting(let occurrence, _) where isCalibrating:
            // Note 12 §7.4: skipped, and recorded as handled with the
            // reason; the schedule continues after the calibration.
            isHandled = true
            handleWeekly(occurrence, as: .skippedForCalibration)
            weeklyOutcome = .skippedForCalibration(occurrence)
            record(.override, "Weekly full charge (\(Self.describeWindow(occurrence.window))) skipped: \(CalibrationWording.inProgress.lowercased()) The weekly schedule continues after it.")
        case .nothingDue:
            weeklyDue = nil
        case .waiting(let occurrence, let wait):
            let due = WeeklyFullChargeDue(occurrence: occurrence, wait: wait)
            if weeklyDue != due {
                record(.override, "Weekly full charge (\(Self.describeTime(occurrence.startsAt))) is due but cannot start yet: \(wait).")
            }
            weeklyDue = due
            weeklyWaitEvidence = (occurrence.day, wait)
        case .passed(let occurrence):
            isHandled = true
            let lastWait = weeklyWaitEvidence.flatMap { $0.day == occurrence.day ? $0.wait : nil }
            handleWeekly(occurrence, as: .passed)
            weeklyOutcome = .windowPassed(occurrence, lastWait: lastWait)
            let lastChecked = lastWait.map { " Last checked: \($0)." } ?? ""
            record(.override, "Weekly full charge (\(Self.describeWindow(occurrence.window))): the window passed before the full charge could start.\(lastChecked)")
        case .start(let occurrence, let remaining):
            guard let candidate = ChargeOverride.scheduledFullCharge(at: input.now, uptime: input.overrideUptime, remaining: remaining) else { break }
            isHandled = true
            handleWeekly(occurrence, as: .started)
            let how = installScheduledFullCharge(candidate, in: &input)
            start = how
            let window = Self.describeWindow(occurrence.window)
            let deadline = Self.describeTime(activeOverride?.expiresAt ?? candidate.expiresAt)
            switch how {
            case .started:
                weeklyOutcome = .started(occurrence)
                record(.override, "Weekly full charge started (\(window)); it expires at about \(deadline). It ends at a check after the battery is full, you unplug, or it expires; CellKeeper then asks for its limit again.")
            case .extended:
                weeklyOutcome = .extendedRunning(occurrence)
                record(.override, "Weekly full charge (\(window)): a temporary full charge was already running; it now expires at about \(deadline).")
            case .kept(let deadlineRelation):
                weeklyOutcome = .keptRunning(occurrence, deadline: deadlineRelation)
                record(.override, "Weekly full charge (\(window)): a temporary full charge was already running, expiring \(Self.describe(deadlineRelation)), at about \(deadline); it continues unchanged.")
            }
        }
        let next = weekly?.next(after: input.now, in: timeZone)
        // A change for any other reason than time passing or an occurrence
        // being handled: a time zone or clock change. Why is not guessed.
        if !isHandled, let previous = weeklyNext, previous.startsAt > input.now, previous != next {
            record(.override, "Next weekly full charge: \(next.map { Self.describeWindow($0.window) } ?? "none").")
        }
        weeklyNext = next
        return start
    }

    /// Records `occurrence` as handled in memory, where this run reads it,
    /// before anything else changes. The record only moves forward.
    private func handleWeekly(_ occurrence: WeeklyFullChargeOccurrence, as result: WeeklyFullChargeRecord.Result) {
        let handled = WeeklyFullChargeRecord(occurrence, result: result)
        weekly?.handled = handled
        weeklyHandledInRun = handled
        weeklyDue = nil
        weeklyWaitEvidence = nil
        isWeeklyStoreDirty = true
    }

    /// Checks the armed schedule against `input` and, if it starts, removes
    /// it from its store and installs its full charge in ``activeOverride``
    /// and `input`, with no suspension point between them. Returns how it
    /// met the override running, if it started.
    ///
    /// Everything here that concerns overrides (the new full charge's
    /// deadline, whether a running one is still live, and the displayed
    /// deadline) uses `input.overrideUptime`, the monotonic clock read
    /// together with `input.now` after the backend's reads, which the policy
    /// also judges expiry on. The backend calls made between `input.uptime`
    /// and `input.now` therefore neither shorten the new deadline nor skew
    /// the display, and the controller and the policy agree on liveness.
    private func applySchedule(to input: inout PolicyInput) -> ScheduledStart? {
        guard let armed = schedule else { return nil }
        switch FullChargeSchedule.check(armed, input: input) {
        case .notYet:
            scheduleWait = nil
            return nil
        case .waiting(let wait):
            if scheduleWait != wait {
                record(.override, "Scheduled full charge is due but cannot start yet: \(wait).")
            }
            scheduleWait = wait
            lastScheduleWait = wait
            return nil
        case .passed:
            scheduleStore?.removeSchedule()
            schedule = nil
            scheduleOutcome = .windowPassed(armed, lastWait: lastScheduleWait)
            let lastChecked = lastScheduleWait.map { " Last checked: \($0)." } ?? ""
            record(.override, "Scheduled full charge (\(Self.describeWindow(armed))): the scheduled window passed before the full charge could start.\(lastChecked)")
            scheduleWait = nil
            lastScheduleWait = nil
            return nil
        case .start(let remaining):
            guard let candidate = ChargeOverride.scheduledFullCharge(at: input.now, uptime: input.overrideUptime, remaining: remaining) else {
                return nil
            }
            scheduleStore?.removeSchedule()
            schedule = nil
            scheduleWait = nil
            lastScheduleWait = nil
            let window = Self.describeWindow(armed)
            let start = installScheduledFullCharge(candidate, in: &input)
            let deadline = Self.describeTime(activeOverride?.expiresAt ?? candidate.expiresAt)
            switch start {
            case .started:
                scheduleOutcome = .started(armed)
                record(.override, "Scheduled full charge started (\(window)); it expires at about \(deadline). It ends at a check after the battery is full, you unplug, or it expires; CellKeeper then asks for its limit again.")
            case .extended:
                scheduleOutcome = .extendedRunning(armed)
                record(.override, "Scheduled full charge (\(window)): a temporary full charge was already running; it now expires at about \(deadline).")
            case .kept(let deadlineRelation):
                scheduleOutcome = .keptRunning(armed, deadline: deadlineRelation)
                record(.override, "Scheduled full charge (\(window)): a temporary full charge was already running, expiring \(Self.describe(deadlineRelation)), at about \(deadline); it continues unchanged.")
            }
            return start
        }
    }

    /// How a schedule's full charge met the override already running.
    private enum ScheduledStart {
        /// It was installed, replacing a discharge session or an expired
        /// override, if any.
        case started
        /// A live full charge took its later monotonic deadline.
        case extended
        /// A live full charge's monotonic deadline was later or the same;
        /// it continues unchanged.
        case kept(RunningDeadline)
    }

    /// Installs `candidate`, a schedule's full charge, in ``activeOverride``
    /// and `input` by D82's rules, and says how. A live full charge keeps
    /// the later of the two monotonic deadlines, so it is never shortened;
    /// one whose monotonic deadline has passed is replaced as expired; a
    /// discharge session is replaced. Liveness is judged on
    /// `input.overrideUptime`, as the policy judges expiry.
    private func installScheduledFullCharge(_ candidate: ChargeOverride, in input: inout PolicyInput) -> ScheduledStart {
        let uptimeAtNow = input.overrideUptime
        if var running = activeOverride, running.kind == .fullCharge, running.isLive(atUptime: uptimeAtNow) {
            // Deadlines compare on the monotonic clock only: a wall-clock
            // estimate can be wrong after a clock change. A running full
            // charge is never shortened, so its deadline may be later than
            // the schedule's end.
            let isExtended = candidate.expiresAtUptime > running.expiresAtUptime
            if isExtended {
                running.expiresAtUptime = candidate.expiresAtUptime
                running.source = .schedule
            }
            running.expiresAt = running.deadlineEstimate(now: input.now, uptime: uptimeAtNow)
            activeOverride = running
            input.activeOverride = running
            if isExtended { return .extended }
            return .kept(candidate.expiresAtUptime == running.expiresAtUptime ? .same : .later)
        }
        if let previous = activeOverride {
            if previous.isLive(atUptime: uptimeAtNow) {
                record(.override, "\(Self.describe(previous)) ended: the scheduled full charge started.")
            } else {
                // Its monotonic deadline passed before this evaluation: it
                // expired, as the policy would have found.
                lastEndedOverride = EndedOverride(override: previous, end: .expired)
                overridesEnded += 1
                record(.override, "\(Self.describe(previous)) \(OverrideEnd.expired).")
            }
        }
        activeOverride = candidate
        input.activeOverride = candidate
        return .started
    }

    /// Derives the displayed deadline of the running override from its
    /// monotonic deadline, with `input.now` and `input.overrideUptime`,
    /// which are read together, so a clock change since it started does not
    /// leave a stale estimate.
    private func refreshOverrideDeadlineEstimate(in input: inout PolicyInput) {
        guard var running = activeOverride else { return }
        running.expiresAt = running.deadlineEstimate(now: input.now, uptime: input.overrideUptime)
        guard running != activeOverride else { return }
        activeOverride = running
        input.activeOverride = running
    }

    // MARK: - Guided calibration

    /// Starts a guided calibration (research note 12 §7) if every condition
    /// of §7.4 holds on a fresh evaluation (``CalibrationAdmission``);
    /// otherwise ``CalibrationStatus/refusal`` says why and nothing starts.
    /// The session is saved and read back before it asks for anything; then
    /// an evaluation asks for macOS's Charge Limit at 100% for step 1.
    ///
    /// - Parameter isNotifying: whether the owner's notifications are on and
    ///   shown, so that requests reach them outside the menu.
    @discardableResult
    public func startCalibration(_ confirmations: CalibrationConfirmations, isNotifying: Bool) async -> ControllerStatus {
        await exclusively {
            await performEvaluation(.manual)
            calibration.refusal = nil
            if let refusal = CalibrationAdmission.refusal(status: status, settings: settings, confirmations: confirmations, isNotifying: isNotifying, now: now()) {
                calibration.refusal = refusal
                record(.calibration, "Calibration not started: \(refusal)")
                return
            }
            let startNow = now()
            // Admission requires both; checked again for the compiler.
            guard let reading = ChargingPolicy.usableSnapshot(snapshot, now: startNow), let ownerLimit = nativeLimit?.ownerLimit ?? nativeLimit?.reportedLimit else { return }
            let session = CalibrationSession.start(
                id: UUID(),
                at: calibration.stamp(at: startNow),
                ownerLimit: ownerLimit,
                cellKeeperLimit: settings.chargeLimit,
                before: CalibrationCapacities(reading.health),
                temperatureCheck: reading.temperatureCelsius == nil ? .ownerConfirmedCoolRoom : .measured,
                optimizedCharging: confirmations.optimizedCharging ?? .boundAccepted
            )
            let isStarted = calibration.start(session)
            recordCalibrationLog()
            if isStarted {
                await performEvaluation(.overrideChanged)
            }
        }
    }

    /// Ends the calibration in progress, running or paused: its report
    /// replaces it in the store, and the normal policy applies at once.
    @discardableResult
    public func cancelCalibration() async -> ControllerStatus {
        await exclusively {
            calibration.loadIfNeeded()
            recordCalibrationLog()
            guard calibration.isInProgress else { return }
            let cancelNow = now()
            calibration.cancel(at: calibration.stamp(at: cancelNow), reading: ChargingPolicy.usableSnapshot(snapshot, now: cancelNow))
            recordCalibrationLog()
            await performEvaluation(.overrideChanged)
        }
    }

    /// The owner's "continue" for a session found at launch (§7.6 step 4).
    /// An evaluation runs first, for a fresh reading and, at the first
    /// command after launch, the startup checks; then the session goes on
    /// from that reading (``CalibrationSession/continued(at:reading:run:restAnswer:bootTime:)``),
    /// and only then may it ask for 100% again. `restAnswer` is the owner's
    /// answer whether the Mac stayed shut down and unplugged until the time
    /// shown, needed in step 5 after a restart.
    @discardableResult
    public func continueCalibration(restAnswer: Bool? = nil) async -> ControllerStatus {
        await exclusively {
            calibration.loadIfNeeded()
            recordCalibrationLog()
            guard calibration.status.isPaused else { return }
            await performEvaluation(.manual)
            guard calibration.status.isPaused, !calibration.needsStartupCheck else { return }
            let continueNow = now()
            calibration.continueSession(restAnswer: restAnswer, reading: ChargingPolicy.usableSnapshot(snapshot, now: continueNow), at: calibration.stamp(at: continueNow))
            recordCalibrationLog()
            if calibration.isInProgress, !calibration.status.isPaused {
                await performEvaluation(.overrideChanged)
            }
        }
    }

    /// Forgets the ended session's outcome once the owner has seen it; its
    /// report stays as the last calibration.
    @discardableResult
    public func dismissCalibrationOutcome() async -> ControllerStatus {
        await exclusively {
            calibration.dismissOutcome()
        }
    }

    /// The latest reading if the policy accepts it now.
    private var usableSnapshotNow: BatterySnapshot? {
        ChargingPolicy.usableSnapshot(snapshot, now: now())
    }

    private func calibrationContext(at evaluationNow: Date, adoptionsBefore: Int) -> CalibrationContext {
        CalibrationContext(
            settings: settings,
            capabilities: capabilities,
            isBackendFaulted: isBackendFaulted,
            hasPendingBackend: pendingBackend != nil,
            hasSchedule: schedule != nil,
            hasAdoptedChange: adoptionCount > adoptionsBefore,
            reading: ChargingPolicy.usableSnapshot(snapshot, now: evaluationNow)
        )
    }

    private static func calibrationEvent(_ trigger: EvaluationTrigger) -> CalibrationObservation.Event {
        switch trigger {
        case .willSleep: .willSleep
        case .didWake: .didWake
        default: .check
        }
    }

    /// Records what the calibration did since this was last called.
    private func recordCalibrationLog() {
        for line in calibration.takeLog() {
            record(.calibration, line)
        }
    }

    /// Confirms `.normal` on the current backend, then switches to
    /// `newBackend`. If `.normal` cannot be confirmed, the current backend
    /// stays responsible: the switch is refused for now and stays pending,
    /// later evaluations keep requesting `.normal`, and the switch completes
    /// once it is confirmed. Choosing a backend of the current kind cancels a
    /// pending switch.
    @discardableResult
    public func switchBackend(to newBackend: any ChargingBackend) async -> ControllerStatus {
        await exclusively {
            if newBackend.descriptor.identifier == backend.descriptor.identifier {
                if let pending = pendingBackend {
                    pendingBackend = nil
                    record(.settings, "Switch to \(pending.descriptor.displayName) cancelled; staying with \(backend.descriptor.displayName).")
                    await performEvaluation(.backendChanged)
                }
                return
            }
            calibration.loadIfNeeded()
            calibration.endIfInProgress(.controlChanged, at: calibration.stamp(at: now()), reading: usableSnapshotNow)
            recordCalibrationLog()
            pendingBackend = newBackend
            guard await restoreNormal(reason: "switching backend") else {
                record(.safety, "Backend switch to \(newBackend.descriptor.displayName) refused for now: normal charging could not be confirmed on \(backend.descriptor.displayName). CellKeeper keeps trying and switches once it is confirmed.", level: .fault)
                return
            }
            guard !isAdoptionUnsaved else {
                record(.safety, "Backend switch to \(newBackend.descriptor.displayName) waits: CellKeeper could not yet store its record of the Charge Limit it kept. It keeps trying and switches once it has.", level: .error)
                return
            }
            await completePendingSwitch()
        }
    }

    /// Asks the backend to check again what it depends on (the native
    /// backend's shortcut; macOS's own Charge Limit for the helper backend,
    /// read again at once), then evaluates.
    @discardableResult
    public func recheckBackendAvailability() async -> ControllerStatus {
        await exclusively {
            await backend.recheckAvailability()
            await performEvaluation(.manual)
        }
    }

    /// Native-limit backends: the user confirmed that their own Charge Limit
    /// is 100%, so a report of "no limit" may be recorded as such.
    @discardableResult
    public func confirmNoLimitIsOwnerLimit() async -> ControllerStatus {
        await exclusively {
            guard let native = backend as? NativeChargeLimitBackend else { return }
            await native.confirmNoLimitIsOwnerLimit()
            record(.settings, "You confirmed that your own macOS Charge Limit is 100% (no limit).")
            await performEvaluation(.manual)
        }
    }

    /// Native-limit backends: discards an unreadable record of the user's
    /// limit after the user has set their limit by hand.
    @discardableResult
    public func discardUnreadableOwnershipRecord() async -> ControllerStatus {
        await exclusively {
            guard let native = backend as? NativeChargeLimitBackend else { return }
            do {
                try await native.discardUnreadableRecord()
                record(.safety, "Discarded the unreadable record of your own Charge Limit at your request.")
            } catch {
                record(.failure, "Could not discard the unreadable record: \(error)", level: .error)
            }
            await performEvaluation(.manual)
        }
    }

    /// Switches to the pending backend. `.normal` must already be confirmed.
    private func completePendingSwitch() async {
        guard let newBackend = pendingBackend else { return }
        pendingBackend = nil
        let previousName = backend.descriptor.displayName
        backend = newBackend
        consecutiveFailures = 0
        lastFailureUptime = nil
        lastFailedRestoreUptime = nil
        restrictingRequests.removeAll { !$0.touchedHardware }
        currentMode = nil
        ownedMode = nil
        unconfirmedRequests = []
        isRestoreOutstanding = false
        hasSeededOwnership = false
        didLastReadReportFault = false
        handledFaults = HandledFaults()
        nativeLimit = nil
        macOSLimitGate = nil
        macOSLimitReleaseUnconfirmed = nil
        responsibleMode = nil
        reportedModeIsOwn = nil
        lastExecution = nil
        record(.settings, "Control backend changed from \(previousName) to \(newBackend.descriptor.displayName).")
        await performEvaluation(.backendChanged)
    }

    /// True while an adopted change's marker could not be stored yet.
    private var isAdoptionUnsaved: Bool {
        nativeLimit?.isAdoptionUnsaved ?? false
    }

    /// Before management is turned on again, removes what kept it off after
    /// an adoption (the marker, or a record the marker could not replace).
    /// Returns false if that could not be done; management must stay off.
    private func retireAdoption() async -> Bool {
        if let native = backend as? NativeChargeLimitBackend {
            guard await native.clearAdoptionMarker() else { return false }
            nativeLimit = await native.nativeLimitStatus()
        }
        if let adoptionMarkerStore {
            do {
                try NativeChargeLimitBackend.removeAdoptionMarker(in: adoptionMarkerStore)
            } catch {
                return false
            }
        }
        return true
    }

    /// Clears the faulted state so non-normal modes may be requested again.
    /// This is the user's deliberate acknowledgement: a backend that stopped
    /// making changes after a problem it found (a helper after an outside
    /// change) may restore macOS defaults now
    /// (``ChargingBackend/resetAfterFault()``).
    @discardableResult
    public func resetBackendFault() async -> ControllerStatus {
        await exclusively {
            guard consecutiveFailures > 0 else { return }
            consecutiveFailures = 0
            lastFailureUptime = nil
            didLastReadReportFault = false
            handledFaults = HandledFaults()
            record(.safety, "Backend fault cleared by user.")
            do {
                try await backend.resetAfterFault()
            } catch {
                registerFailure("\(backend.descriptor.displayName) backend could not recover after the fault was cleared: \(error)")
            }
            await performEvaluation(.manual)
        }
    }

    /// Requests macOS default charging (`.normal`) and confirms it.
    @discardableResult
    public func restoreSystemDefaults(reason: String) async -> ControllerStatus {
        await exclusively {
            _ = await restoreNormal(reason: reason)
        }
    }

    /// Restores `.normal`, then stops: every later command (including ones
    /// already queued) becomes a no-op. Call when quitting.
    @discardableResult
    public func shutdown(reason: String) async -> ControllerStatus {
        await exclusively {
            _ = await restoreNormal(reason: reason)
            isShutDown = true
            record(.safety, "Controller shut down; no further requests will be made.")
        }
    }

    /// Removes CellKeeper's helper (safety precondition 9). If a helper is
    /// registered, first restores normal charging on the current backend and
    /// confirms it (with macOS's Charge Limit: your own limit, its record
    /// deleted only after the read-back); only then runs `removal`
    /// (``HelperRemoval/remove()``). If normal charging is not confirmed,
    /// the helper is not contacted and nothing is removed. The command lock
    /// is held throughout, so no evaluation can apply a restriction between
    /// the confirmed restore and the helper's own. Every step is recorded in
    /// the activity log. With no helper registered, nothing is restored or
    /// removed.
    @discardableResult
    public func removeHelper(using removal: HelperRemoval) async -> HelperUninstallOutcome {
        await performHelperRemoval(removal, force: nil)
    }

    /// As ``removeHelper(using:)``, except that a helper whose restore went
    /// unconfirmed because the transport failed or no reply arrived in time,
    /// at any stage (connecting, `hello` or the restore), is unregistered
    /// anyway, and the outcome says that its restore was not confirmed
    /// (``HelperRemoval/remove(force:)``). An explicit reply other than `ok`
    /// to the restore (`hardwareError`, `notIntroduced`, `rateLimited`) is
    /// never overridden: such a helper is not unregistered.
    @discardableResult
    public func removeHelper(using removal: HelperRemoval, force: HelperRemovalForce) async -> HelperUninstallOutcome {
        await performHelperRemoval(removal, force: force)
    }

    private func performHelperRemoval(_ removal: HelperRemoval, force: HelperRemovalForce?) async -> HelperUninstallOutcome {
        await acquire()
        defer { release() }
        guard !isShutDown else { return .controllerShutDown }
        let registration = await removal.registrationStatus()
        guard !registration.meansNoHelperRegistered else {
            let outcome = HelperUninstallOutcome.nothingToRemove(registration)
            record(.safety, "Remove helper: \(outcome.summary)")
            return outcome
        }
        let backendName = backend.descriptor.displayName
        record(.safety, "Remove helper: confirming normal charging on \(backendName) before contacting the helper.")
        guard await restoreNormal(reason: "removing the helper") else {
            let outcome = HelperUninstallOutcome.normalChargingNotConfirmed(backend: backendName)
            record(.safety, "Remove helper: \(outcome.summary)", level: .fault)
            return outcome
        }
        let result: HelperRemovalOutcome
        if let force {
            result = await removal.remove(force: force)
        } else {
            result = await removal.remove()
        }
        record(.safety, "Remove helper: \(result.summary)", level: result.isHelperRemoved && result.isRestoreConfirmed ? .default : .error)
        return .helperRemoval(result)
    }

    // MARK: - Evaluation

    private func performEvaluation(_ trigger: EvaluationTrigger) async {
        loadScheduleIfNeeded()
        loadWeeklyIfNeeded()
        calibration.loadIfNeeded()
        recordCalibrationLog()
        // Note 12 §7.6 step 1: before anything is written, whether the
        // backend holds a record of the owner's limit (what it loaded; no
        // new I/O). Its own recovery then runs first, as always.
        var calibrationHadRecord: Bool?
        if calibration.needsStartupCheck {
            calibrationHadRecord = await backend.nativeLimitStatus()?.hasUnresolvedOwnership ?? false
        }
        let adoptionsBefore = adoptionCount
        let previousSnapshot = snapshot
        do {
            let fresh = try await telemetry.currentSnapshot()
            snapshot = fresh
            if telemetryError != nil {
                record(.telemetry, "Telemetry available again.")
            }
            telemetryError = nil
        } catch {
            snapshot = nil
            let message = String(describing: error)
            if telemetryError != message {
                record(.telemetry, "Telemetry unavailable: \(message)", level: .error)
            }
            telemetryError = message
        }
        if let snapshot, Self.isPolicyRelevantChange(from: previousSnapshot, to: snapshot) {
            record(.telemetry, Self.describe(snapshot))
        }

        let evaluationUptime = uptime()
        switch trigger {
        case .willSleep: sleepAnnouncedAtUptime = evaluationUptime
        case .didWake, .launch: sleepAnnouncedAtUptime = nil
        default: break
        }
        if let announced = sleepAnnouncedAtUptime, evaluationUptime - announced > Self.sleepAnnouncementWindow {
            sleepAnnouncedAtUptime = nil
        }
        if !isBackendFaulted, let lastFailure = lastFailureUptime, evaluationUptime - lastFailure > Self.failureMemory {
            consecutiveFailures = 0
            lastFailureUptime = nil
        }

        capabilities = await backend.capabilities()
        await observeBackendMode()
        let heldWhenMacOSLimitStarted = noteMacOSChargeLimit()
        let releaseReason: ReleaseReason? = pendingBackend != nil ? .backendSwitch
            : isRestoreOutstanding ? .restoreUnfinished
            : isOwnedStateUnverified ? .stateUnverified
            : nil

        // Two monotonic readings, either side of the backend's reads:
        // - `evaluationUptime`, read before them, times what errs toward
        //   restricting when read early: the rate limit of restricting
        //   requests, the spacing of automatic restore retries, the
        //   temperature pause and its minimum, and the sleep and failure
        //   memory.
        // - `uptimeAtNow`, read together with the wall time after them,
        //   times overrides: whether one has expired (`overrideUptime`), a
        //   scheduled full charge's deadline, and the displayed deadline.
        //   An evaluation that straddles a deadline then ends the override,
        //   and the reads' duration does not shorten a new deadline.
        // The time zone a weekly full charge is read in is taken with them.
        let evaluationNow = now()
        let uptimeAtNow = uptime()
        let evaluationTimeZone = timeZone()
        var input = PolicyInput(
            now: evaluationNow,
            uptime: evaluationUptime,
            overrideUptime: uptimeAtNow,
            settings: settings,
            snapshot: snapshot,
            activeOverride: activeOverride,
            capabilities: capabilities,
            currentMode: currentMode,
            memory: memory,
            isBackendFaulted: isBackendFaulted,
            recentRestrictingRequests: restrictingRequests.map(\.uptime),
            isSleepImminent: sleepAnnouncedAtUptime != nil,
            restoreRetryNotBefore: trigger.isAutomatic
                ? lastFailedRestoreUptime.map { $0 + ChargingPolicy.minimumRestoreRetryInterval }
                : nil,
            releaseReason: releaseReason
        )
        // The calibration, then the schedules, after the backend's mode was
        // read, so that an adoption that turned management off in this
        // evaluation is seen, and on the input the policy then evaluates.
        // A session excludes full charges, so it is checked first (note 12
        // §7.4). The one-shot first, then the weekly one: if both start, the
        // second meets the first's full charge (D82).
        let calibrationStamp = calibration.stamp(at: evaluationNow)
        calibration.check(
            event: Self.calibrationEvent(trigger),
            observedMode: currentMode,
            context: calibrationContext(at: evaluationNow, adoptionsBefore: adoptionsBefore),
            startup: calibrationHadRecord.map { CalibrationStartupEvidence(hadRecord: $0, limitRead: nativeLimit?.reportedLimit) },
            at: calibrationStamp
        )
        recordCalibrationLog()
        input.calibrationWantsFullLimit = calibration.wantsFullLimit
        let isCalibrating = calibration.isInProgress
        let oneShotStart = isCalibrating ? nil : applySchedule(to: &input)
        let weeklyStart = applyWeekly(to: &input, timeZone: evaluationTimeZone, isCalibrating: isCalibrating)
        refreshOverrideDeadlineEstimate(in: &input)
        restrictingRequests.removeAll { input.uptime - $0.uptime >= 60 * 60 }
        let newDecision = ChargingPolicy.evaluate(input)
        memory = newDecision.memory
        lastEvaluation = input.now

        if let ended = newDecision.overrideEnded, let override = activeOverride {
            activeOverride = nil
            lastEndedOverride = EndedOverride(override: override, end: ended)
            overridesEnded += 1
            record(.override, "\(Self.describe(override)) \(ended).")
            // Every schedule that started, extended or kept this full charge
            // in this evaluation found the battery already full. There is
            // still one override and one ending.
            if ended == .completed {
                if oneShotStart != nil, let outcome = scheduleOutcome {
                    scheduleOutcome = outcome.foundAlreadyFull
                }
                if weeklyStart != nil, let outcome = weeklyOutcome {
                    weeklyOutcome = outcome.foundAlreadyFull
                }
            }
        }
        if Self.isMeaningfulChange(from: decision, to: newDecision) {
            let state = newDecision.state.description
            record(.decision, "\(state.prefix(1).uppercased())\(state.dropFirst()) (\(trigger)): wants \(describeTarget(newDecision.desiredMode)), action \(Self.describe(newDecision.action, nativeLimit: capabilities.isEnforcedByMacOS)). \(newDecision.reason.description(restoring: restoreTarget))")
        }
        for note in newDecision.notes where !(decision?.notes.contains(note) ?? false) {
            record(.decision, "Note: \(note)")
        }
        decision = newDecision

        let requestsBefore = requestsMade
        await execute(newDecision.action)
        nativeLimit = await backend.nativeLimitStatus()
        var requestFailed = false
        if requestsMade != requestsBefore, case .failed? = lastExecution?.result {
            requestFailed = true
        }
        calibration.afterRequests(
            wantedFull: input.calibrationWantsFullLimit,
            decision: newDecision,
            currentMode: currentMode,
            requestFailed: requestFailed,
            context: calibrationContext(at: evaluationNow, adoptionsBefore: adoptionsBefore),
            at: calibrationStamp
        )
        recordCalibrationLog()
        if let held = heldWhenMacOSLimitStarted {
            recordMacOSLimitRelease(of: held)
        } else if let held = macOSLimitReleaseUnconfirmed, currentMode == .normal {
            macOSLimitReleaseUnconfirmed = nil
            record(.safety, "A read-back now shows normal charging: CellKeeper's restriction, \(describeTarget(held))\(simulationNote), which it asked to end when macOS's Charge Limit started to apply, has ended.")
        }
        await renewHoldIfStillWanted(newDecision)

        if pendingBackend != nil, currentMode == .normal, !(nativeLimit?.hasUnresolvedOwnership ?? false), !isAdoptionUnsaved {
            await completePendingSwitch()
        }
    }

    /// Reads the backend's mode, counting failures and detecting changes that
    /// CellKeeper did not make.
    private func observeBackendMode() async {
        isOwnedStateUnverified = false
        let adoptionsBefore = adoptionCount
        let observed: ChargeControlMode?
        do {
            observed = try await readBackendMode()
        } catch {
            // `ownedMode` is kept, so a later reading is still compared with
            // what CellKeeper last confirmed.
            currentMode = nil
            nativeLimit = await backend.nativeLimitStatus()
            // A fault reported with the failed read has faulted the backend
            // already (`readBackendMode()`).
            if !didLastReadReportFault {
                registerFailure("Could not read the backend's mode: \(error)")
            }
            isOwnedStateUnverified = holdsNonNormalState
            return
        }
        currentMode = observed
        nativeLimit = await backend.nativeLimitStatus()
        if !hasSeededOwnership {
            hasSeededOwnership = true
            if ownedMode == nil, let target = nativeLimit?.target {
                ownedMode = .nativeLimit(percent: target)
            }
            if let ownerLimit = nativeLimit?.ownerLimit {
                // A normal quit restores the limit and deletes the record, so
                // a record here means an earlier session did not finish. Its
                // markers may be stale, so restore before anything else.
                isRestoreOutstanding = true
                let left = nativeLimit?.target.map { " at \($0)%" } ?? ""
                record(.safety, "An earlier CellKeeper session left macOS's Charge Limit changed\(left); CellKeeper will finish restoring your own limit of \(ownerLimit)% first.")
            }
        }
        // A change adopted while reading has been handled by `adopt(_:)`.
        guard adoptionCount == adoptionsBefore else { return }
        guard capabilities.availability.acceptsRequests else { return }
        // A fault the backend found itself, possibly while CellKeeper held
        // nothing, has been handled by `readBackendMode()`.
        guard !didLastReadReportFault else { return }
        let origin = await backend.reportedModeOrigin()
        guard let observed else {
            registerFailure("The backend did not report its mode.")
            isOwnedStateUnverified = holdsNonNormalState
            return
        }
        if observed == .normal, !(nativeLimit?.hasUnresolvedOwnership ?? false) {
            isRestoreOutstanding = false
        }
        let isOwnDoing = origin == .cellKeeper || unconfirmedRequests.contains(observed)
        if let owned = ownedMode, owned != observed, isOwnDoing {
            ownedMode = observed
            unconfirmedRequests = []
            record(.result, "Now confirmed: \(describeTarget(observed)), requested earlier but not confirmed then.")
        } else if let owned = ownedMode, owned != observed, case .releasedByBackend(let release)? = origin {
            // The backend's own safety rules, not another tool: no fault.
            ownedMode = observed
            unconfirmedRequests = []
            record(.safety, "\(backend.descriptor.displayName) ended CellKeeper's restriction (\(describeTarget(owned))) itself: \(release). Not an outside change; now \(describeTarget(observed)).", level: release == .leaseExpired ? .error : .default)
        } else if ownedMode == observed {
            unconfirmedRequests = []
        } else if let owned = ownedMode {
            ownedMode = nil
            unconfirmedRequests = []
            consecutiveFailures = max(consecutiveFailures, Self.maximumConsecutiveFailures)
            if capabilities.isEnforcedByMacOS {
                record(.safety, "macOS's Charge Limit changed outside CellKeeper (expected \(describeTarget(owned)), found \(describeTarget(observed))); it may have been changed in System Settings or by another tool. Backend faulted; restoring your own limit.", level: .fault)
            } else {
                record(.safety, "Charging mode changed outside CellKeeper (expected \(describeTarget(owned)), found \(describeTarget(observed))); another tool may be controlling charging. Backend faulted; restoring normal charging.", level: .fault)
            }
        }
    }

    /// macOS's own Charge Limit, as a backend that switches charging itself
    /// reports it.
    private enum MacOSLimitGate: Equatable {
        /// Off: macOS reports no limit, or 100%.
        case off
        /// On at this percentage.
        case on(Int)
        /// The report could not be read or recognised; macOS may be limiting.
        case unknown(String)

        init?(_ status: MacOSChargeLimitStatus?) {
            guard let status else { return nil }
            if !status.isLimiting {
                self = .off
            } else if let limit = status.reportedLimit {
                self = .on(limit)
            } else {
                self = .unknown(status.readProblem ?? "no report")
            }
        }

        var isLimiting: Bool { self != .off }

        /// What macOS's report shows now, for the activity log.
        var summary: String {
            switch self {
            case .off: "macOS reports no active Charge Limit"
            case .on(let limit): "macOS reports its Charge Limit on at \(limit)%"
            case .unknown(let problem): "CellKeeper could not read macOS's Charge Limit report (\(problem)), so macOS may be limiting charging"
            }
        }
    }

    /// Marks restrictions as simulated in safety events, so a standalone
    /// message is never read as a change to the Mac's charging.
    private var simulationNote: String {
        capabilities.availability == .simulated ? " (simulated; your Mac's charging is not changed)" : ""
    }

    /// Logs a change of macOS's own Charge Limit as the backend reports it
    /// (``ControlCapabilities/macOSChargeLimit``). Returns the restriction
    /// CellKeeper held if macOS's limit has just started to apply (turned
    /// on, or became unreadable) while CellKeeper held one; this evaluation
    /// releases it, and ``recordMacOSLimitRelease(of:)`` logs the outcome.
    private func noteMacOSChargeLimit() -> ChargeControlMode? {
        let previous = macOSLimitGate
        let gate = MacOSLimitGate(capabilities.macOSChargeLimit)
        macOSLimitGate = gate
        guard let gate, gate != previous else { return nil }
        guard gate.isLimiting else {
            // Nothing to report the first time macOS's limit is seen off. A
            // release still unconfirmed stays a failure like any other, and
            // the decision log says what CellKeeper wants now.
            macOSLimitReleaseUnconfirmed = nil
            if previous != nil {
                record(.decision, "\(gate.summary) any more, so CellKeeper stops deferring to it. This does not establish that the setting is 100% or that macOS holds nothing else.")
            }
            return nil
        }
        if previous?.isLimiting == true {
            record(.decision, "\(gate.summary). CellKeeper keeps deferring to it: it withholds new restrictions and asks for the release of any restriction of its own.")
            return nil
        }
        if let held = responsibleMode {
            return held
        }
        record(.decision, "\(gate.summary). CellKeeper defers to it: it withholds new restrictions and asks for the release of any restriction of its own. To let CellKeeper manage charging, turn macOS's Charge Limit off in System Settings › Battery › Charging (set it to 100%).")
        return nil
    }

    /// After an evaluation that found macOS's own Charge Limit starting to
    /// apply while CellKeeper held `held`: logs, as a safety event, whether
    /// a read-back confirmed that the restriction ended. If not, it may
    /// remain; normal charging keeps being requested, and a later safety
    /// event says when a read-back shows it ended.
    private func recordMacOSLimitRelease(of held: ChargeControlMode) {
        let gate = macOSLimitGate ?? .unknown("no report")
        let started: String = switch gate {
        case .on(let limit): "macOS's Charge Limit was turned on (\(limit)%)"
        case .unknown, .off: gate.summary
        }
        let deferring = "CellKeeper withholds new restrictions until macOS reports no active limit."
        let heldText = "\(describeTarget(held))\(simulationNote)"
        if currentMode == .normal {
            macOSLimitReleaseUnconfirmed = nil
            record(.safety, "\(started) while CellKeeper held a restriction of its own: \(heldText). A read-back confirms that this restriction ended. \(deferring)")
        } else {
            macOSLimitReleaseUnconfirmed = held
            record(.safety, "\(started) while CellKeeper held a restriction of its own: \(heldText). No read-back has confirmed that this restriction ended, so it may remain; CellKeeper keeps asking for its release. \(deferring)", level: .error)
        }
    }

    /// True if CellKeeper may have a non-normal state in effect.
    private var holdsNonNormalState: Bool {
        (ownedMode.map { $0 != .normal } ?? false) || (nativeLimit?.hasUnresolvedOwnership ?? false)
    }

    /// Renews CellKeeper's hold at the end of an evaluation, only if it holds
    /// a confirmed non-normal mode that `decision` still wants and the
    /// backend is not faulted (research rule R3; `safety.md` precondition 3).
    /// Evaluations are the only caller, so a hung or stalled loop lets a
    /// helper's lease lapse. A failed renewal is a failure like a failed
    /// request: it is counted and `.normal` is requested at once.
    private func renewHoldIfStillWanted(_ decision: PolicyDecision) async {
        guard !isBackendFaulted, capabilities.availability.acceptsRequests,
              let held = ownedMode, held != .normal, currentMode == held,
              decision.desiredMode == held
        else { return }
        do {
            try await backend.renewHold(held)
        } catch {
            lastExecution = ExecutionRecord(date: now(), action: ChargingAction(requesting: held), result: .failed(String(describing: error)))
            registerFailure("Could not renew \(describeTarget(held)) with the \(backend.descriptor.displayName) backend: \(error)")
            _ = await restoreNormal(reason: "safety fallback after a failed renewal")
        }
    }

    private func execute(_ action: ChargingAction) async {
        switch action {
        case .noAction:
            return
        case .refuse(let reason):
            let isRepeat: Bool
            switch (lastExecution?.result, reason) {
            case (.refused(.rateLimited)?, .rateLimited):
                isRepeat = true
            default:
                isRepeat = lastExecution?.result == .refused(reason)
            }
            lastExecution = ExecutionRecord(date: now(), action: action, result: .refused(reason))
            if !isRepeat {
                record(.request, "Refused: \(reason)")
            }
        case .enableCharging, .disableCharging, .requestDischarge, .setNativeLimit:
            guard let mode = action.requestedMode else { return }
            await request(mode, for: action)
        }
    }

    private func request(_ mode: ChargeControlMode, for action: ChargingAction) async {
        requestsMade += 1
        let isRestricting = mode.isRestricting(from: currentMode)
        if isRestricting {
            // Attempts count, not just successes, so failures cannot cause
            // a burst of writes.
            restrictingRequests.append((uptime(), capabilities.availability.affectsHardware))
        }
        let target = describeTarget(mode)
        let ownerLimitBefore = nativeLimit?.ownerLimit
        if mode != .normal {
            // From here on the request may take effect, whatever its reply:
            // no read taken before it can show what is in effect.
            responsibleMode = mode
            currentMode = nil
            reportedModeIsOwn = nil
        }
        record(.request, "Requesting \(target) from \(backend.descriptor.displayName) backend.")
        do {
            let result = try await setAndConfirm(mode)
            var outcome = result.outcome
            if ownerLimitBefore == nil, let ownerLimit = nativeLimit?.ownerLimit {
                record(.safety, "Recorded your own macOS Charge Limit of \(ownerLimit)%; it will be restored when CellKeeper stops managing the limit.")
            }
            // A fault persists until the user clears it, even if restoring
            // normal charging succeeds.
            if !isBackendFaulted {
                consecutiveFailures = 0
                lastFailureUptime = nil
            }
            if outcome == .applied || outcome == .unchanged, !capabilities.availability.affectsHardware {
                record(.safety, "\(backend.descriptor.displayName) backend reported a hardware change but is not a hardware backend; treating it as simulated.", level: .error)
                outcome = .simulated
            }
            switch outcome {
            case .applied:
                lastExecution = ExecutionRecord(date: now(), action: action, result: .applied)
                record(.result, "Applied \(target) (confirmed by read-back\(confirmationDetail(mode))).")
            case .unchanged:
                // Nothing was written, so it does not count toward the limit.
                if isRestricting, !restrictingRequests.isEmpty {
                    restrictingRequests.removeLast()
                }
                lastExecution = ExecutionRecord(date: now(), action: action, result: .unchanged)
                record(.result, "Already in effect: \(target); nothing changed (confirmed by read-back\(confirmationDetail(mode))).")
            case .simulated:
                lastExecution = ExecutionRecord(date: now(), action: action, result: .simulated)
                record(.result, "Simulated \(mode); hardware unchanged.")
            case .adoptedOutsideChange:
                // Only a write counts toward the limit. `adopt(_:)` has
                // already logged what happened.
                if isRestricting, !result.wroteBeforeAdopting, !restrictingRequests.isEmpty {
                    restrictingRequests.removeLast()
                }
                lastExecution = ExecutionRecord(date: now(), action: action, result: .adoptedOutsideChange)
            }
        } catch {
            let message = String(describing: error)
            lastExecution = ExecutionRecord(date: now(), action: action, result: .failed(message))
            if error is FaultAlreadyHandled {
                // The confirmation's read reported a fault, which faulted the
                // backend and counted it already.
            } else if await !handleThrownFault(error, context: "Not applied") {
                registerFailure("Backend failed to apply \(target): \(message)")
            }
            if mode != .normal {
                _ = await restoreNormal(reason: "safety fallback after a failed request for \(target)")
            }
        }
    }

    /// What `.normal` is called in the activity log's reasons: the user's
    /// own limit for macOS's Charge Limit, normal charging otherwise.
    private var restoreTarget: String {
        capabilities.isEnforcedByMacOS ? describeTarget(.normal) : "normal charging"
    }

    /// How a mode is described in the activity log: in plain words, and
    /// with macOS's Charge Limit, `.normal` as the user's own limit.
    private func describeTarget(_ mode: ChargeControlMode) -> String {
        guard capabilities.isEnforcedByMacOS, mode == .normal else { return mode.description }
        return "your own macOS Charge Limit" + (nativeLimit?.ownerLimit.map { " of \($0)%" } ?? "")
    }

    /// For native limits, the value macOS reported when confirming.
    private func confirmationDetail(_ mode: ChargeControlMode) -> String {
        guard capabilities.isEnforcedByMacOS, let reported = nativeLimit?.reportedLimit else { return "" }
        return ": macOS reports \(reported)%"
    }

    /// What a confirmed request did.
    private struct RequestResult {
        var outcome: ControlOutcome
        /// For ``ControlOutcome/adoptedOutsideChange``: CellKeeper had
        /// already written when it found the outside change.
        var wroteBeforeAdopting = false
    }

    /// Reads the backend's mode. A native backend may adopt an outside change
    /// during any read; it is handled here at once, so no read can leave an
    /// adoption unreported. Callers compare ``adoptionCount`` to notice it.
    /// So is a fault the backend reports with the read, also when the read
    /// fails: every read, including a request's confirmation, a fallback's
    /// and a recovery's, faults the backend at once for it.
    private func readBackendMode() async throws -> ChargeControlMode? {
        let mode: ChargeControlMode?
        do {
            mode = try await backend.currentMode()
        } catch {
            reportedModeIsOwn = nil
            await handleReportedFault()
            throw error
        }
        await noteResponsibility(after: mode)
        if let change = await backend.takeAdoptedLimitChange() {
            nativeLimit = await backend.nativeLimitStatus()
            // A marker from an earlier session needs nothing more if
            // management already stayed off.
            if !change.isFromEarlierSession || settings.isManagementEnabled {
                adopt(change)
            }
        }
        await handleReportedFault()
        return mode
    }

    /// Updates what CellKeeper may still have in effect after a successful
    /// read (requests are serialised, so it was taken after the last one).
    /// Only normal charging, or the backend's records showing that nothing
    /// in effect is CellKeeper's, ends the responsibility; a fault does not.
    private func noteResponsibility(after mode: ChargeControlMode?) async {
        guard let mode else {
            reportedModeIsOwn = nil
            return
        }
        reportedModeIsOwn = await backend.isReportedModeOwn()
        if mode == .normal {
            // With macOS's Charge Limit, `.normal` means only that no record
            // is held, which is no evidence of a restore; that backend
            // counts its own (`NativeLimitStatus.restoresConfirmed`).
            if responsibleMode != nil, !capabilities.isEnforcedByMacOS {
                releasesConfirmed += 1
            }
            responsibleMode = nil
        } else if reportedModeIsOwn == false {
            // Someone else's, by positive evidence in the backend's records:
            // CellKeeper's own restriction has ended, but not as the release
            // it asked for.
            responsibleMode = nil
            macOSLimitReleaseUnconfirmed = nil
        }
    }

    /// Faults the backend for a fault it reported with its last read
    /// (``ReportedModeOrigin/changedOutside(_:)`` or
    /// ``ReportedModeOrigin/needsAcknowledgement(_:)``), through
    /// ``note(_:isThrown:message:)``: counted once, and logged once per kind
    /// and per distinct outside change for as long as the backend keeps
    /// reporting faults. Afterwards ``didLastReadReportFault`` says whether
    /// the last read reported one.
    private func handleReportedFault() async {
        let fault: BackendFault?
        switch await backend.reportedModeOrigin() {
        case .changedOutside(let detail)?:
            fault = .outside(detail, evidence: await backend.outsideChangeEvidence())
        case .needsAcknowledgement(let detail)?:
            fault = .acknowledgement(detail)
        default:
            fault = nil
        }
        guard let fault else {
            didLastReadReportFault = false
            handledFaults = HandledFaults()
            return
        }
        didLastReadReportFault = true
        note(fault, isThrown: false) { fault in
            switch fault {
            case .outside(let detail, _):
                "Charging control changed outside CellKeeper: \(detail). Backend faulted; CellKeeper asks for the release of its own restrictions and does not override the change."
            case .acknowledgement(let detail):
                "\(detail). Backend faulted: clear the fault to acknowledge it; until then only normal charging is requested."
            }
        }
    }

    /// A fault a backend reports: an outside change it found (rule R27), or
    /// a problem it waits for someone to acknowledge (its own failure, or a
    /// restriction it cannot attribute).
    private enum BackendFault: Equatable {
        /// An outside change, with the backend's records of the changes
        /// behind it (``ChargingBackend/outsideChangeEvidence()``).
        case outside(String, evidence: Set<RecordedChange>)
        case acknowledgement(String)
    }

    /// The faults handled since the backend's reads last reported none.
    private struct HandledFaults {
        /// What identifies an outside change: the backend's record of it.
        /// A backend without records cannot tell its changes apart, and a
        /// read reports one in other words than a request throws it, so all
        /// its outside changes share one identity until a read reports no
        /// fault: one change, read and then thrown, is logged once.
        enum OutsideKey: Hashable {
            case recorded(RecordedChange)
            case unrecorded
        }

        var acknowledgement = false
        var outsideKeys: Set<OutsideKey> = []

        var isEmpty: Bool { !acknowledgement && outsideKeys.isEmpty }

        /// Whether `fault` is news: the first problem needing
        /// acknowledgement, or an outside change with a recorded change not
        /// seen yet (the same change read again or thrown is not news; a new
        /// one, a new generation or another helper process, is). For a
        /// backend without records, only its first outside change is news.
        /// Notes it either way.
        mutating func note(_ fault: BackendFault) -> Bool {
            switch fault {
            case .acknowledgement:
                defer { acknowledgement = true }
                return !acknowledgement
            case .outside(_, let evidence):
                let keys: Set<OutsideKey> = evidence.isEmpty ? [.unrecorded] : Set(evidence.map(OutsideKey.recorded))
                let isNew = !keys.isSubset(of: outsideKeys)
                outsideKeys.formUnion(keys)
                return isNew
            }
        }
    }

    /// A request whose confirmation read reported a fault: the fault faulted
    /// the backend and was counted when the read reported it, so the
    /// request's failure is not counted again.
    private struct FaultAlreadyHandled: Error, CustomStringConvertible {
        let failure: BackendError
        var description: String { String(describing: failure) }
    }

    /// Faults the backend at once for `fault`, from a read or a request,
    /// whatever the operation: an evaluation, a restore, a backend switch or
    /// quitting. A fault is counted only once while the backend keeps
    /// reporting faults; each kind is logged once, and an outside change is
    /// logged again when it is a new one, also after a problem needing
    /// acknowledgement (an escalation), so an existing fault never hides
    /// fresh evidence of another writer.
    private func note(_ fault: BackendFault, isThrown: Bool, message: (BackendFault) -> String) {
        let wasFaulted = !handledFaults.isEmpty
        let isNews = handledFaults.note(fault)
        ownedMode = nil
        unconfirmedRequests = []
        if !wasFaulted {
            consecutiveFailures = max(consecutiveFailures + (isThrown ? 1 : 0), Self.maximumConsecutiveFailures)
            lastFailureUptime = uptime()
        } else {
            consecutiveFailures = max(consecutiveFailures, Self.maximumConsecutiveFailures)
        }
        if isNews {
            record(.safety, message(fault), level: .fault)
        }
    }

    /// For an error a request threw that is a fault (``BackendError/changedOutside(expected:found:)``
    /// or ``BackendError/needsAcknowledgement(_:)``): faults the backend at
    /// once through ``note(_:isThrown:message:)`` and returns true. Any other
    /// error is left to the caller.
    private func handleThrownFault(_ error: any Error, context: String) async -> Bool {
        let fault: BackendFault
        switch error {
        case BackendError.changedOutside:
            fault = .outside(String(describing: error), evidence: await backend.outsideChangeEvidence())
        case BackendError.needsAcknowledgement(let detail):
            fault = .acknowledgement(detail)
        default:
            return false
        }
        note(fault, isThrown: true) { fault in
            switch fault {
            case .outside(let detail, _):
                "\(context): \(detail). It may have been changed in System Settings or by another tool. Backend faulted; CellKeeper does not override the change and only normal charging is requested."
            case .acknowledgement(let detail):
                "\(context): \(detail). Backend faulted: clear the fault to acknowledge it; until then only normal charging is requested."
            }
        }
        return true
    }

    /// Sets a mode and confirms it by read-back. On success the mode is
    /// recorded as owned by CellKeeper. On failure the current mode is
    /// unknown, and the last confirmed mode stays the expectation that later
    /// readings are compared with. A native backend that finds an outside
    /// change at any point adopts it; that is reported as
    /// ``ControlOutcome/adoptedOutsideChange``, not as a failure.
    private func setAndConfirm(_ mode: ChargeControlMode) async throws -> RequestResult {
        let adoptionsBefore = adoptionCount
        do {
            // If the backend throws, the request is not counted as possibly in
            // effect: native backends track that themselves, through their
            // record (`reportedModeOrigin()`).
            let outcome = try await backend.setMode(mode)
            if outcome == .adoptedOutsideChange {
                // Nothing was written: the user's new limit stays in effect.
                nativeLimit = await backend.nativeLimitStatus()
                adopt(await backend.takeAdoptedLimitChange())
                return RequestResult(outcome: outcome)
            }
            let readBack: ChargeControlMode?
            do {
                readBack = try await readBackendMode()
            } catch {
                unconfirmedRequests.insert(mode)
                let failure = BackendError.verificationFailed(expected: mode, actual: nil)
                // A fault the backend reported with this read has faulted it
                // and been counted; the caller must not count it again.
                throw didLastReadReportFault ? FaultAlreadyHandled(failure: failure) : failure
            }
            nativeLimit = await backend.nativeLimitStatus()
            if adoptionCount > adoptionsBefore {
                // Someone else changed the limit right after CellKeeper's
                // write; the read-back adopted it.
                return RequestResult(outcome: .adoptedOutsideChange, wroteBeforeAdopting: outcome == .applied)
            }
            guard readBack == mode else {
                unconfirmedRequests.insert(mode)
                let failure = BackendError.verificationFailed(expected: mode, actual: readBack)
                throw didLastReadReportFault ? FaultAlreadyHandled(failure: failure) : failure
            }
            currentMode = mode
            ownedMode = mode
            unconfirmedRequests = []
            if mode == .normal {
                lastFailedRestoreUptime = nil
                isRestoreOutstanding = false
            }
            return RequestResult(outcome: outcome)
        } catch {
            nativeLimit = await backend.nativeLimitStatus()
            if let change = await backend.takeAdoptedLimitChange() {
                // The backend wrote, then found while confirming that someone
                // else had changed the limit, and adopted that value.
                adopt(change)
                return RequestResult(outcome: .adoptedOutsideChange, wroteBeforeAdopting: true)
            }
            currentMode = nil
            if mode == .normal {
                lastFailedRestoreUptime = uptime()
                isRestoreOutstanding = true
            }
            throw error
        }
    }

    /// Requests `.normal` and confirms it. Returns true only if the backend is
    /// confirmed to be in `.normal`, or cannot control anything and reports no
    /// other mode. Caller must hold the lock.
    private func restoreNormal(reason: String) async -> Bool {
        // Never waits for anything `.normal` does not depend on, such as a
        // read of macOS's Charge Limit.
        let capabilities = await backend.capabilitiesForRelease()
        let ownerLimit = await backend.nativeLimitStatus()?.ownerLimit
        let isNative = capabilities.isEnforcedByMacOS
        guard capabilities.availability.acceptsRequests else {
            let adoptionsBefore = adoptionCount
            let observed = try? await readBackendMode()
            if adoptionCount > adoptionsBefore {
                // The limit in effect is the user's own; `adopt(_:)` logged it.
                return true
            }
            nativeLimit = await backend.nativeLimitStatus()
            if nativeLimit?.isRecordUnreadable == true {
                record(.safety, "Could not restore your own macOS Charge Limit (\(reason)): CellKeeper's record of it cannot be read. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control.", level: .fault)
                return false
            }
            if observed == nil || observed == .normal, !(nativeLimit?.hasUnresolvedOwnership ?? false) {
                record(.safety, "Restore normal charging (\(reason)): the backend controls nothing; nothing to restore.")
                return true
            }
            if isNative, let ownerLimit {
                record(.safety, "Could not restore your own macOS Charge Limit of \(ownerLimit)% (\(reason)): the backend cannot make changes right now. Set it in System Settings › Battery › Charging.", level: .fault)
            } else {
                record(.safety, "Could not restore normal charging (\(reason)): the backend accepts no requests but reports \(observed.map(String.init(describing:)) ?? "unknown").", level: .fault)
            }
            return false
        }
        do {
            let outcome = try await setAndConfirm(.normal).outcome
            if outcome == .adoptedOutsideChange {
                // The limit now in effect is the user's own; `adopt(_:)` has
                // logged it.
                return true
            }
            if isNative {
                let reported = nativeLimit?.reportedLimit.map { "; macOS reports \($0)%" } ?? ""
                if let ownerLimit {
                    let suffix = outcome == .unchanged ? " (already in effect)" : ""
                    record(.safety, "Restored your own macOS Charge Limit of \(ownerLimit)% (\(reason))\(suffix)\(reported).")
                } else {
                    record(.safety, "Nothing to restore: CellKeeper holds no change to macOS's Charge Limit (\(reason))\(reported).")
                }
            } else {
                let suffix = outcome == .simulated ? " (simulated; hardware unchanged)" : ""
                record(.safety, "Restored normal charging (\(reason))\(suffix).")
            }
            return true
        } catch {
            if isNative, let ownerLimit {
                registerFailure("Could not restore your own macOS Charge Limit of \(ownerLimit)% (\(reason)): \(error). CellKeeper will retry; you can also set it in System Settings › Battery › Charging", level: .fault)
            } else if error is FaultAlreadyHandled {
                // The confirmation's read reported a fault, handled already.
            } else if await !handleThrownFault(error, context: "Could not restore normal charging (\(reason))") {
                registerFailure("Could not restore normal charging (\(reason)): \(error)", level: .fault)
            }
            return false
        }
    }

    /// The backend found a Charge Limit that CellKeeper did not set and
    /// adopted it as the user's own limit without writing anything. The
    /// change was most likely deliberate (System Settings), so CellKeeper
    /// turns management off rather than override it; the user turns it on
    /// again to let CellKeeper manage the limit.
    private func adopt(_ change: AdoptedLimitChange?) {
        currentMode = .normal
        ownedMode = .normal
        responsibleMode = nil
        unconfirmedRequests = []
        isRestoreOutstanding = false
        isOwnedStateUnverified = false
        lastFailedRestoreUptime = nil
        adoptedChange = change
        adoptionCount += 1

        let found = change.map { $0.isNoLimit ? "no limit (100%)" : "\($0.limit)%" } ?? "a new value"
        let expected = change.map { " (CellKeeper had set \($0.expectedLimit)%)" } ?? ""
        let when = change?.isFromEarlierSession == true ? "Before CellKeeper last stopped, " : ""
        var message = "\(when)macOS's Charge Limit was changed outside CellKeeper to \(found)\(expected), for example in System Settings. CellKeeper kept it as your own limit and changed nothing"
        if settings.isManagementEnabled {
            settings.isManagementEnabled = false
            message += "; it turned off Manage charging, so turn that on to let CellKeeper manage the limit again"
        }
        if let change, change.isNoLimit, change.previousOwnerLimit != change.limit {
            message += ". If this was a temporary full charge rather than your choice, your earlier limit was \(change.previousOwnerLimit)%: set it in System Settings › Battery › Charging"
        }
        record(.safety, message + ".")
        if let ended = activeOverride {
            activeOverride = nil
            record(.override, "\(Self.describe(ended)) cancelled because the Charge Limit was changed outside CellKeeper.")
        }
    }

    private func registerFailure(_ message: String, level: OSLogType = .error) {
        consecutiveFailures += 1
        lastFailureUptime = uptime()
        record(.failure, "\(message) (consecutive failures: \(consecutiveFailures)).", level: level)
        if consecutiveFailures == Self.maximumConsecutiveFailures {
            record(.safety, "Backend marked faulted; only normal charging will be requested until the fault is cleared.", level: .fault)
        }
    }

    // MARK: - Serialization

    /// Runs `body` while holding the controller's lock and returns the status
    /// afterwards. The lock is FIFO: release hands it directly to the oldest
    /// waiter, so no caller can barge ahead.
    private func exclusively(_ body: () async -> Void) async -> ControllerStatus {
        await acquire()
        if !isShutDown {
            await body()
        }
        release()
        return status
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        // Ownership is handed over by release(); isBusy stays true.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Callers waiting for the lock now; for tests that hold one caller's
    /// backend request and need every other caller queued behind it.
    var waitingCallerCount: Int {
        waiters.count
    }

    // MARK: - Event log

    /// Records an event in the activity log and unified logging. Telemetry
    /// changes log at info level (memory only); everything else defaults to
    /// notice level so that control decisions are persisted.
    private func record(_ kind: ControlEvent.Kind, _ message: String, level: OSLogType? = nil) {
        let level = level ?? (kind == .telemetry ? .info : .default)
        events.append(ControlEvent(id: nextEventID, date: now(), kind: kind, message: message))
        nextEventID += 1
        if events.count > Self.eventLimit {
            events.removeFirst(events.count - Self.eventLimit)
        }
        kind.logger.log(level: level, "\(message, privacy: .public)")
    }

    static func isPolicyRelevantChange(from old: BatterySnapshot?, to new: BatterySnapshot) -> Bool {
        guard let old else { return true }
        if old.chargePercent != new.chargePercent
            || old.powerSource != new.powerSource
            || old.isCharging != new.isCharging
            || old.isFullyCharged != new.isFullyCharged
            || old.isBatteryPresent != new.isBatteryPresent {
            return true
        }
        switch (old.temperatureCelsius, new.temperatureCelsius) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a - b) >= 1
        default: return true
        }
    }

    static func isMeaningfulChange(from old: PolicyDecision?, to new: PolicyDecision) -> Bool {
        guard let old else { return true }
        return old.state != new.state
            || old.desiredMode != new.desiredMode
            || old.action != new.action
    }

    static func describe(_ snapshot: BatterySnapshot) -> String {
        guard snapshot.isBatteryPresent else { return "No battery present." }
        let percent = snapshot.chargePercent.map { "\($0)%" } ?? "unknown charge"
        let temperature = snapshot.temperatureCelsius.map { "\($0.formatted(.number.precision(.fractionLength(1))))°C" } ?? "temperature n/a"
        let power = snapshot.powerSource == .unknown ? "unknown power source" : "on \(snapshot.powerSource)"
        let status = snapshot.chargingStatus == .unknown ? "unknown charging status" : snapshot.chargingStatus.description
        return "Battery \(percent), \(power), \(status), \(temperature)."
    }

    static func describe(_ action: ChargingAction, nativeLimit: Bool = false) -> String {
        switch action {
        case .enableCharging: nativeLimit ? "restore your own limit" : "enable charging"
        case .disableCharging: "disable charging"
        case .requestDischarge: "request discharge"
        case .setNativeLimit(let percent): "set macOS Charge Limit to \(percent)%"
        case .noAction: "none"
        case .refuse(let reason): "refused (\(reason))"
        }
    }

    static func describe(_ kind: ChargeOverride.Kind) -> String {
        switch kind {
        case .fullCharge: "Temporary full charge"
        case .dischargeToLimit: "Discharge to limit"
        }
    }

    /// Like the description of its kind, naming a full charge that a
    /// schedule started or extended.
    static func describe(_ override: ChargeOverride) -> String {
        override.kind == .fullCharge && override.source == .schedule ? "Scheduled full charge" : describe(override.kind)
    }

    /// A schedule's window for the activity log, in the system's time zone.
    static func describeWindow(_ schedule: FullChargeSchedule) -> String {
        "\(describeTime(schedule.startsAt)) to \(describeTime(schedule.endsAt))"
    }

    /// A weekly pattern for the activity log and the diagnostics report,
    /// for example "every Mon, Fri at 07:00 for 12 hours", with fixed
    /// English day names and a 24-hour time.
    static func describe(_ pattern: WeeklyFullChargePattern) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let days = pattern.weekdays.count == 7
            ? "day"
            : pattern.weekdays.sorted().compactMap { names.indices.contains($0 - 1) ? names[$0 - 1] : nil }.joined(separator: ", ")
        let hours = pattern.durationHours == 1 ? "1 hour" : "\(pattern.durationHours) hours"
        return "every \(days) at \(String(format: "%02d:%02d", pattern.hour, pattern.minute)) for \(hours)"
    }

    /// How a kept full charge's deadline compared, for the activity log.
    static func describe(_ deadline: RunningDeadline) -> String {
        switch deadline {
        case .later: "later"
        case .same: "at the same time"
        }
    }

    /// What a weekly record's result means, in words.
    static func describe(_ result: WeeklyFullChargeRecord.Result) -> String {
        switch result {
        case .started: "started"
        case .passed: "passed before it could start"
        case .beforeSave: "began before the schedule was saved"
        case .skippedForCalibration: "skipped: a calibration was in progress"
        }
    }

    static func describeTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func describeChange(from old: ChargingSettings, to new: ChargingSettings) -> String {
        var parts: [String] = []
        if old.isManagementEnabled != new.isManagementEnabled {
            parts.append("management \(new.isManagementEnabled ? "on" : "off")")
        }
        if old.chargeLimit != new.chargeLimit { parts.append("limit \(old.chargeLimit)% → \(new.chargeLimit)%") }
        if old.resumeThreshold != new.resumeThreshold { parts.append("resume \(old.resumeThreshold)% → \(new.resumeThreshold)%") }
        if old.temperatureProtection != new.temperatureProtection {
            let t = new.temperatureProtection
            parts.append("temperature protection \(t.isEnabled ? "on" : "off") (pause \(t.pauseAtCelsius.formatted())°C, resume \(t.resumeAtCelsius.formatted())°C)")
        }
        return "Settings changed: " + (parts.isEmpty ? "no effective change" : parts.joined(separator: ", ")) + "."
    }
}
