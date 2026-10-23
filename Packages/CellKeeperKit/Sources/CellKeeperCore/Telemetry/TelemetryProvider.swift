/// A read-only source of battery telemetry.
///
/// Telemetry providers never change hardware state. Charging control is the
/// job of a ``ChargingBackend``, which is deliberately a separate protocol.
public protocol TelemetryProvider: Sendable {
    /// Reads a fresh snapshot from the system.
    ///
    /// Conformers must tolerate concurrent calls: the menu's power flow
    /// reads through the same provider for display (``PowerFlowRefresher``,
    /// one read of its own at a time), and its read may overlap the
    /// controller's (D114). `SystemTelemetryProvider` holds no state, and
    /// each read gets its own Core Foundation objects from IOKit.
    func currentSnapshot() async throws -> BatterySnapshot

    /// Reads afresh only which power source the Mac runs on: what the
    /// controller checks after every read of macOS's Charge Limit (D118), so
    /// it should cost little. Default: ``currentSnapshot()``'s.
    func currentPowerSource() async throws -> PowerSource

    /// A stream that yields whenever the system signals that power-source
    /// information may have changed. Consumers should re-read
    /// ``currentSnapshot()`` when it yields; the stream carries no data.
    func powerSourceChanges() -> AsyncStream<Void>
}

extension TelemetryProvider {
    public func currentPowerSource() async throws -> PowerSource {
        try await currentSnapshot().powerSource
    }
}
