import CellKeeperHelperCore
import Foundation

/// Everything the daemon uses from the system, so that tests can replace
/// each part. ``system(frontend:log:)`` is the only public way to build one,
/// and it always uses ``UnknownHardwareChargeControl``: no public interface
/// of this module accepts another charge control (R12a).
public struct HelperDaemonEnvironment: Sendable {
    var control: any HelperChargeControl
    var power: any HelperPowerReading
    var clock: any HelperDaemonClock
    var build: Int
    var frontend: any HelperFrontend
    var sleepNotifications: any SleepNotifications
    var terminationSignals: any TerminationSignals
    var historyStore: any ActivationHistoryStore
    /// This boot; nil if it cannot be read, and then the activation history
    /// is neither loaded nor saved.
    var bootIdentifier: BootIdentifier?
    var log: any HelperDaemonLog
    /// Ends the process with a status (`exit(3)` in the daemon).
    var exit: @Sendable (Int32) -> Void

    /// The daemon as it ships in this phase: no hardware control
    /// (``UnknownHardwareChargeControl``: no capabilities, nothing written,
    /// so clients are monitor-only), the daemon's own read-only power
    /// reading, `IORegisterForSystemPower`, SIGTERM, the activation history
    /// file at ``FileActivationHistoryStore/defaultURL``, the boot session
    /// UUID, and unified logging.
    public static func system(frontend: any HelperFrontend, log: any HelperDaemonLog = UnifiedHelperLog()) -> HelperDaemonEnvironment {
        let clock = SystemDaemonClock()
        return HelperDaemonEnvironment(
            control: UnknownHardwareChargeControl(),
            power: DaemonPowerReading(uptime: { clock.uptime() }),
            clock: clock,
            build: HelperBuild.number,
            frontend: frontend,
            sleepNotifications: SystemSleepNotifications(),
            terminationSignals: SystemTerminationSignals(),
            historyStore: FileActivationHistoryStore(),
            bootIdentifier: BootIdentifier.current(),
            log: log,
            exit: { status in Foundation.exit(status) }
        )
    }
}

