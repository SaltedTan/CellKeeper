import Foundation

/// What a control found out about this Mac when probed.
public struct HelperProbe: Sendable, Equatable {
    public var capabilities: HelperCapabilities
    /// True if the control changes no hardware.
    public var isSimulated: Bool

    public init(capabilities: HelperCapabilities, isSimulated: Bool) {
        self.capabilities = capabilities
        self.isSimulated = isSimulated
    }
}

/// An error from a ``HelperChargeControl``, reported to clients as
/// ``HelperStateReply/lastHardwareError``.
///
/// Codes -1 to -99 belong to `CellKeeperHelperCore`. A control that talks to
/// hardware reports the platform's own non-zero code for anything else.
public struct HelperHardwareError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int

    public init(code: Int) {
        self.code = code
    }

    /// The control failed with an error that carries no code.
    public static let unspecified = HelperHardwareError(code: -1)
    /// After a write, the read-back did not show the state written.
    public static let readBackMismatch = HelperHardwareError(code: -2)
    /// After a restore of defaults, the read-back still showed a control
    /// active.
    public static let restoreNotConfirmed = HelperHardwareError(code: -3)
    /// The control was asked for something it cannot do.
    public static let notSupported = HelperHardwareError(code: -4)
    /// A failure injected into ``SimulatedChargeControl``.
    public static let simulatedFailure = HelperHardwareError(code: -10)

    /// The code to report for any error a control throws.
    static func code(for error: any Error) -> Int {
        guard let error = error as? HelperHardwareError, error.code != 0 else { return unspecified.code }
        return error.code
    }

    public var description: String { "hardware error \(code)" }
}

/// The helper's only access to charging hardware.
///
/// This seam is internal to the helper and never on the wire. A real
/// implementation is the one place that holds undocumented operations: it
/// computes its capabilities only from a compiled-in, reviewed allowlist of
/// models and firmware, never by probing with writes. Calls are synchronous
/// and must be bounded in time; ``HelperEngine`` serialises them.
///
/// Contract:
/// - `apply` is only called for a control whose capability `probe` reported.
/// - `readBack` reports the hardware's state, not the state last applied.
/// - `restoreDefaults` returns every control to macOS's default. It must be
///   safe to call at any time and repeatedly, including before `probe`.
public protocol HelperChargeControl: Sendable {
    /// What this Mac supports. Never throws: a probe that cannot complete
    /// reports no capabilities, which means monitor-only.
    func probe() -> HelperProbe
    func apply(_ control: HelperControl, active: Bool) throws
    /// The controls the hardware reports active.
    func readBack() throws -> Set<HelperControl>
    func restoreDefaults() throws
}

/// The control for a Mac whose mechanism has not been verified: no
/// capabilities, and nothing is ever written. The real helper uses it until
/// a mechanism has been verified on a dedicated test Mac (research rule
/// R12a: unknown hardware means monitor-only).
public struct UnknownHardwareChargeControl: HelperChargeControl {
    public init() {}

    public func probe() -> HelperProbe {
        HelperProbe(capabilities: [], isSimulated: false)
    }

    public func apply(_ control: HelperControl, active: Bool) throws {
        throw HelperHardwareError.notSupported
    }

    public func readBack() throws -> Set<HelperControl> {
        []
    }

    /// Nothing to restore: this control never sets anything.
    public func restoreDefaults() throws {}
}

/// A simulated control. It tracks which controls are "active" but never
/// touches hardware, and its probe reports ``HelperProbe/isSimulated``.
///
/// Thread-safe, so a test can inject failures and outside changes while the
/// engine uses it. Used in tests and in builds without a real helper.
public final class SimulatedChargeControl: HelperChargeControl, @unchecked Sendable {
    /// A write the control received.
    public enum Write: Sendable, Equatable {
        case apply(HelperControl, active: Bool)
        case restoreDefaults
    }

