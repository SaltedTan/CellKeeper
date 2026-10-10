import Foundation

/// The charging policy: a pure, deterministic function from ``PolicyInput``
/// to ``PolicyDecision``.
///
/// The policy never calls a backend, reads hardware, or consults a clock;
/// everything it depends on is in the input. Rules, highest priority first:
///
/// 1. Invalid settings, or a release the controller requires (a pending
///    backend switch, or a state it set but could not read back) → fail safe
///    (macOS default charging).
/// 2. Management disabled → macOS default charging.
/// 3. Override expiry and unplugging are processed, even without a valid
///    charge reading.
/// 4. Telemetry missing, stale (by read time or by the system's own update
///    time), without a battery, or with an unknown power source → fail safe.
///    A discharge session never survives this.
/// 5. macOS's own Charge Limit is on, or its report cannot be read and
///    recognised (``ControlCapabilities/macOSChargeLimit``) → normal
///    charging is requested and every restriction withheld, so two limits
///    never compete (safety precondition 7). A discharge session ends. The
///    latches still follow the readings.
/// 6. Safety floor latched (≤ 10%, until ≥ 15%) → charging always allowed.
/// 7. On battery power → CellKeeper's restrictions cleared (a later plug-in
///    then charges normally even if CellKeeper has stopped; the limit latch
///    is kept and re-applied once power returns).
/// 8. Temperature protection tripped → charging paused. Cooling alone ends
///    the pause no sooner than ``minimumTemperaturePause`` after it began.
/// 9. Temporary full charge active → charging allowed.
/// 10. Discharge session active → run from the battery down to the confirmed
///     target (never below it, never below the current limit).
/// 11. Charge limit of 100% → charging allowed.
/// 12. Limit latch set → hold (raising the limit releases it).
/// 13. Sleep imminent at or above the resume threshold → hold, so a software
///     limit cannot overshoot while the Mac sleeps.
/// 14. Otherwise → charge toward the limit. This includes a first reading at
///     or above the limit, which the next distinct reading must confirm
///     before the latch in rule 12 is set.
///
/// Only that latch is debounced (research rule R14): every other rule acts on
/// the first reading that calls for it, because each either relaxes toward
/// macOS defaults or is a safety trigger (the floor, the sleep precaution,
/// temperature protection).
///
/// With a native-limit backend (macOS enforces the limit; see
/// ``evaluateNativeLimit(_:steps:overrideEnded:)``) rules 1–3 apply
/// unchanged and the rest are replaced: CellKeeper only chooses the value of
/// macOS's Charge Limit. Rule 5 never applies to it.
///
/// The desired mode is then turned into an action against the backend's
/// capabilities and current mode. A faulted backend is only ever asked for
/// `.normal`, and restricting changes are rate-limited. Relaxing changes
/// toward `.normal` are not, except that an automatic retry of a failed
/// restore waits ``minimumRestoreRetryInterval``.
public enum ChargingPolicy {
    /// At or below this charge, CellKeeper never restricts charging.
    public static let safetyFloorPercent = 10
    /// The floor stays in effect until the charge is this many points above it.
    public static let safetyFloorExitMargin = 5
    /// Readings taken longer ago than this are treated as unavailable.
    public static let maximumTelemetryAge: TimeInterval = 60
    /// The battery driver refreshes about once a minute. Data whose
    /// system-reported update time is older than three refresh periods is
    /// treated as frozen.
    public static let maximumSourceAge: TimeInterval = 180
    /// Timestamps further than this in the future are treated as stale.
    public static let maximumClockSkew: TimeInterval = 60
    /// Minimum time between restricting requests.
    public static let minimumRestrictingInterval: TimeInterval = 60
    /// Maximum restricting requests in any rolling hour.
    public static let maximumRestrictingRequestsPerHour = 20
    /// Minimum time before a failed restore of `.normal` is retried
    /// automatically. User-initiated evaluations retry at once.
    public static let minimumRestoreRetryInterval: TimeInterval = 60
    /// Charge limits a discharge session may target.
    public static let dischargeTargetRange = 20...95
    /// Cooling alone ends a temperature pause no sooner than this after it
    /// began, on the monotonic clock (research rule R21). An unknown
    /// temperature, turning protection off, and higher-priority rules end or
    /// override it at once.
    public static let minimumTemperaturePause: TimeInterval = 5 * 60

