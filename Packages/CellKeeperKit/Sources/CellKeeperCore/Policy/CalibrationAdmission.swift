import Foundation

/// What the owner confirmed before a guided calibration starts (research
/// note 12 §7.4). Settings asks for each; nothing is assumed.
public struct CalibrationConfirmations: Sendable, Equatable {
    /// Optimized Battery Charging, which CellKeeper cannot read (note 01):
    /// off, or the owner accepts that step 1 may reach its bound. Nil until
    /// the owner chose one.
    public var optimizedCharging: OptimizedChargingConfirmation?
    /// Where the battery's temperature cannot be read: a room at 10–35 °C,
    /// with the Mac out of a bag and off soft surfaces (§7.7, decided by the
    /// owner on 2026-10-21).
    public var isCoolRoomConfirmed: Bool
    /// The owner has seen the recovery: the value to set in System
    /// Settings › Battery (§7.2, safety precondition 11).
    public var isRecoverySeen: Bool
    /// With notifications off: the owner knows that requests appear only in
    /// the menu.
    public var isMenuOnlyAcknowledged: Bool

    public init(optimizedCharging: OptimizedChargingConfirmation? = nil, isCoolRoomConfirmed: Bool = false, isRecoverySeen: Bool = false, isMenuOnlyAcknowledged: Bool = false) {
        self.optimizedCharging = optimizedCharging
        self.isCoolRoomConfirmed = isCoolRoomConfirmed
        self.isRecoverySeen = isRecoverySeen
        self.isMenuOnlyAcknowledged = isMenuOnlyAcknowledged
    }
}

/// Whether a guided calibration may start now (note 12 §7.4); nil means it
/// may. Otherwise one reason, the first that applies: Settings shows it
/// under the disabled button, and the controller refuses with it when the
/// command arrives, after a fresh evaluation.
public enum CalibrationAdmission {
    /// - Parameters:
    ///   - settings: the settings the caller shows, which may be newer than
    ///     `status`'s; both must have Manage charging on.
    ///   - isNotifying: the owner's notifications are on and macOS shows
    ///     them.
    ///   - now: when the reading's age is judged.
    public static func refusal(status: ControllerStatus, settings: ChargingSettings, confirmations: CalibrationConfirmations, isNotifying: Bool, now: Date) -> String? {
        if let refusal = stateRefusal(status: status, settings: settings, now: now) { return refusal }
        return confirmationRefusal(confirmations, isTemperatureReadable: isTemperatureReadable(status: status, now: now), isNotifying: isNotifying)
    }

    /// The conditions that do not depend on the owner's confirmations, in
    /// order: calibration available and not running; control by macOS's
    /// Charge Limit, settled (no switch pending, available, not faulted, no
    /// restore owed, readable); Manage charging on; CellKeeper's limit one
    /// macOS's Charge Limit can take; a usable reading on external power,
    /// and macOS's Charge Limit read after power settled (note 08, O20); no
    /// full charge or discharge running and no one-shot full charge
    /// scheduled; and, where the temperature is read, 10–40 °C (R23).
    public static func stateRefusal(status: ControllerStatus, settings: ChargingSettings, now: Date) -> String? {
        guard status.calibration.isAvailable else { return "Calibration is not available." }
        guard !status.calibration.isInProgress else { return "A calibration is already in progress." }
        let capabilities = status.capabilities
        guard capabilities.isEnforcedByMacOS else {
            return "A calibration needs CellKeeper's control to be macOS's Charge Limit; choose it in Settings › Control."
        }
        guard status.pendingBackend == nil else { return "A change of control backend is waiting to complete." }
        if case .unavailable = capabilities.availability {
            return "CellKeeper cannot change macOS's Charge Limit right now; Settings › Control says why."
        }
        guard !status.isBackendFaulted else { return "The control backend is faulted. Clear the fault in Settings › Control first." }
        guard settings.isManagementEnabled, status.settings.isManagementEnabled else {
            return "Manage charging is off. Turn it on to start a calibration."
        }
        let native = status.nativeLimit
        guard native?.isAdoptionUnsaved != true else {
            return "CellKeeper is still saving its record of a Charge Limit changed outside it."
        }
        guard !status.isOwnLimitRestorePending, native?.isRecordUnreadable != true else {
            return "CellKeeper has not confirmed your own Charge Limit back yet."
        }
        guard native?.reportedLimit != nil else { return "CellKeeper cannot read macOS's Charge Limit right now." }
        guard capabilities.nativeLimitSteps.contains(settings.chargeLimit) else {
            return "\(settings.chargeLimit)% cannot be set with macOS's Charge Limit; choose one of its values first."
        }
        guard let reading = ChargingPolicy.usableSnapshot(status.snapshot, now: now) else {
            return "CellKeeper has no current battery reading."
        }
        guard reading.isOnExternalPower else { return "The Mac is on battery. Connect power first." }
        // The session records the owner's own limit from this read.
        guard native?.readDeferral == nil else {
            return "CellKeeper checks macOS's Charge Limit once your Mac has been on power for a minute. Try again then."
        }
        if let running = status.activeOverride {
            return running.kind == .fullCharge
                ? "A temporary full charge is running. Let it end, or cancel it, first."
                : "A discharge to the limit is running. Stop it first."
        }
        guard status.fullChargeSchedule == nil else { return "A full charge is scheduled. Cancel it first." }
        if let celsius = reading.temperatureCelsius, celsius.isFinite, !CalibrationSession.temperatureRange.contains(celsius) {
            return "The battery is at \(celsius.formatted(.number.precision(.fractionLength(1))))°C; a calibration needs 10–40°C."
        }
        return nil
    }

    /// The owner's confirmations, in order: Optimized Battery Charging, the
    /// cool room where the temperature cannot be read, the recovery, and,
    /// with notifications off, that requests appear only in the menu.
    public static func confirmationRefusal(_ confirmations: CalibrationConfirmations, isTemperatureReadable: Bool, isNotifying: Bool) -> String? {
        guard confirmations.optimizedCharging != nil else {
            return "Confirm that Optimized Battery Charging is off, or that you accept that step 1 may stop at its \(Int(CalibrationSession.chargeBound / 3600))-hour limit."
        }
        guard isTemperatureReadable || confirmations.isCoolRoomConfirmed else {
            return "Confirm that the room is between 10 and 35°C, with your Mac out of a bag and off soft surfaces."
        }
        guard confirmations.isRecoverySeen else { return "Confirm that you have read how to get your own Charge Limit back." }
        guard isNotifying || confirmations.isMenuOnlyAcknowledged else {
            return "Notifications are off: confirm that you will check the menu for CellKeeper's requests."
        }
        return nil
    }

    /// True if the latest usable reading shows the battery's temperature.
    public static func isTemperatureReadable(status: ControllerStatus, now: Date) -> Bool {
        ChargingPolicy.usableSnapshot(status.snapshot, now: now)?.temperatureCelsius?.isFinite == true
    }
}