    private let lock = NSLock()
    private let capabilities: HelperCapabilities
    private var active: Set<HelperControl>
    private var log: [Write] = []
    private var reads = 0
    private var pendingApplyActions: [@Sendable () -> Void] = []
    private var pendingApplyFailures = 0
    private var pendingFailuresAfterApplying = 0
    private var pendingMisapplies = 0
    private var pendingReadBackFailuresAfterApplying = 0
    private var pendingIgnoredApplies = 0
    private var pendingReadBackFailures = 0
    private var pendingRestoreFailures = 0
    private var pendingIgnoredRestores = 0
    private var pendingMisrestores = 0
    private var pendingPartialRestores: [HelperControl] = []
    private var pendingFailuresAfterRestoring = 0
    private var pendingCompetingWrites: [HelperControl] = []
    private var pendingReadBackFailuresAfterRestoring = 0

    public init(
        capabilities: HelperCapabilities = [.chargingInhibit, .adapterDisable],
        initiallyActive: Set<HelperControl> = []
    ) {
        self.capabilities = capabilities
        self.active = initiallyActive
    }

    public func probe() -> HelperProbe {
        HelperProbe(capabilities: capabilities, isSimulated: true)
    }

    public func apply(_ control: HelperControl, active isActive: Bool) throws {
        let during = lock.withLock { pendingApplyActions.isEmpty ? nil : pendingApplyActions.removeFirst() }
        during?()
        try lock.withLock {
            log.append(.apply(control, active: isActive))
            guard capabilities.contains(control.requiredCapability) else {
                throw HelperHardwareError.notSupported
            }
            if pendingApplyFailures > 0 {
                pendingApplyFailures -= 1
                throw HelperHardwareError.simulatedFailure
            }
            if pendingIgnoredApplies > 0 {
                pendingIgnoredApplies -= 1
                return
            }
            var target = control
            if pendingMisapplies > 0 {
                pendingMisapplies -= 1
                target = HelperControl.allCases.first { $0 != control } ?? control
            }
            if isActive {
                active.insert(target)
            } else {
                active.remove(target)
            }
            if pendingReadBackFailuresAfterApplying > 0 {
                pendingReadBackFailuresAfterApplying -= 1
                pendingReadBackFailures += 1
            }
            if pendingFailuresAfterApplying > 0 {
                pendingFailuresAfterApplying -= 1
                throw HelperHardwareError.simulatedFailure
            }
        }
    }

    public func readBack() throws -> Set<HelperControl> {
        try lock.withLock {
            reads += 1
            if pendingReadBackFailures > 0 {
                pendingReadBackFailures -= 1
                throw HelperHardwareError.simulatedFailure
            }
            return active
        }
    }

    public func restoreDefaults() throws {
        try lock.withLock {
            log.append(.restoreDefaults)
            if pendingRestoreFailures > 0 {
                pendingRestoreFailures -= 1
                throw HelperHardwareError.simulatedFailure
            }
            if pendingIgnoredRestores > 0 {
                pendingIgnoredRestores -= 1
                return
            }
            if pendingMisrestores > 0 {
                pendingMisrestores -= 1
                active = Set(HelperControl.allCases).subtracting(active)
            } else if !pendingPartialRestores.isEmpty {
                let kept = pendingPartialRestores.removeFirst()
                active = active.intersection([kept])
            } else {
                active = []
            }
            if !pendingCompetingWrites.isEmpty {
                active.insert(pendingCompetingWrites.removeFirst())
            }
            if pendingReadBackFailuresAfterRestoring > 0 {
                pendingReadBackFailuresAfterRestoring -= 1
                pendingReadBackFailures += 1
            }
            if pendingFailuresAfterRestoring > 0 {
                pendingFailuresAfterRestoring -= 1
                throw HelperHardwareError.simulatedFailure
            }
        }
    }

    // MARK: - Test hooks

    /// The simulated hardware state, without consuming injected failures.
    public var activeControls: Set<HelperControl> {
        lock.withLock { active }
    }

    /// Every write received, in order, including failed ones.
    public var writes: [Write] {
        lock.withLock { log }
    }