    public static func evaluate(_ input: PolicyInput) -> PolicyDecision {
        let settings = input.settings

        let issues = settings.validationIssues
        guard issues.isEmpty else {
            return decision(.failSafe, .normal, .invalidConfiguration(issues), memory: PolicyMemory(), input: input)
        }
        // The latches survive an evaluation that does not look at the charge,
        // but a crossing waiting for confirmation does not: the two readings
        // that set the limit latch must be consecutive.
        let carriedMemory = input.memory.withoutPendingLimitCrossing
        if let release = input.releaseReason {
            let ended: OverrideEnd? = input.activeOverride?.kind == .dischargeToLimit ? .interrupted : nil
            return decision(.failSafe, .normal, .releaseRequired(release), memory: carriedMemory, input: input, overrideEnded: ended)
        }
        guard settings.isManagementEnabled else {
            return decision(.unmanaged, .normal, .managementDisabled, memory: PolicyMemory(), input: input)
        }

        // Endings that do not depend on a valid charge reading come first, so
        // expiry and unplugging always take effect.
        var overrideEnded: OverrideEnd?
        if let activeOverride = input.activeOverride {
            if input.uptime >= activeOverride.expiresAtUptime {
                overrideEnded = .expired
            } else if input.snapshot?.powerSource == .battery {
                overrideEnded = .unplugged
            }
        }

        if case .nativeLimit(let steps) = input.capabilities.style {
            return evaluateNativeLimit(input, steps: steps, overrideEnded: overrideEnded)
        }

        func failSafe(_ reason: DecisionReason, memory: PolicyMemory = carriedMemory) -> PolicyDecision {
            var ended = overrideEnded
            if ended == nil, input.activeOverride?.kind == .dischargeToLimit {
                ended = .interrupted
            }
            return decision(.failSafe, .normal, reason, memory: memory, input: input, overrideEnded: ended)
        }

        guard let snapshot = input.snapshot else {
            return failSafe(.telemetryUnavailable)
        }
        guard snapshot.isBatteryPresent else {
            return failSafe(.batteryNotPresent, memory: PolicyMemory())
        }
        if let age = staleness(of: snapshot, now: input.now) {
            return failSafe(.telemetryStale(ageSeconds: age))
        }
        guard let percent = snapshot.chargePercent, (0...100).contains(percent) else {
            return failSafe(.telemetryUnavailable)
        }
        guard snapshot.powerSource != .unknown else {
            return failSafe(.powerSourceUnknown)
        }
        let macOSLimit = macOSChargeLimitReason(input.capabilities)

        var notes: [PolicyNote] = []
        let protection = settings.temperatureProtection
        let temperature = snapshot.temperatureCelsius.flatMap { $0.isFinite ? $0 : nil }
        if protection.isEnabled, temperature == nil {
            notes.append(.temperatureUnavailable)
        }

        let limit = settings.chargeLimit
        var memory = input.memory
        let limitLatch = nextLimitLatch(input.memory, percent: percent, sampleTime: sampleTime(of: snapshot), settings: settings)
        memory.limitReached = limitLatch.reached
        memory.pendingLimitCrossing = limitLatch.pending
        memory.latchedLimit = memory.limitReached ? limit : nil
        let temperatureLatch = nextTemperatureLatch(input.memory, celsius: temperature, protection: protection, uptime: input.uptime)
        memory.temperatureTripped = temperatureLatch.tripped
        memory.temperatureTrippedAtUptime = temperatureLatch.since
        memory.belowSafetyFloor = nextFloorLatch(current: memory.belowSafetyFloor, percent: percent)

        var activeKind: ChargeOverride.Kind?
        if overrideEnded == nil, let activeOverride = input.activeOverride {
            switch activeOverride.kind {
            case .fullCharge:
                if snapshot.isFullyCharged == true || percent >= 100 {
                    overrideEnded = .completed
                } else {
                    activeKind = .fullCharge
                }
            case .dischargeToLimit:
                // Stop at the confirmed target, or at the current limit if it
                // was raised since; never below what the user confirmed.
                let target = activeOverride.targetPercent ?? limit
                if percent <= max(target, limit) {
                    overrideEnded = .completed
                } else if !dischargeTargetRange.contains(target) || input.isSleepImminent
                    || memory.temperatureTripped || memory.belowSafetyFloor || input.isBackendFaulted {
                    overrideEnded = .interrupted
                } else if macOSLimit != nil {
                    overrideEnded = .interrupted
                    notes.append(.dischargeEndedForMacOSChargeLimit)
                } else if !input.capabilities.supports(.forceDischarge) {
                    overrideEnded = .interrupted
                    notes.append(.dischargeUnsupported)
                } else {
                    activeKind = .dischargeToLimit
                }
            }
        }

        func make(_ state: PolicyState, _ mode: ChargeControlMode, _ reason: DecisionReason) -> PolicyDecision {
            decision(state, mode, reason, memory: memory, input: input, notes: notes, overrideEnded: overrideEnded)
        }

        // macOS's own Charge Limit decides charging: nothing below may ask for
        // a restriction, not even temperature protection or the limit (macOS
        // has its own thermal limiting). The latches above still follow the
        // readings, as they describe the battery, so a limit confirmed
        // meanwhile holds as soon as macOS's limit is off.
        if let macOSLimit {
            return make(.deferringToMacOS, .normal, macOSLimit)
        }

        if memory.belowSafetyFloor {
            return make(.safetyFloor, .normal, .belowSafetyFloor(percent: percent, floor: safetyFloorPercent))
        }

        if snapshot.powerSource == .battery {
            return make(.onBattery, .normal, .onBatteryPower)
        }

        if memory.temperatureTripped, let temperature {
            if activeKind == .fullCharge {
                notes.append(.fullChargeSuppressed(by: .temperaturePause))
            }
            let reason: DecisionReason
            if temperature >= protection.pauseAtCelsius {
                reason = .temperatureHigh(celsius: temperature, pauseAt: protection.pauseAtCelsius)
            } else if temperature <= protection.resumeAtCelsius, let trippedAt = memory.temperatureTrippedAtUptime {
                let remaining = trippedAt + minimumTemperaturePause - input.uptime
                reason = .temperatureMinimumPause(celsius: temperature, resumesAt: input.now.addingTimeInterval(remaining))
            } else {
                reason = .temperatureCooling(celsius: temperature, resumeAt: protection.resumeAtCelsius)
            }
            return make(.temperaturePause, .inhibitCharging, reason)
        }

        switch activeKind {
        case .fullCharge:
            return make(.fullChargeOverride, .normal, .fullChargeRequested(percent: percent))
        case .dischargeToLimit:
            let target = max(input.activeOverride?.targetPercent ?? limit, limit)
            return make(.discharging, .forceDischarge, .dischargingToLimit(percent: percent, limit: target))
        case nil:
            break
        }

        if limit >= 100 {
            return make(.charging, .normal, .noChargeLimit)
        }

        if memory.limitReached {
            let reason: DecisionReason = percent >= limit
                ? .limitReached(percent: percent, limit: limit)
                : .holdingAboveResumeThreshold(percent: percent, resumeThreshold: settings.resumeThreshold)
            return make(.holding, .inhibitCharging, reason)
        }

        if input.isSleepImminent, percent >= settings.resumeThreshold {
            return make(.holding, .inhibitCharging, .sleepPrecaution(percent: percent, resumeThreshold: settings.resumeThreshold))
        }

        if memory.pendingLimitCrossing != nil {
            notes.append(.confirmingLimit)
            return make(.charging, .normal, .confirmingLimit(percent: percent, limit: limit))
        }

        let reason: DecisionReason = percent <= settings.resumeThreshold
            ? .belowResumeThreshold(percent: percent, resumeThreshold: settings.resumeThreshold)
            : .chargingTowardLimit(percent: percent, limit: limit)
        return make(.charging, .normal, reason)
    }

