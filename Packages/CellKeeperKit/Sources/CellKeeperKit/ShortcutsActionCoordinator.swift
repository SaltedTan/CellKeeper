import CellKeeperCore
import Foundation

/// What a Shortcuts action needs from the app. `AppModel` provides it; each
/// command is the one the UI uses.
@MainActor
public protocol ShortcutsActionTarget: AnyObject, Sendable {
    var status: ControllerStatus? { get }
    var settings: ChargingSettings { get }
    /// True once quitting has started.
    var isTerminating: Bool { get }
    /// The identifier of the backend selected in Settings.
    var selectedBackendIdentifier: String { get }
    /// The limits Settings offers right now.
    var chargeLimitChoices: ChargeLimitChoices { get }
    /// Provided when the first status arrives.
    var firstStatus: FirstValue<Bool> { get }
    /// Validates, saves and queues a change, without touching the Settings
    /// banner unless `source` is the UI.
    func changeSettings(_ settings: ChargingSettings, source: SettingsChangeSource) -> SettingsChangeResult
    func queueFullCharge()
    func queueCancelOverride()
}

/// What an action tells the shortcut.
public enum ShortcutsActionOutcome: Sendable, Equatable {
    case done(String)
    case refused(String)
}

public enum ShortcutsStatusOutcome: Sendable, Equatable {
    case status(ShortcutsStatus)
    case refused(String)
}

/// Runs Shortcuts actions against the app: waits, within a bound, until the
/// app has started and, where needed, has a first status; refuses once
/// quitting has started; checks the backend context and the UI's own
/// preconditions; then makes the change synchronously, never awaiting the
/// command queue, the controller or the backend.
@MainActor
public final class ShortcutsActionCoordinator {
    /// How long an action waits for the app to start and report a first
    /// status.
    public static let readinessBound: Duration = .seconds(10)

    private let clock: any DeadlineClock
    private let bound: Duration
    private let attached: FirstValue<any ShortcutsActionTarget>
    private let log: @MainActor (String) -> Void

    /// - Parameter log: receives one fixed-text line per action.
    public init(clock: any DeadlineClock = SystemDeadlineClock(), readinessBound: Duration = ShortcutsActionCoordinator.readinessBound, log: @escaping @MainActor (String) -> Void) {
        self.clock = clock
        self.bound = readinessBound
        self.attached = FirstValue(clock: clock)
        self.log = log
    }

    /// Called once the app's `start()` has queued its start-up work.
    public func attach(_ target: any ShortcutsActionTarget) {
        attached.provide(target)
    }

    // MARK: - Actions

    public func setChargeLimit(_ limit: Int) async -> ShortcutsActionOutcome {
        let outcome: ShortcutsActionOutcome
        switch await ready(needsStatus: true) {
        case .refused(let text):
            outcome = .refused(text)
        case .ready(let target):
            guard let context = settledContext(target) else {
                outcome = .refused(ShortcutsActionWording.notReady)
                break
            }
            switch ChargeLimitRequest(limit: limit, choices: target.chargeLimitChoices, settings: target.settings) {
            case .refused(let text):
                outcome = .refused(text)
            case .accepted(let proposed):
                switch target.changeSettings(proposed, source: .shortcuts) {
                case .refused(let text): outcome = .refused(text)
                case .unchanged: outcome = .done(ShortcutsActionWording.limitUnchanged(in: context.with(settings: target.settings)))
                case .saved: outcome = .done(ShortcutsActionWording.limitSaved(in: context.with(settings: target.settings)))
                }
            }
        }
        return finish("Set CellKeeper Limit (\(limit)%)", outcome)
    }

    public func startFullCharge() async -> ShortcutsActionOutcome {
        let outcome: ShortcutsActionOutcome
        switch await ready(needsStatus: true) {
        case .refused(let text):
            outcome = .refused(text)
        case .ready(let target):
            guard let context = settledContext(target), let status = target.status else {
                outcome = .refused(ShortcutsActionWording.notReady)
                break
            }
            if let refusal = FullChargeStart.refusal(settings: target.settings, status: status) {
                outcome = .refused(refusal)
            } else {
                target.queueFullCharge()
                outcome = .done(ShortcutsActionWording.fullChargeQueued(in: context))
            }
        }
        return finish("Start CellKeeper Full Charge", outcome)
    }

