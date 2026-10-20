@testable import CellKeeperCore
import Foundation
import Testing

private let now = referenceDate

/// A settled status on macOS's Charge Limit: the owner's own limit 90%,
/// CellKeeper's 80% confirmed, plugged in at 70%, no temperature reading.
private func settled() -> ControllerStatus {
    ControllerStatus(
        snapshot: snapshot(percent: 70, temperature: nil),
        telemetryError: nil,
        settings: ChargingSettings.default.withChargeLimit(80),
        activeOverride: nil,
        backend: BackendDescriptor(identifier: NativeChargeLimitBackend.identifier, displayName: "macOS Charge Limit", summary: ""),
        capabilities: nativeCapabilities,
        currentMode: .nativeLimit(percent: 80),
        ownRestrictionMode: nil,
        isReportedModeOwn: nil,
        nativeLimit: NativeLimitStatus(reportedLimit: 80, readAt: now, ownerLimit: 90, target: 80),
        adoptedChange: nil,
        adoptionCount: 0,
        managementRefusal: nil,
        pendingBackend: nil,
        decision: nil,
        lastExecution: nil,
        consecutiveFailures: 0,
        isBackendFaulted: false,
        faultsRaised: 0,
        releasesConfirmed: 0,
        events: [],
        lastEvaluation: now,
        calibration: CalibrationStatus(isAvailable: true)
    )
}

private let confirmed = CalibrationConfirmations(optimizedCharging: .off, isCoolRoomConfirmed: true, isRecoverySeen: true, isMenuOnlyAcknowledged: true)

private func refusal(_ change: (inout ControllerStatus) -> Void = { _ in }, settings: ChargingSettings? = nil, confirmations: CalibrationConfirmations = confirmed, isNotifying: Bool = true) -> String? {
    var status = settled()
    change(&status)
    return CalibrationAdmission.refusal(status: status, settings: settings ?? status.settings, confirmations: confirmations, isNotifying: isNotifying, now: now)
}

@Suite("Calibration: admission")
struct CalibrationAdmissionTests {
    @Test("A settled status with every confirmation is admitted")
    func admitted() {
        #expect(refusal() == nil)
    }

