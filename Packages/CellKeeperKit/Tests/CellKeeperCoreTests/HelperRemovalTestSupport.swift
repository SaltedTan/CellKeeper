@testable import CellKeeperCore
import CellKeeperHelperCore
import Foundation

/// Every step the fakes saw, in order, across the controller's backend, the
/// helper's transport and the registration.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var waiters: [Int: (entry: String, occurrences: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextWaiter = 0

    var all: [String] {
        lock.withLock { entries }
    }

    func append(_ entry: String) {
        let ready: [CheckedContinuation<Bool, Never>] = lock.withLock {
            entries.append(entry)
            let recorded = entries.filter { $0 == entry }.count
            let ids = waiters.filter { $0.value.entry == entry && $0.value.occurrences <= recorded }.map(\.key)
            return ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in ready {
            continuation.resume(returning: true)
        }
    }

    /// Returns true once `entry` has been recorded `occurrences` times, or
    /// false after `limit`, so a test that goes wrong fails instead of
    /// hanging the run.
    ///
    /// The waiter is registered before its timeout starts, so the timeout
    /// always finds it (or finds it already resumed); the limit counts from
    /// the call, whenever the timeout task runs.
    @discardableResult
    func waitFor(_ entry: String, occurrences: Int = 1, within limit: Duration = testWaitLimit) async -> Bool {
        let expiresAt = ContinuousClock.now.advanced(by: limit)
        let id = lock.withLock {
            nextWaiter += 1
            return nextWaiter
        }
        let isLogged = await withCheckedContinuation { continuation in
            let isRecorded = lock.withLock {
                if entries.filter({ $0 == entry }).count >= occurrences { return true }
                waiters[id] = (entry, occurrences, continuation)
                return false
            }
            if isRecorded {
                continuation.resume(returning: true)
                return
            }
            let timeout = Task { [weak self] in
                try? await Task.sleep(until: expiresAt, clock: .continuous)
                self?.giveUp(id)
            }
            let isWaiting = lock.withLock {
                guard waiters[id] != nil else { return false }
                timeouts[id] = timeout
                return true
            }
            if !isWaiting {
                timeout.cancel()
            }
        }
        lock.withLock { timeouts.removeValue(forKey: id) }?.cancel()
        return isLogged
    }

    private func giveUp(_ id: Int) {
        lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume(returning: false)
    }

    /// The recorded entries that are among `wanted`, in order.
    func order(of wanted: Set<String>) -> [String] {
        all.filter(wanted.contains)
    }

    func count(of entry: String) -> Int {
        all.filter { $0 == entry }.count
    }
}

/// The longest any wait in these tests lasts: a test that goes wrong fails
/// or moves on instead of hanging the run.
let testWaitLimit: Duration = .seconds(10)

/// Holds whoever waits until the test opens it, or until ``testWaitLimit``
/// has passed, so a stall never outlives a failing test for long.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextWaiter = 0

    /// Returns once the gate is open, or ``testWaitLimit`` after the call.
    /// The waiter is registered before its timeout starts, so the timeout
    /// always finds it (or finds it already released).
    func wait() async {
        let expiresAt = ContinuousClock.now.advanced(by: testWaitLimit)
        let id = lock.withLock {
            nextWaiter += 1
            return nextWaiter
        }
        await withCheckedContinuation { continuation in
            let passes = lock.withLock {
                if isOpen { return true }
                waiters[id] = continuation
                return false
            }
            if passes {
                continuation.resume()
                return
            }
            let timeout = Task { [weak self] in
                try? await Task.sleep(until: expiresAt, clock: .continuous)
                self?.release(id)
            }
            let isWaiting = lock.withLock {
                guard waiters[id] != nil else { return false }
                timeouts[id] = timeout
                return true
            }
            if !isWaiting {
                timeout.cancel()
            }
        }
        lock.withLock { timeouts.removeValue(forKey: id) }?.cancel()
    }

    func open() {
        let released: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for continuation in released {
            continuation.resume()
        }
    }

    private func release(_ id: Int) {
        lock.withLock { waiters.removeValue(forKey: id) }?.resume()
    }
}

struct RegistrationTestError: Error, CustomStringConvertible {
    var description: String { "test unregister failure" }
}

