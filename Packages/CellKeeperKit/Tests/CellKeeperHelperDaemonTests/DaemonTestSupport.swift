@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

/// A daemon clock the test moves by hand. Every uptime reading is a
/// microsecond later than the one before, like a real clock; waits end only
/// when the test advances the clock past them (or their task is cancelled).
/// A test can also run something as the next wait starts, for example to
/// let time pass as if that wait's task had been scheduled late.
final class ManualClock: HelperDaemonClock, @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var now: TimeInterval = 50_000
    private var sleepers: [Sleeper] = []
    private var nextID = 0
    /// Waits cancelled before they were registered.
    private var cancelled: Set<Int> = []
    private var beforeSleep: (@Sendable () -> Void)?
    private var sleepGate: Gate?

    /// Runs `hook` at the start of the next wait, before it is registered.
    func beforeNextSleep(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { beforeSleep = hook }
    }

    /// Makes the next wait start only once `gate` opens, as a task scheduled
    /// late would. The waiting task is suspended, not blocked.
    func holdNextSleep(until gate: Gate) {
        lock.withLock { sleepGate = gate }
    }

    func uptime() -> TimeInterval {
        lock.withLock {
            now += 1e-6
            return now
        }
    }

    func sleep(until deadline: TimeInterval) async {
        await runHooks()
        await register(deadline)
    }

    /// Runs the hooks first, as if this task had started late, and only then
    /// computes the deadline: a caller that captured a duration earlier
    /// loses nothing to the delay and ends late.
    func sleep(for seconds: TimeInterval) async {
        await runHooks()
        await register(uptime() + seconds)
    }

    private func runHooks() async {
        let (hook, gate) = lock.withLock { () -> ((@Sendable () -> Void)?, Gate?) in
            defer {
                beforeSleep = nil
                sleepGate = nil
            }
            return (beforeSleep, sleepGate)
        }
        hook?()
        await gate?.wait()
    }

    private func register(_ deadline: TimeInterval) async {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if cancelled.remove(id) != nil || deadline <= now { return true }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                if let index = sleepers.firstIndex(where: { $0.id == id }) {
                    return sleepers.remove(at: index)
                }
                cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume()
        }
    }

    /// Moves the clock forward and ends every wait that is due, earliest
    /// first.
    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [Sleeper] in
            now += seconds
            let ready = sleepers.filter { $0.deadline <= now }.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            sleepers.removeAll { $0.deadline <= now }
            return ready
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// The waits in progress, by how long they still have to run.
    var waits: [TimeInterval] {
        lock.withLock { sleepers.map { $0.deadline - now }.sorted() }
    }
}

/// Waits, in real time and for at most 10 s, until `condition` holds, and
/// returns whether it did, which the caller checks: a wait that ran out must
/// fail the test, not let it go on as if the condition held. Used to wait
/// for the daemon's own tasks to catch up, which takes far less than that.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// Thrown by ``bounded(within:releasing:_:)`` when its operation has not
/// returned in time.
struct WaitExpired: Error, CustomStringConvertible {
    let seconds: Double

    var description: String {
        "gave up waiting after \(seconds) s"
    }
}

/// Returns what `operation` returns, for an operation awaited while the test
/// holds a call that, if the behaviour under test is right, the operation
/// does not wait for. The operation runs in a task of its own. If it has not
/// returned `seconds` after this is called, this records an issue, calls
/// `release`, which ends the hold, and throws ``WaitExpired`` at once,
/// without waiting for the operation any longer: an operation that waits for
/// the held call, or for anything else, fails the test in bounded time
/// instead of hanging it. The caller's cleanup belongs in `defer`s, which
/// run when this throws.
///
/// The operation's task is cancelled then, but may run on, even after the
/// test has returned, until what it waits for ends (`release` should end
/// it). So an operation keeps alive what it uses by capturing it, records
/// no issue, and uses nothing that another test uses: each caller's
/// operation only awaits its own test's tasks, client, engine or daemon.
func bounded<Value: Sendable>(
    within seconds: Double = 10,
    releasing release: @escaping @Sendable () -> Void,
    _ operation: @escaping @Sendable () async -> Value
) async throws -> Value {
    let wait = BoundedWait<Value>()
    return try await withCheckedThrowingContinuation { continuation in
        wait.begin(continuation)
        let work = Task {
            wait.finish(returning: await operation())
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            wait.expire(after: seconds) {
                Issue.record("Gave up after \(seconds) s waiting for something that should not wait for the call the test holds; released the call.")
                release()
            }
        }
        wait.adopt([work, timer])
    }
}