    // MARK: - macOS's own Charge Limit

    /// Why the policy must ask a backend that switches charging itself for
    /// normal charging and withhold every restriction: macOS's own Charge
    /// Limit is on, or its report could not be read and recognised. Nil if
    /// the backend does not check it or macOS reports no active limit.
    static func macOSChargeLimitReason(_ capabilities: ControlCapabilities) -> DecisionReason? {
        guard !capabilities.isEnforcedByMacOS, let status = capabilities.macOSChargeLimit, status.isLimiting else { return nil }
        if let limit = status.reportedLimit {
            return .macOSChargeLimitActive(limit: limit)
        }
        return .macOSChargeLimitUnknown(problem: status.readProblem ?? "no report")
    }

    // MARK: - Native limit

    /// The policy for a backend that sets macOS's own Charge Limit.
    ///
    /// macOS enforces the limit, including its hysteresis (it resumes after
    /// a drop of more than 5%), its behaviour during sleep, and its
    /// occasional calibration charge, so CellKeeper's latches, safety floor,
    /// sleep precaution and on-battery rule have nothing to add. CellKeeper
    /// cannot express a resume threshold, a temperature pause or a discharge
    /// through it. What remains:
    ///
    /// 1. No battery, or a limit that is not one of `steps` → fail safe: the
    ///    user's own limit.
    /// 2. A temporary full charge → 100% until full, unplugged or expired.
    ///    A discharge session cannot run and is interrupted.
    /// 3. Otherwise → the configured limit.
    ///
    /// Unusable telemetry does not release the limit: macOS enforces it from
    /// its own measurements, and releasing would only restore and re-apply
    /// the setting after every wake. It only stops a full charge from being
    /// recognised as complete; expiry and unplugging still end it.
    static func evaluateNativeLimit(_ input: PolicyInput, steps: [Int], overrideEnded endedBeforeTelemetry: OverrideEnd?) -> PolicyDecision {
        let limit = input.settings.chargeLimit
        var overrideEnded = endedBeforeTelemetry
        var notes: [PolicyNote] = []

        func make(_ state: PolicyState, _ mode: ChargeControlMode, _ reason: DecisionReason) -> PolicyDecision {
            decision(state, mode, reason, memory: PolicyMemory(), input: input, notes: notes, overrideEnded: overrideEnded)
        }

        let usableSnapshot = input.snapshot.flatMap { snapshot -> BatterySnapshot? in
            guard snapshot.isBatteryPresent, staleness(of: snapshot, now: input.now) == nil,
                  let percent = snapshot.chargePercent, (0...100).contains(percent),
                  snapshot.powerSource != .unknown
            else { return nil }
            return snapshot
        }
        if usableSnapshot == nil {
            notes.append(.nativeLimitKeptWithoutTelemetry)
        }

        var isFullChargeActive = false
        if overrideEnded == nil, let activeOverride = input.activeOverride {
            switch activeOverride.kind {
            case .fullCharge:
                if let snapshot = usableSnapshot, snapshot.isFullyCharged == true || (snapshot.chargePercent ?? 0) >= 100 {
                    overrideEnded = .completed
                } else {
                    isFullChargeActive = true
                }
            case .dischargeToLimit:
                overrideEnded = .interrupted
                notes.append(.dischargeUnsupported)
            }
        }

        if input.snapshot?.isBatteryPresent == false {
            return make(.failSafe, .normal, .batteryNotPresent)
        }
        guard steps.contains(limit) else {
            return make(.failSafe, .normal, .nativeLimitUnsupported(limit: limit, steps: steps))
        }
        if isFullChargeActive, let full = steps.last {
            return make(.fullChargeOverride, .nativeLimit(percent: full), .nativeFullCharge)
        }
        return make(.osEnforcedLimit, .nativeLimit(percent: limit), .nativeLimitActive(limit: limit))
    }