/// The helper's registration, set by the test.
final class FakeHelperRegistration: HelperRegistration, @unchecked Sendable {
    private let lock = NSLock()
    private let log: CallLog?
    private var current: HelperRegistrationStatus
    private var afterUnregister: HelperRegistrationStatus = .notRegistered
    private var unregisterError: RegistrationTestError?
    private var unregisterCalls = 0
    /// Status reads and unregistering wait on these while set.
    private var statusGate: Gate?
    private var statusCallGates: [Int: Gate] = [:]
    private var statusCalls = 0
    private var unregisterGate: Gate?

    init(_ status: HelperRegistrationStatus, log: CallLog? = nil) {
        current = status
        self.log = log
    }

    var unregisterCount: Int {
        lock.withLock { unregisterCalls }
    }

    /// What the status is after `unregister()`, whether it returns or
    /// throws.
    var statusAfterUnregister: HelperRegistrationStatus {
        get { lock.withLock { afterUnregister } }
        set { lock.withLock { afterUnregister = newValue } }
    }

    /// Makes `unregister()` throw (after changing the status to
    /// ``statusAfterUnregister``).
    func failUnregister() {
        lock.withLock { unregisterError = RegistrationTestError() }
    }

    /// Makes every status read wait on `gate`.
    func holdStatus(on gate: Gate) {
        lock.withLock { statusGate = gate }
    }

    /// Makes the status read number `call` (from 1) wait on `gate`.
    func holdStatus(call: Int, on gate: Gate) {
        lock.withLock { statusCallGates[call] = gate }
    }

    /// Makes `unregister()` wait on `gate` before it does anything.
    func holdUnregister(on gate: Gate) {
        lock.withLock { unregisterGate = gate }
    }

    func status() async -> HelperRegistrationStatus {
        log?.append("registration.status")
        let gate: Gate? = lock.withLock {
            statusCalls += 1
            return statusCallGates[statusCalls] ?? statusGate
        }
        if let gate {
            await gate.wait()
        }
        return lock.withLock { current }
    }

    func unregister() async throws {
        log?.append("registration.unregister")
        lock.withLock { unregisterCalls += 1 }
        if let gate = lock.withLock({ unregisterGate }) {
            await gate.wait()
        }
        let error: RegistrationTestError? = lock.withLock {
            current = afterUnregister
            return unregisterError
        }
        if let error {
            throw error
        }
    }
}

/// Wraps a helper transport for removal tests: records each step, and can
/// fail or stall a step, or replace a reply.
final class RemovalTestTransport: HelperTransport, @unchecked Sendable {
    enum Step: Sendable {
        case connect, hello, restoreAndExit
        /// Closing the connection; only stalling applies.
        case invalidate
    }

    let inner: any HelperTransport
    let log: CallLog
    /// Stalled steps wait for it.
    let gate = Gate()
    private let lock = NSLock()
    private var failingStep: Step?
    private var stallingStep: Step?
    private var cancellationStep: Step?
    private var clientVersionValue: Int?
    private var invalidatesBeforeRestore = false
    private var restoreReplyValue: HelperStatus?
    private var restoreObserver: (@Sendable () -> Void)?

    init(inner: any HelperTransport, log: CallLog) {
        self.inner = inner
        self.log = log
    }

    /// Makes `step` throw as a transport failure.
    func fail(at step: Step) {
        lock.withLock { failingStep = step }
    }

    /// Makes `step` wait for ``gate`` before it goes on.
    func stall(at step: Step) {
        lock.withLock { stallingStep = step }
    }

    /// Makes `step` wait until its task is cancelled (as the deadline
    /// cancels it), and only then go on to the helper and answer: a reply
    /// that the cancellation itself sets off.
    func answerOnlyWhenCancelled(at step: Step) {
        lock.withLock { cancellationStep = step }
    }

    /// Says hello to the helper with `version` instead of the client's own,
    /// so a real engine refuses it.
    func sayHello(withClientVersion version: Int) {
        lock.withLock { clientVersionValue = version }
    }

    /// Ends the helper session just before `restoreDefaultsAndExit` reaches
    /// the helper, as if the session had been invalidated meanwhile.
    func invalidateSessionBeforeRestore() {
        lock.withLock { invalidatesBeforeRestore = true }
    }

    /// Answers `restoreDefaultsAndExit` with `status` without asking the
    /// helper.
    func replaceRestoreReply(with status: HelperStatus) {
        lock.withLock { restoreReplyValue = status }
    }

    /// Runs `observer` when `restoreDefaultsAndExit` is sent.
    func observeRestore(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { restoreObserver = observer }
    }

