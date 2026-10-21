import Foundation

/// What the refresher needs of the SMC source: its windows, the section's
/// visibility told in order, and a stop for quitting
/// (``SMCPowerCoordinator``; a test fake in tests).
public protocol SMCPowerControlling: SMCPowerPublishing {
    func send(_ input: SMCPowerCoordinator.Input)
    func stop()
}

extension SMCPowerCoordinator: SMCPowerControlling {}

/// How a run of the refresher ended.
public struct PowerFlowRunOutcome: Sendable, Equatable {
    /// Whether this run's end was the one that told the SMC source the
    /// section is hidden: it was the last run reading.
    public let hidSection: Bool
    /// When it ended, on the continuous clock.
    public let endedAt: ContinuousClock.Instant

    public init(hidSection: Bool, endedAt: ContinuousClock.Instant) {
        self.hidSection = hidSection
        self.endedAt = endedAt
    }

    /// Clears `state`'s SMC track from when this run ended, if its end hid
    /// the section (the menu closed): a window from before then is never
    /// shown after it. A run ended by ``PowerFlowRefresher/collapse(_:at:)``
    /// was cleared there.
    public func clearSMCTrackIfHidden(_ state: inout PowerFlowState) {
        if hidSection {
            state.clearSMCTrack(at: endedAt)
        }
    }
}

/// The menu's display-only reads of the power flow as the app runs them
/// (D114, D115): ``PowerFlowRefresh`` for each time the menu shows the
/// expanded section, through one source whose reads never overlap and,
/// when the build has a reader, the SMC source, and a stop for quitting.
///
/// The section's task can start a run while an earlier one is still
/// finishing (SwiftUI starts it again when the section is expanded or
/// collapsed), so two runs may overlap; they share one read at a time, and
/// the SMC source counts as shown while any run reads. A run ends at the
/// first of: its caller cancelled (the menu closes), ``collapse(_:at:)`` or
/// ``endRuns()``, ``stop()`` (quitting), or its own end. It ends then and
/// there, on whatever thread that happens: it is no longer counted, the SMC
/// source is told the section is hidden if it was the last reading, and a
/// display read in flight is not waited for (it ends on its own, and its
/// tick is dropped). Whatever comes later for that run does nothing. The
/// controller's own telemetry reads are separate and may overlap these
/// (``TelemetryProvider`` allows it).
@MainActor
public final class PowerFlowRefresher {
    /// A run not yet ended: its task, and what ends it.
    private struct Run {
        let task: Task<Void, Never>
        let end: RunEnd
    }

    let source: SingleFlightPowerFlowReading
    /// The SMC source; nil when the build has no reader (it is absent).
    let smc: (any SMCPowerControlling)?
    private let ledger: RunLedger
    private let interval: Duration
    private let pause: @Sendable (Duration) async -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var runs: [Int: Run] = [:]
    private var nextRun = 0
    /// True once ``stop()`` was called: nothing is read or delivered after.
    public private(set) var isStopped = false

    public init(
        source: any PowerFlowReading,
        smc: (any SMCPowerControlling)? = nil,
        interval: Duration = PowerFlowRefresh.interval,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.source = SingleFlightPowerFlowReading(source)
        self.smc = smc
        self.ledger = RunLedger(smc: smc)
        self.interval = interval
        self.pause = pause
        self.now = now
    }

    /// Whether a run is reading: the section is shown in an open menu.
    public var isShowing: Bool {
        ledger.readingRuns > 0
    }

    /// The runs reading now.
    var readingRuns: Int {
        ledger.readingRuns
    }

    /// Reads while `isWanted` holds, until the run ends (see the type),
    /// handing each tick to `deliver`
    /// (``PowerFlowRefresh/run(source:smc:interval:while:pause:now:deliver:)``).
    /// The SMC source is told the section is shown when the first such run
    /// begins and hidden when the last ends. Returns as soon as the run
    /// ends, with how it ended; at once once stopped.
    @discardableResult
    public func run(
        while isWanted: @escaping @MainActor @Sendable () -> Bool,
        deliver: @escaping @MainActor @Sendable (PowerFlowTick) -> Void
    ) async -> PowerFlowRunOutcome {
        guard !isStopped else { return PowerFlowRunOutcome(hidSection: false, endedAt: now()) }
        let id = nextRun
        nextRun += 1
        ledger.begin(id, reads: isWanted())
        let end = RunEnd()
        let ledger = ledger
        let task = Task { [source, smc, interval, pause, now] in
            await PowerFlowRefresh.run(
                source: source,
                smc: smc,
                interval: interval,
                // False once the run has ended, however it ended.
                while: { ledger.isLive(id) && isWanted() },
                pause: pause,
                now: now
            ) { tick in
                // A tick read before the run ended and delivered after is
                // dropped.
                guard ledger.isLive(id) else { return }
                deliver(tick)
            }
            end.finish(at: now()) { ledger.end(id) }
        }
        runs[id] = Run(task: task, end: end)
        let outcome = await withTaskCancellationHandler {
            await end.wait()
        } onCancel: { [now] in
            task.cancel()
            end.finish(at: now()) { ledger.end(id) }
        }
        runs[id] = nil
        return outcome
    }

