import CellKeeperCore
import Foundation
import Testing

/// Waits for `body` for at most `seconds`, and records an issue naming
/// `what` if it has not finished by then. Returns whether it finished. The
/// time only bounds a failure: a passing outcome never depends on how fast
/// anything runs. See ``boundedValue(_:seconds:expiry:_:)``.
@discardableResult
func waitBounded(_ what: String, seconds: Double = 10, expiry: (@Sendable () async -> Void)? = nil, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let finished = await boundedValue(what, seconds: seconds, expiry: expiry) { () async -> Bool in
        await body()
        return true
    }
    return finished ?? false
}

/// What `body` returns, if it returns within `seconds`, or before `expiry`
/// returns when one is given (a test of the bound itself). Otherwise it
/// records an issue naming `what`, cancels `body`, and waits a second bound
/// of `seconds` for it to stop, recording another issue if it has not; it
/// then returns nil. A `body` that ignored cancellation may still be running
/// after that.
///
/// With `expiry`, a watchdog of `seconds` still bounds the wait: if the
/// expiry has not come by then, it records an issue of its own (which does
/// not say "Timed out", so a test expecting the expiry fails) and ends the
/// wait as the expiry would. Neither fires once `body` has finished.
func boundedValue<Value: Sendable>(_ what: String, seconds: Double = 10, expiry: (@Sendable () async -> Void)? = nil, _ body: @escaping @Sendable () async -> Value) async -> Value? {
    let race = FirstOutcome<Value?>()
    let work = Task {
        let value = await body()
        race.settle(value)
    }
    let timer = Task {
        if let expiry {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await expiry()
                    return true
                }
                // The watchdog: false only if its time ran out.
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        return false
                    } catch {
                        return true
                    }
                }
                let isExpiry = await group.next() ?? true
                group.cancelAll()
                if !isExpiry, !Task.isCancelled {
                    Issue.record("The expiry for \(what) never came within \(seconds) s")
                }
                // Before the group waits for an expiry that may never
                // return, so the caller is never held up by it.
                race.settle(nil)
            }
            return
        }
        do {
            try await Task.sleep(for: .seconds(seconds))
            race.settle(nil)
        } catch {
            // Cancelled: the work finished first.
        }
    }
    let value = await race.value()
    timer.cancel()
    if value == nil {
        Issue.record(expiry == nil ? "Timed out after \(seconds) s waiting for \(what)" : "Timed out waiting for \(what)")
        work.cancel()
        let stopped = FirstOutcome<Bool>()
        Task {
            await work.value
            stopped.settle(true)
        }
        let stopTimer = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
                stopped.settle(false)
            } catch {}
        }
        if await !stopped.value() {
            Issue.record("Waiting for \(what) did not stop when cancelled")
        }
        stopTimer.cancel()
    }
    return value
}

/// Polls `condition` until it holds, and stops when cancelled; use inside
/// ``waitBounded(_:seconds:expiry:_:)``.
func until(_ condition: @escaping @Sendable () -> Bool) async {
    while !condition() {
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            return
        }
    }
}

/// The first of several outcomes, whichever settles first.
final class FirstOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Value?
    private var isSettled = false
    private var waiter: CheckedContinuation<Value, Never>?

    func settle(_ value: Value) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            guard !isSettled else { return nil }
            isSettled = true
            outcome = value
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: value)
    }

    func value() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            // `outcome` is an optional of `Value`, which may itself be
            // optional; `isSettled` says whether it holds a result.
            let (isDone, stored) = lock.withLock { () -> (Bool, Value?) in
                if isSettled { return (true, outcome) }
                waiter = continuation
                return (false, nil)
            }
            if isDone, let stored {
                continuation.resume(returning: stored)
            }
        }
    }
}

/// A one-time signal, fired from any thread.
final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isFired: Bool {
        lock.withLock { isSet }
    }

    func fire() {
        let waiting = lock.withLock {
            isSet = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// Unbounded; use inside ``waitBounded(_:seconds:expiry:_:)``.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isDone = lock.withLock { () -> Bool in
                if isSet { return true }
                waiters.append(continuation)
                return false
            }
            if isDone {
                continuation.resume()
            }
        }
    }
}

/// What happened, in order, from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    var all: [String] {
        lock.withLock { entries }
    }
}

