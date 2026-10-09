import Foundation

/// The logic of the privileged helper: it serves client sessions, holds
/// controls under per-control leases, and enforces the helper's own safety
/// rules whatever its clients ask. It never touches hardware itself; every
/// write and read goes through a ``HelperChargeControl``, and it reads the
/// power state itself through a ``HelperPowerReading``.
///
/// Safety behaviour (rule numbers from research note 06):
/// - ``start()`` restores defaults and reads back before anything else is
///   served (R2). Until it has run, only restores are honoured.
/// - A control is active only while the session that set it holds a lease
///   on it (R3). The lease is clamped to the control's maximum, and ends
///   when it expires, when it is released, when its session is invalidated
///   or revoked (R1), when a client restores defaults, and at shutdown; the
///   control is cleared with it. Only one session holds leases at a time.
///   The lease is checked again on a fresh clock reading right before an
///   activation is written.
/// - Every write that returns is read back. A write that throws, a failed
///   read-back or a mismatch restores defaults and raises `writeFailed`,
///   which refuses activations until a client restores defaults or an hour
///   has passed (R11).
/// - A restore that throws or does not read back clean raises
///   `hardwareFault`: a restore is owed until one reads back clean. Ticks,
///   system events, client restores and the end of the lease holder's
///   session retry it; requests never do.
/// - Interlocks from the helper's own power reading clear the controls they
///   block and refuse their activation: missing or stale power state (R9,
///   R17), the battery floor (R5), loss of external power (R18), a missing
///   or unknown adapter, the adapter floor, thermal pressure (R21), and
///   imminent sleep (R16).
/// - A read-back that differs from what the engine set means another tool
///   may be in control (R27): `externalModification` is raised and defaults
///   are restored until none of the engine's own controls can still be
///   active. From then until a client's restore reads back clean, the
///   engine writes nothing on its own, so it never fights the other tool.
///   Shutdown still restores.
/// - Activations are rate-limited (R13). A refused activation restores
///   defaults. Deactivations and restores are never limited. Each session
///   also has a request budget; a session that keeps exceeding it is
///   revoked.
/// - ``terminate()`` and a client's `restoreDefaultsAndExit` restore
///   defaults and shut the engine down (R4). Until defaults are confirmed,
///   the engine keeps serving restores and retrying them; ``isSafeToExit``
///   says when the host may exit. The engine never exits the process
///   itself.
/// - Read-back state is reported, never intended state (R30).
///
/// Every call is synchronous inside the actor, so requests, ticks and
/// system events never interleave hardware access.
public actor HelperEngine {
    /// Each control is activated at most once per this interval (R13).
    public static let minimumActivationInterval: TimeInterval = 60
    /// Activations of all controls per rolling hour (R13).
    public static let maximumActivationsPerHour = 20
    /// Requests a session may make at once before it is rate-limited.
    public static let requestBurst = 10
    /// Requests a session may make per second, sustained.
    public static let requestsPerSecond: Double = 2
    /// Requests beyond the budget, in a row, after which a session is
    /// revoked. Restores and deactivations count too, although they are
    /// still served until then.
    public static let maximumOverBudgetRequests = 20
    /// A power state read longer ago than this is unavailable (R9).
    public static let maximumPowerStateAge: TimeInterval = 60
    /// At or below this charge every control is cleared (R5) ...
    public static let batteryFloor = 10
    /// ... until the charge recovers to this.
    public static let batteryFloorExit = 15
    /// At or below this charge the adapter is never disabled (research
    /// note 02, §7) ...
    public static let adapterFloor = 25
    /// ... until the charge recovers to this.
    public static let adapterFloorExit = 30
    /// How long a sleep announcement holds `sleepImminent` if no wake
    /// follows (a cancelled sleep). The monotonic clock counts sleep, so a
    /// real sleep always exceeds it.
    public static let sleepAnnouncementWindow: TimeInterval = 120
    /// How long `writeFailed` refuses activations after the last failed
    /// write, unless a client restores defaults first (R11).
    public static let writeFailureBackoff: TimeInterval = 60 * 60

    /// Seconds on the system's monotonic clock (`CLOCK_MONOTONIC`), which
    /// keeps counting during sleep and is the same in every process. On
    /// macOS it counts from boot (observed, not documented), so values from
    /// an earlier helper process in the same boot can be compared with it;
    /// values from another boot cannot.
    public static let continuousUptime: @Sendable () -> TimeInterval = {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
    }

    private static let conditionInterlocks: HelperInterlocks = [
        .belowBatteryFloor, .notOnExternalPower, .belowAdapterFloor, .adapterAbsent,
        .adapterPresenceUnknown, .thermalPressure, .powerStateUnavailable, .sleepImminent,
    ]

    private enum Phase {
        case notStarted, running, shuttingDown
    }

    private enum Trigger {
        case request, tick, systemEvent
    }

    private struct SessionState {
        var isIntroduced = false
        var budget: RequestBudget
        /// A refusal for an exhausted budget has been reported.
        var isThrottled = false
        /// Requests in a row that found no token.
        var overBudgetStreak = 0
    }

    private let hardware: any HelperChargeControl
    private let power: any HelperPowerReading
    private let build: Int
    private let uptime: @Sendable () -> TimeInterval
    private let emit: @Sendable (HelperEvent) -> Void

    private var phase = Phase.notStarted
    private var hasAnnouncedSafeToExit = false
    private var probe = HelperProbe(capabilities: [], isSimulated: false)
    private var sessions: [HelperSessionID: SessionState] = [:]
    private var nextSessionNumber = 1
    /// The one session that may hold leases at a time.
    private var leaseHolder: HelperSessionID?
    /// Lease deadlines on the monotonic clock, all held by ``leaseHolder``.
    private var leases: [HelperControl: TimeInterval] = [:]
    /// What the engine set and confirmed by read-back. Empty while a
    /// restore is owed.
    private var expected: Set<HelperControl> = []
    /// Controls the engine may have made active that no read-back has shown
    /// inactive since. Until the first read-back that is every control: an
    /// earlier helper process may have set them.
    private var owned = Set(HelperControl.allCases)
    /// The latest read-back; nil if it failed.
    private var lastReadBack: Set<HelperControl>?
    private var interlocks: HelperInterlocks = []
    private var isBatteryFloorLatched = false
    private var isAdapterFloorLatched = false
    private var sleepAnnouncedAt: TimeInterval?
    /// Power states read at or before this time are unavailable (R17).
    private var lastWakeAt: TimeInterval?
    /// When the power state last found usable was read; nil if the last one
    /// was not usable.
    private var powerStateReadAt: TimeInterval?
    private var activations: ActivationHistory
    private var lastHardwareError = 0
    private var writeFailedAt: TimeInterval?

    /// - Parameters:
    ///   - control: the only access to charging hardware.
    ///   - power: the helper's own power-state source. It must stamp its
    ///     readings with `uptime`.
    ///   - build: the helper's build number, reported by `hello`.
    ///   - uptime: monotonic seconds that keep counting during sleep, for
    ///     leases, rate limits and the age of power states (R22). See
    ///     ``continuousUptime``.
    ///   - activationHistory: the activations an earlier helper process
    ///     made in this boot (see ``activationHistory``), so that a
    ///     relaunch cannot reset the activation limits. Records older than
    ///     an hour or later than now are dropped.
    ///   - events: receives every event, synchronously, for the audit log.
    ///     It must not block: it runs inside the engine, between its checks
    ///     and its writes. Persisting the activation history, for example,
    ///     is done asynchronously; losing the last record in a crash is
    ///     acceptable, because the next start restores defaults first.
    public init(
        control: any HelperChargeControl,
        power: any HelperPowerReading,
        build: Int,
        uptime: @escaping @Sendable () -> TimeInterval,
        activationHistory: [HelperActivationRecord] = [],
        events: @escaping @Sendable (HelperEvent) -> Void
    ) {
        self.hardware = control
        self.power = power
        self.build = build
        self.uptime = uptime
        self.emit = events
        self.activations = ActivationHistory(records: activationHistory, at: uptime())
    }

    // MARK: - Host

    /// Restores defaults, confirms them by read-back, and probes the
    /// control's capabilities. Sessions are served only afterwards. If the
    /// restore fails, the engine serves sessions with a restore owed (no
    /// activation) and returns `hardwareError`. Later calls do nothing.
    @discardableResult
    public func start() -> HelperStatus {
        switch phase {
        case .shuttingDown:
            return .shuttingDown
        case .running:
            return isRestoreOwed ? .hardwareError : .ok
        case .notStarted:
            break
        }
        let restored = restoreAll(reason: .start)
        probe = hardware.probe()
        phase = .running
        emit(.started(capabilities: probe.capabilities, isSimulated: probe.isSimulated))
        updateConditionInterlocks()
        return restored ? .ok : .hardwareError
    }

    /// A new session for a client connection. See ``HelperSession``.
    public func openSession() -> HelperSession {
        let id = HelperSessionID(rawValue: nextSessionNumber)
        nextSessionNumber += 1
        sessions[id] = SessionState(budget: RequestBudget(at: uptime()))
        emit(.sessionOpened(id))
        return HelperSession(id: id, engine: self)
    }

    /// Runs the periodic checks: verifies the read-back (retrying an owed
    /// restore), expires leases, and applies the interlocks. The host calls
    /// it every few seconds. Every admitted request except `hello` and the
    /// restores runs the same checks, but only ticks and system events
    /// retry an owed restore. During shutdown it only retries the restore.
    public func tick() {
        switch phase {
        case .running: refresh(.tick)
        case .shuttingDown: retryRestoreDuringShutdown()
        case .notStarted: break
        }
    }

    /// The system is about to sleep (R16): `sleepImminent` clears the
    /// adapter-disable and refuses it until ``systemDidWake()``. The
    /// charging inhibit stays only while its lease is valid.
    public func systemWillSleep() {
        switch phase {
        case .running:
            sleepAnnouncedAt = uptime()
            refresh(.systemEvent)
        case .shuttingDown:
            retryRestoreDuringShutdown()
        case .notStarted:
            break
        }
    }

    /// The system has woken (R17): reads back, compares, and runs every
    /// check. Power states read at or before this call count as
    /// unavailable, so the power reading must provide a newer one.
    public func systemDidWake() {
        switch phase {
        case .running:
            sleepAnnouncedAt = nil
            lastWakeAt = uptime()
            refresh(.systemEvent)
        case .shuttingDown:
            retryRestoreDuringShutdown()
        case .notStarted:
            break
        }
    }

    /// The host is terminating (SIGTERM, R4): ends every lease, restores
    /// defaults, and shuts down. Returns `ok` once defaults are confirmed
    /// (``isSafeToExit``), `hardwareError` otherwise. Called again during
    /// shutdown, it retries an owed restore.
    ///
    /// Host policy: after SIGTERM, call it, then keep retrying (with this
    /// or ``tick()``) about once a second until ``isSafeToExit`` or until
    /// launchd's `ExitTimeOut` is nearly used up, then exit anyway. The next
    /// start restores defaults before anything else (R2).
    @discardableResult
    public func terminate() -> HelperStatus {
        switch phase {
        case .shuttingDown:
            if isRestoreOwed {
                restoreAll(reason: .terminate)
            }
            return isSafeToExit ? .ok : .hardwareError
        case .notStarted, .running:
            return shutDown(reason: .terminate) ? .ok : .hardwareError
        }
    }

    /// True once shutdown was requested; only restores are served.
    public var isShuttingDown: Bool {
        phase == .shuttingDown
    }

    /// True once shutdown was requested and defaults are confirmed: the
    /// host may exit. It can turn false again if a client's restore during
    /// shutdown fails, so the host checks it right before exiting.
    public var isSafeToExit: Bool {
        phase == .shuttingDown && !isRestoreOwed
    }

    /// The activations of the last hour, for the activation limits. The
    /// daemon persists them (an ``HelperEvent/activationRecorded(_:)`` event
    /// follows every change) and passes them to the next engine in the same
    /// boot; it discards them when the boot changes, because the clock
    /// starts again. The engine keeps at most the latest
    /// ``maximumActivationsPerHour`` records it is given, which is enough
    /// for both limits; the daemon's reader must bound what it reads too.
    public var activationHistory: [HelperActivationRecord] {
        activations.current(at: uptime())
    }

    // MARK: - Requests (through HelperSession)

    func hello(_ id: HelperSessionID, clientProtocolVersion: Int) -> HelperHelloReply {
        var status = admit(id, .hello, needsIntroduction: false).refusal ?? .ok
        if status == .ok, !HelperProtocolVersion.isSupported(client: clientProtocolVersion) {
            status = reject(id, .hello, .incompatibleProtocol)
        }
        // Any failed hello withdraws the introduction.
        sessions[id]?.isIntroduced = status == .ok
        return HelperHelloReply(
            status: status,
            helperProtocolVersion: HelperProtocolVersion.current,
            build: build,
            capabilities: probe.capabilities,
            isSimulated: probe.isSimulated
        )
    }

    func readState(_ id: HelperSessionID) -> HelperStateReply {
        if let refusal = admit(id, .readState).refusal {
            return HelperStateReply(
                status: refusal,
                activeControls: [],
                chargingInhibitedLeaseSeconds: 0,
                adapterDisabledLeaseSeconds: 0,
                isLeaseHolder: false,
                interlocks: [],
                lastHardwareError: 0
            )
        }
        refresh(.request)
        let now = uptime()
        func remaining(_ control: HelperControl) -> Int {
            guard let deadline = leases[control] else { return 0 }
            return max(0, Int((deadline - now).rounded(.up)))
        }
        return HelperStateReply(
            status: lastReadBack == nil ? .hardwareError : .ok,
            activeControls: HelperControlSet(controls: lastReadBack ?? []),
            chargingInhibitedLeaseSeconds: remaining(.chargingInhibited),
            adapterDisabledLeaseSeconds: remaining(.adapterDisabled),
            isLeaseHolder: leaseHolder == id,
            interlocks: interlocks,
            lastHardwareError: lastHardwareError
        )
    }

    func acquireOrRenewLease(_ id: HelperSessionID, control rawControl: Int, seconds: Int) -> HelperLeaseReply {
        func refused(_ status: HelperStatus) -> HelperLeaseReply {
            HelperLeaseReply(status: reject(id, .acquireOrRenewLease, status), grantedSeconds: 0)
        }
        if let refusal = admit(id, .acquireOrRenewLease).refusal {
            return HelperLeaseReply(status: refusal, grantedSeconds: 0)
        }
        guard let control = HelperControl(rawValue: rawControl), seconds > 0 else {
            return refused(.invalidArgument)
        }
        guard probe.capabilities.contains(control.requiredCapability) else {
            return refused(.unsupportedControl)
        }
        // Expire first, so a lapsed holder no longer blocks this session.
        refresh(.request)
        if let leaseHolder, leaseHolder != id {
            return refused(.leaseHeldByOtherClient)
        }
        let granted = min(seconds, control.maximumLeaseSeconds)
        let isRenewal = leases[control] != nil
        leaseHolder = id
        leases[control] = uptime() + TimeInterval(granted)
        emit(isRenewal ? .leaseRenewed(id, control, seconds: granted) : .leaseGranted(id, control, seconds: granted))
        return HelperLeaseReply(status: .ok, grantedSeconds: granted)
    }

    func releaseLease(_ id: HelperSessionID, control rawControl: Int) -> HelperStatus {
        // Only moves toward safety, so the budget does not refuse it
        // (unless this request revokes the session).
        let admission = admit(id, .releaseLease, metered: false)
        if let refusal = admission.refusal {
            return refusal
        }
        guard let control = HelperControl(rawValue: rawControl) else {
            return reject(id, .releaseLease, .invalidArgument)
        }
        if admission.hasToken {
            refresh(.request)
        }
        guard leaseHolder == id, leases[control] != nil else {
            return reject(id, .releaseLease, .noLease)
        }
        endLease(control, reason: .released)
        return deactivate(control, reason: .leaseReleased) ? .ok : reject(id, .releaseLease, .hardwareError)
    }

    func setControl(_ id: HelperSessionID, control rawControl: Int, active: Bool) -> HelperStatus {
        // Deactivation only moves toward safety, so the budget does not
        // refuse it (unless this request revokes the session).
        let admission = admit(id, .setControl, metered: active)
        if let refusal = admission.refusal {
            return refusal
        }
        guard let control = HelperControl(rawValue: rawControl) else {
            return reject(id, .setControl, .invalidArgument)
        }
        guard active else {
            // Over the budget, it skips the checks and only does what the
            // deactivation itself needs. It clears only what the engine set;
            // a control set by another tool is cleared by restoreDefaults.
            if admission.hasToken {
                refresh(.request)
            }
            return deactivate(control, reason: .clientRequest) ? .ok : reject(id, .setControl, .hardwareError)
        }
        guard probe.capabilities.contains(control.requiredCapability) else {
            return reject(id, .setControl, .unsupportedControl)
        }
        refresh(.request)
        // The checks read the hardware and the power state, and every event
        // is a synchronous callback, all of which takes time: the lease is
        // checked on a fresh clock.
        guard isLeaseValid(control, for: id, at: uptime()) else {
            return reject(id, .setControl, .noLease)
        }
        guard interlocks.isDisjoint(with: control.blockingInterlocks) else {
            return reject(id, .setControl, .blockedByInterlock)
        }
        guard !expected.contains(control) else { return .ok }
        let reservedAt = uptime()
        guard activations.allows(control, at: reservedAt) else {
            // R13: the safe state, but no degraded mode (a deliberate
            // deviation; see architecture.md).
            ensureDefaults(reason: .activationLimited)
            return reject(id, .setControl, .rateLimited)
        }
        // The activation is reserved before the event that reports it, and
        // counts from here even if the write is then abandoned.
        emit(.activationRecorded(activations.record(control, at: reservedAt)))
        // Final checks on a fresh clock, after the last callback: nothing is
        // emitted between them and the write.
        let writeAt = uptime()
        guard isLeaseValid(control, for: id, at: writeAt) else {
            return reject(id, .setControl, .noLease)
        }
        guard let readAt = powerStateReadAt, writeAt - readAt <= Self.maximumPowerStateAge else {
            raise(.powerStateUnavailable)
            return reject(id, .setControl, .blockedByInterlock)
        }
        // The activation limits measure from the real write time.
        activations.moveLatestRecord(to: writeAt)
        if let failure = write(control, active: true) {
            noteWriteFailure()
            restoreAll(reason: failure)
            return reject(id, .setControl, .hardwareError)
        }
        emit(.activated(control, by: id))
        return .ok
    }

    func restoreDefaults(_ id: HelperSessionID) -> HelperStatus {
        if let refusal = admit(id, .restoreDefaults, metered: false, needsIntroduction: false, isRestore: true).refusal {
            return refusal
        }
        return clientRestore(id, .restoreDefaults)
    }

    func restoreDefaultsAndExit(_ id: HelperSessionID) -> HelperStatus {
        if let refusal = admit(id, .restoreDefaultsAndExit, metered: false, needsIntroduction: false, isRestore: true).refusal {
            return refusal
        }
        if phase == .shuttingDown {
            return clientRestore(id, .restoreDefaultsAndExit)
        }
        return shutDown(reason: .exitRequested) ? .ok : reject(id, .restoreDefaultsAndExit, .hardwareError)
    }

    func invalidate(_ id: HelperSessionID) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        emit(.sessionInvalidated(id))
        endSession(id)
    }

    // MARK: - Admission

    /// Admits a request: the phase, a live session, the request budget, and
    /// `hello`. Restores (`isRestore`) are served before start and during
    /// shutdown, need no `hello`, and are not refused by the budget
    /// (`metered: false`), except by the request that revokes the session.
    /// Every request spends a token if one is left; `hasToken` says whether
    /// it did. A refusal is reported before it is returned.
    private func admit(
        _ id: HelperSessionID,
        _ request: HelperRequestKind,
        metered: Bool = true,
        needsIntroduction: Bool = true,
        isRestore: Bool = false
    ) -> (refusal: HelperStatus?, hasToken: Bool) {
        if !isRestore {
            switch phase {
            case .shuttingDown: return (reject(id, request, .shuttingDown), false)
            case .notStarted: return (reject(id, request, .notReady), false)
            case .running: break
            }
        }
        guard sessions[id] != nil else {
            return (reject(id, request, .notIntroduced), false)
        }
        let hasToken = spendToken(id)
        guard let session = sessions[id] else {
            // Revoked by this request.
            return (.rateLimited, false)
        }
        if !hasToken, metered {
            guard !session.isThrottled else { return (.rateLimited, false) }
            sessions[id]?.isThrottled = true
            return (reject(id, request, .rateLimited), false)
        }
        if needsIntroduction, !session.isIntroduced {
            return (reject(id, request, .notIntroduced), hasToken)
        }
        return (nil, hasToken)
    }

    /// Takes a token if one is left. A session that keeps going beyond its
    /// budget, served or not, is revoked (research note 04, §3.6).
    private func spendToken(_ id: HelperSessionID) -> Bool {
        guard var session = sessions[id] else { return false }
        let hasToken = session.budget.take(at: uptime())
        if hasToken {
            session.overBudgetStreak = 0
            session.isThrottled = false
        } else {
            session.overBudgetStreak += 1
        }
        sessions[id] = session
        if session.overBudgetStreak > Self.maximumOverBudgetRequests {
            revoke(id)
        }
        return hasToken
    }

    private func reject(_ id: HelperSessionID, _ request: HelperRequestKind, _ status: HelperStatus) -> HelperStatus {
        emit(.requestRejected(id, request, status))
        return status
    }

    private func revoke(_ id: HelperSessionID) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        emit(.sessionRevoked(id))
        endSession(id)
    }

    /// Ends what an ended session held: its leases, and the controls set
    /// under them (R1, R3). If a restore is owed, retries it instead.
    private func endSession(_ id: HelperSessionID) {
        guard leaseHolder == id else { return }
        endAllLeases(reason: .sessionInvalidated)
        if isRestoreOwed {
            if !owned.isEmpty {
                restoreAll(reason: .sessionInvalidated)
            }
            return
        }
        for control in HelperControl.allCases where expected.contains(control) {
            clear(control, reason: .sessionInvalidated)
        }
    }

    /// A client's restore of defaults: ends every lease, confirms or
    /// restores defaults, and on a clean read-back clears the interlocks
    /// only a client may clear. It always reads the hardware afresh, also
    /// beyond the request budget, because a change made by another tool
    /// since the last read must not be missed; it writes only if something
    /// is set.
    private func clientRestore(_ id: HelperSessionID, _ request: HelperRequestKind) -> HelperStatus {
        endAllLeases(reason: .restoredDefaults)
        guard ensureDefaults(reason: .clientRequest) else {
            return reject(id, request, .hardwareError)
        }
        writeFailedAt = nil
        lower([.externalModification, .writeFailed])
        return .ok
    }

    // MARK: - Checks

    private func refresh(_ trigger: Trigger) {
        verifyHardware(trigger)
        let now = uptime()
        for control in HelperControl.allCases {
            if let deadline = leases[control], deadline <= now {
                endLease(control, reason: .expired)
                clear(control, reason: .leaseExpired)
            }
        }
        updateConditionInterlocks()
    }

    /// Compares the read-back with what the engine set, and retries an owed
    /// restore.
    private func verifyHardware(_ trigger: Trigger) {
        let readBack = readHardware()
        if isRestoreOwed {
            // Never from requests. Under externalModification only while a
            // control the engine set may still be active (D28's quiet state
            // begins once none can be).
            if trigger != .request, !owned.isEmpty || !interlocks.contains(.externalModification) {
                restoreAll(reason: .faultRetry)
            }
            return
        }
        if interlocks.contains(.externalModification) {
            // Restored already; no more writes of its own (R26, R27).
            return
        }
        guard let readBack else {
            restoreAll(reason: .readBackFailed)
            return
        }
        guard readBack != expected else { return }
        raise(.externalModification)
        restoreAll(reason: .externalModification)
    }

    private func retryRestoreDuringShutdown() {
        if isRestoreOwed {
            restoreAll(reason: .faultRetry)
        }
    }

    /// Recomputes the interlocks that follow from the power state, from
    /// sleep and from the write-failure backoff, and clears every control
    /// they block.
    private func updateConditionInterlocks() {
        let state = power.latestPowerState()
        let now = uptime()
        var found: HelperInterlocks = []
        if let state, let charge = state.stateOfCharge, let isOnExternalPower = state.isOnExternalPower,
           (0...100).contains(charge), state.readAtUptime <= now,
           now - state.readAtUptime <= Self.maximumPowerStateAge,
           lastWakeAt.map({ state.readAtUptime > $0 }) ?? true {
            if charge <= Self.batteryFloor {
                isBatteryFloorLatched = true
            } else if charge >= Self.batteryFloorExit {
                isBatteryFloorLatched = false
            }
            if charge <= Self.adapterFloor {
                isAdapterFloorLatched = true
            } else if charge >= Self.adapterFloorExit {
                isAdapterFloorLatched = false
            }
            if !isOnExternalPower {
                found.insert(.notOnExternalPower)
            }
            switch state.isAdapterPresent {
            case nil: found.insert(.adapterPresenceUnknown)
            case false?: found.insert(.adapterAbsent)
            case true?: break
            }
            if state.isThermalPressureHigh {
                found.insert(.thermalPressure)
            }
            powerStateReadAt = state.readAtUptime
        } else {
            powerStateReadAt = nil
            found.insert(.powerStateUnavailable)
        }
        if isBatteryFloorLatched {
            found.insert(.belowBatteryFloor)
        }
        if isAdapterFloorLatched {
            found.insert(.belowAdapterFloor)
        }
        if let sleepAnnouncedAt {
            if now - sleepAnnouncedAt < Self.sleepAnnouncementWindow {
                found.insert(.sleepImminent)
            } else {
                self.sleepAnnouncedAt = nil
            }
        }
        raise(found)
        lower(Self.conditionInterlocks.subtracting(found))
        if let writeFailedAt, now - writeFailedAt >= Self.writeFailureBackoff {
            self.writeFailedAt = nil
            lower(.writeFailed)
        }
        for control in HelperControl.allCases where expected.contains(control) {
            let blocking = interlocks.intersection(control.blockingInterlocks)
            if !blocking.isEmpty {
                clear(control, reason: .interlock(blocking))
            }
        }
    }

    private func raise(_ new: HelperInterlocks) {
        let added = new.subtracting(interlocks)
        guard !added.isEmpty else { return }
        interlocks.formUnion(added)
        emit(.interlocksRaised(added))
    }

    private func lower(_ old: HelperInterlocks) {
        let removed = old.intersection(interlocks)
        guard !removed.isEmpty else { return }
        interlocks.subtract(removed)
        emit(.interlocksCleared(removed))
    }

    // MARK: - Leases

    private func endLease(_ control: HelperControl, reason: HelperLeaseEndReason) {
        guard let holder = leaseHolder, leases.removeValue(forKey: control) != nil else { return }
        emit(.leaseEnded(holder, control, reason))
        if leases.isEmpty {
            leaseHolder = nil
        }
    }

    /// True if `id` holds an unexpired lease on `control` at `now`. A lease
    /// found expired ends here, and its control is cleared.
    private func isLeaseValid(_ control: HelperControl, for id: HelperSessionID, at now: TimeInterval) -> Bool {
        guard leaseHolder == id, let deadline = leases[control] else { return false }
        guard deadline > now else {
            endLease(control, reason: .expired)
            deactivate(control, reason: .leaseExpired)
            return false
        }
        return true
    }

    private func endAllLeases(reason: HelperLeaseEndReason) {
        for control in HelperControl.allCases {
            endLease(control, reason: reason)
        }
    }

    // MARK: - Hardware

    /// A restore attempt failed or did not read back clean, and none has
    /// read back clean since.
    private var isRestoreOwed: Bool {
        interlocks.contains(.hardwareFault)
    }

    /// Reads the controls back, recording a failure as nil. A control that
    /// reads back inactive is no longer the engine's.
    @discardableResult
    private func readHardware() -> Set<HelperControl>? {
        do {
            let readBack = try hardware.readBack()
            lastReadBack = readBack
            owned.formIntersection(readBack)
            return readBack
        } catch {
            lastReadBack = nil
            recordHardwareError(HelperHardwareError.code(for: error))
            return nil
        }
    }

    /// Writes one control and confirms the whole state by read-back.
    /// Returns nil on success, or why it failed. What the write may have
    /// made active counts as the engine's: the target once confirmed; after
    /// a throw or a failed read-back, every control, because what took
    /// effect is unknown; after a mismatch, whatever reads back active.
    private func write(_ control: HelperControl, active: Bool) -> HelperChangeReason? {
        let target = active ? expected.union([control]) : expected.subtracting([control])
        func record(_ outcome: HelperWriteRecord.Outcome, _ readBack: Set<HelperControl>?) {
            emit(.write(HelperWriteRecord(target: .control(control, active: active), outcome: outcome, readBack: readBack)))
        }
        do {
            try hardware.apply(control, active: active)
        } catch {
            let code = HelperHardwareError.code(for: error)
            recordHardwareError(code)
            owned.formUnion(HelperControl.allCases)
            record(.threw(code: code), nil)
            return .writeFailed
        }
        guard let readBack = readHardware() else {
            owned.formUnion(HelperControl.allCases)
            record(.readBackFailed(code: lastHardwareError), nil)
            return .writeFailed
        }
        guard readBack == target else {
            recordHardwareError(HelperHardwareError.readBackMismatch.code)
            owned.formUnion(readBack)
            record(.readBackMismatch, readBack)
            return .readBackMismatch
        }
        expected = target
        owned.formUnion(target)
        record(.confirmed, readBack)
        return nil
    }

    /// Clears one control if the engine set it; writes nothing otherwise. If
    /// the write fails, raises `writeFailed`, restores defaults and returns
    /// false.
    @discardableResult
    private func clear(_ control: HelperControl, reason: HelperChangeReason) -> Bool {
        guard expected.contains(control) else { return true }
        if let failure = write(control, active: false) {
            noteWriteFailure()
            restoreAll(reason: failure)
            return false
        }
        emit(.deactivated(control, reason))
        return true
    }

    /// Clears a control for a client or a lease that ended. While a restore
    /// is owed and the control may still be active, retries the restore
    /// instead. Returns true if the control is known to be inactive.
    @discardableResult
    private func deactivate(_ control: HelperControl, reason: HelperChangeReason) -> Bool {
        guard isRestoreOwed else {
            return clear(control, reason: reason)
        }
        guard owned.contains(control) else { return true }
        restoreAll(reason: reason)
        return !owned.contains(control)
    }

    /// Confirms defaults from a fresh read-back without writing if nothing
    /// is set; restores them otherwise.
    @discardableResult
    private func ensureDefaults(reason: HelperChangeReason) -> Bool {
        if expected.isEmpty, !isRestoreOwed, readHardware() == [] {
            emit(.restored(reason))
            return true
        }
        return restoreAll(reason: reason)
    }

    /// Restores every control to its default and confirms by read-back. A
    /// failure means a restore is owed (`hardwareFault`); a clean read-back
    /// settles it. Whatever the restore may have made active counts as the
    /// engine's: a control that reads back active and was not active before
    /// it, and, if the restore threw or could not be read back, every
    /// control not known to have been active before. A control active
    /// before and after keeps its owner, so another tool's control does not
    /// become the engine's.
    @discardableResult
    private func restoreAll(reason: HelperChangeReason) -> Bool {
        expected = []
        // Unknown before the restore counts as nothing active, so that
        // everything active after it counts as the engine's.
        let before = lastReadBack ?? []
        let mayHaveBeenIntroduced = Set(HelperControl.allCases).subtracting(before)
        func record(_ outcome: HelperWriteRecord.Outcome, _ readBack: Set<HelperControl>?) {
            emit(.write(HelperWriteRecord(target: .restoreDefaults, outcome: outcome, readBack: readBack)))
        }
        do {
            try hardware.restoreDefaults()
        } catch {
            let code = HelperHardwareError.code(for: error)
            recordHardwareError(code)
            owned.formUnion(mayHaveBeenIntroduced)
            record(.threw(code: code), nil)
            return restoreFailed(reason)
        }
        guard let readBack = readHardware() else {
            owned.formUnion(mayHaveBeenIntroduced)
            record(.readBackFailed(code: lastHardwareError), nil)
            return restoreFailed(reason)
        }
        owned.formUnion(readBack.subtracting(before))
        guard readBack.isEmpty else {
            recordHardwareError(HelperHardwareError.restoreNotConfirmed.code)
            record(.readBackMismatch, readBack)
            return restoreFailed(reason)
        }
        record(.confirmed, readBack)
        emit(.restored(reason))
        lower(.hardwareFault)
        if phase == .shuttingDown {
            announceSafeToExit()
        }
        return true
    }

    private func restoreFailed(_ reason: HelperChangeReason) -> Bool {
        if phase == .shuttingDown {
            // A new debt during shutdown: announce safety again once settled.
            hasAnnouncedSafeToExit = false
        }
        emit(.restoreFailed(reason))
        raise(.hardwareFault)
        return false
    }

    private func noteWriteFailure() {
        writeFailedAt = uptime()
        raise(.writeFailed)
    }

    private func recordHardwareError(_ code: Int) {
        lastHardwareError = code
        emit(.hardwareError(code: code))
    }

    /// Ends every lease and restores defaults, always writing (an explicit
    /// exception to D28's quiet state), then serves only restores.
    private func shutDown(reason: HelperChangeReason) -> Bool {
        endAllLeases(reason: .shutdown)
        let restored = restoreAll(reason: reason)
        phase = .shuttingDown
        emit(.shuttingDown(reason, restored: restored))
        if restored {
            announceSafeToExit()
        }
        return restored
    }

    private func announceSafeToExit() {
        guard !hasAnnouncedSafeToExit else { return }
        hasAnnouncedSafeToExit = true
        emit(.safeToExit)
    }
}
