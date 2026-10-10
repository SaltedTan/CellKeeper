import CellKeeperHelperCore
import Foundation

/// A backend that controls charging through CellKeeper's helper
/// (``HelperEngine``), reached through a ``HelperTransport``.
///
/// - `.inhibitCharging` holds the helper's charging-inhibit control and
///   `.forceDischarge` its adapter-disable control, each under the longest
///   lease the helper grants. `.normal` releases both.
/// - Every mode is read back from the helper (`readState`), never assumed,
///   including after reconnecting. Every request is confirmed by a fresh read.
/// - Switching between the two controls sets the new one before clearing the
///   old one, so charging is never allowed in between.
/// - Ownership comes from the helper's change history: CellKeeper records the
///   generation of each control it activates, once the helper names the
///   activation as the control's latest change, and the control stays its
///   own only while that generation is current. Why a hold ended is looked
///   up, not inferred: the cause the helper recorded for the next change
///   decides whether it was one of the helper's own releases, CellKeeper's
///   own, a failure, or an outside change. Any other generation is an
///   outside change.
/// - An activation is recorded as pending before it is sent. Until a read
///   settles it, CellKeeper stays responsible for the control, but owns
///   nothing on its account.
/// - `.normal` releases only what is still CellKeeper's: each clear names
///   the change CellKeeper made, and the helper clears nothing that changed
///   since (`clearControlIfUnchanged`). If the helper reports an outside
///   change, or a control CellKeeper did not set is active, the backend
///   never restores defaults by itself (research rules R26, R27): it reports
///   the change, and only ``resetAfterFault()`` (the user clearing the
///   fault) restores defaults. An outside change found by a request stays
///   reported until a read reports it, even if the request succeeds.
/// - While CellKeeper may still hold a control it cannot confirm released,
///   or one an activation it sent may have set (the helper cannot be
///   reached, cannot read its controls, or is shutting down), the backend
///   still accepts `.normal` and reports its mode as unknown, so the
///   controller keeps asking for `.normal` and a backend switch waits.
/// - A helper that waits for an acknowledgement (`writeFailed`, a restore it
///   owes) is reported as ``ReportedModeOrigin/needsAcknowledgement(_:)``,
///   also when it cannot read its controls back, and a new hardware error as
///   a failure.
/// - Requests are paced to stay within the helper's per-session request
///   budget, far from the point where it revokes a session.
/// - While CellKeeper holds a control through a live session, a
///   ``LeaseActivity`` keeps the app from being napped, so evaluations renew
///   the lease on time.
/// - With a ``MacOSChargeLimitMonitor`` (on a Mac that has macOS's Charge
///   Limit), every mode but `.normal` is withheld while macOS's own Charge
///   Limit is on or its report cannot be read and recognised, so CellKeeper
///   starts no restriction on top of macOS's (safety precondition 7). The
///   availability is kept: the backend is fine, macOS is in the way.
///   Withholding new requests says nothing about a hold already in place;
///   that ends only through a release, confirmed by a read like any other.
///   Releasing never waits for a read of macOS's limit. CellKeeper never
///   turns macOS's limit off itself.
/// - ``isReportedModeOwn()`` says, from the helper's history, whether a
///   control CellKeeper set or may have set is in effect, so that only that
///   history makes a restriction someone else's.
///
/// The controller serialises all calls into it.
public actor HelperChargingBackend: ChargingBackend {
    public nonisolated let descriptor: BackendDescriptor
    public nonisolated let transport: any HelperTransport
    /// Watches macOS's own Charge Limit; nil on a Mac without it.
    public nonisolated let macOSChargeLimit: MacOSChargeLimitMonitor?

    private let uptime: @Sendable () -> TimeInterval
    private let pause: @Sendable (TimeInterval) async -> Void
    private let activity: any LeaseActivity

    /// A control CellKeeper activated, by the helper's account.
    private struct Hold {
        /// The control's generation right after CellKeeper set it.
        var generation: UInt64
        /// The helper process it was set on.
        var instance: UInt64
        /// CellKeeper asked for it to be cleared; no read has confirmed
        /// that yet.
        var isReleaseRequested = false
    }

    /// An activation CellKeeper sent whose outcome no read has shown yet. It
    /// may have taken effect, so CellKeeper stays responsible for the
    /// control, but it grants no ownership: nothing is cleared on its
    /// account.
    private struct PendingActivation {
        /// The helper process it was sent to.
        var instance: UInt64
        /// The session it was sent on, which the helper names as the cause
        /// of the change if it took effect.
        var session: UInt64
        /// The control's generation just before.
        var generationBefore: UInt64
    }

    private var connection: (any HelperConnection)?
    /// The helper's reply to `hello` on ``connection``.
    private var introduction: HelperHelloReply?
    /// Whether the helper last said its control is simulated; kept across
    /// connections, so a simulated request is never reported as applied.
    private var isSimulated = false
    private var pacer: RequestPacer
    /// The helper process the last introduction was made to.
    private var helperInstance: UInt64?
    /// The session numbers of CellKeeper's own sessions with that process.
    private var ownSessions: Set<UInt64> = []
    /// The controls CellKeeper set whose end it has not yet seen. Kept across
    /// disconnects: until a fresh read explains it, CellKeeper may still
    /// hold the control.
    private var holds: [HelperControl: Hold] = [:]
    /// Activations sent but not yet settled by a read. Kept across failures
    /// and disconnects, like ``holds``.
    private var pendingActivations: [HelperControl: PendingActivation] = [:]
    /// When CellKeeper's leases end at the latest, on ``uptime``: the time
    /// before each grant was requested, plus the seconds granted. Never later
    /// than the helper's own deadline. Used only to avoid renewing a lease
    /// that may have lapsed.
    private var leaseDeadlines: [HelperControl: TimeInterval] = [:]
    /// The helper's count of hardware errors at the last read, on
    /// ``helperInstance``.
    private var lastHardwareErrorCount: Int?
    /// An outside change the helper still shows: its `externalModification`
    /// interlock, or a control CellKeeper did not set.
    private var currentOutsideChange: String?
    /// An outside change found in the history of a control CellKeeper held.
    /// Kept, whatever CellKeeper asks for meanwhile, until ``currentMode()``
    /// reports it or the user clears the fault (``resetAfterFault()``), so a
    /// release that succeeds cannot hide it.
    private var outsideLoss: String?
    /// How the helper last ended CellKeeper's hold, kept until the next
    /// request.
    private var lastRelease: HoldRelease?
    /// CellKeeper's own release, confirmed only after a later read, kept
    /// until the next request.
    private var isOwnReleaseConfirmed = false
    /// A hardware error the helper reported, or a hold it cleared because
    /// of one, that ``currentMode()`` has not reported yet.
    private var unreportedHardwareError: String?
    private var origin: ReportedModeOrigin?
    /// Whether a control CellKeeper set, or may have set, was in effect at
    /// the last ``currentMode()``; nil if that read failed.
    private var isLastReportedOwn: Bool?
    /// Whether ``activity`` is held.
    private var isActivityHeld = false

    /// - Parameters:
    ///   - uptime: monotonic seconds that keep counting during sleep, on the
    ///     same scale as the helper's clock.
    ///   - pause: waits the given number of seconds; used to stay within the
    ///     helper's request budget.
    ///   - activity: told when CellKeeper starts and stops holding a control
    ///     through a live session.
    ///   - macOSChargeLimit: watches macOS's own Charge Limit; nil where the
    ///     Mac has none, so nothing is withheld for it.
    public init(
        descriptor: BackendDescriptor,
        transport: any HelperTransport,
        uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime,
        pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        activity: any LeaseActivity = ProcessLeaseActivity(),
        macOSChargeLimit: MacOSChargeLimitMonitor? = nil
    ) {
        self.descriptor = descriptor
        self.transport = transport
        self.macOSChargeLimit = macOSChargeLimit
        self.uptime = uptime
        self.pause = pause
        self.activity = activity
        self.pacer = RequestPacer(at: uptime())
    }

    deinit {
        // The helper clears whatever the session still holds.
        if let connection {
            Task { await connection.invalidate() }
        }
        if isActivityHeld {
            activity.setHolding(false)
        }
    }

    // MARK: - ChargingBackend

    /// The helper's capabilities, with macOS's own Charge Limit attached
    /// when a monitor watches it. While that limit may be limiting charging
    /// (it is on, or its report cannot be read and recognised), every mode
    /// but `.normal` is withheld, as for the helper's own interlocks, and
    /// the availability is kept. The monitor reuses a recent reading, so the
    /// several checks of one evaluation read macOS's limit at most once.
    public func capabilities() async -> ControlCapabilities {
        var capabilities = await helperCapabilities()
        guard let macOSChargeLimit else { return capabilities }
        let status = await macOSChargeLimit.status()
        if status.isLimiting {
            capabilities = capabilities.withoutRestrictingModes
        }
        capabilities.macOSChargeLimit = status
        return capabilities
    }

    /// The helper's capabilities without a new read of macOS's Charge Limit:
    /// a release does not depend on it. The latest reading kept is attached;
    /// without one, restricting modes are withheld all the same.
    public func capabilitiesForRelease() async -> ControlCapabilities {
        var capabilities = await helperCapabilities()
        guard let macOSChargeLimit else { return capabilities }
        let status = await macOSChargeLimit.lastStatus
        if status?.isLimiting ?? true {
            capabilities = capabilities.withoutRestrictingModes
        }
        capabilities.macOSChargeLimit = status
        return capabilities
    }

    /// Reads macOS's Charge Limit again, at the user's request.
    public func recheckAvailability() async {
        await macOSChargeLimit?.refresh()
    }

    private func helperCapabilities() async -> ControlCapabilities {
        defer { updateActivity() }
        let introduction: HelperHelloReply
        let state: HelperStateReply
        do {
            introduction = try await introduced()
            guard !introduction.capabilities.isEmpty else {
                return .unavailable("CellKeeper's helper cannot control charging on this Mac yet, so CellKeeper only monitors it.")
            }
            state = try await fetchState()
        } catch {
            // CellKeeper may still hold a control there, or an activation it
            // sent may have taken effect: keep accepting `.normal`, so the
            // controller keeps asking for it.
            if !unresolvedControls.isEmpty {
                return ControlCapabilities(availability: isSimulated ? .simulated : .experimental, supportedModes: [.normal])
            }
            return .unavailable(Self.reason(error))
        }
        // Modes an interlock blocks right now are not offered, so the policy
        // refuses them as unsupported instead of counting failures.
        var modes: Set<ChargeControlMode> = []
        for control in HelperControl.allCases
        where introduction.capabilities.contains(control.requiredCapability)
            && state.interlocks.isDisjoint(with: control.blockingInterlocks) {
            modes.insert(Self.mode(for: control))
        }
        return ControlCapabilities(availability: introduction.isSimulated ? .simulated : .experimental, supportedModes: modes)
    }

    /// The mode read back from the helper. Unknown (nil) if the helper cannot
    /// be reached and CellKeeper holds nothing there, like a backend that
    /// accepts no requests; an error if a request fails, if the helper could
    /// not read its controls back, if CellKeeper may still hold a control it
    /// cannot confirm released (or one an activation it sent may have set),
    /// or if the helper reports a new hardware error.
    ///
    /// A fault is reported through ``reportedModeOrigin()`` on every path,
    /// also when this throws: an outside change (the helper still shows
    /// one, or one was found earlier and not reported yet), then what the
    /// helper waits for an acknowledgement of. Its interlocks are read even
    /// when its controls cannot be.
    public func currentMode() async throws -> ChargeControlMode? {
        defer { updateActivity() }
        origin = nil
        isLastReportedOwn = nil
        let state: HelperStateReply
        do {
            state = try await fetchState()
        } catch BackendError.unavailable(let reason) {
            origin = takeOutsideLoss().map(ReportedModeOrigin.changedOutside)
            let unresolved = unresolvedControls
            guard unresolved.isEmpty else {
                throw BackendError.operationFailed("\(reason) CellKeeper may still have \(Self.describe(unresolved)) set there, so it keeps asking for normal charging until the helper confirms the release.")
            }
            return nil
        } catch {
            origin = takeOutsideLoss().map(ReportedModeOrigin.changedOutside)
            throw error
        }
        noteHardwareErrors(state)
        guard state.status == .ok else {
            // Which controls are active is unknown, but the helper's
            // interlocks are not: a fault it reports is reported now. The
            // error thrown reports the hardware error.
            unreportedHardwareError = nil
            let loss = takeOutsideLoss()
            if state.interlocks.contains(.externalModification) {
                origin = .changedOutside(Self.externalModificationDetail)
            } else if let loss {
                origin = .changedOutside(loss)
            } else if let waiting = Self.acknowledgementNeeded(state) {
                origin = .needsAcknowledgement(waiting)
            }
            throw BackendError.operationFailed("CellKeeper's helper could not read back its controls (hardware error \(state.lastHardwareError))")
        }
        observe(state)
        let active = state.activeControls.controls
        // By the helper's history: a hold is CellKeeper's only while its
        // generation is current, and a pending activation may have set its
        // control.
        isLastReportedOwn = !active.isDisjoint(with: unresolvedControls)
        // A fault reported here makes a hardware error moot.
        let loss = takeOutsideLoss()
        if let outside = currentOutsideChange ?? loss {
            unreportedHardwareError = nil
            origin = .changedOutside(outside)
            return Self.mode(for: active)
        }
        if let waiting = Self.acknowledgementNeeded(state) {
            unreportedHardwareError = nil
            origin = .needsAcknowledgement(waiting)
            return Self.mode(for: active)
        }
        if let error = unreportedHardwareError {
            unreportedHardwareError = nil
            throw BackendError.operationFailed(error)
        }
        guard let mode = Self.mode(for: active) else {
            throw BackendError.operationFailed("CellKeeper's helper reports both charging inhibited and the adapter disabled")
        }
        if let lastRelease {
            origin = .releasedByBackend(lastRelease)
        } else if isOwnReleaseConfirmed {
            origin = .cellKeeper
        }
        return mode
    }

    public func reportedModeOrigin() async -> ReportedModeOrigin? {
        origin
    }

    public func isReportedModeOwn() async -> Bool? {
        isLastReportedOwn
    }

    /// The controls CellKeeper may have set on the helper and has not seen
    /// end: those it holds, and those an activation it sent may have set.
    private var unresolvedControls: Set<HelperControl> {
        Set(holds.keys).union(pendingActivations.keys)
    }

    /// The outside change found earlier and not yet reported, now reported.
    private func takeOutsideLoss() -> String? {
        defer { outsideLoss = nil }
        return outsideLoss
    }

    public func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome {
        defer { updateActivity() }
        switch mode {
        case .normal:
            return try await releaseAll()
        case .inhibitCharging:
            return try await hold(.chargingInhibited, as: mode)
        case .forceDischarge:
            return try await hold(.adapterDisabled, as: mode)
        case .nativeLimit:
            throw BackendError.unsupportedMode(mode)
        }
    }

    /// Renews CellKeeper's lease on the control behind `mode`, for the
    /// longest the helper grants. A lease already past its deadline is left
    /// alone: it may have lapsed, and a new lease would not bring back a
    /// control the helper has cleared. The next read reports the lapse.
    public func renewHold(_ mode: ChargeControlMode) async throws {
        defer { updateActivity() }
        guard let control = Self.control(for: mode) else { return }
        guard let hold = holds[control], !hold.isReleaseRequested else {
            throw BackendError.operationFailed("CellKeeper holds no \(Self.describe([control])) on its helper to renew")
        }
        if let deadline = leaseDeadlines[control], uptime() >= deadline {
            return
        }
        try await takeLease(control)
    }

    /// Restores macOS's defaults through the helper if it is waiting for a
    /// client to acknowledge a problem: an interlock other than the power
    /// and sleep conditions (an outside change, a failed write, an owed
    /// restore), a control CellKeeper did not set, or a failed read-back.
    /// This ends every lease and may undo another tool's change, which is
    /// why only the user's clearing of the fault does it. A helper that
    /// cannot be reached has nothing to acknowledge. If the session ended
    /// before the restore arrived, the backend connects again, says hello,
    /// and tries once more.
    public func resetAfterFault() async throws {
        defer { updateActivity() }
        clearNotices()
        // The user has acknowledged it.
        outsideLoss = nil
        let state: HelperStateReply
        do {
            state = try await fetchState()
        } catch BackendError.unavailable {
            return
        }
        if state.status == .ok {
            observe(state)
        }
        let needsAcknowledgement = state.status == .hardwareError
            || !state.interlocks.subtracting(Self.conditionInterlocks).isEmpty
            || !state.activeControls.controls.subtracting(holds.keys).isEmpty
        guard needsAcknowledgement else { return }
        var status: HelperStatus?
        do {
            status = try await send(needsToken: false) { try await $0.restoreDefaults() }
        } catch BackendError.operationFailed {
            // The connection was lost; `send` has dropped it.
            status = nil
        }
        if status.map(Self.isSessionLost) ?? true {
            await dropConnection()
            status = try await send(needsToken: false) { try await $0.restoreDefaults() }
        }
        guard status == .ok else {
            if status.map(Self.isSessionLost) ?? false { await dropConnection() }
            throw BackendError.operationFailed("CellKeeper's helper could not restore macOS's defaults (\(status.map(String.init(describing:)) ?? "no reply"))")
        }
        // Confirmed by the helper's read-back: nothing is set any more.
        holds = [:]
        pendingActivations = [:]
        leaseDeadlines = [:]
        currentOutsideChange = nil
    }

    // MARK: - Requests

    /// Holds `target`, then lets go of the other control if it is
    /// CellKeeper's. Confirms by a fresh read that exactly `target` is
    /// active, set by CellKeeper.
    private func hold(_ target: HelperControl, as mode: ChargeControlMode) async throws -> ControlOutcome {
        clearNotices()
        // Withheld by the capabilities already; checked again on the latest
        // reading, so nothing is ever set while macOS's limit may be on.
        if let macOSChargeLimit, await macOSChargeLimit.status().isLimiting {
            throw BackendError.unsupportedMode(mode)
        }
        let introduction = try await introduced()
        guard introduction.capabilities.contains(target.requiredCapability) else {
            throw BackendError.unsupportedMode(mode)
        }
        let expected = Self.mode(for: Set(holds.keys)) ?? .normal
        let before = try await readState()
        observe(before)
        if currentOutsideChange != nil || outsideLoss != nil {
            // Never write over another tool's change (R26, R27).
            throw BackendError.changedOutside(expected: expected, found: Self.mode(for: before.activeControls.controls))
        }
        let wasInEffect = before.activeControls.controls == [target] && holds[target] != nil
        do {
            try await takeLease(target)
            guard let instance = helperInstance, let session = self.introduction?.sessionID else {
                throw BackendError.operationFailed("no connection to CellKeeper's helper")
            }
            // Recorded before it is sent: from here on the activation may
            // take effect whatever happens to the reply, so CellKeeper stays
            // responsible for the control until a read shows the outcome.
            pendingActivations[target] = PendingActivation(
                instance: instance,
                session: session,
                generationBefore: before.change(for: target).generation
            )
            let status = try await send(needsToken: true) { try await $0.setControl(control: target.rawValue, active: true) }
            guard status == .ok else {
                throw await refusal(status, activating: target)
            }
            let set = try await readState()
            observe(set)
            // The read settled the activation: the control is CellKeeper's
            // only if the helper names this activation as its latest change.
            guard let hold = holds[target], hold.generation == set.change(for: target).generation,
                  set.activeControls.controls.contains(target) else {
                throw BackendError.verificationFailed(expected: mode, actual: Self.mode(for: set.activeControls.controls))
            }
            // Only now that the new control is set: no moment in between
            // allows charging the policy did not ask for.
            for other in HelperControl.allCases where other != target {
                try await letGo(other, leaseHeld: set.isLeaseHolder && set.leaseSeconds(for: other) > 0)
            }
            let after = try await readState()
            observe(after)
            let active = after.activeControls.controls
            guard active == [target], holds[target] != nil, currentOutsideChange == nil, outsideLoss == nil else {
                throw BackendError.verificationFailed(expected: mode, actual: Self.mode(for: active))
            }
        } catch {
            await reconcileAfterFailure()
            throw error
        }
        clearNotices()
        return outcome(changed: !wasInEffect)
    }

    /// Clears what is still CellKeeper's and ends its leases; then confirms
    /// that nothing is active. Each clear names the change CellKeeper made,
    /// so the helper clears nothing that changed since. A control CellKeeper
    /// did not set, or no longer owns, is never touched: it is reported as an
    /// outside change. An outside change found on the way stays reported
    /// after the release succeeds.
    private func releaseAll() async throws -> ControlOutcome {
        clearNotices()
        let before = try await readState()
        observe(before)
        let ownedBefore = Set(holds.keys)
        do {
            // The adapter first, so external power returns as soon as possible.
            for control in [HelperControl.adapterDisabled, .chargingInhibited] {
                try await letGo(control, leaseHeld: before.isLeaseHolder && before.leaseSeconds(for: control) > 0)
            }
        } catch {
            await reconcileAfterFailure()
            throw error
        }
        let after = try await readState()
        observe(after)
        let remaining = after.activeControls.controls
        guard remaining.isEmpty else {
            if remaining.isDisjoint(with: holds.keys) {
                throw BackendError.changedOutside(expected: .normal, found: Self.mode(for: remaining))
            }
            throw BackendError.verificationFailed(expected: .normal, actual: Self.mode(for: remaining))
        }
        leaseDeadlines = [:]
        clearNotices()
        return outcome(changed: !ownedBefore.isEmpty)
    }

    /// Clears `control` if it is still the change CellKeeper made, and ends
    /// CellKeeper's lease on it. The helper compares the change right before
    /// it clears (`clearControlIfUnchanged`); if the control changed since,
    /// it clears nothing, and the next read tells how CellKeeper's hold
    /// ended. The hold is kept, marked as released, until a read confirms the
    /// change; the helper's history then shows it as CellKeeper's own, also
    /// after a reconnect. Neither request needs a lease or is ever
    /// rate-limited by the helper.
    private func letGo(_ control: HelperControl, leaseHeld: Bool) async throws {
        if let hold = holds[control] {
            holds[control]?.isReleaseRequested = true
            let status = try await send(needsToken: false) {
                try await $0.clearControlIfUnchanged(control: control.rawValue, generation: hold.generation, helperInstance: hold.instance)
            }
            guard status == .ok || status == .controlChanged else {
                if Self.isSessionLost(status) { await dropConnection() }
                throw BackendError.operationFailed("CellKeeper's helper could not clear \(Self.describe([control])) (\(status))")
            }
        }
        if leaseHeld {
            let status = try await send(needsToken: false) { try await $0.releaseLease(control: control.rawValue) }
            // `noLease`: it has already ended.
            guard status == .ok || status == .noLease else {
                if Self.isSessionLost(status) { await dropConnection() }
                throw BackendError.operationFailed("CellKeeper's helper could not end the lease on \(Self.describe([control])) (\(status))")
            }
        }
        leaseDeadlines[control] = nil
    }

    /// Takes or renews CellKeeper's lease on `control` for the longest the
    /// helper grants.
    private func takeLease(_ control: HelperControl) async throws {
        let requestedAt = uptime()
        let reply = try await send(needsToken: true) {
            try await $0.acquireOrRenewLease(control: control.rawValue, seconds: control.maximumLeaseSeconds)
        }
        guard reply.status == .ok, reply.grantedSeconds > 0 else {
            if Self.isSessionLost(reply.status) { await dropConnection() }
            throw BackendError.operationFailed("CellKeeper's helper refused a lease on \(Self.describe([control])) (\(reply.status))")
        }
        leaseDeadlines[control] = requestedAt + TimeInterval(reply.grantedSeconds)
    }

    /// The error for a refused activation.
    private func refusal(_ status: HelperStatus, activating control: HelperControl) async -> BackendError {
        if Self.isSessionLost(status) {
            await dropConnection()
            return .operationFailed("CellKeeper's helper ended its session (\(status))")
        }
        guard status == .blockedByInterlock, let state = try? await readState() else {
            return .operationFailed("CellKeeper's helper refused to set \(Self.describe([control])) (\(status))")
        }
        if state.interlocks.contains(.externalModification) {
            return .changedOutside(expected: Self.mode(for: Set(holds.keys)) ?? .normal, found: Self.mode(for: state.activeControls.controls))
        }
        let blocking = state.interlocks.intersection(control.blockingInterlocks)
        return .operationFailed("CellKeeper's helper refused to set \(Self.describe([control])): \(Self.describe(blocking))")
    }

    /// After a failed request, a fresh read decides what is still
    /// CellKeeper's; the controller then requests `.normal`.
    private func reconcileAfterFailure() async {
        guard let state = try? await readState() else { return }
        observe(state)
    }

    private func outcome(changed: Bool) -> ControlOutcome {
        if isSimulated { return .simulated }
        return changed ? .applied : .unchanged
    }

    /// Forgets the notices kept until the next request. An outside change
    /// not yet reported is kept (see ``outsideLoss``).
    private func clearNotices() {
        origin = nil
        lastRelease = nil
        isOwnReleaseConfirmed = false
    }

    /// Holds the activity exactly while CellKeeper holds a control it has
    /// not asked to release, through a live session that renews it.
    private func updateActivity() {
        let isRenewing = connection != nil && holds.values.contains { !$0.isReleaseRequested && $0.instance == helperInstance }
        guard isRenewing != isActivityHeld else { return }
        isActivityHeld = isRenewing
        activity.setHolding(isRenewing)
    }

    // MARK: - Reading state

    /// Why a control CellKeeper held changed, looked up in the helper's
    /// history.
    private enum Ending {
        /// One of the helper's own rules ended it.
        case released(HoldRelease)
        /// CellKeeper released it.
        case own
        /// The helper cleared it because of a hardware problem: a failure.
        case failure
        /// Someone else changed it.
        case outside(String)
    }

    /// Notes a hardware error the helper had not reported before, until
    /// ``currentMode()`` reports it. Any reply that carries the helper's
    /// state counts, also one whose read-back failed.
    private func noteHardwareErrors(_ state: HelperStateReply) {
        if let count = lastHardwareErrorCount, state.hardwareErrorCount > count {
            unreportedHardwareError = "CellKeeper's helper reports a new hardware error (code \(state.lastHardwareError))"
        }
        lastHardwareErrorCount = state.hardwareErrorCount
    }

    /// Updates what CellKeeper holds from a fresh read whose status is `ok`:
    /// settles the activations it sent, notes how holds ended, any outside
    /// change the helper still shows, and any hardware error it had not
    /// reported before (until ``currentMode()`` reports it).
    private func observe(_ state: HelperStateReply) {
        let active = state.activeControls.controls
        noteHardwareErrors(state)
        settlePendingActivations(in: state)
        var endings: [Ending] = []
        for (control, hold) in holds {
            guard let ending = ending(of: control, hold, in: state) else { continue }
            holds[control] = nil
            endings.append(ending)
        }
        for ending in endings {
            switch ending {
            case .released(let release): lastRelease = lastRelease ?? release
            case .own: isOwnReleaseConfirmed = true
            case .failure: unreportedHardwareError = unreportedHardwareError ?? "CellKeeper's helper cleared CellKeeper's control after a hardware error (code \(state.lastHardwareError))"
            case .outside(let detail): outsideLoss = outsideLoss ?? detail
            }
        }
        let foreign = active.subtracting(holds.keys)
        if state.interlocks.contains(.externalModification) {
            currentOutsideChange = Self.externalModificationDetail
        } else if !foreign.isEmpty {
            currentOutsideChange = "CellKeeper's helper reports \(Self.describe(foreign)), which CellKeeper did not set or no longer holds"
        } else {
            currentOutsideChange = nil
        }
    }

    /// Settles each activation CellKeeper sent, by the helper's history. If
    /// the helper names it as the control's latest change (`setByClient`, on
    /// the session it was sent on, after the generation before it), it took
    /// effect and the control is CellKeeper's. Otherwise nothing of it is
    /// still in effect: it did not take effect (the control has not changed
    /// since), or the control changed since, or the helper restarted (and its
    /// start restored defaults). A control that changed since is never
    /// CellKeeper's, but its latest change is classified like the end of a
    /// hold: another client's clear or restore, or any other outside change,
    /// is reported as an outside change (R27), and a failure as a failure. An
    /// active control CellKeeper did not set is reported as well (``observe``).
    private func settlePendingActivations(in state: HelperStateReply) {
        for (control, pending) in pendingActivations {
            pendingActivations[control] = nil
            guard pending.instance == helperInstance else { continue }
            let change = state.change(for: control)
            guard change.generation > pending.generationBefore else { continue }
            if change.cause == .setByClient, change.session == pending.session,
               state.activeControls.controls.contains(control) {
                holds[control] = Hold(generation: change.generation, instance: pending.instance)
                continue
            }
            switch ending(by: change, of: control) {
            case .outside(let detail):
                outsideLoss = outsideLoss ?? detail
            case .failure:
                unreportedHardwareError = unreportedHardwareError ?? "CellKeeper's helper cleared \(Self.describe([control])) after a hardware error (code \(state.lastHardwareError))"
            case .released, .own:
                break
            }
        }
    }

    /// How a hold ended, by the helper's history; nil if it has not.
    private func ending(of control: HelperControl, _ hold: Hold, in state: HelperStateReply) -> Ending? {
        let name = Self.describe([control])
        let isActive = state.activeControls.controls.contains(control)
        guard hold.instance == helperInstance else {
            // An earlier helper process is gone; its successor restored
            // defaults at start (R2).
            return isActive
                ? .outside("\(name) is active after the helper restarted, so CellKeeper cannot tell whose it is")
                : .released(.backendStopped)
        }
        let change = state.change(for: control)
        if change.generation == hold.generation {
            return nil
        }
        guard change.generation == hold.generation + 1, !isActive else {
            return .outside("\(name) changed \(change.generation &- hold.generation) times since CellKeeper set it, and is \(isActive ? "active again, set by someone else" : "off")")
        }
        return ending(by: change, of: control)
    }

    /// What `change`, the helper's latest change of `control`, says about how
    /// something CellKeeper set there ended: one of the helper's own rules,
    /// CellKeeper's own release, a failure, or an outside change.
    private func ending(by change: HelperControlChange, of control: HelperControl) -> Ending {
        let name = Self.describe([control])
        let isOwnSession = ownSessions.contains(change.session)
        switch change.cause {
        case .leaseExpired?:
            return .released(.leaseExpired)
        case .interlock?:
            if change.interlocks.contains(.externalModification) {
                return .outside("CellKeeper's helper cleared \(name) after its controls were changed outside CellKeeper")
            }
            let routine = change.interlocks.intersection(Self.conditionInterlocks)
            guard change.interlocks == routine, !routine.isEmpty else { return .failure }
            return .released(.interlock(Self.describe(routine)))
        case .sessionEnded?, .sessionRevoked?:
            return isOwnSession
                ? .released(.connectionLost)
                : .outside("another client's session ended, which cleared \(name)")
        case .shutdown?, .start?:
            return .released(.backendStopped)
        case .clearedByClient?, .clearedByRestore?, .activationLimited?:
            return isOwnSession
                ? .own
                : .outside(change.cause == .clearedByRestore
                    ? "another client of the helper restored macOS's defaults, which cleared \(name)"
                    : "another client of the helper cleared \(name)")
        case .restoredAfterWriteFailure?, .restoredAfterReadBackFailure?, .restoreRetried?:
            return .failure
        case .changedOutside?, .restoredAfterOutsideChange?:
            return .outside("\(name) was changed outside CellKeeper")
        case .setByClient?, nil:
            return .outside("\(name) changed in a way CellKeeper cannot account for")
        }
    }

    /// What the helper waits for a client to acknowledge, if anything: an
    /// interlock other than the power and sleep conditions and an outside
    /// change (`writeFailed`, a restore it owes, one this version does not
    /// know).
    static func acknowledgementNeeded(_ state: HelperStateReply) -> String? {
        let waiting = state.interlocks.subtracting(conditionInterlocks).subtracting(.externalModification)
        guard !waiting.isEmpty else { return nil }
        return "CellKeeper's helper stopped making changes: \(describe(waiting))"
    }

    /// A fresh `readState` whose status is `ok`.
    private func readState() async throws -> HelperStateReply {
        let state = try await fetchState()
        guard state.status == .ok else {
            throw BackendError.operationFailed("CellKeeper's helper could not read back its controls (hardware error \(state.lastHardwareError))")
        }
        return state
    }

    /// A fresh `readState` whose status is `ok` or `hardwareError` (the
    /// read-back failed; interlocks are still reported). If the helper no
    /// longer knows the session, connects again and reads once more.
    private func fetchState() async throws -> HelperStateReply {
        var state = try await send(needsToken: true) { try await $0.readState() }
        if Self.isSessionLost(state.status) {
            await dropConnection()
            state = try await send(needsToken: true) { try await $0.readState() }
        }
        switch state.status {
        case .ok, .hardwareError:
            return state
        default:
            if Self.isSessionLost(state.status) { await dropConnection() }
            throw BackendError.operationFailed("CellKeeper's helper did not report its state (\(state.status))")
        }
    }

    // MARK: - Connection

    /// The current connection's reply to `hello`, connecting and introducing
    /// CellKeeper first if there is no connection.
    @discardableResult
    private func introduced() async throws -> HelperHelloReply {
        if connection != nil, let introduction { return introduction }
        let new: any HelperConnection
        do {
            new = try await transport.connect()
        } catch {
            throw BackendError.unavailable("CellKeeper's helper cannot be reached (\(error)); it may not be installed or running.")
        }
        // The helper gives each new session a full request budget.
        pacer = RequestPacer(at: uptime())
        await paced(needsToken: true)
        let reply: HelperHelloReply
        do {
            reply = try await new.hello(clientProtocolVersion: HelperProtocolVersion.current)
        } catch {
            await new.invalidate()
            throw BackendError.unavailable("The connection to CellKeeper's helper ended while connecting (\(error)).")
        }
        guard reply.status == .ok else {
            await new.invalidate()
            throw BackendError.unavailable(Self.helloRefusal(reply))
        }
        if reply.helperInstance != helperInstance {
            // A new helper process: its sessions and generations start
            // again. Holds made with the old one are settled at the next
            // read.
            helperInstance = reply.helperInstance
            ownSessions = []
            lastHardwareErrorCount = nil
        }
        ownSessions.insert(reply.sessionID)
        connection = new
        introduction = reply
        isSimulated = reply.isSimulated
        return reply
    }

    /// Sends one request on the introduced connection. A transport failure
    /// drops the connection, so the next request connects again and reads
    /// the state afresh.
    private func send<Reply: Sendable>(
        needsToken: Bool,
        _ request: @Sendable (any HelperConnection) async throws -> Reply
    ) async throws -> Reply {
        try await introduced()
        guard let connection else {
            throw BackendError.operationFailed("no connection to CellKeeper's helper")
        }
        await paced(needsToken: needsToken)
        do {
            return try await request(connection)
        } catch {
            await dropConnection()
            throw BackendError.operationFailed("lost the connection to CellKeeper's helper (\(error))")
        }
    }

    /// Ends the current connection. The helper clears what its session
    /// held; CellKeeper keeps its holds until a fresh read explains them.
    private func dropConnection() async {
        let old = connection
        connection = nil
        introduction = nil
        updateActivity()
        await old?.invalidate()
    }

    /// Waits, if needed, so the helper's request budget never refuses
    /// CellKeeper or revokes its session (see ``RequestPacer``).
    private func paced(needsToken: Bool) async {
        let wait = pacer.wait(needsToken: needsToken, at: uptime())
        if wait > 0 {
            await pause(wait)
        }
        pacer.take(at: uptime())
    }

    // MARK: - Vocabulary

    /// Interlocks that follow from the power state and sleep, and lift by
    /// themselves. Any other interlock waits for a client to restore
    /// defaults.
    static let conditionInterlocks: HelperInterlocks = [
        .belowBatteryFloor, .notOnExternalPower, .belowAdapterFloor, .adapterAbsent,
        .adapterPresenceUnknown, .thermalPressure, .powerStateUnavailable, .sleepImminent,
    ]

    static let externalModificationDetail = "CellKeeper's helper found its controls changed by something other than CellKeeper (another tool may be controlling charging); it restored macOS's defaults and changes nothing more until the fault is cleared"

    static func mode(for control: HelperControl) -> ChargeControlMode {
        switch control {
        case .chargingInhibited: .inhibitCharging
        case .adapterDisabled: .forceDischarge
        }
    }

    /// The mode the controls amount to; nil if both are active.
    static func mode(for controls: Set<HelperControl>) -> ChargeControlMode? {
        switch controls.count {
        case 0: .normal
        case 1: controls.first.map(mode(for:))
        default: nil
        }
    }

    static func control(for mode: ChargeControlMode) -> HelperControl? {
        switch mode {
        case .inhibitCharging: .chargingInhibited
        case .forceDischarge: .adapterDisabled
        case .normal, .nativeLimit: nil
        }
    }

    static func describe(_ controls: Set<HelperControl>) -> String {
        HelperControl.allCases.filter(controls.contains).map { control -> String in
            switch control {
            case .chargingInhibited: "charging inhibited"
            case .adapterDisabled: "the adapter disabled"
            }
        }.joined(separator: " and ")
    }

    static func describe(_ interlocks: HelperInterlocks) -> String {
        let names: [(HelperInterlocks, String)] = [
            (.belowBatteryFloor, "the battery is at or below the helper's \(HelperEngine.batteryFloor)% floor"),
            (.notOnExternalPower, "the Mac is not on external power"),
            (.belowAdapterFloor, "the battery is at or below the \(HelperEngine.adapterFloor)% floor for running from it"),
            (.adapterAbsent, "no power adapter is connected"),
            (.adapterPresenceUnknown, "the helper cannot tell whether a power adapter is connected"),
            (.thermalPressure, "macOS reports high thermal pressure"),
            (.powerStateUnavailable, "the helper's own power reading is missing or out of date"),
            (.sleepImminent, "the Mac is about to sleep"),
            (.externalModification, "its controls were changed outside CellKeeper"),
            (.hardwareFault, "a restore of macOS's defaults failed and is owed"),
            (.writeFailed, "a write to one of its controls failed"),
        ]
        var parts = names.filter { interlocks.contains($0.0) }.map(\.1)
        let unnamed = names.reduce(interlocks) { $0.subtracting($1.0) }
        if !unnamed.isEmpty {
            parts.append("interlock 0x\(String(unnamed.rawValue, radix: 16))")
        }
        return parts.joined(separator: "; ")
    }

    static func isSessionLost(_ status: HelperStatus) -> Bool {
        status == .notIntroduced || status == .shuttingDown
    }

    static func helloRefusal(_ reply: HelperHelloReply) -> String {
        switch reply.status {
        case .incompatibleProtocol:
            "CellKeeper's helper speaks protocol version \(reply.helperProtocolVersion), which this version of CellKeeper (protocol version \(HelperProtocolVersion.current)) cannot use. Update CellKeeper and its helper."
        case .notReady:
            "CellKeeper's helper has not finished starting."
        case .shuttingDown:
            "CellKeeper's helper is shutting down."
        default:
            "CellKeeper's helper refused the connection (\(reply.status))."
        }
    }

    static func reason(_ error: any Error) -> String {
        if case BackendError.unavailable(let reason) = error { return reason }
        return "CellKeeper's helper is not responding: \(error)"
    }
}