/// The helper daemon's host: it runs a ``HelperEngine`` and connects it to
/// the system. The engine decides; the host only delivers what happens
/// (start, time, sleep and wake, SIGTERM) and does what the engine cannot:
/// log, persist, and exit.
///
/// The initialiser handles SIGTERM first (a signal that arrives before
/// ``run()`` is held until then), then loads the activation history saved
/// earlier in this boot (D35) and builds the engine with it. ``run()``, in
/// order:
/// 1. Starts the engine, which restores defaults and reads them back
///    before anything else is served (R2).
/// 2. Registers for sleep and wake (R16, R17, `safety.md` precondition 13).
/// 3. Waits up to ``logFlushTimeout`` for the log, so that the start's
///    restore is usually written before anyone is served (this is not
///    guaranteed), then starts the frontend, never once shutdown has begun.
/// 4. Ticks the engine every ``tickInterval``.
///
/// Shutdown (R4, D31, D59) begins on SIGTERM, when the engine shuts down at
/// a client's request (`restoreDefaultsAndExit`), or when a seam cannot
/// start. Whatever began it, one absolute deadline,
/// ``terminationDeadline`` after it began, bounds all of it, logging and
/// the final decision included, and every wait is bounded by what is left:
/// 1. The frontend is told to stop by ``finalisationReserve`` before the
///    deadline; it confirms once everything it accepted is answered and
///    every session invalidated (see ``HelperFrontend/stop(by:)``), and a
///    confirmation after that deadline does not count.
/// 2. `terminate()`, retried about once a second until the frontend has
///    confirmed and the engine is safe to exit, or until
///    ``finalisationReserve`` before the deadline.
/// 3. The log is written, keeping ``finalCheckReserve`` for:
/// 4. the final, bounded check of ``HelperEngine/isSafeToExit``, made only
///    if the frontend has confirmed, because only then can nothing else
///    change the state.
/// 5. Only then is the exit status committed: 0 if that check passed,
///    ``restoreNotConfirmedExitStatus`` otherwise. While the job is loaded
///    and approved, launchd's `KeepAlive.SuccessfulExit = false` starts the
///    daemon again after a non-zero exit, and that start restores defaults
///    first; after a removal, a bootout or a revoked approval no start
///    follows (see the recovery procedure in `safety.md`). Ticks and
///    SIGTERM handling stay live until this point.
///
/// The deadline holds even if the engine is stuck in a call to the control
/// or the log cannot be written. The daemon exits only from its own tasks,
/// never from inside the engine's event sink.
///
/// The daemon's actor coordinates and must stay responsive, so nothing that
/// can block runs on it: log lines are only enqueued (``DaemonEventQueue``).
/// Nothing that can block runs on Swift's cooperative thread pool either,
/// which the coordination needs: the log is written and the activation
/// history saved on a dispatch queue of their own (`DaemonEventWriter`),
/// the frontend's start and the sleep and signal registrations run on
/// another (``blocking(_:)``), and the engine runs on its own. Every wait is
/// bounded by an absolute deadline, recomputed when the wait actually
/// starts, so a late start shortens a wait instead of postponing its end.
///
/// Sleep: on will-sleep the engine runs its sleep checks and only then is
/// sleep acknowledged, or after ``sleepAcknowledgementTimeout`` at the
/// latest, with a fault logged: an unacknowledged sleep only delays sleep,
/// and the engine's leases count sleep. Wake is forwarded to the engine.
/// Sleep and wake reach the engine in the order they happened.
///
/// The engine's events go to the audit log, and on each
/// `activationRecorded` a snapshot of the activation history is saved; both
/// happen on a task of their own, so the engine's sink returns at once.
public actor HelperDaemon {
    /// launchd's grace between SIGTERM and SIGKILL; must equal `ExitTimeOut`
    /// in the property list (a test checks).
    public static let exitTimeout: TimeInterval = 10
    /// The daemon exits within this time after shutdown begins, whatever
    /// happens, leaving launchd's grace a margin.
    public static let terminationDeadline: TimeInterval = exitTimeout - 2
    /// Of the shutdown budget, what is kept for writing the log and for the
    /// final safety check: retries stop this long before the deadline.
    public static let finalisationReserve: TimeInterval = 1
    /// Of the shutdown budget, what is kept for the final safety check:
    /// writing the log stops this long before the deadline.
    public static let finalCheckReserve: TimeInterval = 0.5
    /// The exit status when defaults could not be confirmed (`EX_TEMPFAIL`).
    /// Being non-zero, it makes launchd start the daemon again, but only
    /// while the job is still loaded and approved.
    public static let restoreNotConfirmedExitStatus: Int32 = 75
    /// How often the engine runs its periodic checks.
    public static let tickInterval: TimeInterval = 5
    /// How often an owed restore is retried during shutdown.
    public static let exitPollInterval: TimeInterval = 1
    /// The longest the daemon holds back the acknowledgement of a sleep.
    public static let sleepAcknowledgementTimeout: TimeInterval = 5
    /// How long shutdown waits for the frontend's confirmation before it
    /// restores defaults; it keeps waiting for it while it retries.
    public static let frontendStopTimeout: TimeInterval = 1
    /// The longest the daemon waits for its log to be written, each time.
    public static let logFlushTimeout: TimeInterval = 0.5

    /// The engine this daemon runs.
    public nonisolated let engine: HelperEngine
    private let environment: HelperDaemonEnvironment
    private let queue: DaemonEventQueue
    private let relay: DaemonRelay

    private var hasRun = false
    private var isShuttingDown = false
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var ticker: Task<Void, Never>?
    private var sleepEvents: AsyncStream<SleepCheck>.Continuation?
    private var isRegisteredForSleep = false
    /// The frontend's start, which its stop waits for.
    private var frontendStart: Task<Void, any Error>?

    /// Handles SIGTERM from here on (one that arrives before ``run()`` is
    /// held until then), then builds the engine with the activation history
    /// saved earlier in this boot. Loading never fails: anything unusable
    /// is logged and discarded.
    public init(environment: HelperDaemonEnvironment) {
        let queue = DaemonEventQueue()
        let relay = DaemonRelay()
        self.queue = queue
        self.relay = relay
        self.environment = environment
        environment.terminationSignals.start { relay.terminationRequested() }
        queue.log(.notice, .lifecycle, "CellKeeperHelper build \(environment.build) starting (pid \(getpid()), uid \(geteuid())).")
        let clock = environment.clock
        engine = HelperEngine(
            control: environment.control,
            power: environment.power,
            build: environment.build,
            uptime: { clock.uptime() },
            activationHistory: Self.loadHistory(environment, log: queue),
            events: { [frontend = environment.frontend] event in
                queue.event(event)
                // The frontend closes the connection of a revoked session.
                frontend.handle(event)
                // Seen here rather than when the log reaches it, so a slow
                // log cannot delay the shutdown. The daemon reacts on a
                // task of its own.
                if case .shuttingDown = event {
                    relay.engineShutDown()
                }
            }
        )
    }

    /// Runs the daemon until it exits, and returns the exit status it passed
    /// to the environment's `exit` (which, in the daemon, does not return).
    /// Calling it again only waits for that status.
    public func run() async -> Int32 {
        guard !hasRun else { return await waitForExit() }
        hasRun = true
        startEventPump()
        if relay.attach(self) {
            // SIGTERM arrived during start-up: shut down before serving.
            await shutDown(reason: "SIGTERM (received while starting)")
            return await waitForExit()
        }

        let started = await engine.start()
        if started == .ok {
            queue.log(.notice, .lifecycle, "Engine started; defaults confirmed.")
        } else {
            queue.log(.fault, .lifecycle, "Engine started, but defaults are not confirmed (\(started)); it keeps retrying the restore and refuses activations.")
        }
        guard !isShuttingDown else { return await waitForExit() }

        if case .failure(let error) = await registerForSleep() {
            queue.log(.fault, .safety, "Sleep notifications could not be registered (\(error)). Without them the daemon cannot hold sleep until its checks have run, so it serves nobody and exits.")
            await shutDown(reason: "Sleep notifications unavailable")
            return await waitForExit()
        }
        guard !isShuttingDown else { return await waitForExit() }

        // Wait up to logFlushTimeout for the log, so that the start's restore
        // is usually written before anyone is served; this does not
        // guarantee it.
        let clock = environment.clock
        let queue = queue
        _ = await withDeadline(Self.logFlushTimeout, on: clock) { await queue.flush() }
        guard !isShuttingDown else { return await waitForExit() }

        // Off the actor; a shutdown that begins meanwhile stops the frontend
        // once this has returned.
        let frontend = environment.frontend
        let engine = engine
        let start = Task {
            try await Self.blocking { Result { try frontend.start(serving: engine, log: queue) } }.get()
        }
        frontendStart = start
        if case .failure(let error) = await start.result {
            queue.log(.fault, .xpc, "The frontend could not start (\(error)); exiting without serving anyone.")
            await shutDown(reason: "Frontend unavailable")
            return await waitForExit()
        }
        guard !isShuttingDown else { return await waitForExit() }
        startTicking()
        return await waitForExit()
    }

    // MARK: - Start

    private static func loadHistory(_ environment: HelperDaemonEnvironment, log: DaemonEventQueue) -> [HelperActivationRecord] {
        guard let boot = environment.bootIdentifier else {
            log.log(.fault, .safety, "The boot session UUID cannot be read: the activation history is neither loaded nor saved, so a relaunch resets the activation limits.")
            return []
        }
        switch environment.historyStore.load(boot: boot, now: environment.clock.uptime()) {
        case .loaded(let records):
            log.log(.notice, .safety, "Loaded \(records.count) activation record(s) saved earlier in this boot (\(boot)).")
            return records
        case .missing:
            log.log(.info, .safety, "No activation history was saved before.")
            return []
        case .discarded(let reason):
            log.log(.notice, .safety, "Discarded the saved activation history because \(reason); starting with an empty one.")
            return []
        }
    }

    /// Logs the engine's events and saves the activation history, in
    /// order, on a dispatch queue of their own.
    private func startEventPump() {
        let writer = DaemonEventWriter(
            log: environment.log,
            engine: engine,
            store: environment.historyStore,
            boot: environment.bootIdentifier
        )
        let items = queue.items
        Task {
            await writer.pump(items)
        }
    }

    /// Where the daemon calls seams that may block (the frontend's start,
    /// the sleep and signal registrations and their removal): threads
    /// outside Swift's cooperative pool, so a blocked call cannot take a
    /// thread the daemon's coordination needs. Concurrent, so one blocked
    /// call does not hold up the next.
    private static let blockingQueue = DispatchQueue(label: "io.github.saltedtan.CellKeeper.Helper.seams", attributes: .concurrent)

    /// Runs `work`, which may block, on ``blockingQueue`` and returns its
    /// result; the calling task is suspended meanwhile, not blocked.
    static func blocking<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            blockingQueue.async { continuation.resume(returning: work()) }
        }
    }

    /// Registers for sleep and wake from a task of its own, so that the
    /// actor stays responsive meanwhile.
    private func registerForSleep() async -> Result<Void, any Error> {
        let (checks, continuation) = AsyncStream.makeStream(of: SleepCheck.self)
        let clock = environment.clock
        let queue = queue
        let handler: @Sendable (SleepEvent) -> Void = { event in
            switch event {
            case .willSleep(let acknowledge):
                // The deadline is fixed at the announcement, whatever the
                // engine is busy with and however late the timer starts.
                let acknowledgement = SleepAcknowledgement(acknowledge)
                acknowledgement.acknowledge(by: clock.uptime() + Self.sleepAcknowledgementTimeout, on: clock) {
                    queue.log(.fault, .safety, "The engine had not finished its sleep checks \(Int(Self.sleepAcknowledgementTimeout)) s after the sleep announcement: sleep acknowledged anyway. Its leases count sleep.")
                }
                continuation.yield(.willSleep(acknowledgement))
            case .didWake:
                continuation.yield(.didWake)
            }
        }
        let notifications = environment.sleepNotifications
        let result = await Self.blocking { Result { try notifications.start(handler) } }
        guard case .success = result else {
            continuation.finish()
            return result
        }
        if exitStatus != nil {
            // The exit was committed meanwhile, without this registration.
            continuation.finish()
            await Self.blocking { notifications.stop() }
            return result
        }
        isRegisteredForSleep = true
        sleepEvents = continuation
        let engine = engine
        Task {
            await Self.handleSleepChecks(checks, engine: engine, log: queue)
        }
        return result
    }

    private static func handleSleepChecks(_ checks: AsyncStream<SleepCheck>, engine: HelperEngine, log: DaemonEventQueue) async {
        for await check in checks {
            switch check {
            case .willSleep(let acknowledgement):
                await engine.systemWillSleep()
                if acknowledgement.acknowledge() {
                    log.log(.info, .lifecycle, "Sleep acknowledged after the engine's sleep checks.")
                } else {
                    log.log(.notice, .lifecycle, "The engine finished its sleep checks after sleep had been acknowledged.")
                }
            case .didWake:
                await engine.systemDidWake()
                log.log(.info, .lifecycle, "Wake forwarded to the engine.")
            }
        }
    }

    private func startTicking() {
        let engine = engine
        let clock = environment.clock
        ticker = Task {
            await Self.tick(engine, every: Self.tickInterval, on: clock)
        }
    }

    private static func tick(_ engine: HelperEngine, every interval: TimeInterval, on clock: any HelperDaemonClock) async {
        while !Task.isCancelled {
            await clock.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await engine.tick()
        }
    }

    // MARK: - Shutdown

    fileprivate func terminationRequested() async {
        await shutDown(reason: "SIGTERM")
    }

    /// The engine shut down. Unless the daemon began that itself, a client
    /// asked for it with `restoreDefaultsAndExit`.
    fileprivate func engineShutDown() async {
        guard !isShuttingDown, exitStatus == nil else { return }
        await shutDown(reason: "Exit requested by a client")
    }

    /// Shuts the daemon down within one absolute deadline (see the type's
    /// documentation, R4, D31, D59).
    private func shutDown(reason: String) async {
        guard !isShuttingDown, exitStatus == nil else {
            queue.log(.notice, .lifecycle, "\(reason) while already shutting down: ignored.")
            return
        }
        isShuttingDown = true
        let clock = environment.clock
        let deadline = clock.uptime() + Self.terminationDeadline
        let engine = engine
        let queue = queue
        queue.log(.notice, .lifecycle, "\(reason): stopping the frontend and restoring defaults; exiting within \(Int(Self.terminationDeadline)) s.")

        // 1. Stop the frontend (once a start in progress has returned) by
        // the end of the retries, on the same deadline; its confirmation may
        // come later.
        let stop = FrontendStop(
            environment.frontend,
            after: frontendStart,
            by: HelperDaemonDeadline(uptime: deadline - Self.finalisationReserve, on: clock),
            log: queue
        )

        // 2. Restore and retry until the frontend has confirmed and the
        // engine is safe to exit, keeping the reserve.
        let stopWaitEnd = clock.uptime() + Self.frontendStopTimeout
        let settled = await withDeadline(at: deadline - Self.finalisationReserve, on: clock) {
            _ = await withDeadline(at: stopWaitEnd, on: clock) { await stop.wait() }
            await engine.terminate()
            while true {
                switch stop.outcome {
                case .refused:
                    return false
                case .confirmed:
                    if await engine.isSafeToExit { return true }
                case .pending:
                    break
                }
                await clock.sleep(for: Self.exitPollInterval)
                guard !Task.isCancelled else { return false }
                await engine.terminate()
            }
        } ?? false
        if !settled {
            switch stop.outcome {
            case .confirmed:
                queue.log(.fault, .safety, "Defaults not confirmed within the shutdown's retries.")
            case .pending:
                queue.log(.fault, .xpc, "The frontend has not confirmed that it stopped serving, so a request it accepted could still change the state.")
            case .refused:
                queue.log(.fault, .xpc, "The frontend could not confirm that it stopped serving, so a request it accepted could still change the state.")
            }
        }

        // 3. Write the log, keeping time for the final check.
        let flushEnd = min(clock.uptime() + Self.logFlushTimeout, deadline - Self.finalCheckReserve)
        _ = await withDeadline(at: flushEnd, on: clock) { await queue.flush() }

        // 4. The final check, after everything that could still change the
        // state: only a frontend that has confirmed it stopped can no longer
        // change it, so without that confirmation nothing is safe.
        var isSafe = false
        if stop.outcome == .confirmed {
            isSafe = await withDeadline(at: deadline, on: clock) { await engine.isSafeToExit } ?? false
        }

        // 5. Commit.
        await commitExit(status: isSafe ? 0 : Self.restoreNotConfirmedExitStatus, deadline: deadline)
    }

    /// Commits the exit status decided by the final check, ends the
    /// daemon's work, writes the log within what is left of the deadline,
    /// and exits.
    private func commitExit(status: Int32, deadline: TimeInterval) async {
        exitStatus = status
        ticker?.cancel()
        sleepEvents?.finish()
        let isRegisteredForSleep = isRegisteredForSleep
        self.isRegisteredForSleep = false
        if status == 0 {
            queue.log(.notice, .lifecycle, "The frontend stopped and defaults are confirmed: exiting with status 0.")
        } else {
            queue.log(.fault, .safety, "Defaults or the frontend's stop not confirmed: exiting with status \(status). If launchd starts the helper again, it restores defaults before anything else; after a removal, bootout or revoked approval, no start follows (see the recovery procedure in docs/safety.md).")
        }
        let clock = environment.clock
        let queue = queue
        // Off the actor and within the deadline: stop delivering sleep and
        // signals (SIGTERM stays ignored), then wait for the log.
        let notifications = environment.sleepNotifications
        let signals = environment.terminationSignals
        _ = await withDeadline(at: deadline, on: clock) {
            await Self.blocking {
                if isRegisteredForSleep {
                    notifications.stop()
                }
                signals.stop()
            }
        }
        _ = await withDeadline(at: min(clock.uptime() + Self.logFlushTimeout, deadline), on: clock) { await queue.flush() }
        queue.finish()
        environment.exit(status)
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    private func waitForExit() async -> Int32 {
        if let exitStatus {
            return exitStatus
        }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }
}