    func fails(_ step: Step) -> Bool {
        lock.withLock { failingStep == step }
    }

    func stalls(_ step: Step) -> Bool {
        lock.withLock { stallingStep == step }
    }

    func answersOnlyWhenCancelled(_ step: Step) -> Bool {
        lock.withLock { cancellationStep == step }
    }

    var clientVersion: Int? {
        lock.withLock { clientVersionValue }
    }

    var invalidatesSessionBeforeRestore: Bool {
        lock.withLock { invalidatesBeforeRestore }
    }

    var restoreReply: HelperStatus? {
        lock.withLock { restoreReplyValue }
    }

    var onRestore: (@Sendable () -> Void)? {
        lock.withLock { restoreObserver }
    }

    /// The injected behaviour of `step`, before it reaches the helper.
    func intervene(at step: Step, name: String) async throws {
        log.append(name)
        if stalls(step) {
            await gate.wait()
        }
        if answersOnlyWhenCancelled(step) {
            let cancelled = Gate()
            await withTaskCancellationHandler {
                await cancelled.wait()
            } onCancel: {
                cancelled.open()
            }
            log.append("\(name) cancelled")
        }
        if fails(step) {
            throw TransportTestError()
        }
    }

    func connect() async throws -> any HelperConnection {
        try await intervene(at: .connect, name: "helper.connect")
        return RemovalTestConnection(inner: try await inner.connect(), transport: self)
    }
}

/// A connection made by ``RemovalTestTransport``.
struct RemovalTestConnection: HelperConnection {
    let inner: any HelperConnection
    let transport: RemovalTestTransport

    func hello(clientProtocolVersion: Int) async throws -> HelperHelloReply {
        do {
            try await transport.intervene(at: .hello, name: "helper.hello")
        } catch {
            await inner.invalidate()
            throw error
        }
        let reply = try await inner.hello(clientProtocolVersion: transport.clientVersion ?? clientProtocolVersion)
        transport.log.append("helper.hello replied \(reply.status)")
        return reply
    }

    func restoreDefaultsAndExit() async throws -> HelperStatus {
        transport.onRestore?()
        do {
            try await transport.intervene(at: .restoreAndExit, name: "helper.restoreDefaultsAndExit")
        } catch {
            await inner.invalidate()
            throw error
        }
        if transport.invalidatesSessionBeforeRestore {
            await inner.invalidate()
        }
        let status: HelperStatus
        if let replaced = transport.restoreReply {
            status = replaced
        } else {
            status = try await inner.restoreDefaultsAndExit()
        }
        transport.log.append("helper.restoreDefaultsAndExit replied \(status)")
        return status
    }

    func invalidate() async {
        transport.log.append("helper.invalidate")
        if transport.stalls(.invalidate) {
            await transport.gate.wait()
        }
        await inner.invalidate()
    }

    func readState() async throws -> HelperStateReply {
        try await inner.readState()
    }

    func acquireOrRenewLease(control: Int, seconds: Int) async throws -> HelperLeaseReply {
        try await inner.acquireOrRenewLease(control: control, seconds: seconds)
    }

    func releaseLease(control: Int) async throws -> HelperStatus {
        try await inner.releaseLease(control: control)
    }

    func setControl(control: Int, active: Bool) async throws -> HelperStatus {
        try await inner.setControl(control: control, active: active)
    }

    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64) async throws -> HelperStatus {
        try await inner.clearControlIfUnchanged(control: control, generation: generation, helperInstance: helperInstance)
    }

    func restoreDefaults() async throws -> HelperStatus {
        try await inner.restoreDefaults()
    }
}

/// A helper engine run in process (``InProcessHelperTransport``) on a
/// simulated control, reached through a ``RemovalTestTransport``, with a
/// fake registration; every step goes to one ``CallLog``.
struct RemovalRig {
    let clock = TestClock()
    let log = CallLog()
    let control: SimulatedChargeControl
    let helper: InProcessHelperTransport
    let transport: RemovalTestTransport
    let registration: FakeHelperRegistration

    /// - Parameters:
    ///   - chargeControl: replaces the simulated control, for a helper that
    ///     says it controls hardware or one that controls nothing.
    init(registration status: HelperRegistrationStatus = .enabled, chargeControl: (any HelperChargeControl)? = nil) {
        let control = SimulatedChargeControl()
        self.control = control
        let clock = clock
        helper = InProcessHelperTransport(
            control: chargeControl ?? control,
            power: StubHelperPower(clock: clock),
            build: 7,
            uptime: { clock.uptime }
        )
        transport = RemovalTestTransport(inner: helper, log: log)
        registration = FakeHelperRegistration(status, log: log)
    }