    public var writeCount: Int {
        lock.withLock { log.count }
    }

    /// The number of calls to `readBack`, including failed ones.
    public var readBackCount: Int {
        lock.withLock { reads }
    }

    /// Runs `action` during each of the next `count` calls to `apply`, for
    /// example to advance a test clock as if the call took time.
    public func performDuringNextApplies(_ count: Int, _ action: @escaping @Sendable () -> Void) {
        lock.withLock { pendingApplyActions.append(contentsOf: Array(repeating: action, count: count)) }
    }

    /// Makes the next `count` calls to `apply` throw without changing state.
    public func failNextApplies(_ count: Int) {
        lock.withLock { pendingApplyFailures += count }
    }

    /// Makes the next `count` calls to `apply` change the state and then
    /// throw, like a write that took effect but reported an error.
    public func failNextAppliesAfterApplying(_ count: Int) {
        lock.withLock { pendingFailuresAfterApplying += count }
    }

    /// Makes the next `count` calls to `apply` change the other control
    /// instead of the one asked for, and return normally.
    public func misapplyNextApplies(_ count: Int) {
        lock.withLock { pendingMisapplies += count }
    }

    /// After each of the next `count` successful calls to `apply`, makes
    /// the next `readBack` throw.
    public func failReadBacksAfterNextApplies(_ count: Int) {
        lock.withLock { pendingReadBackFailuresAfterApplying += count }
    }

    /// Makes the next `count` calls to `apply` succeed without changing
    /// state, so the read-back does not match.
    public func ignoreNextApplies(_ count: Int) {
        lock.withLock { pendingIgnoredApplies += count }
    }

    /// Makes the next `count` calls to `readBack` throw.
    public func failNextReadBacks(_ count: Int) {
        lock.withLock { pendingReadBackFailures += count }
    }

    /// Makes the next `count` calls to `restoreDefaults` throw without
    /// changing state.
    public func failNextRestores(_ count: Int) {
        lock.withLock { pendingRestoreFailures += count }
    }

    /// Makes the next `count` calls to `restoreDefaults` succeed without
    /// changing state, so the read-back is not clean.
    public func ignoreNextRestores(_ count: Int) {
        lock.withLock { pendingIgnoredRestores += count }
    }

    /// Makes the next `count` calls to `restoreDefaults` change the wrong
    /// controls: every active control is cleared and every inactive one is
    /// set. They return normally.
    public func misrestoreNextRestores(_ count: Int) {
        lock.withLock { pendingMisrestores += count }
    }

    /// Makes the next `count` calls to `restoreDefaults` clear every
    /// control except `kept`, and return normally.
    public func partiallyRestoreNextRestores(_ count: Int, keeping kept: HelperControl) {
        lock.withLock { pendingPartialRestores.append(contentsOf: Array(repeating: kept, count: count)) }
    }

    /// Makes another writer set `control` during each of the next `count`
    /// calls to `restoreDefaults`, after the restore has changed the state.
    /// They return normally.
    public func simulateCompetingWriterDuringNextRestores(_ count: Int, setting control: HelperControl) {
        lock.withLock { pendingCompetingWrites.append(contentsOf: Array(repeating: control, count: count)) }
    }

    /// Makes the next `count` calls to `restoreDefaults` change the state
    /// (as any other hook says) and then throw.
    public func failNextRestoresAfterRestoring(_ count: Int) {
        lock.withLock { pendingFailuresAfterRestoring += count }
    }

    /// After each of the next `count` calls to `restoreDefaults` that change
    /// the state, makes the next `readBack` throw.
    public func failReadBacksAfterNextRestores(_ count: Int) {
        lock.withLock { pendingReadBackFailuresAfterRestoring += count }
    }

    /// Changes a control as if another tool had done it. Not counted as a
    /// write.
    public func simulateOutsideChange(_ control: HelperControl, active isActive: Bool) {
        lock.withLock {
            if isActive {
                active.insert(control)
            } else {
                active.remove(control)
            }
        }
    }
}