/// The two sides of ``bounded(within:releasing:_:)``: the first to finish
/// resumes the caller, and both tasks are then cancelled. The operation's
/// task may run on; nothing waits for it.
private final class BoundedWait<Value: Sendable>: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`.

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []

    func begin(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func adopt(_ tasks: [Task<Void, Never>]) {
        let isFinished = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            self.tasks = tasks
            return false
        }
        if isFinished {
            for task in tasks {
                task.cancel()
            }
        }
    }

    func finish(returning value: Value) {
        guard let (continuation, tasks) = take() else { return }
        for task in tasks {
            task.cancel()
        }
        continuation.resume(returning: value)
    }

    /// Runs `giveUp` and throws to the caller, unless the operation has
    /// returned.
    func expire(after seconds: Double, _ giveUp: () -> Void) {
        guard let (continuation, tasks) = take() else { return }
        giveUp()
        for task in tasks {
            task.cancel()
        }
        continuation.resume(throwing: WaitExpired(seconds: seconds))
    }

    /// The caller's continuation and both tasks, for the first side to
    /// finish; nil for the other.
    private func take() -> (CheckedContinuation<Value, any Error>, [Task<Void, Never>])? {
        lock.withLock {
            guard let continuation else { return nil }
            self.continuation = nil
            defer { tasks = [] }
            return (continuation, tasks)
        }
    }
}

/// A power state that allows every control, stamped with the clock's time.
final class StubPower: HelperPowerReading, @unchecked Sendable {
    private let clock: ManualClock

    init(clock: ManualClock) {
        self.clock = clock
    }

    func latestPowerState() -> HelperPowerState? {
        HelperPowerState(stateOfCharge: 60, isOnExternalPower: true, isAdapterPresent: true, isThermalPressureHigh: false, readAtUptime: clock.uptime())
    }
}

/// Records what the daemon does to its frontend. Its stop confirms at once
/// unless the test holds it back, makes it refuse, or makes it wait for its
/// deadline.
final class FakeFrontend: HelperFrontend, @unchecked Sendable {
    enum Call: Equatable {
        case start
        case stop
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var startCheck: (@Sendable (HelperEngine) throws -> Void)?
    private var isHoldingStop = false
    private var heldStops: [CheckedContinuation<Bool, Never>] = []
    private var stopResult = true
    private var handled: [HelperEvent] = []
    /// What a stop returns once its deadline has passed; nil: it does not
    /// wait for its deadline.
    private var resultAtDeadline: Bool?
    private var deadlines: [TimeInterval] = []
    private var returned: [Bool] = []

    /// The deadline (uptime) of every stop, in order.
    var stopDeadlines: [TimeInterval] {
        lock.withLock { deadlines }
    }

    /// What every stop that has returned returned, in order.
    var stopResults: [Bool] {
        lock.withLock { returned }
    }

    /// Makes `stop(by:)` wait until its deadline has passed and then return
    /// `result`, as a frontend that cannot drain would (`false`), or one
    /// whose confirmation comes too late (`true`).
    func holdStopUntilDeadline(thenReturn result: Bool) {
        lock.withLock { resultAtDeadline = result }
    }

    /// The engine's events the daemon passed on.
    var handledEvents: [HelperEvent] {
        lock.withLock { handled }
    }

    func handle(_ event: HelperEvent) {
        lock.withLock { handled.append(event) }
    }

    /// Makes `stop(by:)` wait until ``confirmStop(_:)``, as a frontend still
    /// draining its requests would.
    func holdStop() {
        lock.withLock { isHoldingStop = true }
    }

    /// Ends a held `stop(by:)` with `confirmed`; later stops return it at once.
    func confirmStop(_ confirmed: Bool = true) {
        let held = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            isHoldingStop = false
            stopResult = confirmed
            defer { heldStops = [] }
            return heldStops
        }
        for continuation in held {
            continuation.resume(returning: confirmed)
        }
    }

    /// Makes `stop(by:)` report that it could not confirm.
    func refuseStop() {
        lock.withLock { stopResult = false }
    }

    /// True while a `stop(by:)` is held.
    var isStopHeld: Bool {
        lock.withLock { !heldStops.isEmpty }
    }

    /// Runs `check` inside `start(serving:)`; it may throw to refuse.
    func onStart(_ check: @escaping @Sendable (HelperEngine) throws -> Void) {
        lock.withLock { startCheck = check }
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func start(serving engine: HelperEngine, log: any HelperDaemonLog) throws {
        let check = lock.withLock {
            recorded.append(.start)
            return startCheck
        }
        try check?(engine)
    }

    func stop(by deadline: HelperDaemonDeadline) async -> Bool {
        let result = await stopResult(by: deadline)
        lock.withLock { returned.append(result) }
        return result
    }

    private func stopResult(by deadline: HelperDaemonDeadline) async -> Bool {
        let (result, atDeadline) = lock.withLock { () -> (Bool?, Bool?) in
            recorded.append(.stop)
            deadlines.append(deadline.uptime)
            if let resultAtDeadline { return (nil, resultAtDeadline) }
            return (isHoldingStop ? nil : stopResult, nil)
        }
        if let atDeadline {
            await deadline.wait()
            return atDeadline
        }
        if let result {
            return result
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumeNow = lock.withLock { () -> Bool? in
                guard isHoldingStop else { return stopResult }
                heldStops.append(continuation)
                return nil
            }
            if let resumeNow {
                continuation.resume(returning: resumeNow)
            }
        }
    }
}

/// Delivers sleep and wake when the test says so.
final class FakeSleepNotifications: SleepNotifications, @unchecked Sendable {
    struct RegistrationFailed: Error {}

    private let lock = NSLock()
    private var handler: (@Sendable (SleepEvent) -> Void)?
    private var failsToStart = false
    private(set) var isStopped = false

    func failToStart() {
        lock.withLock { failsToStart = true }
    }

    var isStarted: Bool {
        lock.withLock { handler != nil }
    }

    func start(_ handler: @escaping @Sendable (SleepEvent) -> Void) throws {
        try lock.withLock {
            if failsToStart { throw RegistrationFailed() }
            self.handler = handler
        }
    }

    func stop() {
        lock.withLock {
            handler = nil
            isStopped = true
        }
    }

    /// Announces sleep; `acknowledged` runs when the daemon acknowledges.
    func announceSleep(acknowledged: @escaping @Sendable () -> Void) {
        let handler = lock.withLock { self.handler }
        handler?(.willSleep(acknowledge: acknowledged))
    }

    func wake() {
        let handler = lock.withLock { self.handler }
        handler?(.didWake)
    }
}

/// Sends SIGTERM when the test says so.
final class FakeTerminationSignals: TerminationSignals, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    var isStarted: Bool {
        lock.withLock { handler != nil }
    }

    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func sendSIGTERM() {
        let handler = lock.withLock { self.handler }
        handler?()
    }
}

/// The activation history in memory, in the file's format.
final class InMemoryHistoryStore: ActivationHistoryStore, @unchecked Sendable {
    struct SaveFailed: Error {}

    private let lock = NSLock()
    private var data: Data?
    private var saves = 0
    private var failingSaves = 0
    private var gate: DispatchSemaphore?
    private var loadHook: (@Sendable () -> Void)?

    /// Runs `hook` at the start of every load.
    func onLoad(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { loadHook = hook }
    }

    var saveCount: Int {
        lock.withLock { saves }
    }

    /// What `load` will find for `boot`.
    func saved(boot: BootIdentifier, now: TimeInterval) -> ActivationHistoryLoad {
        load(boot: boot, now: now)
    }

    func preload(_ records: [HelperActivationRecord], boot: BootIdentifier) throws {
        let data = try ActivationHistoryFormat.encode(records, boot: boot)
        lock.withLock { self.data = data }
    }

    func failNextSaves(_ count: Int) {
        lock.withLock { failingSaves += count }
    }

    /// Makes the next save wait until ``release()``, however long that takes.
    func blockSaves() {
        lock.withLock { gate = DispatchSemaphore(value: 0) }
    }

    func release() {
        let gate = lock.withLock {
            defer { self.gate = nil }
            return self.gate
        }
        gate?.signal()
    }

    func load(boot: BootIdentifier, now: TimeInterval) -> ActivationHistoryLoad {
        lock.withLock { loadHook }?()
        guard let data = lock.withLock({ self.data }) else { return .missing }
        return ActivationHistoryFormat.decode(data, boot: boot, now: now)
    }

    func save(_ records: [HelperActivationRecord], boot: BootIdentifier) throws {
        let gate = lock.withLock { self.gate }
        gate?.wait()
        let data = try ActivationHistoryFormat.encode(records, boot: boot)
        try lock.withLock {
            if failingSaves > 0 {
                failingSaves -= 1
                throw SaveFailed()
            }
            saves += 1
            self.data = data
        }
    }
}

/// Collects the daemon's log lines. The test can hold the next write back,
/// as if writing the log were slow, until it releases it.
final class RecordingLog: HelperDaemonLog, @unchecked Sendable {
    struct Line: Equatable {
        var level: HelperLogLevel
        var category: HelperLogCategory
        var message: String
    }

    private let lock = NSLock()
    private var recorded: [Line] = []
    private var gate: DispatchSemaphore?
    /// Only a write containing this waits at the gate; nil: the next write.
    private var gatedFragment: String?
    /// How long a write waits at the gate before it goes through anyway;
    /// nil: until ``release()``.
    private var gateLimit: TimeInterval?
    /// Writes that took the gate and have not gone through yet. The daemon
    /// writes from one queue, so there is at most one, unless it writes
    /// from elsewhere too; ``release()`` lets every one through.
    private var writesAtGate = 0

    var lines: [Line] {
        lock.withLock { recorded }
    }

    func contains(_ level: HelperLogLevel, _ category: HelperLogCategory, _ fragment: String) -> Bool {
        lines.contains { $0.level == level && $0.category == category && $0.message.contains(fragment) }
    }

    /// Makes the next write wait until ``release()``, however long that
    /// takes, or for `limit` at most if one is given.
    func block(limit: TimeInterval? = nil) {
        lock.withLock {
            gate = DispatchSemaphore(value: 0)
            gatedFragment = nil
            gateLimit = limit
        }
    }

    /// Makes the first write that contains `fragment` wait until
    /// ``release()``, however long that takes; the writes before it go
    /// through.
    func block(whenMessageContains fragment: String) {
        lock.withLock {
            gate = DispatchSemaphore(value: 0)
            gatedFragment = fragment
            gateLimit = nil
        }
    }

    /// True while a write waits for ``release()``.
    var isWaiting: Bool {
        lock.withLock { writesAtGate > 0 }
    }

    /// Lets every write waiting at the gate through, and stops holding new
    /// ones.
    func release() {
        let (gate, waiting) = lock.withLock { () -> (DispatchSemaphore?, Int) in
            defer { self.gate = nil }
            return (self.gate, writesAtGate)
        }
        for _ in 0..<waiting {
            gate?.signal()
        }
    }

    func write(_ level: HelperLogLevel, _ category: HelperLogCategory, _ message: String) {
        let (gate, limit) = lock.withLock { () -> (DispatchSemaphore?, TimeInterval?) in
            guard let held = self.gate, gatedFragment.map({ message.contains($0) }) ?? true else { return (nil, nil) }
            writesAtGate += 1
            return (held, gateLimit)
        }
        if let gate {
            if let limit {
                _ = gate.wait(timeout: .now() + limit)
            } else {
                gate.wait()
            }
        }
        lock.withLock {
            if gate != nil {
                writesAtGate -= 1
            }
            recorded.append(Line(level: level, category: category, message: message))
        }
    }
}

/// Records the statuses the daemon exits with.
final class ExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []

    var statuses: [Int32] {
        lock.withLock { recorded }
    }

    func record(_ status: Int32) {
        lock.withLock { recorded.append(status) }
    }
}

/// A simulated control whose next read-back can be held, as if the
/// hardware call hung, until the test releases it.
final class BlockingControl: HelperChargeControl, @unchecked Sendable {
    let simulated: SimulatedChargeControl
    private let lock = NSLock()
    private var gate: DispatchSemaphore?
    private var blockedReads = 0

    init(_ simulated: SimulatedChargeControl = SimulatedChargeControl()) {
        self.simulated = simulated
    }

    /// Makes the next read-back wait until ``release()``, however long that
    /// takes.
    func holdNextReadBack() {
        lock.withLock { gate = DispatchSemaphore(value: 0) }
    }

    /// True while a read-back waits for ``release()``.
    var isHolding: Bool {
        lock.withLock { blockedReads > 0 }
    }

    func release() {
        let gate = lock.withLock {
            defer { self.gate = nil }
            return self.gate
        }
        gate?.signal()
    }

    func probe() -> HelperProbe {
        simulated.probe()
    }

    func apply(_ control: HelperControl, active: Bool) throws {
        try simulated.apply(control, active: active)
    }

    func readBack() throws -> Set<HelperControl> {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            guard let held = self.gate else { return nil }
            blockedReads += 1
            return held
        }
        if let gate {
            gate.wait()
            lock.withLock { blockedReads -= 1 }
        }
        return try simulated.readBack()
    }

    func restoreDefaults() throws {
        try simulated.restoreDefaults()
    }
}

extension BootIdentifier {
    static let testBoot = BootIdentifier(sessionUUID: UUID(uuidString: "6F2B1C3E-0A4D-4E5F-9A8B-1C2D3E4F5A6B")!)
    static let otherBoot = BootIdentifier(sessionUUID: UUID(uuidString: "0D9E8F7A-6B5C-4D3E-8F1A-2B3C4D5E6F70")!)
}

/// A daemon on fakes: a simulated control, a stub power reading, a manual
/// clock, and recorded log, exits, frontend, sleep and signals.
struct DaemonHarness {
    let clock: ManualClock
    let control: any HelperChargeControl
    /// The frontend the daemon uses, unless another one is given.
    let frontend = FakeFrontend()
    let sleep = FakeSleepNotifications()
    let signals: FakeTerminationSignals
    let store: InMemoryHistoryStore
    let log = RecordingLog()
    let exits = ExitRecorder()
    let daemon: HelperDaemon

    init(
        control: any HelperChargeControl = SimulatedChargeControl(),
        store: InMemoryHistoryStore = InMemoryHistoryStore(),
        boot: BootIdentifier? = .testBoot,
        clock: ManualClock = ManualClock(),
        signals: FakeTerminationSignals = FakeTerminationSignals(),
        frontend customFrontend: (any HelperFrontend)? = nil
    ) {
        self.clock = clock
        self.control = control
        self.store = store
        self.signals = signals
        let exits = exits
        let environment = HelperDaemonEnvironment(
            control: control,
            power: StubPower(clock: clock),
            clock: clock,
            build: 7,
            frontend: customFrontend ?? frontend,
            sleepNotifications: sleep,
            terminationSignals: signals,
            historyStore: store,
            bootIdentifier: boot,
            log: log,
            exit: { exits.record($0) }
        )
        daemon = HelperDaemon(environment: environment)
    }

    /// Runs the daemon and waits until it serves (the frontend started and
    /// the first tick is scheduled) or has exited; throws, failing the test,
    /// if it has done neither within `eventually`'s bound.
    func run() async throws -> Task<Int32, Never> {
        let daemon = daemon
        let running = Task { await daemon.run() }
        let clock = clock
        let exits = exits
        let frontend = frontend
        let settled = await eventually { (frontend.calls.contains(.start) && clock.waits.contains(HelperDaemon.tickInterval - 0.001...HelperDaemon.tickInterval)) || !exits.statuses.isEmpty }
        try #require(settled, "the daemon neither served nor exited")
        return running
    }

    /// A session on the daemon's engine that has said hello.
    func introducedSession() async -> HelperSession {
        let session = await daemon.engine.openSession()
        _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        return session
    }

    /// What `running`, a task running this daemon's `run()`, returns; see
    /// ``daemonExitStatus(of:clock:)``.
    func exitStatus(of running: Task<Int32, Never>) async -> Int32? {
        await daemonExitStatus(of: running, clock: clock)
    }

    /// Sends SIGTERM and returns the status the daemon exits with, when the
    /// engine can confirm defaults at once; see ``exitStatus(of:)``.
    func terminate(_ running: Task<Int32, Never>) async -> Int32? {
        signals.sendSIGTERM()
        return await exitStatus(of: running)
    }
}

/// What `running`, a task running a daemon's `run()`, returns, once the test
/// expects the daemon to exit without more of `clock`'s time. Every wait is
/// bounded, and the expiry of each records an issue:
/// 1. Waits up to `eventually`'s 10 s for it to return.
/// 2. Then moves `clock` on, a second at a time, for a minute of the
///    daemon's time: a shutdown that has begun ends by its deadline on that
///    clock. It waits up to 10 s more.
/// 3. Then returns nil, and the test goes on without waiting for it.
///
/// So a daemon that needs more of its time than the test gave it, or that
/// does not exit, fails the test instead of hanging it. No wait here joins
/// `running`: a task of its own waits for it and only stores what it
/// returns, which these waits poll for. That task may run on after the test
/// has returned, holding nothing but the daemon's task and that value.
func daemonExitStatus(of running: Task<Int32, Never>, clock: ManualClock) async -> Int32? {
    let status = ReturnedStatus()
    Task { status.set(await running.value) }
    if await eventually({ status.value != nil }) {
        return status.value
    }
    Issue.record("The daemon had not exited 10 s after the test expected it to; moving its clock on.")
    for _ in 0..<60 where status.value == nil {
        clock.advance(by: 1)
        try? await Task.sleep(for: .milliseconds(20))
    }
    if await eventually({ status.value != nil }) {
        return status.value
    }
    Issue.record("The daemon had not exited after another minute of its time; no longer waiting for it.")
    return nil
}

/// The status a daemon's `run()` returned, set by the task that waits for
/// it.
private final class ReturnedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var returned: Int32?

    var value: Int32? {
        lock.withLock { returned }
    }

    func set(_ status: Int32) {
        lock.withLock { returned = status }
    }
}

extension Array where Element == TimeInterval {
    func contains(_ range: ClosedRange<TimeInterval>) -> Bool {
        contains { range.contains($0) }
    }
}

/// An operation's end, opened by the test.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let openNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if openNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting {
            waiter.resume()
        }
    }
}

@Suite("Test support: bounded waits")
struct BoundedWaitTests {
    @Test("A bounded wait that runs out records an issue, releases the hold and throws without waiting for its operation, which ends once what it waits for does")
    func expiry() async {
        let never = Gate()
        let released = Flag()
        let operationReturned = Flag()
        let gaveUp = Flag()
        await withKnownIssue("the bound records an issue when it runs out") {
            do {
                try await bounded(within: 0.05, releasing: { released.set(true) }) {
                    await never.wait()
                    operationReturned.set(true)
                }
            } catch is WaitExpired {
                gaveUp.set(true)
            }
        }
        #expect(gaveUp.value)
        #expect(released.value)
        #expect(!operationReturned.value)
        // Left running, the operation ends once what it waits for does,
        // before this test returns.
        never.open()
        let ended = await eventually { operationReturned.value }
        #expect(ended)
    }

    @Test("A bounded wait returns what its operation returns")
    func value() async throws {
        let value = try await bounded(releasing: {}) { 42 }
        #expect(value == 42)
    }
}
