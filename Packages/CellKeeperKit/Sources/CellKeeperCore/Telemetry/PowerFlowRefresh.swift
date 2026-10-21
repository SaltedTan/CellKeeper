import Foundation

/// The menu's display-only reads for the power flow (D114, D115).
/// CellKeeper evaluates on power-source notifications and once a minute,
/// and macOS's battery data changes about once a minute, so the flow could
/// be shown almost two minutes late; while the menu is open with its Power
/// flow section expanded, it is refreshed every few seconds instead: from
/// the SMC source's window when that source is available and has one,
/// otherwise from a read of the section's source (``PowerFlowReading``).
/// Otherwise nothing extra is read: the history fills from the statuses.
///
/// These reads go only to the display. They are not evaluations: nothing
/// reaches the policy, the controller or a backend, and nothing is logged.
public enum PowerFlowRefresh {
    /// How often the display is refreshed while the section is shown (the
    /// owner's choice, 2026-10-21).
    public static let interval: Duration = .seconds(3)

    /// Delivers a tick at once and then every `interval` while `isWanted`
    /// says so (the section is expanded) and until the calling task is
    /// cancelled (the menu closes). Each tick holds the SMC source's window,
    /// if it is available and has one; otherwise a read of `source`; or,
    /// when that read fails, nothing: an empty tick is still delivered, so
    /// that the display is decided again (research note 13 §6.4). A failed
    /// read is not reported: the controller's own reads report telemetry
    /// problems. Nothing is read once `isWanted` is false, also at the
    /// start, and a tick that ends after cancellation is not delivered.
    public static func run(
        source: any PowerFlowReading,
        smc: (any SMCPowerPublishing)? = nil,
        interval: Duration = interval,
        while isWanted: @MainActor @Sendable () -> Bool,
        pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        deliver: @MainActor @Sendable (PowerFlowTick) -> Void
    ) async {
        while !Task.isCancelled, await isWanted() {
            let publication = await smc?.publish() ?? .absent
            let content: PowerFlowTick.Content
            if publication.state == .available, let window = publication.window {
                content = .window(window)
            } else if let sample = try? await source.currentSample() {
                content = .registry(sample)
            } else {
                content = .empty
            }
            guard !Task.isCancelled else { return }
            await deliver(PowerFlowTick(content: content, smcState: publication.state, at: now()))
            await pause(interval)
        }
    }
}
