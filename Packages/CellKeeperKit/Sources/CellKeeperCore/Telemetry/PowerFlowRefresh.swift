import Foundation

/// The menu's display-only reads for the power flow (D114). CellKeeper
/// evaluates on power-source notifications and once a minute, and macOS's
/// battery data changes about once a minute, so the flow could be shown
/// almost two minutes late; while the menu is open with its Power flow
/// section expanded, the section's source (``PowerFlowReading``) is read
/// every few seconds instead. Otherwise nothing extra is read: the history
/// fills from the statuses.
///
/// These reads go only to the display. They are not evaluations: nothing
/// reaches the policy, the controller or a backend, and nothing is logged.
public enum PowerFlowRefresh {
    /// How often the source is read while the section is shown (the owner's
    /// choice, 2026-10-21).
    public static let interval: Duration = .seconds(3)

    /// Reads `source` at once and then every `interval` while `isWanted`
    /// says so (the section is expanded) and until the calling task is
    /// cancelled (the menu closes), handing each sample to `deliver`. Nothing
    /// is read once `isWanted` is false, also at the start. A read that fails
    /// is skipped without a word: the controller's own reads report telemetry
    /// problems. A read that ends after cancellation is not delivered.
    public static func run(
        source: any PowerFlowReading,
        interval: Duration = interval,
        while isWanted: @MainActor @Sendable () -> Bool,
        pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        deliver: @MainActor @Sendable (PowerFlowSample) -> Void
    ) async {
        while !Task.isCancelled, await isWanted() {
            if let sample = try? await source.currentSample() {
                guard !Task.isCancelled else { return }
                await deliver(sample)
            }
            await pause(interval)
        }
    }
}