/// Brings SIGTERM and the engine's shutdown to the daemon. Signals are
/// handled from the start of the daemon's initialiser, before it loads the
/// activation history; one that arrives before ``HelperDaemon/run()`` is
/// held until then.
final class DaemonRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var daemon: HelperDaemon?
    private var isTerminationPending = false
    private var isEngineShutdownPending = false

    /// From now on, delivers to `daemon`. Returns true if a SIGTERM arrived
    /// before, for the daemon to handle at once.
    func attach(_ daemon: HelperDaemon) -> Bool {
        let (termination, engineShutdown) = lock.withLock { () -> (Bool, Bool) in
            self.daemon = daemon
            defer {
                isTerminationPending = false
                isEngineShutdownPending = false
            }
            return (isTerminationPending, isEngineShutdownPending)
        }
        if engineShutdown, !termination {
            Task { await daemon.engineShutDown() }
        }
        return termination
    }

    func terminationRequested() {
        guard let daemon = lock.withLock({ () -> HelperDaemon? in
            if self.daemon == nil { isTerminationPending = true }
            return self.daemon
        }) else { return }
        Task { await daemon.terminationRequested() }
    }

    func engineShutDown() {
        guard let daemon = lock.withLock({ () -> HelperDaemon? in
            if self.daemon == nil { isEngineShutdownPending = true }
            return self.daemon
        }) else { return }
        Task { await daemon.engineShutDown() }
    }
}

