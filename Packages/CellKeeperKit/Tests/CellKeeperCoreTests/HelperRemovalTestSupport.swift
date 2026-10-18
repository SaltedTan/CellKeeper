@testable import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

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
    func waitFor(_ entry: String, occurrences: Int = 1, within limit: Duration = testWaitLimit) async -> Bool {
        let expiresAt = SuspendingClock.now.advanced(by: limit)
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
                try? await Task.sleep(until: expiresAt, clock: .suspending)
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

/// How long a bounded wait in these tests waits for what it expects. One
/// that gives up reports it, and the test records an issue (see
/// ``expectLogged(_:_:occurrences:)``), so a test that goes wrong fails
/// instead of hanging the run. The limits here are measured on
/// `SuspendingClock`: time the Mac spends asleep is not a hang.
let testWaitLimit: Duration = .seconds(10)

/// How long a ``Gate`` holds a call the test has not let through, and how
/// long a ``ManualDeadlineClock`` timer waits for the test to move the
/// clock: three times ``testWaitLimit``, because a test here makes up to
/// two bounded waits while it holds a call or a timer waits for it.
let gateLimit: Duration = testWaitLimit * 3

/// Holds whoever waits until the test opens it. A call it still holds after
/// its limit records an issue, which fails the test, and is then let
/// through, so a failing test does not hang the run: a test that goes on
/// past a gate it did not open fails.
final class Gate: @unchecked Sendable {
    private let limit: Duration
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextWaiter = 0

    /// - Parameter limit: for the test of the gate itself; otherwise
    ///   ``gateLimit``.
    init(limit: Duration = gateLimit) {
        self.limit = limit
    }

    /// Returns once the gate is open; or, having recorded an issue, `limit`
    /// after the call. The waiter is registered before its timeout starts,
    /// so the timeout always finds it (or finds it already released).
    func wait() async {
        let expiresAt = SuspendingClock.now.advanced(by: limit)
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
                try? await Task.sleep(until: expiresAt, clock: .suspending)
                self?.expire(id)
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

    /// A waiter the gate still holds at its limit (not one that `open()`
    /// released meanwhile) fails the test, then goes on.
    private func expire(_ id: Int) {
        guard let continuation = lock.withLock({ waiters.removeValue(forKey: id) }) else { return }
        Issue.record("a gate held a call for \(limit) without being opened; the call was let through so that the run goes on")
        continuation.resume()
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

/// Connects to a helper engine in process as ``InProcessHelperTransport``
/// does: the engine is started before it serves a session, and a session it
/// revokes is a closed connection (``InProcessHelperConnection``). Unlike
/// that transport it has no ticker, so the engine is ticked only when a
/// test calls ``HelperEngine/tick()``.
struct UntickedHelperTransport: HelperTransport {
    let engine: HelperEngine
    private let revoked: RevokedSessions

    init(control: any HelperChargeControl, power: any HelperPowerReading, build: Int, uptime: @escaping @Sendable () -> TimeInterval) {
        let revoked = RevokedSessions()
        engine = HelperEngine(control: control, power: power, build: build, uptime: uptime, events: { event in
            if case .sessionRevoked(let id) = event {
                revoked.insert(id)
            }
        })
        self.revoked = revoked
    }

    func connect() async throws -> any HelperConnection {
        await engine.start()
        return InProcessHelperConnection(session: await engine.openSession(), revoked: revoked)
    }
}

/// A helper engine run in process (``UntickedHelperTransport``) on a
/// simulated control, reached through a ``RemovalTestTransport``, with a
/// fake registration; every step goes to one ``CallLog``.
///
/// Only the test ticks the engine. That matters: a tick during shutdown
/// retries a restore that failed, which ends the state a test checks.
struct RemovalRig {
    let clock = TestClock()
    let log = CallLog()
    let control: SimulatedChargeControl
    let helper: UntickedHelperTransport
    let transport: RemovalTestTransport
    let registration: FakeHelperRegistration

    /// - Parameters:
    ///   - chargeControl: replaces the simulated control, for a helper that
    ///     says it controls hardware or one that controls nothing.
    init(registration status: HelperRegistrationStatus = .enabled, chargeControl: (any HelperChargeControl)? = nil) {
        let control = SimulatedChargeControl()
        self.control = control
        let clock = clock
        helper = UntickedHelperTransport(
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

    /// A removal whose deadlines are judged on `clock`, whose timers wake
    /// only when the test advances it. By default the test never advances
    /// it, so in a passing test a call times out only if the test holds it
    /// and advances the clock after seeing it wait. Otherwise a call times
    /// out only once a timer has waited past the clock's limit, which fails
    /// the test.
    func removal(
        helperDeadline: Duration = HelperRemoval.defaultHelperDeadline,
        registrationDeadline: Duration = HelperRemoval.defaultRegistrationDeadline,
        clock: ManualDeadlineClock = ManualDeadlineClock()
    ) -> HelperRemoval {
        HelperRemoval(
            transport: transport,
            registration: registration,
            helperDeadline: helperDeadline,
            registrationDeadline: registrationDeadline,
            clock: clock.removalClock
        )
    }

    /// A removal on the system's clock, for the one smoke test that needs a
    /// real timer. Only the conversation's deadline is short; the
    /// registration keeps its 15 s, far more than its calls, which answer
    /// at once, ever take. A real timer establishes no stage, so such a
    /// test asserts only what holds whichever stage the deadline finds.
    func realTimeRemoval(helperDeadline: Duration) -> HelperRemoval {
        HelperRemoval(
            transport: transport,
            registration: registration,
            helperDeadline: helperDeadline,
            registrationDeadline: HelperRemoval.defaultRegistrationDeadline,
            clock: .system
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
/// advances it (or once the clock has run out, below), and a timer wakes
/// once its time has come, unless the test holds the timers back: then the
/// deadline has passed by the clock, but no timer has woken to check it.
///
/// A timer checks its deadline once before it first waits, so holding the
/// timers keeps one from deciding only once it waits. A test that holds
/// the timers therefore first awaits ``waitForSuspendedTimer(dueIn:)``.
///
/// A timer that waits longer than its limit for the test to move the clock
/// fails the test, and the clock runs out (see ``runOut(ifStillWaiting:)``),
/// so a removal whose evidence never comes ends instead of hanging the test.
final class ManualDeadlineClock: @unchecked Sendable {
    /// How far each reading moves a clock that has run out: more than any
    /// deadline here.
    private static let runOutStep: Duration = .seconds(86_400)

    private let limit: Duration
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var isHeld = false
    private var hasRunOut = false
    private var sleepers: [Int: (due: Duration, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var cancelledSleepers: Set<Int> = []
    private var watchdogs: [Int: Task<Void, Never>] = [:]
    private var nextSleeper = 0
    private var suspensionWaiters: [Int: (due: Duration, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var suspensionTimeouts: [Int: Task<Void, Never>] = [:]
    private var nextSuspensionWaiter = 0

    /// - Parameter limit: how long a timer waits for the test to move the
    ///   clock before the clock runs out; for the test of the clock itself,
    ///   otherwise ``gateLimit``.
    init(limit: Duration = gateLimit) {
        self.limit = limit
    }

    var removalClock: RemovalClock {
        RemovalClock(now: { self.now() }, wake: { await self.wake(at: $0) })
    }

    func now() -> ContinuousClock.Instant {
        lock.withLock {
            if hasRunOut {
                elapsed += Self.runOutStep
            }
            return origin.advanced(by: elapsed)
        }
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

    /// Returns true once a timer due `duration` from now (by this clock) is
    /// suspended in its wake-up, where it checks nothing until the clock
    /// reaches its deadline with the timers not held; false after
    /// ``testWaitLimit``. The waiter is registered before its timeout
    /// starts, so the timeout always finds it.
    func waitForSuspendedTimer(dueIn duration: Duration) async -> Bool {
        let expiresAt = SuspendingClock.now.advanced(by: testWaitLimit)
        let (id, due) = lock.withLock {
            nextSuspensionWaiter += 1
            return (nextSuspensionWaiter, elapsed + duration)
        }
        let isSuspended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let isAlreadySuspended = lock.withLock {
                if sleepers.values.contains(where: { $0.due == due }) { return true }
                suspensionWaiters[id] = (due, continuation)
                return false
            }
            if isAlreadySuspended {
                continuation.resume(returning: true)
                return
            }
            let timeout = Task { [weak self] in
                try? await Task.sleep(until: expiresAt, clock: .suspending)
                self?.giveUpWaitingForSuspension(id)
            }
            let isWaiting = lock.withLock {
                guard suspensionWaiters[id] != nil else { return false }
                suspensionTimeouts[id] = timeout
                return true
            }
            if !isWaiting {
                timeout.cancel()
            }
        }
        lock.withLock { suspensionTimeouts.removeValue(forKey: id) }?.cancel()
        return isSuspended
    }

    private func giveUpWaitingForSuspension(_ id: Int) {
        lock.withLock { suspensionWaiters.removeValue(forKey: id) }?.continuation.resume(returning: false)
    }

    private func takeDue() -> [CheckedContinuation<Void, Never>] {
        let ready = sleepers.filter { $0.value.due <= elapsed }
        for id in ready.keys {
            sleepers.removeValue(forKey: id)
        }
        return ready.values.map(\.continuation)
    }

    /// A timer that has waited `limit` for the test to move the clock fails
    /// the test, and the clock runs out: from then on every reading is a day
    /// after the one before and every timer wakes at once. A deadline, also
    /// one set after that, has then passed whenever it is checked, so the
    /// removal ends.
    private func runOut(ifStillWaiting id: Int) {
        let woken: [CheckedContinuation<Void, Never>]? = lock.withLock {
            guard sleepers[id] != nil else { return nil }
            hasRunOut = true
            defer { sleepers = [:] }
            return sleepers.values.map(\.continuation)
        }
        guard let woken else { return }
        Issue.record("a deadline's timer waited \(limit) for the test to move the clock; the clock ran out so that the removal ends")
        for continuation in woken {
            continuation.resume()
        }
    }

    /// Returns once the clock has reached `instant` and timers are not
    /// held, or when the calling task is cancelled, or once the clock has
    /// run out.
    private func wake(at instant: ContinuousClock.Instant) async {
        let due = origin.duration(to: instant)
        let watchdogExpiry = SuspendingClock.now.advanced(by: limit)
        let id = lock.withLock {
            nextSleeper += 1
            return nextSleeper
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (wakesNow, suspended): (Bool, [CheckedContinuation<Bool, Never>]) = lock.withLock {
                    if cancelledSleepers.remove(id) != nil { return (true, []) }
                    if hasRunOut || (!isHeld && due <= elapsed) { return (true, []) }
                    sleepers[id] = (due, continuation)
                    let ids = suspensionWaiters.filter { $0.value.due == due }.map(\.key)
                    return (false, ids.compactMap { suspensionWaiters.removeValue(forKey: $0)?.continuation })
                }
                if wakesNow {
                    continuation.resume()
                } else {
                    // Registered after the sleeper, so it always finds it
                    // (or finds it already woken).
                    let watchdog = Task { [weak self] in
                        try? await Task.sleep(until: watchdogExpiry, clock: .suspending)
                        self?.runOut(ifStillWaiting: id)
                    }
                    let isWaiting = lock.withLock {
                        guard sleepers[id] != nil else { return false }
                        watchdogs[id] = watchdog
                        return true
                    }
                    if !isWaiting {
                        watchdog.cancel()
                    }
                }
                for waiter in suspended {
                    waiter.resume(returning: true)
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
        lock.withLock { watchdogs.removeValue(forKey: id) }?.cancel()
    }
}

/// A removal whose deadlines are judged on a ``ManualDeadlineClock`` the
/// test never advances, so no call times out unless a timer waits past the
/// clock's limit, which fails the test: for tests that hold nothing and
/// must not depend on how fast the scheduler runs.
func removalThatNeverTimesOut(transport: any HelperTransport, registration: any HelperRegistration) -> HelperRemoval {
    HelperRemoval(
        transport: transport,
        registration: registration,
        helperDeadline: HelperRemoval.defaultHelperDeadline,
        registrationDeadline: HelperRemoval.defaultRegistrationDeadline,
        clock: ManualDeadlineClock().removalClock
    )
}