    // MARK: - Telemetry freshness

    /// The age in seconds if the snapshot is stale, otherwise nil. Checks
    /// both when CellKeeper read it and, where reported, when the system
    /// last refreshed it (a frozen driver can return old values forever).
    static func staleness(of snapshot: BatterySnapshot, now: Date) -> Int? {
        let readAge = now.timeIntervalSince(snapshot.timestamp)
        if readAge > maximumTelemetryAge || readAge < -maximumClockSkew {
            return wholeSeconds(readAge)
        }
        if let source = snapshot.sourceTimestamp {
            let sourceAge = now.timeIntervalSince(source)
            if sourceAge > maximumSourceAge || sourceAge < -maximumClockSkew {
                return wholeSeconds(sourceAge)
            }
        }
        return nil
    }

    private static func wholeSeconds(_ interval: TimeInterval) -> Int {
        interval.isFinite ? Int(min(max(interval, -1e9), 1e9)) : Int.max
    }

    // MARK: - Latches

    /// A reading's identity for the limit debounce: the driver's own update
    /// time where reported, so that several evaluations within one driver
    /// refresh are one reading. Otherwise it is when CellKeeper read it, and
    /// only evaluations of the same read are one reading.
    static func sampleTime(of snapshot: BatterySnapshot) -> Date {
        snapshot.sourceTimestamp ?? snapshot.timestamp
    }

