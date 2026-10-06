/// A read-only source of battery telemetry.
///
/// Telemetry providers never change hardware state. Charging control is the
/// job of a ``ChargingBackend``, which is deliberately a separate protocol.
public protocol TelemetryProvider: Sendable {
    /// Reads a fresh snapshot from the system.
    func currentSnapshot() async throws -> BatterySnapshot

    /// A stream that yields whenever the system signals that power-source
    /// information may have changed. Consumers should re-read
    /// ``currentSnapshot()`` when it yields; the stream carries no data.
    func powerSourceChanges() -> AsyncStream<Void>
}
