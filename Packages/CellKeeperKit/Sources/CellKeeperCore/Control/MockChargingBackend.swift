/// A simulated backend. It records requests and tracks a simulated mode but
/// never touches hardware, and it always reports ``ControlOutcome/simulated``.
///
/// Used as the default backend while real control is unimplemented, and in
/// tests (with failure injection).
public actor MockChargingBackend: ChargingBackend {
    public nonisolated let descriptor = BackendDescriptor(
        identifier: "simulated",
        displayName: "Simulated",
        summary: "Decisions are computed and recorded, but your Mac's charging is not changed."
    )

    private var mode: ChargeControlMode
    private var supportedModes: Set<ChargeControlMode>
    private var unavailableReason: String?
    private var pendingFailures: [BackendError] = []
    private var pendingModeReadFailures = 0
    private var modeReportedOnReadBack: ChargeControlMode??

    /// Every mode passed to ``setMode(_:)``, in order, including failed ones.
    public private(set) var requestedModes: [ChargeControlMode] = []

    public init(
        supportedModes: Set<ChargeControlMode> = ChargeControlMode.chargingModes,
        initialMode: ChargeControlMode = .normal
    ) {
        self.supportedModes = supportedModes
        self.mode = initialMode
    }

    public func capabilities() -> ControlCapabilities {
        if let unavailableReason {
            return .unavailable(unavailableReason)
        }
        return ControlCapabilities(availability: .simulated, supportedModes: supportedModes)
    }

    public func currentMode() throws -> ChargeControlMode? {
        if pendingModeReadFailures > 0 {
            pendingModeReadFailures -= 1
            throw BackendError.operationFailed("injected mode-read failure")
        }
        if let override = modeReportedOnReadBack { return override }
        return mode
    }

    public func setMode(_ newMode: ChargeControlMode) throws -> ControlOutcome {
        requestedModes.append(newMode)
        if let unavailableReason {
            throw BackendError.unavailable(unavailableReason)
        }
        guard newMode == .normal || supportedModes.contains(newMode) else {
            throw BackendError.unsupportedMode(newMode)
        }
        if !pendingFailures.isEmpty {
            throw pendingFailures.removeFirst()
        }
        mode = newMode
        return .simulated
    }

    // MARK: - Test hooks

    /// Makes the next `count` calls to ``setMode(_:)`` fail with `error`.
    public func failNextRequests(_ count: Int, with error: BackendError = .operationFailed("injected failure")) {
        pendingFailures.append(contentsOf: Array(repeating: error, count: count))
    }

    /// Makes the next `count` calls to ``currentMode()`` throw.
    public func failNextModeReads(_ count: Int) {
        pendingModeReadFailures += count
    }

    /// Changes the simulated mode as if another tool had done it.
    public func simulateExternalChange(to newMode: ChargeControlMode) {
        mode = newMode
    }

    /// Simulates the backend becoming unavailable (or available again with nil).
    public func setUnavailable(reason: String?) {
        unavailableReason = reason
    }

    /// Forces ``currentMode()`` to report a value regardless of the simulated
    /// mode, to exercise read-back verification. Pass `.none` to stop.
    public func overrideReadBack(_ reported: ChargeControlMode??) {
        modeReportedOnReadBack = reported
    }
}
