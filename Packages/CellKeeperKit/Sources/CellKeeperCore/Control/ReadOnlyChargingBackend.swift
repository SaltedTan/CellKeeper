/// A backend that performs no control at all. CellKeeper still reads
/// telemetry and computes what it would do, and reports every control request
/// as refused.
public struct ReadOnlyChargingBackend: ChargingBackend {
    public let descriptor = BackendDescriptor(
        identifier: "read-only",
        displayName: "Read-only",
        summary: "Shows telemetry and what CellKeeper would do. No control is attempted."
    )

    public let reason: String

    public init(reason: String = "Read-only is selected, so CellKeeper changes nothing.") {
        self.reason = reason
    }

    public func capabilities() async -> ControlCapabilities {
        .unavailable(reason)
    }

    public func currentMode() async throws -> ChargeControlMode? {
        nil
    }

    public func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome {
        throw BackendError.unavailable(reason)
    }
}
