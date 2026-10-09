import CellKeeperHelperCore
import Foundation

/// A backend that controls charging through CellKeeper's helper
/// (``HelperEngine``), reached through a ``HelperTransport``.
///
/// - `.inhibitCharging` holds the helper's charging-inhibit control and
///   `.forceDischarge` its adapter-disable control, each under the longest
///   lease the helper grants. `.normal` releases both.
/// - Every mode is read back from the helper (`readState`), never assumed,
///   including after reconnecting. Every request is confirmed by a fresh read.
/// - Switching between the two controls sets the new one before clearing the
///   old one, so charging is never allowed in between.
/// - `.normal` releases only what CellKeeper set. If the helper reports an
///   outside change, or a control CellKeeper did not set is active, the
///   backend never restores defaults by itself (research rules R26, R27): it
///   reports the change, and only ``resetAfterFault()`` (the user clearing
///   the fault) restores defaults.
/// - A hold the helper ended itself (a lapsed lease, one of its power or
///   sleep interlocks, a lost connection) is reported by
///   ``reportedModeOrigin()``, so the controller does not take it for an
///   outside change. Why a hold ended comes from the helper: the reason its
///   lease ended, its interlocks, and its count of hardware errors. Another
///   client's restore or deactivation is an outside change.
/// - Requests are paced to stay within the helper's per-session request
///   budget, far from the point where it revokes a session.
/// - While CellKeeper holds a control, a ``LeaseActivity`` keeps the app
///   from being napped, so evaluations renew the lease on time.
///
/// The controller serialises all calls into it.
public actor HelperChargingBackend: ChargingBackend {
    public nonisolated let descriptor: BackendDescriptor
    public nonisolated let transport: any HelperTransport

    private let uptime: @Sendable () -> TimeInterval
    private let pause: @Sendable (TimeInterval) async -> Void
    private let activity: any LeaseActivity

    private var connection: (any HelperConnection)?
    /// The helper's reply to `hello` on ``connection``.
    private var introduction: HelperHelloReply?
    /// Whether the helper last said its control is simulated; kept across
    /// connections, so a simulated request is never reported as applied.
    private var isSimulated = false
    private var pacer: RequestPacer
    /// The controls CellKeeper set, confirmed by read-back, that it has not
    /// released and has not seen cleared.
    private var held: Set<HelperControl> = [] {
        didSet {
            if held.isEmpty != oldValue.isEmpty {
                activity.setHolding(!held.isEmpty)
            }
        }
    }
    /// When CellKeeper's leases end at the latest, on ``uptime``: the time
    /// before each grant was requested, plus the seconds granted. Never later
    /// than the helper's own deadline. Used only to avoid renewing a lease
    /// that may have lapsed.
    private var leaseDeadlines: [HelperControl: TimeInterval] = [:]
    /// The connection ended while CellKeeper held a control, so the helper
    /// has cleared it.
    private var isConnectionLostWhileHolding = false
    /// The helper's count of hardware errors at the last read.
    private var lastHardwareErrorCount: Int?
    /// An outside change the helper still shows: its `externalModification`
    /// interlock, or a control CellKeeper did not set.
    private var currentOutsideChange: String?
    /// A hold that ended without CellKeeper or a rule of the helper, kept
    /// until the next request.
    private var unexplainedLoss: String?
    /// How the helper last ended CellKeeper's hold, kept until the next
    /// request.
    private var lastRelease: HoldRelease?
    private var origin: ReportedModeOrigin?

    /// - Parameters:
    ///   - uptime: monotonic seconds that keep counting during sleep, on the
    ///     same scale as the helper's clock.
    ///   - pause: waits the given number of seconds; used to stay within the
    ///     helper's request budget.
    ///   - activity: told when CellKeeper starts and stops holding a control.
    public init(
        descriptor: BackendDescriptor,
        transport: any HelperTransport,
        uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime,
        pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        activity: any LeaseActivity = ProcessLeaseActivity()
    ) {
        self.descriptor = descriptor
        self.transport = transport
        self.uptime = uptime
        self.pause = pause
        self.activity = activity
        self.pacer = RequestPacer(at: uptime())
    }

    deinit {
        // The helper clears whatever the session still holds.
        if let connection {
            Task { await connection.invalidate() }
        }
        if !held.isEmpty {
            activity.setHolding(false)
        }
    }

    // MARK: - ChargingBackend

    public func capabilities() async -> ControlCapabilities {
        let introduction: HelperHelloReply
        let state: HelperStateReply
        do {
            introduction = try await introduced()
            guard !introduction.capabilities.isEmpty else {
                return .unavailable("CellKeeper's helper cannot control charging on this Mac yet, so CellKeeper only monitors it.")
            }
            state = try await fetchState()
        } catch {
            return .unavailable(Self.reason(error))
        }
        // Modes an interlock blocks right now are not offered, so the policy
        // refuses them as unsupported instead of counting failures.
        var modes: Set<ChargeControlMode> = []
        for control in HelperControl.allCases
        where introduction.capabilities.contains(control.requiredCapability)
            && state.interlocks.isDisjoint(with: control.blockingInterlocks) {
            modes.insert(Self.mode(for: control))
        }
        return ControlCapabilities(availability: introduction.isSimulated ? .simulated : .experimental, supportedModes: modes)
    }

    /// The mode read back from the helper. Unknown (nil) if the helper cannot
    /// be reached or used at all, like a backend that accepts no requests;
    /// an error if a request to it fails.
    public func currentMode() async throws -> ChargeControlMode? {
        origin = nil
        let state: HelperStateReply
        do {
            state = try await readState()
        } catch BackendError.unavailable {
            return nil
        }
        switch observe(state) {
        case nil:
            break
        case .released(let release)?:
            lastRelease = release
        case .unexplained(let detail)?:
            unexplainedLoss = detail
        case .hardwareError(let detail)?:
            throw BackendError.operationFailed(detail)
        }
        let active = state.activeControls.controls
        if let outside = currentOutsideChange ?? unexplainedLoss {
            origin = .changedOutside(outside)
            return Self.mode(for: active)
        }
        guard let mode = Self.mode(for: active) else {
            throw BackendError.operationFailed("CellKeeper's helper reports both charging inhibited and the adapter disabled")
        }
        if let lastRelease {
            origin = .releasedByBackend(lastRelease)
        }
        return mode
    }

    public func reportedModeOrigin() async -> ReportedModeOrigin? {
        origin
    }

    public func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome {
        switch mode {
        case .normal:
            return try await releaseAll()
        case .inhibitCharging:
            return try await hold(.chargingInhibited, as: mode)
        case .forceDischarge:
            return try await hold(.adapterDisabled, as: mode)
        case .nativeLimit:
            throw BackendError.unsupportedMode(mode)
        }
    }

    /// Renews CellKeeper's lease on the control behind `mode`, for the
    /// longest the helper grants. A lease already past its deadline is left
    /// alone: it may have lapsed, and a new lease would not bring back a
    /// control the helper has cleared. The next read reports the lapse.
    public func renewHold(_ mode: ChargeControlMode) async throws {
        guard let control = Self.control(for: mode) else { return }
        guard held.contains(control) else {
            throw BackendError.operationFailed("CellKeeper holds no \(Self.describe([control])) on its helper to renew")
        }
        if let deadline = leaseDeadlines[control], uptime() >= deadline {
            return
        }
        try await takeLease(control)
    }

    /// Restores macOS's defaults through the helper if it is waiting for a
    /// client to acknowledge a problem: an interlock other than the power
    /// and sleep conditions (an outside change, a failed write, an owed
    /// restore), a control CellKeeper did not set, or a failed read-back.
    /// This ends every lease and may undo another tool's change, which is
    /// why only the user's clearing of the fault does it. A helper that
    /// cannot be reached has nothing to acknowledge. If the session ended
    /// before the restore arrived, the backend connects again, says hello,
    /// and tries once more.
    public func resetAfterFault() async throws {
        clearNotices()
        let state: HelperStateReply
        do {
            state = try await fetchState()
        } catch BackendError.unavailable {
            return
        }
        if state.status == .ok {
            _ = observe(state)
        }
        let needsAcknowledgement = state.status == .hardwareError
            || !state.interlocks.subtracting(Self.conditionInterlocks).isEmpty
            || !state.activeControls.controls.subtracting(held).isEmpty
        guard needsAcknowledgement else { return }
        var status: HelperStatus?
        do {
            status = try await send(needsToken: false) { try await $0.restoreDefaults() }
        } catch BackendError.operationFailed {
            // The connection was lost; `send` has dropped it.
            status = nil
        }
        if status.map(Self.isSessionLost) ?? true {
            await dropConnection()
            status = try await send(needsToken: false) { try await $0.restoreDefaults() }
        }
        held = []
        leaseDeadlines = [:]
        isConnectionLostWhileHolding = false
        currentOutsideChange = nil
        guard status == .ok else {
            if status.map(Self.isSessionLost) ?? false { await dropConnection() }
            throw BackendError.operationFailed("CellKeeper's helper could not restore macOS's defaults (\(status.map(String.init(describing:)) ?? "no reply"))")
        }
    }

    // MARK: - Requests

    /// Holds `target`, then lets go of the other control. Confirms by a
    /// fresh read that exactly `target` is active.
    private func hold(_ target: HelperControl, as mode: ChargeControlMode) async throws -> ControlOutcome {
        clearNotices()
        let introduction = try await introduced()
        guard introduction.capabilities.contains(target.requiredCapability) else {
            throw BackendError.unsupportedMode(mode)
        }
        let expected = Self.mode(for: held) ?? .normal
        let before = try await readState()
        if case .unexplained(let detail)? = observe(before) {
            unexplainedLoss = detail
        }
        if currentOutsideChange != nil || unexplainedLoss != nil {
            // Never write over another tool's change (R26, R27).
            throw BackendError.changedOutside(expected: expected, found: Self.mode(for: before.activeControls.controls))
        }
        let wasInEffect = before.activeControls.controls == [target]
        do {
            try await takeLease(target)
            let status = try await send(needsToken: true) { try await $0.setControl(control: target.rawValue, active: true) }
            guard status == .ok else {
                throw await refusal(status, activating: target)
            }
            held.insert(target)
            // Only now that the new control is set: no moment in between
            // allows charging the policy did not ask for.
            for other in HelperControl.allCases where other != target {
                try await letGo(other, leaseHeld: before.isLeaseHolder && before.leaseSeconds(for: other) > 0)
            }
            let after = try await readState()
            let active = after.activeControls.controls
            guard active == [target], !after.interlocks.contains(.externalModification) else {
                throw BackendError.verificationFailed(expected: mode, actual: Self.mode(for: active))
            }
            held = [target]
            isConnectionLostWhileHolding = false
        } catch {
            await reconcileAfterFailure()
            throw error
        }
        return outcome(changed: !wasInEffect)
    }

    /// Clears what CellKeeper set and ends its leases, then confirms that
    /// nothing is active. A control CellKeeper did not set is never touched:
    /// it is reported as an outside change.
    private func releaseAll() async throws -> ControlOutcome {
        clearNotices()
        let before = try await readState()
        _ = observe(before)
        let ownedBefore = held
        do {
            // The adapter first, so external power returns as soon as possible.
            for control in [HelperControl.adapterDisabled, .chargingInhibited] {
                try await letGo(control, leaseHeld: before.isLeaseHolder && before.leaseSeconds(for: control) > 0)
            }
        } catch {
            await reconcileAfterFailure()
            throw error
        }
        let after = try await readState()
        let remaining = after.activeControls.controls
        held.formIntersection(remaining)
        guard remaining.isEmpty else {
            if remaining.isDisjoint(with: ownedBefore) {
                throw BackendError.changedOutside(expected: .normal, found: Self.mode(for: remaining))
            }
            throw BackendError.verificationFailed(expected: .normal, actual: Self.mode(for: remaining))
        }
        leaseDeadlines = [:]
        isConnectionLostWhileHolding = false
        return outcome(changed: !ownedBefore.isEmpty)
    }

    /// Clears `control` if CellKeeper set it, and ends CellKeeper's lease on
    /// it. Neither needs a lease or is ever rate-limited by the helper.
    private func letGo(_ control: HelperControl, leaseHeld: Bool) async throws {
        if held.contains(control) {
            let status = try await send(needsToken: false) { try await $0.setControl(control: control.rawValue, active: false) }
            guard status == .ok else {
                if Self.isSessionLost(status) { await dropConnection() }
                throw BackendError.operationFailed("CellKeeper's helper could not clear \(Self.describe([control])) (\(status))")
            }
            held.remove(control)
        }
        if leaseHeld || leaseDeadlines[control] != nil {
            let status = try await send(needsToken: false) { try await $0.releaseLease(control: control.rawValue) }
            // `noLease`: it has already ended.
            guard status == .ok || status == .noLease else {
                if Self.isSessionLost(status) { await dropConnection() }
                throw BackendError.operationFailed("CellKeeper's helper could not end the lease on \(Self.describe([control])) (\(status))")
            }
            leaseDeadlines[control] = nil
        }
    }

    /// Takes or renews CellKeeper's lease on `control` for the longest the
    /// helper grants.
    private func takeLease(_ control: HelperControl) async throws {
        let requestedAt = uptime()
        let reply = try await send(needsToken: true) {
            try await $0.acquireOrRenewLease(control: control.rawValue, seconds: control.maximumLeaseSeconds)
        }
        guard reply.status == .ok, reply.grantedSeconds > 0 else {
            if Self.isSessionLost(reply.status) { await dropConnection() }
            throw BackendError.operationFailed("CellKeeper's helper refused a lease on \(Self.describe([control])) (\(reply.status))")
        }
        leaseDeadlines[control] = requestedAt + TimeInterval(reply.grantedSeconds)
    }

    /// The error for a refused activation.
    private func refusal(_ status: HelperStatus, activating control: HelperControl) async -> BackendError {
        if Self.isSessionLost(status) {
            await dropConnection()
            return .operationFailed("CellKeeper's helper ended its session (\(status))")
        }
        guard status == .blockedByInterlock, let state = try? await readState() else {
            return .operationFailed("CellKeeper's helper refused to set \(Self.describe([control])) (\(status))")
        }
        if state.interlocks.contains(.externalModification) {
            return .changedOutside(expected: Self.mode(for: held) ?? .normal, found: Self.mode(for: state.activeControls.controls))
        }
        let blocking = state.interlocks.intersection(control.blockingInterlocks)
        return .operationFailed("CellKeeper's helper refused to set \(Self.describe([control])): \(Self.describe(blocking))")
    }

    /// After a failed request CellKeeper holds only what is still active of
    /// what it set; the controller then requests `.normal`.
    private func reconcileAfterFailure() async {
        guard let state = try? await readState() else { return }
        held.formIntersection(state.activeControls.controls)
        if held.isEmpty {
            isConnectionLostWhileHolding = false
        }
    }

    private func outcome(changed: Bool) -> ControlOutcome {
        if isSimulated { return .simulated }
        return changed ? .applied : .unchanged
    }

    private func clearNotices() {
        origin = nil
        lastRelease = nil
        unexplainedLoss = nil
    }

    // MARK: - Reading state

    /// What a fresh read shows about controls CellKeeper held that are no
    /// longer active.
    private enum Loss {
        case released(HoldRelease)
        /// The helper cleared it after a hardware error: a failure.
        case hardwareError(String)
        /// Neither CellKeeper nor a rule of the helper explains it.
        case unexplained(String)
    }

    /// Updates what CellKeeper holds from a fresh read and says how a hold
    /// that ended came about, from what the helper reports: why the lease
    /// ended, its interlocks, and its count of hardware errors. Also notes an
    /// outside change the helper still shows.
    private func observe(_ state: HelperStateReply) -> Loss? {
        let active = state.activeControls.controls
        let isNewHardwareError = lastHardwareErrorCount.map { state.hardwareErrorCount > $0 } ?? false
        lastHardwareErrorCount = state.hardwareErrorCount
        let foreign = active.subtracting(held)
        if state.interlocks.contains(.externalModification) {
            currentOutsideChange = "CellKeeper's helper found its controls changed by something other than CellKeeper (another tool may be controlling charging); it restored macOS's defaults once and changes nothing more until the fault is cleared"
        } else if !foreign.isEmpty {
            currentOutsideChange = "CellKeeper's helper reports \(Self.describe(foreign)), which CellKeeper did not set"
        } else {
            currentOutsideChange = nil
        }
        let lost = held.subtracting(active)
        held.formIntersection(active)
        defer {
            for control in lost { leaseDeadlines[control] = nil }
            if held.isEmpty { isConnectionLostWhileHolding = false }
        }
        guard !lost.isEmpty, currentOutsideChange == nil else { return nil }
        let losses = lost.compactMap { loss(of: $0, in: state, isNewHardwareError: isNewHardwareError) }
        // The most serious explanation wins: an outside change, then a
        // failure, then one of the helper's releases.
        return losses.first { if case .unexplained = $0 { true } else { false } }
            ?? losses.first { if case .hardwareError = $0 { true } else { false } }
            ?? losses.first
    }

    /// Why `control`, which CellKeeper held, is no longer active; nil if
    /// CellKeeper released it itself.
    private func loss(of control: HelperControl, in state: HelperStateReply, isNewHardwareError: Bool) -> Loss? {
        if isConnectionLostWhileHolding {
            return .released(.connectionLost)
        }
        let name = Self.describe([control])
        switch state.change(for: control).cause {
        case .leaseExpired?:
            return .released(.leaseExpired)
        case .sessionEnded?, .sessionRevoked?, .shutdown?:
            // CellKeeper's earlier session ended; the helper cleared what
            // it held.
            return .released(.connectionLost)
        case .clearedByRestore?:
            // CellKeeper forgets what it held before its own restores.
            return .unexplained("another client of the helper restored macOS's defaults, which ended CellKeeper's \(name)")
        default:
            break
        }
        // The lease runs on. Only the power and sleep conditions are
        // routine; an interlock that waits for an acknowledgement is not.
        let blocking = state.interlocks.intersection(control.blockingInterlocks).intersection(Self.conditionInterlocks)
        if !blocking.isEmpty {
            return .released(.interlock(Self.describe(blocking)))
        }
        if isNewHardwareError {
            return .hardwareError("CellKeeper's helper cleared \(name) after a hardware error (code \(state.lastHardwareError))")
        }
        if state.leaseSeconds(for: control) > 0 {
            return .unexplained("\(name) was cleared while CellKeeper's lease on it ran on, by no rule of the helper: another client of the helper cleared it")
        }
        return .unexplained("\(name) ended, and the helper reports no reason")
    }

    /// A fresh `readState` whose status is `ok`.
    private func readState() async throws -> HelperStateReply {
        let state = try await fetchState()
        guard state.status == .ok else {
            throw BackendError.operationFailed("CellKeeper's helper could not read back its controls (hardware error \(state.lastHardwareError))")
        }
        return state
    }

    /// A fresh `readState` whose status is `ok` or `hardwareError` (the
    /// read-back failed; interlocks are still reported). If the helper no
    /// longer knows the session, connects again and reads once more.
    private func fetchState() async throws -> HelperStateReply {
        var state = try await send(needsToken: true) { try await $0.readState() }
        if Self.isSessionLost(state.status) {
            await dropConnection()
            state = try await send(needsToken: true) { try await $0.readState() }
        }
        switch state.status {
        case .ok, .hardwareError:
            return state
        default:
            if Self.isSessionLost(state.status) { await dropConnection() }
            throw BackendError.operationFailed("CellKeeper's helper did not report its state (\(state.status))")
        }
    }

    // MARK: - Connection

    /// The current connection's reply to `hello`, connecting and introducing
    /// CellKeeper first if there is no connection.
    @discardableResult
    private func introduced() async throws -> HelperHelloReply {
        if connection != nil, let introduction { return introduction }
        let new: any HelperConnection
        do {
            new = try await transport.connect()
        } catch {
            throw BackendError.unavailable("CellKeeper's helper cannot be reached (\(error)); it may not be installed or running.")
        }
        // The helper gives each new session a full request budget.
        pacer = RequestPacer(at: uptime())
        await paced(needsToken: true)
        let reply: HelperHelloReply
        do {
            reply = try await new.hello(clientProtocolVersion: HelperProtocolVersion.current)
        } catch {
            await new.invalidate()
            throw BackendError.unavailable("The connection to CellKeeper's helper ended while connecting (\(error)).")
        }
        guard reply.status == .ok else {
            await new.invalidate()
            throw BackendError.unavailable(Self.helloRefusal(reply))
        }
        connection = new
        introduction = reply
        isSimulated = reply.isSimulated
        return reply
    }

    /// Sends one request on the introduced connection. A transport failure
    /// drops the connection, so the next request connects again and reads
    /// the state afresh.
    private func send<Reply: Sendable>(
        needsToken: Bool,
        _ request: @Sendable (any HelperConnection) async throws -> Reply
    ) async throws -> Reply {
        try await introduced()
        guard let connection else {
            throw BackendError.operationFailed("no connection to CellKeeper's helper")
        }
        await paced(needsToken: needsToken)
        do {
            return try await request(connection)
        } catch {
            await dropConnection()
            throw BackendError.operationFailed("lost the connection to CellKeeper's helper (\(error))")
        }
    }

    /// Ends the current connection. The helper clears what its session held.
    private func dropConnection() async {
        let old = connection
        connection = nil
        introduction = nil
        if !held.isEmpty {
            isConnectionLostWhileHolding = true
        }
        await old?.invalidate()
    }

    /// Waits, if needed, so the helper's request budget never refuses
    /// CellKeeper or revokes its session (see ``RequestPacer``).
    private func paced(needsToken: Bool) async {
        let wait = pacer.wait(needsToken: needsToken, at: uptime())
        if wait > 0 {
            await pause(wait)
        }
        pacer.take(at: uptime())
    }

    // MARK: - Vocabulary

    /// Interlocks that follow from the power state and sleep, and lift by
    /// themselves. Any other interlock waits for a client to restore
    /// defaults.
    static let conditionInterlocks: HelperInterlocks = [
        .belowBatteryFloor, .notOnExternalPower, .belowAdapterFloor, .adapterAbsent,
        .adapterPresenceUnknown, .thermalPressure, .powerStateUnavailable, .sleepImminent,
    ]

    static func mode(for control: HelperControl) -> ChargeControlMode {
        switch control {
        case .chargingInhibited: .inhibitCharging
        case .adapterDisabled: .forceDischarge
        }
    }

    /// The mode the controls amount to; nil if both are active.
    static func mode(for controls: Set<HelperControl>) -> ChargeControlMode? {
        switch controls.count {
        case 0: .normal
        case 1: controls.first.map(mode(for:))
        default: nil
        }
    }

    static func control(for mode: ChargeControlMode) -> HelperControl? {
        switch mode {
        case .inhibitCharging: .chargingInhibited
        case .forceDischarge: .adapterDisabled
        case .normal, .nativeLimit: nil
        }
    }

    static func describe(_ controls: Set<HelperControl>) -> String {
        HelperControl.allCases.filter(controls.contains).map { control -> String in
            switch control {
            case .chargingInhibited: "charging inhibited"
            case .adapterDisabled: "the adapter disabled"
            }
        }.joined(separator: " and ")
    }

    static func describe(_ interlocks: HelperInterlocks) -> String {
        let names: [(HelperInterlocks, String)] = [
            (.belowBatteryFloor, "the battery is at or below the helper's \(HelperEngine.batteryFloor)% floor"),
            (.notOnExternalPower, "the Mac is not on external power"),
            (.belowAdapterFloor, "the battery is at or below the \(HelperEngine.adapterFloor)% floor for running from it"),
            (.adapterAbsent, "no power adapter is connected"),
            (.adapterPresenceUnknown, "the helper cannot tell whether a power adapter is connected"),
            (.thermalPressure, "macOS reports high thermal pressure"),
            (.powerStateUnavailable, "the helper's own power reading is missing or out of date"),
            (.sleepImminent, "the Mac is about to sleep"),
            (.externalModification, "its controls were changed outside CellKeeper"),
            (.hardwareFault, "a hardware fault"),
            (.writeFailed, "a write to one of its controls failed"),
        ]
        var parts = names.filter { interlocks.contains($0.0) }.map(\.1)
        let unnamed = names.reduce(interlocks) { $0.subtracting($1.0) }
        if !unnamed.isEmpty {
            parts.append("interlock 0x\(String(unnamed.rawValue, radix: 16))")
        }
        return parts.joined(separator: "; ")
    }

    static func isSessionLost(_ status: HelperStatus) -> Bool {
        status == .notIntroduced || status == .shuttingDown
    }

    static func helloRefusal(_ reply: HelperHelloReply) -> String {
        switch reply.status {
        case .incompatibleProtocol:
            "CellKeeper's helper speaks protocol version \(reply.helperProtocolVersion), which this version of CellKeeper (protocol version \(HelperProtocolVersion.current)) cannot use. Update CellKeeper and its helper."
        case .notReady:
            "CellKeeper's helper has not finished starting."
        case .shuttingDown:
            "CellKeeper's helper is shutting down."
        default:
            "CellKeeper's helper refused the connection (\(reply.status))."
        }
    }

    static func reason(_ error: any Error) -> String {
        if case BackendError.unavailable(let reason) = error { return reason }
        return "CellKeeper's helper is not responding: \(error)"
    }
}