/// Mirrors a helper session's request budget (``HelperEngine/requestBurst``
/// at once, refilled at ``HelperEngine/requestsPerSecond``) with one token
/// in reserve for timing differences.
struct RequestPacer {
    static let capacity = Double(HelperEngine.requestBurst - 1)
    static let rate = HelperEngine.requestsPerSecond
    /// Requests that only move toward safety are sent without waiting, but
    /// never more than this many in a row beyond the budget: far below
    /// ``HelperEngine/maximumOverBudgetRequests``, after which the helper
    /// revokes the session.
    static let maximumUnpacedStreak = 4

    private var tokens: Double
    private var refilledAt: TimeInterval
    /// Requests sent in a row without a token.
    private(set) var overBudgetStreak = 0

    init(at now: TimeInterval) {
        tokens = Self.capacity
        refilledAt = now
    }

    /// Seconds to wait before sending a request; 0 to send it now. A request
    /// the helper's budget may refuse waits for a token; one that only moves
    /// toward safety waits only after ``maximumUnpacedStreak`` requests in a
    /// row went without one.
    mutating func wait(needsToken: Bool, at now: TimeInterval) -> TimeInterval {
        refill(at: now)
        guard tokens < 1, needsToken || overBudgetStreak >= Self.maximumUnpacedStreak else { return 0 }
        return (1 - tokens) / Self.rate
    }

    /// Uses a token if one is available, as the helper does for every
    /// request.
    mutating func take(at now: TimeInterval) {
        refill(at: now)
        if tokens >= 1 {
            tokens -= 1
            overBudgetStreak = 0
        } else {
            overBudgetStreak += 1
        }
    }

    private mutating func refill(at now: TimeInterval) {
        guard now > refilledAt else { return }
        tokens = min(Self.capacity, tokens + (now - refilledAt) * Self.rate)
        refilledAt = now
    }
}
