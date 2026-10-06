import Foundation

/// The charging policy: a pure, deterministic function from ``PolicyInput``
/// to ``PolicyDecision``.
///
/// The policy never calls a backend, reads hardware, or consults a clock;
/// everything it depends on is in the input. Rules, highest priority first:
///
/// 1. Invalid settings → fail safe (macOS default charging).
/// 2. Management disabled → macOS default charging.
/// 3. Override expiry and unplugging are processed, even without a valid
///    charge reading.
/// 4. Telemetry missing, stale (by read time or by the system's own update
///    time), without a battery, or with an unknown power source → fail safe.
///    A discharge session never survives this.
/// 5. Safety floor latched (≤ 10%, until ≥ 15%) → charging always allowed.
/// 6. On battery power → CellKeeper's restrictions cleared (a later plug-in
///    then charges normally even if CellKeeper has stopped; the limit latch
///    is kept and re-applied once power returns).
/// 7. Temperature protection tripped → charging paused.
/// 8. Temporary full charge active → charging allowed.
/// 9. Discharge session active → run from the battery down to the limit.
/// 10. Charge limit of 100% → charging allowed.
/// 11. Limit latch set → hold.
/// 12. Sleep imminent at or above the resume threshold → hold, so a software
///     limit cannot overshoot while the Mac sleeps.
/// 13. Otherwise → charge toward the limit.
///
/// The desired mode is then turned into an action against the backend's
/// capabilities and current mode. A faulted backend is only ever asked for
/// `.normal`, and restricting changes are rate-limited; relaxing changes
/// toward `.normal` never are.
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
    /// Charge limits a discharge session may target.
    public static let dischargeTargetRange = 20...95

    public static func evaluate(_ input: PolicyInput) -> PolicyDecision {
        let settings = input.settings

        let issues = settings.validationIssues
        guard issues.isEmpty else {
            return decision(.failSafe, .normal, .invalidConfiguration(issues), memory: PolicyMemory(), input: input)
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

        func failSafe(_ reason: DecisionReason, memory: PolicyMemory = input.memory) -> PolicyDecision {
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

        var notes: [PolicyNote] = []
        let protection = settings.temperatureProtection
        let temperature = snapshot.temperatureCelsius.flatMap { $0.isFinite ? $0 : nil }
        if protection.isEnabled, temperature == nil {
            notes.append(.temperatureUnavailable)
        }

        var memory = input.memory
        memory.limitReached = nextLimitLatch(current: memory.limitReached, percent: percent, settings: settings)
        memory.temperatureTripped = nextTemperatureLatch(current: memory.temperatureTripped, celsius: temperature, protection: protection)
        memory.belowSafetyFloor = nextFloorLatch(current: memory.belowSafetyFloor, percent: percent)

        let limit = settings.chargeLimit
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
                if percent <= limit {
                    overrideEnded = .completed
                } else if !dischargeTargetRange.contains(limit) || input.isSleepImminent
                    || memory.temperatureTripped || memory.belowSafetyFloor {
                    overrideEnded = .interrupted
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
            let reason: DecisionReason = temperature >= protection.pauseAtCelsius
                ? .temperatureHigh(celsius: temperature, pauseAt: protection.pauseAtCelsius)
                : .temperatureCooling(celsius: temperature, resumeAt: protection.resumeAtCelsius)
            return make(.temperaturePause, .inhibitCharging, reason)
        }

        switch activeKind {
        case .fullCharge:
            return make(.fullChargeOverride, .normal, .fullChargeRequested(percent: percent))
        case .dischargeToLimit:
            return make(.discharging, .forceDischarge, .dischargingToLimit(percent: percent, limit: limit))
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

        let reason: DecisionReason = percent <= settings.resumeThreshold
            ? .belowResumeThreshold(percent: percent, resumeThreshold: settings.resumeThreshold)
            : .chargingTowardLimit(percent: percent, limit: limit)
        return make(.charging, .normal, reason)
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

    /// Limit hysteresis: set at or above the limit, cleared at or below the
    /// resume threshold, unchanged in between. Never set when the limit is 100%.
    static func nextLimitLatch(current: Bool, percent: Int, settings: ChargingSettings) -> Bool {
        if settings.chargeLimit >= 100 { return false }
        if percent >= settings.chargeLimit { return true }
        if percent <= settings.resumeThreshold { return false }
        return current
    }

    /// Temperature hysteresis: set at or above the pause threshold, cleared at
    /// or below the resume threshold. Cleared when protection is disabled or
    /// the temperature is unknown, so a lost sensor can never pause charging
    /// indefinitely.
    static func nextTemperatureLatch(current: Bool, celsius: Double?, protection: TemperatureProtection) -> Bool {
        guard protection.isEnabled, let celsius else { return false }
        if celsius >= protection.pauseAtCelsius { return true }
        if celsius <= protection.resumeAtCelsius { return false }
        return current
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
            return .enableCharging
        }
        guard capabilities.supports(desired) else {
            return .refuse(.modeUnsupported(desired))
        }
        if input.currentMode == desired {
            return .noAction
        }
        let currentLevel = input.currentMode?.restrictionLevel ?? 0
        if desired.restrictionLevel > currentLevel, let retryAt = rateLimitRetryTime(input) {
            return .refuse(.rateLimited(retryAt: retryAt))
        }
        return ChargingAction(requesting: desired)
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
