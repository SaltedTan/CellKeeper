import Foundation

/// The menu's display-only reads for the power flow (D114). macOS updates
/// the battery data about once a minute, and CellKeeper evaluates on
/// power-source notifications and once a minute, so the flow could be shown
/// almost two minutes late; while the menu shows it, it is read every few
/// seconds instead.
///
/// These reads go only to the display. They are not evaluations: nothing
/// reaches the policy, the controller or a backend, and nothing is logged.
public enum PowerFlowRefresh {
    /// How often the battery data is read while the menu shows the flow.
    public static let interval: Duration = .seconds(5)

    /// Reads `telemetry` at once and then every `interval` until the calling
    /// task is cancelled (the menu closes), handing each reading to
    /// `deliver`. A read that fails is skipped without a word: the
    /// controller's own reads report telemetry problems. A read that ends
    /// after cancellation is not delivered.
    public static func run(
        telemetry: any TelemetryProvider,
        interval: Duration = interval,
        pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        deliver: @MainActor @Sendable (BatterySnapshot) -> Void
    ) async {
        while !Task.isCancelled {
            if let snapshot = try? await telemetry.currentSnapshot() {
                guard !Task.isCancelled else { return }
                await deliver(snapshot)
            }
            await pause(interval)
        }
    }
}
