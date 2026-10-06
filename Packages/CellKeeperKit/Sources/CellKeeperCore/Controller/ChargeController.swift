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
/// - With a native-limit backend, `.normal` means the user's own macOS Charge
///   Limit, so every path above restores exactly that value. If the backend
///   remembers a limit it set in an earlier session, that limit counts as
///   CellKeeper's own, so a change made while CellKeeper was not running is
///   detected like any other external change.
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
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval

    private var settings: ChargingSettings
    private var activeOverride: ChargeOverride?
    private var memory = PolicyMemory()
    private var snapshot: BatterySnapshot?
    private var telemetryError: String?
    private var capabilities: ControlCapabilities = .unavailable("Not evaluated yet.")
    private var currentMode: ChargeControlMode?
    /// The mode CellKeeper last requested and confirmed on this backend.
    private var ownedMode: ChargeControlMode?
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
    private var decision: PolicyDecision?
    private var lastExecution: ExecutionRecord?
    private var consecutiveFailures = 0
    private var lastFailureUptime: TimeInterval?
    private var sleepAnnouncedAtUptime: TimeInterval?
    private var isShutDown = false
    private var restrictingRequestTimes: [TimeInterval] = []
    private var events: [ControlEvent] = []
    private var nextEventID = 0
    private var lastEvaluation: Date?

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - now: wall-clock time, for telemetry age and display.
    ///   - uptime: monotonic seconds that keep counting during sleep, for
    ///     override expiry and rate limiting. Defaults to `ContinuousClock`.
    public init(
        telemetry: any TelemetryProvider,
        backend: any ChargingBackend,
        settings: ChargingSettings,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: (@Sendable () -> TimeInterval)? = nil
    ) {
        self.telemetry = telemetry
        self.backend = backend
        self.settings = settings
        self.now = now
        self.uptime = uptime ?? Self.continuousUptime()
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
            nativeLimit: nativeLimit,
            pendingBackend: pendingBackend?.descriptor,
            decision: decision,
            lastExecution: lastExecution,
            consecutiveFailures: consecutiveFailures,
            isBackendFaulted: isBackendFaulted,
            events: events,
            lastEvaluation: lastEvaluation
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
    @discardableResult
    public func apply(settings newSettings: ChargingSettings) async throws -> ControllerStatus {
        let validSettings: ChargingSettings
        do {
            validSettings = try newSettings.validated()
        } catch {
            _ = await exclusively {
                record(.settings, "Rejected invalid settings: \(error)", level: .error)
            }
            throw error
        }
        return await exclusively {
            guard validSettings != settings else { return }
            let previous = settings
            settings = validSettings
            record(.settings, Self.describeChange(from: previous, to: validSettings))
            if !validSettings.isManagementEnabled, let ended = activeOverride {
                activeOverride = nil
                record(.override, "\(Self.describe(ended.kind)) cancelled because charge management was turned off.")
            }
            await performEvaluation(.settingsChanged)
        }
    }

    /// Starts a temporary full charge. It ends at 100%, when fully charged, on
    /// unplug, or when `duration` elapses, whichever comes first.
    @discardableResult
    public func startFullCharge(duration: TimeInterval = ChargeOverride.defaultFullChargeDuration) async -> ControllerStatus {
        await exclusively {
            guard settings.isManagementEnabled else {
                record(.override, "Temporary full charge not started: charge management is off.")
                return
            }
            let override = ChargeOverride.fullCharge(at: now(), uptime: uptime(), duration: duration)
            activeOverride = override
            record(.override, "Temporary full charge requested (expires \(override.expiresAt.formatted(date: .omitted, time: .shortened))).")
            await performEvaluation(.overrideChanged)
        }
    }

    /// Starts a one-shot discharge session down to the charge limit. It ends
    /// at the limit, on unplug, before sleep, on temperature pause, on lost
    /// telemetry, or when `duration` elapses. Requires management to be on
    /// and a limit within ``ChargingPolicy/dischargeTargetRange``.
    @discardableResult
    public func startDischargeToLimit(duration: TimeInterval = ChargeOverride.defaultDischargeDuration) async -> ControllerStatus {
        await exclusively {
            guard settings.isManagementEnabled, ChargingPolicy.dischargeTargetRange.contains(settings.chargeLimit) else {
                record(.override, "Discharge not started: requires charge management on and a limit of \(ChargingPolicy.dischargeTargetRange.lowerBound)–\(ChargingPolicy.dischargeTargetRange.upperBound)%.", level: .default)
                return
            }
            let override = ChargeOverride.dischargeToLimit(target: settings.chargeLimit, at: now(), uptime: uptime(), duration: duration)
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
            record(.override, "\(Self.describe(cancelled.kind)) cancelled.")
            await performEvaluation(.overrideChanged)
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
            pendingBackend = newBackend
            guard await restoreNormal(reason: "switching backend") else {
                record(.safety, "Backend switch to \(newBackend.descriptor.displayName) refused for now: normal charging could not be confirmed on \(backend.descriptor.displayName). CellKeeper keeps trying and switches once it is confirmed.", level: .fault)
                return
            }
            await completePendingSwitch()
        }
    }

    /// Native-limit backends: looks for the shortcut again, then evaluates.
    @discardableResult
    public func recheckBackendAvailability() async -> ControllerStatus {
        await exclusively {
            await (backend as? NativeChargeLimitBackend)?.recheckAvailability()
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
        currentMode = nil
        ownedMode = nil
        hasSeededOwnership = false
        nativeLimit = nil
        lastExecution = nil
        record(.settings, "Control backend changed from \(previousName) to \(newBackend.descriptor.displayName).")
        await performEvaluation(.backendChanged)
    }

    /// Clears the faulted state so non-normal modes may be requested again.
    @discardableResult
    public func resetBackendFault() async -> ControllerStatus {
        await exclusively {
            guard consecutiveFailures > 0 else { return }
            consecutiveFailures = 0
            lastFailureUptime = nil
            record(.safety, "Backend fault cleared by user.")
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

    // MARK: - Evaluation

    private func performEvaluation(_ trigger: EvaluationTrigger) async {
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
        let releaseReason: ReleaseReason? = pendingBackend != nil ? .backendSwitch
            : isOwnedStateUnverified ? .stateUnverified
            : nil

        let input = PolicyInput(
            now: now(),
            uptime: evaluationUptime,
            settings: settings,
            snapshot: snapshot,
            activeOverride: activeOverride,
            capabilities: capabilities,
            currentMode: currentMode,
            memory: memory,
            isBackendFaulted: isBackendFaulted,
            recentRestrictingRequests: restrictingRequestTimes,
            isSleepImminent: sleepAnnouncedAtUptime != nil,
            restoreRetryNotBefore: trigger.isAutomatic
                ? lastFailedRestoreUptime.map { $0 + ChargingPolicy.minimumRestoreRetryInterval }
                : nil,
            releaseReason: releaseReason
        )
        restrictingRequestTimes.removeAll { input.uptime - $0 >= 60 * 60 }
        let newDecision = ChargingPolicy.evaluate(input)
        memory = newDecision.memory
        lastEvaluation = input.now

        if let ended = newDecision.overrideEnded, let override = activeOverride {
            activeOverride = nil
            record(.override, "\(Self.describe(override.kind)) \(ended).")
        }
        if Self.isMeaningfulChange(from: decision, to: newDecision) {
            record(.decision, "[\(trigger.rawValue)] \(newDecision.state.rawValue): want \(newDecision.desiredMode), action \(Self.describe(newDecision.action, nativeLimit: capabilities.isEnforcedByMacOS)). \(newDecision.reason)")
        }
        for note in newDecision.notes where !(decision?.notes.contains(note) ?? false) {
            record(.decision, "Note: \(note)")
        }
        decision = newDecision

        await execute(newDecision.action)
        nativeLimit = await backend.nativeLimitStatus()

        if pendingBackend != nil, currentMode == .normal, !(nativeLimit?.hasUnresolvedOwnership ?? false) {
            await completePendingSwitch()
        }
    }

    /// Reads the backend's mode, counting failures and detecting changes that
    /// CellKeeper did not make.
    private func observeBackendMode() async {
        isOwnedStateUnverified = false
        let observed: ChargeControlMode?
        do {
            observed = try await backend.currentMode()
        } catch {
            // `ownedMode` is kept, so a later reading is still compared with
            // what CellKeeper last confirmed.
            currentMode = nil
            nativeLimit = await backend.nativeLimitStatus()
            registerFailure("Could not read the backend's mode: \(error)")
            isOwnedStateUnverified = holdsNonNormalState
            return
        }
        currentMode = observed
        nativeLimit = await backend.nativeLimitStatus()
        if !hasSeededOwnership {
            hasSeededOwnership = true
            if ownedMode == nil, let target = nativeLimit?.target {
                ownedMode = .nativeLimit(percent: target)
                record(.safety, "macOS's Charge Limit was left at \(target)% by an earlier CellKeeper session; your own limit (\(nativeLimit?.ownerLimit.map { "\($0)%" } ?? "unknown")) is still recorded and will be restored.")
            }
        }
        guard capabilities.availability.acceptsRequests else { return }
        guard let observed else {
            registerFailure("The backend did not report its mode.")
            isOwnedStateUnverified = holdsNonNormalState
            return
        }
        if let owned = ownedMode, owned != observed {
            ownedMode = nil
            consecutiveFailures = max(consecutiveFailures, Self.maximumConsecutiveFailures)
            if capabilities.isEnforcedByMacOS {
                record(.safety, "macOS's Charge Limit changed outside CellKeeper (expected \(owned), found \(observed)); it may have been changed in System Settings or by another tool. Backend faulted; restoring your own limit.", level: .fault)
            } else {
                record(.safety, "Charging mode changed outside CellKeeper (expected \(owned), found \(observed)); another tool may be controlling charging. Backend faulted; restoring normal charging.", level: .fault)
            }
        }
    }

    /// True if CellKeeper may have a non-normal state in effect.
    private var holdsNonNormalState: Bool {
        (ownedMode.map { $0 != .normal } ?? false) || (nativeLimit?.hasUnresolvedOwnership ?? false)
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
        let isRestricting = mode.isRestricting(from: currentMode)
        if isRestricting {
            // Attempts count, not just successes, so failures cannot cause
            // a burst of writes.
            restrictingRequestTimes.append(uptime())
        }
        let target = describeTarget(mode)
        let ownerLimitBefore = nativeLimit?.ownerLimit
        record(.request, "Requesting \(target) from \(backend.descriptor.displayName) backend.")
        do {
            var outcome = try await setAndConfirm(mode)
            if ownerLimitBefore == nil, let ownerLimit = nativeLimit?.ownerLimit {
                record(.safety, "Recorded your own macOS Charge Limit of \(ownerLimit)% before changing it; it is restored when CellKeeper stops managing it.")
            }
            // A fault persists until the user clears it, even if restoring
            // normal charging succeeds.
            if !isBackendFaulted {
                consecutiveFailures = 0
                lastFailureUptime = nil
            }
            if outcome != .simulated, !capabilities.availability.affectsHardware {
                record(.safety, "\(backend.descriptor.displayName) backend reported a hardware change but is not a hardware backend; treating it as simulated.", level: .error)
                outcome = .simulated
            }
            switch outcome {
            case .applied:
                lastExecution = ExecutionRecord(date: now(), action: action, result: .applied)
                record(.result, "Applied \(target) (confirmed by read-back\(confirmationDetail(mode))).")
            case .unchanged:
                // Nothing was written, so it does not count toward the limit.
                if isRestricting, !restrictingRequestTimes.isEmpty {
                    restrictingRequestTimes.removeLast()
                }
                lastExecution = ExecutionRecord(date: now(), action: action, result: .unchanged)
                record(.result, "Already in effect: \(target); nothing changed (confirmed by read-back\(confirmationDetail(mode))).")
            case .simulated:
                lastExecution = ExecutionRecord(date: now(), action: action, result: .simulated)
                record(.result, "Simulated \(mode); hardware unchanged.")
            }
        } catch {
            let message = String(describing: error)
            lastExecution = ExecutionRecord(date: now(), action: action, result: .failed(message))
            if case BackendError.changedOutside = error {
                consecutiveFailures = max(consecutiveFailures + 1, Self.maximumConsecutiveFailures)
                lastFailureUptime = uptime()
                record(.safety, "Not applied: \(message). It may have been changed in System Settings or by another tool. Backend faulted; restoring \(describeTarget(.normal)).", level: .fault)
            } else {
                registerFailure("Backend failed to apply \(target): \(message)")
            }
            if mode != .normal {
                _ = await restoreNormal(reason: "safety fallback after failed \(mode) request")
            }
        }
    }

    /// How a requested mode is described in the activity log.
    private func describeTarget(_ mode: ChargeControlMode) -> String {
        guard capabilities.isEnforcedByMacOS else { return mode.description }
        switch mode {
        case .normal:
            return "your own macOS Charge Limit" + (nativeLimit?.ownerLimit.map { " of \($0)%" } ?? "")
        case .nativeLimit(let percent):
            return "a macOS Charge Limit of \(percent)%"
        case .inhibitCharging, .forceDischarge:
            return mode.description
        }
    }

    /// For native limits, the value macOS reported when confirming.
    private func confirmationDetail(_ mode: ChargeControlMode) -> String {
        guard capabilities.isEnforcedByMacOS, let reported = nativeLimit?.reportedLimit else { return "" }
        return ": macOS reports \(reported)%"
    }

    /// Sets a mode and confirms it by read-back. On success the mode is
    /// recorded as owned by CellKeeper. On failure the current mode is
    /// unknown, and the last confirmed mode stays the expectation that later
    /// readings are compared with.
    private func setAndConfirm(_ mode: ChargeControlMode) async throws -> ControlOutcome {
        do {
            let outcome = try await backend.setMode(mode)
            let readBack: ChargeControlMode?
            do {
                readBack = try await backend.currentMode()
            } catch {
                throw BackendError.verificationFailed(expected: mode, actual: nil)
            }
            nativeLimit = await backend.nativeLimitStatus()
            guard readBack == mode else {
                throw BackendError.verificationFailed(expected: mode, actual: readBack)
            }
            currentMode = mode
            ownedMode = mode
            if mode == .normal {
                lastFailedRestoreUptime = nil
            }
            return outcome
        } catch {
            currentMode = nil
            if mode == .normal {
                lastFailedRestoreUptime = uptime()
            }
            nativeLimit = await backend.nativeLimitStatus()
            throw error
        }
    }

    /// Requests `.normal` and confirms it. Returns true only if the backend is
    /// confirmed to be in `.normal`, or cannot control anything and reports no
    /// other mode. Caller must hold the lock.
    private func restoreNormal(reason: String) async -> Bool {
        let capabilities = await backend.capabilities()
        let ownerLimit = await backend.nativeLimitStatus()?.ownerLimit
        let isNative = capabilities.isEnforcedByMacOS
        guard capabilities.availability.acceptsRequests else {
            let observed = try? await backend.currentMode()
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
            let outcome = try await setAndConfirm(.normal)
            if isNative {
                let suffix = outcome == .unchanged ? " (already in effect)" : ""
                let what = ownerLimit.map { "Restored your own macOS Charge Limit of \($0)%" }
                    ?? "Nothing to restore: CellKeeper had not changed macOS's Charge Limit"
                let reported = nativeLimit?.reportedLimit.map { "; macOS reports \($0)%" } ?? ""
                record(.safety, "\(what) (\(reason))\(suffix)\(reported).")
            } else {
                let suffix = outcome == .simulated ? " (simulated; hardware unchanged)" : ""
                record(.safety, "Restored normal charging (\(reason))\(suffix).")
            }
            return true
        } catch {
            if isNative, let ownerLimit {
                registerFailure("Could not restore your own macOS Charge Limit of \(ownerLimit)% (\(reason)): \(error)", level: .fault)
            } else {
                registerFailure("Could not restore normal charging (\(reason)): \(error)", level: .fault)
            }
            return false
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
        return "Battery \(percent), \(snapshot.powerSource.rawValue), \(snapshot.chargingStatus.rawValue), \(temperature)."
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
