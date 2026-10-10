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
    /// file at ``FileActivationHistoryStore/defaultURL``, `kern.boottime`,
    /// and unified logging.
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
/// ``run()``, in order:
/// 1. Starts handling SIGTERM.
/// 2. Starts the engine, which restores defaults and reads them back
///    before anything else is served (R2). The engine was built with the
///    activation history saved earlier in this boot, if any (D35).
/// 3. Registers for sleep and wake (R16, R17, `safety.md` precondition 13).
/// 4. Starts the frontend, only now, and never once shutdown has begun,
///    once the log has caught up with the start.
/// 5. Ticks the engine every ``tickInterval``.
///
/// Then it runs until one of these ends it, and it exits only from its own
/// tasks, never from inside the engine's event sink:
/// - **SIGTERM (R4, D31).** Stops the frontend, calls `terminate()`, and
///   retries about once a second until the engine says it is safe to exit
///   or ``terminationDeadline`` has passed since the signal; then exits with
///   0 if defaults are confirmed, else with ``restoreNotConfirmedExitStatus``
///   (launchd's `KeepAlive.SuccessfulExit = false` then starts it again,
///   and the next start restores defaults first). The deadline holds even
///   if the engine is stuck in a call to the control.
/// - **A client's `restoreDefaultsAndExit`.** On the engine's `safeToExit`
///   event, stops the frontend, checks ``HelperEngine/isSafeToExit`` once
///   more, and exits with 0; if a restore is owed again, it waits for the
///   next `safeToExit`.
/// - **A seam that cannot start** (sleep notifications, the frontend): the
///   same as SIGTERM, without serving anyone.
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
    /// After SIGTERM, the daemon exits by this time whatever happens,
    /// leaving launchd's grace a margin.
    public static let terminationDeadline: TimeInterval = exitTimeout - 2
    /// The exit status when defaults could not be confirmed (`EX_TEMPFAIL`).
    /// Being non-zero, it makes launchd start the daemon again.
    public static let restoreNotConfirmedExitStatus: Int32 = 75
    /// How often the engine runs its periodic checks.
    public static let tickInterval: TimeInterval = 5
    /// How often an owed restore is retried after SIGTERM.
    public static let exitPollInterval: TimeInterval = 1
    /// The longest the daemon holds back the acknowledgement of a sleep.
    public static let sleepAcknowledgementTimeout: TimeInterval = 5
    /// The longest the daemon waits for the frontend to stop.
    public static let frontendStopTimeout: TimeInterval = 1
    /// The longest the daemon waits for its log to be written before it
    /// exits.
    public static let logFlushTimeout: TimeInterval = 1

    /// The engine this daemon runs.
    public nonisolated let engine: HelperEngine
    private let environment: HelperDaemonEnvironment
    private let queue: DaemonEventQueue

    private var hasRun = false
    private var isTerminating = false
    private var isExitingAtClientRequest = false
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var ticker: Task<Void, Never>?
    private var sleepEvents: AsyncStream<SleepCheck>.Continuation?

    /// Builds the engine with the activation history saved earlier in this
    /// boot. Loading never fails: anything unusable is logged and discarded.
    public init(environment: HelperDaemonEnvironment) {
        let queue = DaemonEventQueue()
        self.queue = queue
        self.environment = environment
        queue.log(.notice, .lifecycle, "CellKeeperHelper build \(environment.build) starting (pid \(getpid()), uid \(geteuid())).")
        let clock = environment.clock
        engine = HelperEngine(
            control: environment.control,
            power: environment.power,
            build: environment.build,
            uptime: { clock.uptime() },
            activationHistory: Self.loadHistory(environment, log: queue),
            events: { queue.event($0) }
        )
    }

    /// Runs the daemon until it exits, and returns the exit status it passed
    /// to the environment's `exit` (which, in the daemon, does not return).
    /// Calling it again only waits for that status.
    public func run() async -> Int32 {
        guard !hasRun else { return await waitForExit() }
        hasRun = true
        startEventPump()
        environment.terminationSignals.start { [weak self] in
            guard let self else { return }
            Task { await self.terminate(reason: "SIGTERM") }
        }

        let started = await engine.start()
        if started == .ok {
            queue.log(.notice, .lifecycle, "Engine started; defaults confirmed.")
        } else {
            queue.log(.fault, .lifecycle, "Engine started, but defaults are not confirmed (\(started)); it keeps retrying the restore and refuses activations.")
        }
        guard !isTerminating else { return await waitForExit() }

        do {
            try startSleepHandling()
        } catch {
            queue.log(.fault, .safety, "Sleep notifications could not be registered (\(error)). Without them the daemon cannot hold sleep until its checks have run, so it serves nobody and exits.")
            await terminate(reason: "Sleep notifications unavailable")
            return await waitForExit()
        }
        // The start's restore is in the log before anyone is served.
        await flushLog()
        guard !isTerminating else { return await waitForExit() }
        do {
            try environment.frontend.start(serving: engine)
        } catch {
            queue.log(.fault, .xpc, "The frontend could not start (\(error)); exiting without serving anyone.")
            await terminate(reason: "Frontend unavailable")
            return await waitForExit()
        }
        startTicking()
        return await waitForExit()
    }

    // MARK: - Start

    private static func loadHistory(_ environment: HelperDaemonEnvironment, log: DaemonEventQueue) -> [HelperActivationRecord] {
        guard let boot = environment.bootIdentifier else {
            log.log(.fault, .safety, "The boot identifier (kern.boottime) cannot be read: the activation history is neither loaded nor saved, so a relaunch resets the activation limits.")
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
    /// order, on a task of its own; tells the daemon when the engine says
    /// it is safe to exit.
    private func startEventPump() {
        let notifySafeToExit: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task { await self.engineAnnouncedSafeToExit() }
        }
        let items = queue.items
        let log = environment.log
        let engine = engine
        let store = environment.historyStore
        let boot = environment.bootIdentifier
        Task {
            await Self.pumpEvents(items, log: log, engine: engine, store: store, boot: boot, notifySafeToExit: notifySafeToExit)
        }
    }

    private static func pumpEvents(
        _ items: AsyncStream<DaemonEventQueue.Item>,
        log: any HelperDaemonLog,
        engine: HelperEngine,
        store: any ActivationHistoryStore,
        boot: BootIdentifier?,
        notifySafeToExit: @Sendable () -> Void
    ) async {
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
                switch event {
                case .activationRecorded:
                    guard let boot else { break }
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
                case .safeToExit:
                    notifySafeToExit()
                default:
                    break
                }
            }
        }
    }

    private func startSleepHandling() throws {
        let (checks, continuation) = AsyncStream.makeStream(of: SleepCheck.self)
        let clock = environment.clock
        let queue = queue
        try environment.sleepNotifications.start { event in
            switch event {
            case .willSleep(let acknowledge):
                // The deadline runs from the announcement, whatever the
                // engine is busy with.
                let acknowledgement = SleepAcknowledgement(acknowledge)
                acknowledgement.acknowledge(after: Self.sleepAcknowledgementTimeout, on: clock) {
                    queue.log(.fault, .safety, "The engine had not finished its sleep checks \(Int(Self.sleepAcknowledgementTimeout)) s after the sleep announcement: sleep acknowledged anyway. Its leases count sleep.")
                }
                continuation.yield(.willSleep(acknowledgement))
            case .didWake:
                continuation.yield(.didWake)
            }
        }
        sleepEvents = continuation
        let engine = engine
        Task {
            await Self.handleSleepChecks(checks, engine: engine, log: queue)
        }
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

    /// SIGTERM, or a seam that could not start (R4, D31).
    private func terminate(reason: String) async {
        guard exitStatus == nil else { return }
        guard !isTerminating else {
            queue.log(.notice, .lifecycle, "\(reason) while already shutting down: ignored.")
            return
        }
        isTerminating = true
        queue.log(.notice, .lifecycle, "\(reason): stopping the frontend and restoring defaults; exiting within \(Int(Self.terminationDeadline)) s.")
        let engine = engine
        let frontend = environment.frontend
        let clock = environment.clock
        let queue = queue
        let isSafe = await withDeadline(Self.terminationDeadline, on: clock) {
            await Self.stop(frontend, on: clock, log: queue)
            await engine.terminate()
            while !(await engine.isSafeToExit) {
                await clock.sleep(for: Self.exitPollInterval)
                guard !Task.isCancelled else { return false }
                await engine.terminate()
            }
            return true
        } ?? false
        if isSafe {
            queue.log(.notice, .lifecycle, "Defaults confirmed: exiting with status 0.")
            await finish(status: 0)
        } else {
            queue.log(.fault, .safety, "Defaults not confirmed within \(Int(Self.terminationDeadline)) s: exiting with status \(Self.restoreNotConfirmedExitStatus). The next start restores defaults before anything else.")
            await finish(status: Self.restoreNotConfirmedExitStatus)
        }
    }

    /// The engine shut down at a client's request (`restoreDefaultsAndExit`)
    /// and confirmed defaults.
    private func engineAnnouncedSafeToExit() async {
        guard exitStatus == nil, !isTerminating, !isExitingAtClientRequest else { return }
        isExitingAtClientRequest = true
        defer { isExitingAtClientRequest = false }
        queue.log(.notice, .lifecycle, "The engine shut down at a client's request with defaults confirmed: stopping the frontend and exiting.")
        await Self.stop(environment.frontend, on: environment.clock, log: queue)
        guard exitStatus == nil, !isTerminating else { return }
        guard await engine.isSafeToExit else {
            queue.log(.notice, .safety, "A restore is owed again: waiting until the engine confirms defaults.")
            return
        }
        guard exitStatus == nil, !isTerminating else { return }
        await finish(status: 0)
    }

    private static func stop(_ frontend: any HelperFrontend, on clock: any HelperDaemonClock, log: DaemonEventQueue) async {
        if await withDeadline(frontendStopTimeout, on: clock, { await frontend.stop() }) == nil {
            log.log(.fault, .xpc, "The frontend did not stop within \(Int(frontendStopTimeout)) s; carrying on with the shutdown.")
        }
    }

    /// Ends the daemon's work, writes the log, and exits with `status`.
    private func finish(status: Int32) async {
        guard exitStatus == nil else { return }
        exitStatus = status
        ticker?.cancel()
        environment.sleepNotifications.stop()
        sleepEvents?.finish()
        environment.terminationSignals.stop()
        queue.log(.notice, .lifecycle, "Exiting with status \(status).")
        await flushLog()
        queue.finish()
        environment.exit(status)
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    /// Waits until the log has caught up, for at most ``logFlushTimeout``.
    private func flushLog() async {
        let queue = queue
        _ = await withDeadline(Self.logFlushTimeout, on: environment.clock) { await queue.flush() }
    }

    private func waitForExit() async -> Int32 {
        if let exitStatus {
            return exitStatus
        }
        return await withCheckedContinuation { exitWaiters.append($0) }
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

    /// Acknowledges after `seconds` on `clock` unless that has been done,
    /// and then calls `onTimeout`.
    func acknowledge(after seconds: TimeInterval, on clock: any HelperDaemonClock, onTimeout: @escaping @Sendable () -> Void) {
        let timer = Task {
            await clock.sleep(for: seconds)
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