/// Mirrors a helper session's request budget (``HelperEngine/requestBurst``
/// at once, refilled at ``HelperEngine/requestsPerSecond``) with one token
/// in reserve for timing differences.
struct RequestPacer {
    static let capacity = Double(HelperEngine.requestBurst - 1)
    static let rate = HelperEngine.requestsPerSecond
    /// Requests that only move toward safety are sent without waiting, but
    /// never more than this many in a row beyond the budget: far below
    /// ``HelperEngine/maximumOverBudgetRequests``, after which the helper
    /// revokes the session.
    static let maximumUnpacedStreak = 4

    private var tokens: Double
    private var refilledAt: TimeInterval
    /// Requests sent in a row without a token.
    private(set) var overBudgetStreak = 0

    init(at now: TimeInterval) {
        tokens = Self.capacity
        refilledAt = now
    }

    /// Seconds to wait before sending a request; 0 to send it now. A request
    /// the helper's budget may refuse waits for a token; one that only moves
    /// toward safety waits only after ``maximumUnpacedStreak`` requests in a
    /// row went without one.
    mutating func wait(needsToken: Bool, at now: TimeInterval) -> TimeInterval {
        refill(at: now)
        guard tokens < 1, needsToken || overBudgetStreak >= Self.maximumUnpacedStreak else { return 0 }
        return (1 - tokens) / Self.rate
    }

    /// Uses a token if one is available, as the helper does for every
    /// request.
    mutating func take(at now: TimeInterval) {
        refill(at: now)
        if tokens >= 1 {
            tokens -= 1
            overBudgetStreak = 0
        } else {
            overBudgetStreak += 1
        }
    }

    private mutating func refill(at now: TimeInterval) {
        guard now > refilledAt else { return }
        tokens = min(Self.capacity, tokens + (now - refilledAt) * Self.rate)
        refilledAt = now
    }
}