/// The frontend's stop, on a task of its own. The daemon waits for it only
/// within its budget, and counts it as confirmed only once `stop(by:)` has
/// returned true before its deadline.
final class FrontendStop: @unchecked Sendable {
    enum Outcome: Equatable {
        case pending
        case confirmed
        case refused
    }

    private let lock = NSLock()
    private var current = Outcome.pending
    private var task: Task<Void, Never>?

    /// Stops `frontend` by `deadline` once `start`, if any, has returned,
    /// and logs when its stop returns. A true that comes after the deadline
    /// is not counted: the daemon has stopped waiting for it by then.
    init(_ frontend: any HelperFrontend, after start: Task<Void, any Error>?, by deadline: HelperDaemonDeadline, log: DaemonEventQueue) {
        let task = Task.detached { [self] in
            _ = await start?.result
            let returned = await frontend.stop(by: deadline)
            let confirmed = returned && !deadline.hasPassed
            lock.withLock { current = confirmed ? .confirmed : .refused }
            if confirmed {
                log.log(.info, .xpc, "The frontend stopped and confirmed that everything it accepted was answered.")
            } else if returned {
                log.log(.fault, .xpc, "The frontend confirmed its stop only after its deadline: not counted.")
            } else {
                log.log(.fault, .xpc, "The frontend stopped without confirming that everything it accepted was answered.")
            }
        }
        lock.withLock { self.task = task }
    }