    var engine: HelperEngine {
        helper.engine
    }

    /// - Parameter clock: if given, every deadline is judged on it, and its
    ///   timers wake only when the test advances it; otherwise the system's.
    func removal(
        helperDeadline: Duration = HelperRemoval.defaultHelperDeadline,
        registrationDeadline: Duration = HelperRemoval.defaultRegistrationDeadline,
        clock: ManualDeadlineClock? = nil
    ) -> HelperRemoval {
        HelperRemoval(
            transport: transport,
            registration: registration,
            helperDeadline: helperDeadline,
            registrationDeadline: registrationDeadline,
            clock: clock?.removalClock ?? .system
        )
    }

    /// Another client of the helper holds the charging inhibit, so the
    /// helper has something to restore.
    func holdInhibit() async {
        let session = await engine.openSession()
        _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        _ = await session.acquireOrRenewLease(control: HelperControl.chargingInhibited.rawValue, seconds: 900)
        _ = await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: true)
    }
}

/// A backend that records its requests in a ``CallLog``.
actor RecordingBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "recording", displayName: "Recording", summary: "")
    private let log: CallLog
    private var mode = ChargeControlMode.normal
    private var failsNormal = false

    init(log: CallLog) {
        self.log = log
    }

    /// Makes every request for `.normal` fail.
    func failNormal() {
        failsNormal = true
    }

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)
    }

    func currentMode() -> ChargeControlMode? {
        mode
    }

    func setMode(_ newMode: ChargeControlMode) throws -> ControlOutcome {
        log.append(newMode == .normal ? "backend.normal" : "backend.restrict")
        if newMode == .normal, failsNormal {
            throw BackendError.operationFailed("injected failure")
        }
        mode = newMode
        return .simulated
    }
}

/// A value set from a closure the code under test runs, read by the test.
final class Observed<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A monotonic clock for deadline tests. Time moves only when the test
/// advances it, and a timer wakes once its time has come, unless the test
/// holds the timers back: then the deadline has passed by the clock, but no
/// timer has woken to check it.
final class ManualDeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var isHeld = false
    private var sleepers: [Int: (due: Duration, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var cancelledSleepers: Set<Int> = []
    private var nextSleeper = 0

    var removalClock: RemovalClock {
        RemovalClock(now: { self.now() }, wake: { await self.wake(at: $0) })
    }

    func now() -> ContinuousClock.Instant {
        lock.withLock { origin.advanced(by: elapsed) }
    }

    /// Moves time on, and wakes the timers now due unless they are held.
    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, Never>] = lock.withLock {
            elapsed += duration
            return isHeld ? [] : takeDue()
        }
        for continuation in due {
            continuation.resume()
        }
    }

    /// From now on, timers do not wake, even once their time has come.
    func holdTimers() {
        lock.withLock { isHeld = true }
    }

    /// Lets timers wake again, and wakes those now due.
    func releaseTimers() {
        let due: [CheckedContinuation<Void, Never>] = lock.withLock {
            isHeld = false
            return takeDue()
        }
        for continuation in due {
            continuation.resume()
        }
    }

    private func takeDue() -> [CheckedContinuation<Void, Never>] {
        let ready = sleepers.filter { $0.value.due <= elapsed }
        for id in ready.keys {
            sleepers.removeValue(forKey: id)
        }
        return ready.values.map(\.continuation)
    }

    /// Returns once the clock has reached `instant` and timers are not
    /// held, or when the calling task is cancelled.
    private func wake(at instant: ContinuousClock.Instant) async {
        let due = origin.duration(to: instant)
        let id = lock.withLock {
            nextSleeper += 1
            return nextSleeper
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let wakesNow: Bool = lock.withLock {
                    if cancelledSleepers.remove(id) != nil { return true }
                    if !isHeld, due <= elapsed { return true }
                    sleepers[id] = (due, continuation)
                    return false
                }
                if wakesNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
                if let sleeper = sleepers.removeValue(forKey: id) {
                    return sleeper.continuation
                }
                cancelledSleepers.insert(id)
                return nil
            }
            continuation?.resume()
        }
    }
}