    /// Accepted in any backend context: it is the menu's Cancel.
    public func stopOverride() async -> ShortcutsActionOutcome {
        let outcome: ShortcutsActionOutcome
        switch await ready(needsStatus: false) {
        case .refused(let text):
            outcome = .refused(text)
        case .ready(let target):
            target.queueCancelOverride()
            outcome = .done(ShortcutsActionWording.stopQueued(in: settledContext(target)))
        }
        return finish("Stop CellKeeper Full Charge or Discharge", outcome)
    }

    /// Turning it on needs a settled context; turning it off does not.
    public func setManagement(_ isOn: Bool) async -> ShortcutsActionOutcome {
        let outcome: ShortcutsActionOutcome
        switch await ready(needsStatus: isOn) {
        case .refused(let text):
            outcome = .refused(text)
        case .ready(let target):
            let context = settledContext(target)
            if isOn, context == nil {
                outcome = .refused(ShortcutsActionWording.notReady)
                break
            }
            var proposed = target.settings
            proposed.isManagementEnabled = isOn
            switch target.changeSettings(proposed, source: .shortcuts) {
            case .refused(let text):
                outcome = .refused(text)
            case let result:
                let saved = context?.with(settings: target.settings)
                outcome = .done(ShortcutsActionWording.management(isOn: isOn, changed: result != .unchanged, in: saved))
            }
        }
        return finish("Set CellKeeper Manage Charging (\(isOn ? "on" : "off"))", outcome)
    }

    /// The latest status; starts no evaluation of its own.
    public func status(timeZone: TimeZone = .current, locale: Locale = .current) async -> ShortcutsStatusOutcome {
        switch await ready(needsStatus: true) {
        case .refused(let text):
            log("Shortcuts action Get CellKeeper Status: refused: \(text)")
            return .refused(text)
        case .ready(let target):
            guard let status = target.status else {
                log("Shortcuts action Get CellKeeper Status: refused: \(ShortcutsActionWording.notReady)")
                return .refused(ShortcutsActionWording.notReady)
            }
            let value = ShortcutsStatus(status: status, settings: target.settings, selectedBackendIdentifier: target.selectedBackendIdentifier, timeZone: timeZone, locale: locale)
            log("Shortcuts action Get CellKeeper Status: \(value.dialog)")
            return .status(value)
        }
    }

    // MARK: - Readiness

    private enum Readiness {
        case ready(any ShortcutsActionTarget)
        case refused(String)
    }

    /// Waits for the app, then for its first status if `needsStatus`, both
    /// against one absolute deadline, and admits the action after each wait.
    /// The last admission is the caller's final check: nothing suspends
    /// between it and the change the caller then makes.
    private func ready(needsStatus: Bool) async -> Readiness {
        let deadline = clock.now.advanced(by: bound)
        guard let target = await attached.value(by: deadline) else {
            return .refused(ShortcutsActionWording.notReady)
        }
        if let refusal = admissionRefusal(target, deadline: deadline) { return .refused(refusal) }
        guard needsStatus else { return .ready(target) }
        let hasStatus = await target.firstStatus.value(by: deadline) != nil
        if let refusal = admissionRefusal(target, deadline: deadline) { return .refused(refusal) }
        guard hasStatus, target.status != nil else { return .refused(ShortcutsActionWording.notReady) }
        return .ready(target)
    }

    /// Whether the action may go on, decided after a suspension and never on
    /// a cached value alone: not once quitting has started, not if the
    /// action was cancelled (also when a value reached it in the same turn),
    /// and not once the clock shows the deadline passed (however early the
    /// value it waited for arrived).
    private func admissionRefusal(_ target: any ShortcutsActionTarget, deadline: ContinuousClock.Instant) -> String? {
        if target.isTerminating { return ShortcutsActionWording.quitting }
        if Task.isCancelled || clock.now >= deadline { return ShortcutsActionWording.notReady }
        return nil
    }

    private func settledContext(_ target: any ShortcutsActionTarget) -> ShortcutsActionContext? {
        ShortcutsActionContext(status: target.status, settings: target.settings, selectedBackendIdentifier: target.selectedBackendIdentifier)
    }

    private func finish(_ action: String, _ outcome: ShortcutsActionOutcome) -> ShortcutsActionOutcome {
        switch outcome {
        case .done(let text): log("Shortcuts action \(action): \(text)")
        case .refused(let text): log("Shortcuts action \(action): refused: \(text)")
        }
        return outcome
    }
}