    var outcome: Outcome {
        lock.withLock { current }
    }

    /// Returns when `stop(by:)` has returned.
    func wait() async {
        let task = lock.withLock { self.task }
        await task?.value
    }
}

/// A sleep or wake, queued for the engine in the order it happened.
enum SleepCheck: Sendable {
    case willSleep(SleepAcknowledgement)
    case didWake
}

/// Acknowledges one sleep announcement exactly once: when the engine has
/// run its sleep checks, or when the deadline passes, whichever is first.
final class SleepAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledgeSleep: (@Sendable () -> Void)?
    private var timer: Task<Void, Never>?

    init(_ acknowledge: @escaping @Sendable () -> Void) {
        acknowledgeSleep = acknowledge
    }

    /// Acknowledges the sleep unless that has been done; true if this call
    /// did it.
    @discardableResult
    func acknowledge() -> Bool {
        let (acknowledge, timer) = lock.withLock { () -> ((@Sendable () -> Void)?, Task<Void, Never>?) in
            defer {
                acknowledgeSleep = nil
                self.timer = nil
            }
            return (acknowledgeSleep, self.timer)
        }
        timer?.cancel()
        acknowledge?()
        return acknowledge != nil
    }

    /// Acknowledges when `clock`'s uptime reaches `deadline`, unless that
    /// has been done, and then calls `onTimeout`. The timer waits for what
    /// is left when it starts, so a late start does not postpone it.
    func acknowledge(by deadline: TimeInterval, on clock: any HelperDaemonClock, onTimeout: @escaping @Sendable () -> Void) {
        let timer = Task {
            await clock.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            if self.acknowledge() {
                onTimeout()
            }
        }
        let isAcknowledged = lock.withLock {
            if acknowledgeSleep == nil { return true }
            self.timer = timer
            return false
        }
        if isAcknowledged {
            timer.cancel()
        }
    }
}