/// A backend that reports real, experimental control of the charging modes,
/// for tests of what is said about a backend that changes the Mac's
/// charging. It touches nothing.
actor HardwareLikeBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "test-hardware", displayName: "Test hardware", summary: "Pretends to control charging, for tests.")

    private var mode: ChargeControlMode = .normal
    private var pendingFailures = 0
    private var pendingReadFailures = 0
    private var failsReadAfterNextRequest = false

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .experimental, supportedModes: ChargeControlMode.chargingModes)
    }

    func currentMode() throws -> ChargeControlMode? {
        if pendingReadFailures > 0 {
            pendingReadFailures -= 1
            throw BackendError.operationFailed("injected read failure")
        }
        return mode
    }

    func setMode(_ newMode: ChargeControlMode) throws -> ControlOutcome {
        if pendingFailures > 0 {
            pendingFailures -= 1
            throw BackendError.operationFailed("injected failure")
        }
        if failsReadAfterNextRequest {
            failsReadAfterNextRequest = false
            pendingReadFailures += 1
        }
        defer { mode = newMode }
        return newMode == mode ? .unchanged : .applied
    }

    /// Makes the next `count` requests fail without changing anything.
    func failNextRequests(_ count: Int) {
        pendingFailures += count
    }

    /// Makes the next request take effect, and the read that confirms it
    /// fail.
    func failReadAfterNextRequest() {
        failsReadAfterNextRequest = true
    }
}

/// A simulated backend that reports, with every read, a problem it waits
/// for someone to acknowledge (as the helper does after its own failure),
/// so the controller faults on its first read. Clearing the fault does not
/// end the wait unless ``stopWaiting()`` was called.
actor AcknowledgingBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "test-acknowledging", displayName: "Test acknowledging", summary: "Waits for an acknowledgement, for tests.")

    private var isWaiting = true

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)
    }

    func currentMode() -> ChargeControlMode? {
        .normal
    }

    func setMode(_ mode: ChargeControlMode) -> ControlOutcome {
        .simulated
    }

    func reportedModeOrigin() -> ReportedModeOrigin? {
        isWaiting ? .needsAcknowledgement("test problem awaiting acknowledgement") : nil
    }

    func stopWaiting() {
        isWaiting = false
    }
}

/// Drives a controller and hands every status to a planner, in order, as the
/// app does. Each step moves the clock first, so every reading is distinct.
final class PlannerScenario {
    let clock: TestClock
    let telemetry: StubTelemetry
    let controller: ChargeController
    var planner = NotificationPlanner()
    /// Whether the planner may deliver (the user opted in and macOS shows
    /// notifications).
    var isDelivering = true
    /// Every notification planned so far.
    private(set) var all: [PlannedNotification] = []

    /// - Parameter clock: shared with a backend that needs one.
    init(
        clock: TestClock = TestClock(),
        percent: Int,
        temperature: Double? = 30,
        backend: any ChargingBackend = MockChargingBackend(),
        settings: ChargingSettings = .default,
        adoptionMarkerStore: (any OwnershipRecordStore)? = nil
    ) {
        self.clock = clock
        telemetry = StubTelemetry(snapshot(percent: percent, temperature: temperature), clock: clock)
        controller = ChargeController(
            telemetry: telemetry,
            backend: backend,
            settings: settings,
            adoptionMarkerStore: adoptionMarkerStore,
            now: { clock.now },
            uptime: { clock.uptime }
        )
    }

    /// Sets the next reading. `sourceAge`: how old the driver's own update
    /// time is, now; a reading of more than ``ChargingPolicy/maximumSourceAge``
    /// is stale. `present`: false for a reading with no battery.
    func read(_ percent: Int, source: PowerSource = .externalPower, charging: Bool? = nil, fullyCharged: Bool? = false, temperature: Double? = 30, sourceAge: TimeInterval? = nil, present: Bool = true) async {
        let sourceTimestamp = sourceAge.map { clock.now.addingTimeInterval(-$0) }
        await telemetry.set(snapshot(percent: percent, source: source, charging: charging, fullyCharged: fullyCharged, temperature: temperature, sourceTimestamp: sourceTimestamp, present: present))
    }

    func feed(_ status: ControllerStatus, _ trigger: EvaluationTrigger) -> [PlannedNotification] {
        let planned = planner.plan(status, trigger: trigger, uptime: clock.uptime, isDelivering: isDelivering)
        all += planned
        return planned
    }

    @discardableResult
    func evaluate(_ trigger: EvaluationTrigger = .periodic, after seconds: TimeInterval = 60) async -> [PlannedNotification] {
        clock.advance(by: seconds)
        let status = await controller.evaluate(trigger)
        return feed(status, trigger)
    }

    @discardableResult
    func apply(_ settings: ChargingSettings, after seconds: TimeInterval = 60) async throws -> [PlannedNotification] {
        clock.advance(by: seconds)
        let status = try await controller.apply(settings: settings)
        return feed(status, .settingsChanged)
    }

    /// Runs one of the controller's other commands, as the app does for the
    /// user, and plans with `trigger`.
    @discardableResult
    func command(_ trigger: EvaluationTrigger, after seconds: TimeInterval = 60, _ run: (ChargeController) async -> ControllerStatus) async -> [PlannedNotification] {
        clock.advance(by: seconds)
        let status = await run(controller)
        return feed(status, trigger)
    }

    var status: ControllerStatus {
        get async { await controller.status }
    }
}