    /// Limit hysteresis, set only on confirmation (research rule R14).
    ///
    /// While clear, a reading at or above the limit becomes the pending
    /// crossing. The latch sets when the next distinct reading is also at or
    /// above the limit, and so was the pending one, judged against the
    /// current limit. A reading below the limit drops the pending crossing.
    ///
    /// Once set, the latch holds at or above the limit, including a limit
    /// raised to a charge already reached: that is not a new crossing, so the
    /// hold continues without a gap. Below the limit it is cleared at once if
    /// the limit was raised above the one it was set at, or at or below the
    /// resume threshold, and is otherwise unchanged (the hysteresis band).
    /// Never set when the limit is 100%.
    static func nextLimitLatch(
        _ memory: PolicyMemory,
        percent: Int,
        sampleTime: Date,
        settings: ChargingSettings
    ) -> (reached: Bool, pending: PolicyMemory.LimitCrossing?) {
        let limit = settings.chargeLimit
        if limit >= 100 { return (false, nil) }
        if memory.limitReached {
            if percent >= limit { return (true, nil) }
            // The user asked for more charge.
            if limit > (memory.latchedLimit ?? limit) { return (false, nil) }
            return (percent > settings.resumeThreshold, nil)
        }
        guard percent >= limit else { return (false, nil) }
        if let first = memory.pendingLimitCrossing, first.percent >= limit {
            return first.sampleTime != sampleTime ? (true, nil) : (false, first)
        }
        return (false, PolicyMemory.LimitCrossing(sampleTime: sampleTime, percent: percent))
    }

    /// Temperature hysteresis with a minimum pause (research rule R21). Set
    /// at or above the pause threshold on the first such reading, because
    /// pausing is a safety action. Cooling to the resume threshold clears it
    /// only once it has been set for ``minimumTemperaturePause`` of monotonic
    /// time. It is cleared at once when protection is disabled or the
    /// temperature is unknown, so a lost sensor can never hold charging off.
    /// Once clear, it sets again on the next hot reading, with no minimum
    /// time.
    static func nextTemperatureLatch(
        _ memory: PolicyMemory,
        celsius: Double?,
        protection: TemperatureProtection,
        uptime: TimeInterval
    ) -> (tripped: Bool, since: TimeInterval?) {
        guard protection.isEnabled, let celsius else { return (false, nil) }
        guard memory.temperatureTripped else {
            return celsius >= protection.pauseAtCelsius ? (true, uptime) : (false, nil)
        }
        // A trip time later than now (a clock that went backwards) counts as
        // now, so it can extend the pause by at most the minimum.
        let trippedAt = memory.temperatureTrippedAtUptime.map { min($0, uptime) }
        if celsius > protection.resumeAtCelsius { return (true, trippedAt) }
        if let trippedAt {
            let paused = uptime - trippedAt
            // A clock that does not give a usable duration ends the pause.
            if paused.isFinite, paused < minimumTemperaturePause { return (true, trippedAt) }
        }
        return (false, nil)
    }

