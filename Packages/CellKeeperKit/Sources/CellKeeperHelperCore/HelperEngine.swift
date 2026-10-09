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
///   (R1), when a client restores defaults, and at shutdown; the control is
///   cleared with it. Only one session holds leases at a time.
/// - Every write is read back. A mismatch, or any failed write, restores
///   defaults. A restore or clear that fails or does not read back clean
///   raises the `hardwareFault` interlock until a restore reads back clean;
///   ``tick()`` retries the restore.
/// - Interlocks from the helper's own power reading clear the controls they
///   block and refuse their activation: missing or stale power state (R9,
///   R17), the battery floor (R5), loss of external power (R18), a missing
///   or unknown adapter, the adapter floor, thermal pressure (R21), and
///   imminent sleep (R16).
/// - A read-back that differs from what the engine set means another tool
///   may be in control (R27): defaults are restored once and
///   `externalModification` is raised. Until a client's restore reads back
///   clean, the engine writes nothing on its own, so it never fights the
///   other tool.
/// - Activations are rate-limited (R13); deactivations and restores never
///   are. Each session also has a request budget.
/// - ``terminate()`` and a client's `restoreDefaultsAndExit` restore
///   defaults and shut the engine down (R4). The engine never exits the
///   process itself.
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

    /// Monotonic seconds that keep counting during sleep, from an origin
    /// shared by the whole process, so a host can give the same clock to the
    /// engine and to its power reading.
    public static let continuousUptime: @Sendable () -> TimeInterval = {
        let clock = ContinuousClock()
        let origin = clock.now
        return {
            let elapsed = origin.duration(to: clock.now).components
            return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
        }
    }()

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
    }

    private let hardware: any HelperChargeControl
    private let power: any HelperPowerReading
    private let build: Int
    private let uptime: @Sendable () -> TimeInterval
    private let emit: @Sendable (HelperEvent) -> Void

    private var phase = Phase.notStarted
    private var probe = HelperProbe(capabilities: [], isSimulated: false)
    private var sessions: [HelperSessionID: SessionState] = [:]
    private var nextSessionNumber = 1
    /// The one session that may hold leases at a time.
    private var leaseHolder: HelperSessionID?
    /// Lease deadlines on the monotonic clock, all held by ``leaseHolder``.
    private var leases: [HelperControl: TimeInterval] = [:]
    /// What the engine set and confirmed by read-back.
    private var expected: Set<HelperControl> = []
    /// The latest read-back; nil if it failed.
    private var lastReadBack: Set<HelperControl>?
    private var interlocks: HelperInterlocks = []
    private var isBatteryFloorLatched = false
    private var isAdapterFloorLatched = false
    private var sleepAnnouncedAt: TimeInterval?
    /// Power states read before this time are unavailable (R17).
    private var lastWakeAt: TimeInterval?
    private var activations = ActivationHistory()
    private var lastHardwareError = 0

    /// - Parameters:
    ///   - control: the only access to charging hardware.
    ///   - power: the helper's own power-state source. It must stamp its
    ///     readings with `uptime`.
    ///   - build: the helper's build number, reported by `hello`.
    ///   - uptime: monotonic seconds that keep counting during sleep, for
    ///     leases, rate limits and the age of power states (R22). See
    ///     ``continuousUptime``.
    ///   - events: receives every event, synchronously, for the audit log.
    public init(
        control: any HelperChargeControl,
        power: any HelperPowerReading,
        build: Int,
        uptime: @escaping @Sendable () -> TimeInterval,
        events: @escaping @Sendable (HelperEvent) -> Void
    ) {
        self.hardware = control
        self.power = power
        self.build = build
        self.uptime = uptime
        self.emit = events
    }

    // MARK: - Host

    /// Restores defaults, confirms them by read-back, and probes the
    /// control's capabilities. Sessions are served only afterwards. If the
    /// restore fails, the engine serves sessions faulted (no activation)
    /// and returns `hardwareError`. Later calls do nothing.
    @discardableResult
    public func start() -> HelperStatus {
        switch phase {
        case .shuttingDown:
            return .shuttingDown
        case .running:
            return interlocks.contains(.hardwareFault) ? .hardwareError : .ok
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

    /// Runs the periodic checks: verifies the read-back (retrying a failed
    /// restore), expires leases, and applies the interlocks. The host calls
    /// it every few seconds. Every request except `hello` and the restores
    /// runs the same checks, but only ticks and system events retry a failed
    /// restore.
    public func tick() {
        guard phase == .running else { return }
        refresh(.tick)
    }

    /// The system is about to sleep (R16): `sleepImminent` clears the
    /// adapter-disable and refuses it until ``systemDidWake()``. The
    /// charging inhibit stays only while its lease is valid.
    public func systemWillSleep() {
        guard phase == .running else { return }
        sleepAnnouncedAt = uptime()
        refresh(.systemEvent)
    }

    /// The system has woken (R17): reads back, compares, and runs every
    /// check. Power states read before this call count as unavailable, so
    /// the power reading must provide a fresh one.
    public func systemDidWake() {
        guard phase == .running else { return }
        sleepAnnouncedAt = nil
        lastWakeAt = uptime()
        refresh(.systemEvent)
    }

    /// The host is terminating (SIGTERM, R4): ends every lease, restores
    /// defaults, and shuts down. Returns `hardwareError` if the restore was
    /// not confirmed, and `shuttingDown` if the engine had already shut
    /// down.
    @discardableResult
    public func terminate() -> HelperStatus {
        guard phase != .shuttingDown else { return .shuttingDown }
        return shutDown(reason: .terminate) ? .ok : .hardwareError
    }

    /// True once the engine has shut down; the host may then exit.
    public var isShuttingDown: Bool {
        phase == .shuttingDown
    }

    // MARK: - Requests (through HelperSession)

    func hello(_ id: HelperSessionID, clientProtocolVersion: Int) -> HelperHelloReply {
        var status = admit(id, .hello, needsIntroduction: false) ?? .ok
        if status == .ok {
            let isSupported = HelperProtocolVersion.isSupported(client: clientProtocolVersion)
            sessions[id]?.isIntroduced = isSupported
            if !isSupported {
                status = reject(id, .hello, .incompatibleProtocol)
            }
        }
        return HelperHelloReply(
            status: status,
            helperProtocolVersion: HelperProtocolVersion.current,
            build: build,
            capabilities: probe.capabilities,
            isSimulated: probe.isSimulated
        )
    }

    func readState(_ id: HelperSessionID) -> HelperStateReply {
        if let refusal = admit(id, .readState) {
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
        if let refusal = admit(id, .acquireOrRenewLease) {
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
        if let refusal = admit(id, .releaseLease, needsToken: false) {
            return refusal
        }
        guard let control = HelperControl(rawValue: rawControl) else {
            return reject(id, .releaseLease, .invalidArgument)
        }
        refresh(.request)
        guard leaseHolder == id, leases[control] != nil else {
            return reject(id, .releaseLease, .noLease)
        }
        endLease(control, reason: .released)
        return clear(control, reason: .leaseReleased) ? .ok : reject(id, .releaseLease, .hardwareError)
    }

    func setControl(_ id: HelperSessionID, control rawControl: Int, active: Bool) -> HelperStatus {
        // Deactivation only moves toward safety, so the budget never
        // refuses it.
        if let refusal = admit(id, .setControl, needsToken: active) {
            return refusal
        }
        guard let control = HelperControl(rawValue: rawControl) else {
            return reject(id, .setControl, .invalidArgument)
        }
        guard active else {
            refresh(.request)
            // Clears only what the engine set, and writes nothing if it is
            // not set; a control set by another tool is cleared by
            // restoreDefaults.
            return clear(control, reason: .clientRequest) ? .ok : reject(id, .setControl, .hardwareError)
        }
        guard probe.capabilities.contains(control.requiredCapability) else {
            return reject(id, .setControl, .unsupportedControl)
        }
        refresh(.request)
        guard leaseHolder == id, leases[control] != nil else {
            return reject(id, .setControl, .noLease)
        }
        guard interlocks.isDisjoint(with: control.blockingInterlocks) else {
            return reject(id, .setControl, .blockedByInterlock)
        }
        guard !expected.contains(control) else { return .ok }
        let now = uptime()
        guard activations.allows(control, at: now) else {
            return reject(id, .setControl, .rateLimited)
        }
        // An attempted write counts, whatever its outcome.
        activations.record(control, at: now)
        if let failure = write(control, active: true) {
            restoreAll(reason: failure)
            return reject(id, .setControl, .hardwareError)
        }
        emit(.activated(control, by: id))
        return .ok
    }

    func restoreDefaults(_ id: HelperSessionID) -> HelperStatus {
        guard phase != .shuttingDown else {
            return reject(id, .restoreDefaults, .shuttingDown)
        }
        spendTokenIfAvailable(id)
        endAllLeases(reason: .restoredDefaults)
        let isClean: Bool
        if expected.isEmpty, !interlocks.contains(.hardwareFault), readHardware() == [] {
            // Already at defaults: confirmed without writing.
            isClean = true
            emit(.restored(.clientRequest))
        } else {
            isClean = restoreAll(reason: .clientRequest)
        }
        guard isClean else {
            return reject(id, .restoreDefaults, .hardwareError)
        }
        lower(.externalModification)
        return .ok
    }

    func restoreDefaultsAndExit(_ id: HelperSessionID) -> HelperStatus {
        guard phase != .shuttingDown else {
            return reject(id, .restoreDefaultsAndExit, .shuttingDown)
        }
        spendTokenIfAvailable(id)
        return shutDown(reason: .exitRequested) ? .ok : reject(id, .restoreDefaultsAndExit, .hardwareError)
    }

    func invalidate(_ id: HelperSessionID) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        emit(.sessionInvalidated(id))
        guard leaseHolder == id else { return }
        endAllLeases(reason: .sessionInvalidated)
        for control in HelperControl.allCases where expected.contains(control) {
            clear(control, reason: .sessionInvalidated)
        }
    }

    // MARK: - Admission

    /// The checks every request except a restore must pass. Returns the
    /// refusal, already reported, or nil.
    private func admit(_ id: HelperSessionID, _ request: HelperRequestKind, needsToken: Bool = true, needsIntroduction: Bool = true) -> HelperStatus? {
        switch phase {
        case .shuttingDown:
            return reject(id, request, .shuttingDown)
        case .notStarted:
            return reject(id, request, .notReady)
        case .running:
            break
        }
        guard var session = sessions[id] else {
            return reject(id, request, .notIntroduced)
        }
        defer { sessions[id] = session }
        if session.budget.take(at: uptime()) {
            session.isThrottled = false
        } else if needsToken {
            guard !session.isThrottled else { return .rateLimited }
            session.isThrottled = true
            return reject(id, request, .rateLimited)
        }
        guard session.isIntroduced || !needsIntroduction else {
            return reject(id, request, .notIntroduced)
        }
        return nil
    }

    private func spendTokenIfAvailable(_ id: HelperSessionID) {
        if sessions[id]?.budget.take(at: uptime()) == true {
            sessions[id]?.isThrottled = false
        }
    }

    private func reject(_ id: HelperSessionID, _ request: HelperRequestKind, _ status: HelperStatus) -> HelperStatus {
        emit(.requestRejected(id, request, status))
        return status
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

    /// Compares the read-back with what the engine set.
    private func verifyHardware(_ trigger: Trigger) {
        let readBack = readHardware()
        if interlocks.contains(.externalModification) {
            // Restored once already; no more writes of its own (R26, R27).
            return
        }
        if interlocks.contains(.hardwareFault) {
            if trigger != .request {
                restoreAll(reason: .faultRetry)
            }
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

    /// Recomputes the interlocks that follow from the power state and from
    /// sleep, and clears every control they block.
    private func updateConditionInterlocks() {
        let state = power.latestPowerState()
        let now = uptime()
        var found: HelperInterlocks = []
        if let state, let charge = state.stateOfCharge, let isOnExternalPower = state.isOnExternalPower,
           (0...100).contains(charge), state.readAtUptime <= now,
           now - state.readAtUptime <= Self.maximumPowerStateAge,
           state.readAtUptime >= (lastWakeAt ?? -.infinity) {
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
        } else {
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

    private func endAllLeases(reason: HelperLeaseEndReason) {
        for control in HelperControl.allCases {
            endLease(control, reason: reason)
        }
    }

    // MARK: - Hardware

    /// Reads the controls back, recording a failure as nil.
    @discardableResult
    private func readHardware() -> Set<HelperControl>? {
        do {
            let readBack = try hardware.readBack()
            lastReadBack = readBack
            return readBack
        } catch {
            lastReadBack = nil
            recordHardwareError(HelperHardwareError.code(for: error))
            return nil
        }
    }

    /// Writes one control and confirms the whole state by read-back.
    /// Returns nil on success, or why it failed.
    private func write(_ control: HelperControl, active: Bool) -> HelperChangeReason? {
        let target = active ? expected.union([control]) : expected.subtracting([control])
        do {
            try hardware.apply(control, active: active)
        } catch {
            recordHardwareError(HelperHardwareError.code(for: error))
            return .writeFailed
        }
        guard let readBack = readHardware() else { return .writeFailed }
        guard readBack == target else {
            recordHardwareError(HelperHardwareError.readBackMismatch.code)
            return .readBackMismatch
        }
        expected = target
        return nil
    }

    /// Clears one control if the engine set it; writes nothing otherwise. If
    /// the write fails, restores defaults and returns false.
    @discardableResult
    private func clear(_ control: HelperControl, reason: HelperChangeReason) -> Bool {
        guard expected.contains(control) else { return true }
        if let failure = write(control, active: false) {
            restoreAll(reason: failure)
            return false
        }
        emit(.deactivated(control, reason))
        return true
    }

    /// Restores every control to its default and confirms by read-back. A
    /// failure raises `hardwareFault`; a clean read-back lowers it.
    @discardableResult
    private func restoreAll(reason: HelperChangeReason) -> Bool {
        expected = []
        do {
            try hardware.restoreDefaults()
        } catch {
            recordHardwareError(HelperHardwareError.code(for: error))
            return restoreFailed(reason)
        }
        guard let readBack = readHardware() else {
            return restoreFailed(reason)
        }
        guard readBack.isEmpty else {
            recordHardwareError(HelperHardwareError.restoreNotConfirmed.code)
            return restoreFailed(reason)
        }
        emit(.restored(reason))
        lower(.hardwareFault)
        return true
    }

    private func restoreFailed(_ reason: HelperChangeReason) -> Bool {
        emit(.restoreFailed(reason))
        raise(.hardwareFault)
        return false
    }

    private func recordHardwareError(_ code: Int) {
        lastHardwareError = code
        emit(.hardwareError(code: code))
    }

    private func shutDown(reason: HelperChangeReason) -> Bool {
        endAllLeases(reason: .shutdown)
        let restored = restoreAll(reason: reason)
        phase = .shuttingDown
        emit(.shuttingDown(reason, restored: restored))
        return restored
    }
}