/// A controller on a stub telemetry and a test clock, for tests on the main
/// actor (``PlannerScenario`` is not `Sendable`).
struct ControllerDriver: Sendable {
    let clock: TestClock
    let telemetry: StubTelemetry
    let controller: ChargeController

    init(percent: Int, backend: any ChargingBackend = MockChargingBackend()) {
        let clock = TestClock()
        self.clock = clock
        telemetry = StubTelemetry(snapshot(percent: percent), clock: clock)
        controller = ChargeController(telemetry: telemetry, backend: backend, settings: .default, now: { clock.now }, uptime: { clock.uptime })
    }

    /// Reads `percent` (and `temperature`) a minute later and evaluates.
    func evaluate(_ percent: Int, temperature: Double? = 30, _ trigger: EvaluationTrigger = .periodic) async -> ControllerStatus {
        await telemetry.set(snapshot(percent: percent, temperature: temperature))
        clock.advance(by: 60)
        return await controller.evaluate(trigger)
    }
}

/// Holds calls until released, and lets a test wait until a number of calls
/// have arrived (and, while held, are waiting), so a test knows that work
/// reached the point it holds rather than assuming it.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func hold() {
        lock.withLock { isHeld = true }
    }

    func release() {
        let released = lock.withLock {
            isHeld = false
            defer { waiting = [] }
            return waiting
        }
        for continuation in released {
            continuation.resume()
        }
    }

    /// Called by the code under test: counts the arrival, and waits while
    /// the gate is held.
    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (passes, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                arrivals += 1
                let ready = watchers.filter { $0.count <= arrivals }.map(\.continuation)
                watchers.removeAll { $0.count <= arrivals }
                if isHeld {
                    waiting.append(continuation)
                    return (false, ready)
                }
                return (true, ready)
            }
            for watcher in ready {
                watcher.resume()
            }
            if passes {
                continuation.resume()
            }
        }
    }

    /// Waits until `count` calls have arrived.
    func waitForArrivals(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isDone = lock.withLock { () -> Bool in
                guard arrivals < count else { return true }
                watchers.append((count, continuation))
                return false
            }
            if isDone {
                continuation.resume()
            }
        }
    }
}

/// Stands in for the system's notification center: a permission the test
/// sets, every request and post recorded, gates on permission reads and on
/// posts, and posts that fail.
final class FakeNotificationPoster: NotificationPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _permission: NotificationPermission
    private var _answer: NotificationPermission
    private var _failureCode: Int?
    private var _posted: [PlannedNotification] = []
    private var _permissionReads = 0
    private var _finishedReads = 0
    private var _requests = 0
    private var _refusedAdds = 0
    /// Permission reads wait here; each returns what macOS allowed when it
    /// began.
    let reads = TestGate()
    /// Posts wait here, before the hand-over, which checks the generation
    /// immediately before it, as production does.
    let adds = TestGate()

    /// - Parameters:
    ///   - permission: what macOS allows before any request.
    ///   - answer: what macOS allows after a request.
    init(permission: NotificationPermission = .notDetermined, answer: NotificationPermission = .shown) {
        _permission = permission
        _answer = answer
    }

    var posted: [PlannedNotification] { lock.withLock { _posted } }
    var permissionReads: Int { lock.withLock { _permissionReads } }
    /// Reads that returned, after any hold.
    var finishedReads: Int { lock.withLock { _finishedReads } }
    var requests: Int { lock.withLock { _requests } }
    /// Posts that ran to the hand-over and found their generation ended.
    var refusedAdds: Int { lock.withLock { _refusedAdds } }

    /// What macOS allows from now on.
    func setPermission(_ permission: NotificationPermission) {
        lock.withLock { _permission = permission }
    }

    /// Makes every later post fail with the system error `code`.
    func failPosts(code: Int) {
        lock.withLock { _failureCode = code }
    }

    func permission() async -> NotificationPermission {
        let permission = lock.withLock {
            _permissionReads += 1
            return _permission
        }
        await reads.pass()
        lock.withLock { _finishedReads += 1 }
        return permission
    }

    func requestPermission() async -> NotificationPermission {
        lock.withLock {
            _requests += 1
            _permission = _answer
            return _permission
        }
    }

    func add(_ notification: PlannedNotification, in generation: NotificationGeneration) async -> NotificationPostResult {
        await adds.pass()
        return lock.withLock {
            guard generation.isCurrent else {
                _refusedAdds += 1
                return .ended
            }
            if let code = _failureCode { return .failed(code: code) }
            _posted.append(notification)
            return .posted
        }
    }
}

extension NotificationPermission {
    static let notDetermined = NotificationPermission(authorization: .notDetermined, showsBanners: false, listsInNotificationCenter: false)
    static let shown = NotificationPermission(authorization: .authorized, showsBanners: true, listsInNotificationCenter: true)
    static let denied = NotificationPermission(authorization: .denied, showsBanners: false, listsInNotificationCenter: false)
}