/// Writes the daemon's log and saves the activation history, on a serial
/// dispatch queue of its own: writing a log line or a file may block, and
/// must never hold a thread of Swift's cooperative pool.
actor DaemonEventWriter {
    private let executor = DispatchSerialQueue(label: "io.github.saltedtan.CellKeeper.Helper.log")
    private let log: any HelperDaemonLog
    private let engine: HelperEngine
    private let store: any ActivationHistoryStore
    private let boot: BootIdentifier?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(log: any HelperDaemonLog, engine: HelperEngine, store: any ActivationHistoryStore, boot: BootIdentifier?) {
        self.log = log
        self.engine = engine
        self.store = store
        self.boot = boot
    }

    /// Handles every item, in order, until the queue finishes.
    func pump(_ items: AsyncStream<DaemonEventQueue.Item>) async {
        var isFailingToSave = false
        for await item in items {
            switch item {
            case .log(let level, let category, let message):
                log.write(level, category, message)
            case .flush(let waiter):
                waiter.resume()
            case .event(let event):
                let placement = event.logPlacement
                log.write(placement.level, placement.category, "engine: \(event)")
                guard case .activationRecorded = event, let boot else { continue }
                let records = await engine.activationHistory
                do {
                    try store.save(records, boot: boot)
                    if isFailingToSave {
                        isFailingToSave = false
                        log.write(.notice, .safety, "The activation history is being saved again.")
                    }
                } catch {
                    if !isFailingToSave {
                        isFailingToSave = true
                        log.write(.fault, .safety, "Cannot save the activation history (\(error)); carrying on without it, so a relaunch in this boot would not know these activations.")
                    }
                }
            }
        }
    }
}