    /// Ends every run at once: their tasks are cancelled, they are no longer
    /// counted, and the SMC source is told the section is hidden, now,
    /// whenever their callers resume. A display read in flight ends on its
    /// own and its tick is dropped. A later run reads again.
    public func endRuns() {
        for (id, run) in runs {
            run.task.cancel()
            run.end.finish(at: now()) { ledger.end(id) }
        }
        runs.removeAll()
    }

    /// The section collapsed, the hide event: ends every run
    /// (``endRuns()``) and clears `state`'s SMC track from `now`, so a run
    /// started right after begins afresh and nothing from before is shown.
    public func collapse(_ state: inout PowerFlowState, at now: ContinuousClock.Instant? = nil) {
        endRuns()
        state.clearSMCTrack(at: now ?? self.now())
    }

    /// Stops every run and any later one: CellKeeper is quitting. A read in
    /// flight ends on its own, and its tick is dropped; the SMC source stops
    /// without waiting for a call in flight.
    public func stop() {
        isStopped = true
        endRuns()
        smc?.stop()
    }
}

/// Which runs are live and how many read, changed under a lock at the
/// moment a run begins or ends, from any thread (a caller's cancellation
/// arrives on its own), and told to the SMC source in that same order.
final class RunLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let smc: (any SMCPowerControlling)?
    /// Each live run, and whether it reads.
    private var live: [Int: Bool] = [:]
    private var reading = 0

    init(smc: (any SMCPowerControlling)?) {
        self.smc = smc
    }

    var readingRuns: Int {
        lock.withLock { reading }
    }

    func isLive(_ id: Int) -> Bool {
        lock.withLock { live[id] != nil }
    }

    /// Run `id` begins; the first reading run shows the section.
    func begin(_ id: Int, reads: Bool) {
        lock.withLock {
            live[id] = reads
            guard reads else { return }
            reading += 1
            if reading == 1 { smc?.send(.shown(true)) }
        }
    }

    /// Run `id` ends, once: a second call does nothing. Returns whether this
    /// end hid the section (the last reading run ended).
    func end(_ id: Int) -> Bool {
        lock.withLock {
            guard let reads = live.removeValue(forKey: id), reads else { return false }
            reading -= 1
            guard reading == 0 else { return false }
            smc?.send(.shown(false))
            return true
        }
    }
}

/// Ends a run once, whichever comes first: its own end, its caller's
/// cancellation, or the refresher ending it; and lets the caller's wait
/// return with how it ended.
final class RunEnd: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: PowerFlowRunOutcome?
    private var waiter: CheckedContinuation<PowerFlowRunOutcome, Never>?

    /// Ends the run at `now` if it has not ended: `ending` ends its
    /// accounting and says whether that hid the section. Later calls do
    /// nothing.
    func finish(at now: ContinuousClock.Instant, _ ending: () -> Bool) {
        let (pending, ended): (CheckedContinuation<PowerFlowRunOutcome, Never>?, PowerFlowRunOutcome?) = lock.withLock {
            guard outcome == nil else { return (nil, nil) }
            let ended = PowerFlowRunOutcome(hidSection: ending(), endedAt: now)
            outcome = ended
            defer { waiter = nil }
            return (waiter, ended)
        }
        if let pending, let ended {
            pending.resume(returning: ended)
        }
    }

    /// Returns how the run ended, once it has, before or after this call.
    func wait() async -> PowerFlowRunOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<PowerFlowRunOutcome, Never>) in
            let ended: PowerFlowRunOutcome? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ended { continuation.resume(returning: ended) }
        }
    }
}

/// A source whose reads never overlap: a read asked for while another is in
/// flight waits for that one and gets its sample, so the menu never has more
/// than one read of its own in flight. A caller whose task is cancelled (its
/// run has ended) starts no read and waits for none.
actor SingleFlightPowerFlowReading: PowerFlowReading {
    private let base: any PowerFlowReading
    private var inFlight: Task<PowerFlowSample, any Error>?
    /// How many reads are waiting for the one in flight.
    private(set) var waitingReads = 0

    init(_ base: any PowerFlowReading) {
        self.base = base
    }

    nonisolated var sourceName: String { base.sourceName }

    nonisolated var updateInterval: Duration { base.updateInterval }

    func currentSample() async throws -> PowerFlowSample {
        // Checked here, where a read is admitted: a run that ended while its
        // request was on its way starts nothing.
        try Task.checkCancellation()
        if let inFlight {
            waitingReads += 1
            defer { waitingReads -= 1 }
            return try await inFlight.value
        }
        let read = Task { [base] in
            let began = ContinuousClock.now
            var sample = try await base.currentSample()
            // Every display read is ordered by when it began, whatever the
            // source (``PowerFlowState``).
            if sample.readBegan == nil {
                sample.readBegan = began
            }
            return sample
        }
        inFlight = read
        defer { inFlight = nil }
        return try await read.value
    }
}