    /// Safety-floor hysteresis: set at or below the floor, cleared at or above
    /// floor + ``safetyFloorExitMargin``.
    static func nextFloorLatch(current: Bool, percent: Int) -> Bool {
        if percent <= safetyFloorPercent { return true }
        if percent >= safetyFloorPercent + safetyFloorExitMargin { return false }
        return current
    }

    // MARK: - Action

    static func action(for desired: ChargeControlMode, input: PolicyInput) -> ChargingAction {
        let capabilities = input.capabilities
        if case .unavailable(let reason) = capabilities.availability {
            // Nothing to do if we want macOS defaults and have no reason to
            // believe anything else is in effect.
            if desired == .normal, (input.currentMode ?? .normal) == .normal {
                return .noAction
            }
            return .refuse(.controlUnavailable(reason))
        }
        if input.isBackendFaulted {
            // Only the fail-safe mode may be requested, and it is requested
            // until the backend confirms it is in effect.
            if input.currentMode == .normal {
                return desired == .normal ? .noAction : .refuse(.backendFaulted)
            }
            return restoreRetryRefusal(input) ?? .enableCharging
        }
        guard capabilities.supports(desired) else {
            return .refuse(.modeUnsupported(desired))
        }
        if input.currentMode == desired {
            return .noAction
        }
        if desired == .normal, let refusal = restoreRetryRefusal(input) {
            return refusal
        }
        if desired.isRestricting(from: input.currentMode), let retryAt = rateLimitRetryTime(input) {
            return .refuse(.rateLimited(retryAt: retryAt))
        }
        return ChargingAction(requesting: desired)
    }

    /// A refusal while an automatic retry of a failed restore must wait.
    static func restoreRetryRefusal(_ input: PolicyInput) -> ChargingAction? {
        guard let notBefore = input.restoreRetryNotBefore, input.uptime < notBefore else { return nil }
        return .refuse(.rateLimited(retryAt: input.now.addingTimeInterval(notBefore - input.uptime)))
    }

    /// When a restricting request must wait, the earliest (wall-clock) time it
    /// may be made; nil if it may be made now. Measured on the monotonic
    /// ``PolicyInput/uptime`` clock.
    static func rateLimitRetryTime(_ input: PolicyInput) -> Date? {
        let window: TimeInterval = 60 * 60
        let recent = input.recentRestrictingRequests
            .map { min($0, input.uptime) }
            .filter { input.uptime - $0 < window }
            .sorted()
        if let last = recent.last, input.uptime - last < minimumRestrictingInterval {
            return input.now.addingTimeInterval(last + minimumRestrictingInterval - input.uptime)
        }
        if recent.count >= maximumRestrictingRequestsPerHour, let oldest = recent.first {
            return input.now.addingTimeInterval(oldest + window - input.uptime)
        }
        return nil
    }

    private static func decision(
        _ state: PolicyState,
        _ mode: ChargeControlMode,
        _ reason: DecisionReason,
        memory: PolicyMemory,
        input: PolicyInput,
        notes: [PolicyNote] = [],
        overrideEnded: OverrideEnd? = nil
    ) -> PolicyDecision {
        PolicyDecision(
            state: state,
            desiredMode: mode,
            action: action(for: mode, input: input),
            reason: reason,
            notes: notes,
            memory: memory,
            overrideEnded: overrideEnded
        )
    }
}