    @Test("Each condition of §7.4 refuses with its reason, in order")
    func stateConditions() {
        #expect(refusal { $0.calibration.isAvailable = false } == "Calibration is not available.")
        #expect(refusal { $0.calibration.session = CalibrationSession.start(id: UUID(), at: CalibrationStamp(wall: now, monotonic: 0, boot: "b"), ownerLimit: 90, cellKeeperLimit: 80, before: CalibrationCapacities(), temperatureCheck: .ownerConfirmedCoolRoom, optimizedCharging: .off) }
            == "A calibration is already in progress.")
        #expect(refusal { $0.capabilities = simulatedCapabilities } == "A calibration needs CellKeeper's control to be macOS's Charge Limit; choose it in Settings › Control.")
        #expect(refusal { $0.pendingBackend = BackendDescriptor(identifier: "simulated", displayName: "Simulated", summary: "") } == "A change of control backend is waiting to complete.")
        #expect(refusal { $0.capabilities = .unavailable("no shortcut", style: .nativeLimit(steps: NativeChargeLimitBackend.supportedLimits)) } == "CellKeeper cannot change macOS's Charge Limit right now; Settings › Control says why.")
        #expect(refusal { $0.isBackendFaulted = true } == "The control backend is faulted. Clear the fault in Settings › Control first.")
        #expect(refusal { $0.settings.isManagementEnabled = false } == "Manage charging is off. Turn it on to start a calibration.")
        var off = settled().settings
        off.isManagementEnabled = false
        #expect(refusal(settings: off) == "Manage charging is off. Turn it on to start a calibration.", "the app's own settings count too")
        #expect(refusal { $0.nativeLimit?.isAdoptionUnsaved = true } == "CellKeeper is still saving its record of a Charge Limit changed outside it.")
        #expect(refusal { $0.nativeLimit?.isRestoreUnfinished = true } == "CellKeeper has not confirmed your own Charge Limit back yet.")
        #expect(refusal { $0.nativeLimit?.isRecordUnreadable = true } == "CellKeeper has not confirmed your own Charge Limit back yet.")
        #expect(refusal { $0.nativeLimit?.reportedLimit = nil } == "CellKeeper cannot read macOS's Charge Limit right now.")
        #expect(refusal(settings: ChargingSettings.default.withChargeLimit(77)) == "77% cannot be set with macOS's Charge Limit; choose one of its values first.")
        #expect(refusal { $0.snapshot = nil } == "CellKeeper has no current battery reading.")
        #expect(refusal { $0.snapshot = snapshot(percent: 70, temperature: nil, at: now.addingTimeInterval(-61)) } == "CellKeeper has no current battery reading.")
        #expect(refusal { $0.snapshot = snapshot(percent: 70, source: .battery, temperature: nil) } == "The Mac is on battery. Connect power first.")
        #expect(refusal { $0.activeOverride = .fullCharge(at: now, uptime: 10_000) } == "A temporary full charge is running. Let it end, or cancel it, first.")
        #expect(refusal { $0.activeOverride = .dischargeToLimit(target: 80, at: now, uptime: 10_000) } == "A discharge to the limit is running. Stop it first.")
        #expect(refusal { $0.fullChargeSchedule = FullChargeSchedule(startsAt: now.addingTimeInterval(3600), endsAt: now.addingTimeInterval(7200)) } == "A full charge is scheduled. Cancel it first.")
    }

    @Test("Where the temperature is read, R23's 10–40 °C applies; the cool room is then not asked")
    func measuredTemperature() {
        let none = CalibrationConfirmations(optimizedCharging: .off, isRecoverySeen: true, isMenuOnlyAcknowledged: true)
        #expect(refusal({ $0.snapshot = snapshot(percent: 70, temperature: 10) }, confirmations: none) == nil)
        #expect(refusal({ $0.snapshot = snapshot(percent: 70, temperature: 40) }, confirmations: none) == nil)
        #expect(refusal { $0.snapshot = snapshot(percent: 70, temperature: 9.5) } == "The battery is at 9.5°C; a calibration needs 10–40°C.")
        #expect(refusal { $0.snapshot = snapshot(percent: 70, temperature: 40.5) } == "The battery is at 40.5°C; a calibration needs 10–40°C.")
    }

    @Test("Where it cannot be read, the owner confirms a cool room (§7.7, decided 2026-10-21)")
    func coolRoom() {
        var confirmations = confirmed
        confirmations.isCoolRoomConfirmed = false
        #expect(refusal(confirmations: confirmations) == "Confirm that the room is between 10 and 35°C, with your Mac out of a bag and off soft surfaces.")
    }

    @Test("The owner's confirmations are asked in order: Optimized Battery Charging, the room, the recovery, and the menu-only requests with notifications off")
    func confirmations() {
        #expect(refusal(confirmations: CalibrationConfirmations()) == "Confirm that Optimized Battery Charging is off, or that you accept that step 1 may stop at its 6-hour limit.")
        var accepted = confirmed
        accepted.optimizedCharging = .boundAccepted
        #expect(refusal(confirmations: accepted) == nil)
        var noRecovery = confirmed
        noRecovery.isRecoverySeen = false
        #expect(refusal(confirmations: noRecovery) == "Confirm that you have read how to get your own Charge Limit back.")
        var menuOnly = confirmed
        menuOnly.isMenuOnlyAcknowledged = false
        #expect(refusal(confirmations: menuOnly) == nil, "with notifications shown, nothing to acknowledge")
        #expect(refusal(confirmations: menuOnly, isNotifying: false) == "Notifications are off: confirm that you will check the menu for CellKeeper's requests.")
        // The state comes first: the reasons beside the button are the
        // conditions CellKeeper checks before the owner's.
        #expect(refusal({ $0.isBackendFaulted = true }, confirmations: CalibrationConfirmations()) == "The control backend is faulted. Clear the fault in Settings › Control first.")
    }

    @Test("The temperature is readable only from a usable reading")
    func temperatureReadable() {
        var status = settled()
        #expect(!CalibrationAdmission.isTemperatureReadable(status: status, now: now))
        status.snapshot = snapshot(percent: 70, temperature: 31)
        #expect(CalibrationAdmission.isTemperatureReadable(status: status, now: now))
        status.snapshot = snapshot(percent: 70, temperature: 31, at: now.addingTimeInterval(-120))
        #expect(!CalibrationAdmission.isTemperatureReadable(status: status, now: now))
    }
}

