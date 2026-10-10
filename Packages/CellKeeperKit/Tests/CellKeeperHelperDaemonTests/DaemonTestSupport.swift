@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation

/// A daemon clock the test moves by hand. Every uptime reading is a
/// microsecond later than the one before, like a real clock; waits end only
/// when the test advances the clock past them (or their task is cancelled).
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

    func uptime() -> TimeInterval {
        lock.withLock {
            now += 1e-6
            return now
        }
    }

    func sleep(for seconds: TimeInterval) async {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if cancelled.remove(id) != nil || seconds <= 0 { return true }
                    sleepers.append(Sleeper(id: id, deadline: now + seconds, continuation: continuation))
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
/// returns whether it did. Used only to wait for the daemon's own tasks to
/// catch up; the outcome never depends on timing.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
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
/// unless the test holds it back or makes it refuse.
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

    /// Makes `stop()` wait until ``confirmStop(_:)``, as a frontend still
    /// draining its requests would.
    func holdStop() {
        lock.withLock { isHoldingStop = true }
    }

    /// Ends a held `stop()` with `confirmed`; later stops return it at once.
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

    /// Makes `stop()` report that it could not confirm.
    func refuseStop() {
        lock.withLock { stopResult = false }
    }

    /// True while a `stop()` is held.
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

    func start(serving engine: HelperEngine) throws {
        let check = lock.withLock {
            recorded.append(.start)
            return startCheck
        }
        try check?(engine)
    }

    func stop() async -> Bool {
        let result = lock.withLock { () -> Bool? in
            recorded.append(.stop)
            return isHoldingStop ? nil : stopResult
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

    /// Makes the next save wait until ``release()``.
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
        _ = gate?.wait(timeout: .now() + 10)
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
/// as if writing the log were slow.
final class RecordingLog: HelperDaemonLog, @unchecked Sendable {
    struct Line: Equatable {
        var level: HelperLogLevel
        var category: HelperLogCategory
        var message: String
    }

    private let lock = NSLock()
    private var recorded: [Line] = []
    private var gate: DispatchSemaphore?
    private var waitingAtGate = false

    var lines: [Line] {
        lock.withLock { recorded }
    }

    func contains(_ level: HelperLogLevel, _ category: HelperLogCategory, _ fragment: String) -> Bool {
        lines.contains { $0.level == level && $0.category == category && $0.message.contains(fragment) }
    }

    /// Makes the next write wait until ``release()``.
    func block() {
        lock.withLock { gate = DispatchSemaphore(value: 0) }
    }

    /// True while a write waits for ``release()``.
    var isWaiting: Bool {
        lock.withLock { waitingAtGate }
    }

    func release() {
        let gate = lock.withLock {
            defer { self.gate = nil }
            return self.gate
        }
        gate?.signal()
    }

    func write(_ level: HelperLogLevel, _ category: HelperLogCategory, _ message: String) {
        let gate = lock.withLock {
            waitingAtGate = self.gate != nil
            return self.gate
        }
        _ = gate?.wait(timeout: .now() + 10)
        lock.withLock {
            waitingAtGate = false
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
/// hardware call hung.
final class BlockingControl: HelperChargeControl, @unchecked Sendable {
    let simulated: SimulatedChargeControl
    private let lock = NSLock()
    private var gate: DispatchSemaphore?
    private var blockedReads = 0

    init(_ simulated: SimulatedChargeControl = SimulatedChargeControl()) {
        self.simulated = simulated
    }

    /// Makes the next read-back wait until ``release()``.
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
            _ = gate.wait(timeout: .now() + 10)
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
        signals: FakeTerminationSignals = FakeTerminationSignals()
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
            frontend: frontend,
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
    /// the first tick is scheduled) or has exited.
    func run() async -> Task<Int32, Never> {
        let daemon = daemon
        let running = Task { await daemon.run() }
        let clock = clock
        let exits = exits
        let frontend = frontend
        _ = await eventually { (frontend.calls.contains(.start) && clock.waits.contains(HelperDaemon.tickInterval - 0.001...HelperDaemon.tickInterval)) || !exits.statuses.isEmpty }
        return running
    }

    /// A session on the daemon's engine that has said hello.
    func introducedSession() async -> HelperSession {
        let session = await daemon.engine.openSession()
        _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        return session
    }

    /// Sends SIGTERM and returns the status the daemon exits with, when the
    /// engine can confirm defaults at once.
    func terminate(_ running: Task<Int32, Never>) async -> Int32 {
        signals.sendSIGTERM()
        return await running.value
    }
}

extension Array where Element == TimeInterval {
    func contains(_ range: ClosedRange<TimeInterval>) -> Bool {
        contains { range.contains($0) }
    }
}