@Suite("Calibration: what confirms the limit after a session")
struct CalibrationLimitAfterTests {
    @Test("A confirmation needs a successful read that shows the value; holding no record alone confirms nothing")
    func evidence() {
        var status = settled()
        status.decision = PolicyDecision(state: .osEnforcedLimit, desiredMode: .nativeLimit(percent: 80), action: .noAction, reason: .nativeLimitActive(limit: 80), notes: [], memory: PolicyMemory(), overrideEnded: nil)
        #expect(CalibrationWording.limitAfter(status) == .cellKeeperLimit(80))
        var stale = status
        stale.nativeLimit?.reportedLimit = nil
        stale.nativeLimit?.readProblem = "read failed"
        #expect(CalibrationWording.limitAfter(stale) == .unconfirmed(reported: nil))
        var other = status
        other.nativeLimit?.reportedLimit = 85
        #expect(CalibrationWording.limitAfter(other) == .unconfirmed(reported: 85))
        var released = status
        released.currentMode = .normal
        released.nativeLimit = NativeLimitStatus(reportedLimit: 90, readAt: referenceDate)
        #expect(CalibrationWording.limitAfter(released) == .ownLimit(90))
        released.nativeLimit = NativeLimitStatus(reportedLimit: 100, readAt: referenceDate)
        #expect(CalibrationWording.limitAfter(released) == .ownLimit(100), "a no-limit read is a value")
        released.nativeLimit = NativeLimitStatus(reportedLimit: nil, readAt: referenceDate, readProblem: "read failed")
        #expect(CalibrationWording.limitAfter(released) == .unconfirmed(reported: nil))
        var unknown = status
        unknown.currentMode = nil
        #expect(CalibrationWording.limitAfter(unknown) == .unconfirmed(reported: 80))
        var owed = status
        owed.currentMode = .nativeLimit(percent: 100)
        owed.nativeLimit = NativeLimitStatus(reportedLimit: 100, readAt: referenceDate, ownerLimit: 90, target: 100, isRestoreUnfinished: true)
        #expect(CalibrationWording.limitAfter(owed) == .unconfirmed(reported: 100))
    }
}

@Suite("Calibration: policy")
struct CalibrationPolicyTests {
    private func decide(_ reading: BatterySnapshot?, settings: ChargingSettings = ChargingSettings.default.withChargeLimit(80), override: ChargeOverride? = nil, capabilities: ControlCapabilities = nativeCapabilities, wantsFull: Bool = true, currentMode: ChargeControlMode? = .nativeLimit(percent: 80)) -> PolicyDecision {
        var policyInput = input(reading, settings: settings, override: override, capabilities: capabilities, currentMode: currentMode)
        policyInput.calibrationWantsFullLimit = wantsFull
        return ChargingPolicy.evaluate(policyInput)
    }

    @Test("A calibration step asks for 100%, and keeps it when the battery is full, unlike a temporary full charge")
    func full() {
        let charging = decide(snapshot(percent: 60))
        #expect(charging.state == .calibrating)
        #expect(charging.desiredMode == .nativeLimit(percent: 100))
        #expect(charging.reason == .calibrationFullCharge)
        #expect(charging.action == .setNativeLimit(100))
        let charged = decide(snapshot(percent: 100, charging: false, fullyCharged: true))
        #expect(charged.desiredMode == .nativeLimit(percent: 100))
        #expect(charged.overrideEnded == nil)
        // Without telemetry the limit stays, as macOS enforces it.
        #expect(decide(nil).desiredMode == .nativeLimit(percent: 100))
        let fullCharge = decide(snapshot(percent: 100, charging: false, fullyCharged: true), override: .fullCharge(at: referenceDate, uptime: 10_000), wantsFull: false)
        #expect(fullCharge.overrideEnded == .completed)
    }

    @Test("Otherwise the normal policy: CellKeeper's own limit")
    func normal() {
        let decision = decide(snapshot(percent: 60), wantsFull: false)
        #expect(decision.state == .osEnforcedLimit)
        #expect(decision.desiredMode == .nativeLimit(percent: 80))
    }

    @Test("The higher rules still win: management off, a required release, no battery, a limit macOS cannot take")
    func precedence() {
        var off = ChargingSettings.default.withChargeLimit(80)
        off.isManagementEnabled = false
        #expect(decide(snapshot(percent: 60), settings: off).desiredMode == .normal)
        var released = input(snapshot(percent: 60), settings: ChargingSettings.default.withChargeLimit(80), capabilities: nativeCapabilities)
        released.calibrationWantsFullLimit = true
        released.releaseReason = .restoreUnfinished
        #expect(ChargingPolicy.evaluate(released).desiredMode == .normal)
        #expect(decide(snapshot(percent: 60, present: false)).desiredMode == .normal)
        #expect(decide(snapshot(percent: 60), settings: ChargingSettings.default.withChargeLimit(77)).desiredMode == .normal)
    }

    @Test("A backend that switches charging itself ignores it")
    func notNative() {
        let decision = decide(snapshot(percent: 60), capabilities: simulatedCapabilities, currentMode: .normal)
        #expect(decision.state == .charging)
        #expect(decision.desiredMode == .normal)
    }

    @Test("The request is rate-limited like any change of the limit")
    func rateLimited() {
        var policyInput = input(snapshot(percent: 60), settings: ChargingSettings.default.withChargeLimit(80), capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 80), recentRestrictingRequests: [10_000 - 30])
        policyInput.calibrationWantsFullLimit = true
        guard case .refuse(.rateLimited) = ChargingPolicy.evaluate(policyInput).action else {
            Issue.record("not rate-limited")
            return
        }
    }
}
