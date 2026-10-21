import Foundation

/// The menu's display-only reads of the power flow as the app runs them
/// (D114, D115): ``PowerFlowRefresh`` for each time the menu shows the
/// expanded section, through one source whose reads never overlap and,
/// when the build has a reader, the SMC source, and a stop for quitting.
///
/// The section's task can start a run while an earlier one is still
/// finishing (SwiftUI starts it again when the section is expanded or
/// collapsed), so two runs may overlap; they share one read at a time, and
/// the SMC source counts as shown while any run reads. A run ends as soon
/// as its caller is cancelled (the menu closes), the section collapses or
/// CellKeeper quits, without waiting for a display read in flight: that
/// read ends on its own and its tick is dropped, so a slow read never keeps
/// the SMC source sampling. The controller's own telemetry reads are
/// separate and may overlap these (``TelemetryProvider`` allows it).
@MainActor
public final class PowerFlowRefresher {
    /// A run not yet ended: its task, and what ends the wait for it.
    private struct Run {
        let task: Task<Void, Never>
        let end: RunEnd
    }

    let source: SingleFlightPowerFlowReading
    /// The SMC source; nil when the build has no reader (it is absent).
    let smc: SMCPowerCoordinator?
    private let interval: Duration
    private let pause: @Sendable (Duration) async -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var runs: [Int: Run] = [:]
    private var nextRun = 0
    /// The runs that began with the section expanded and have not ended.
    private(set) var readingRuns = 0
    /// True once ``stop()`` was called: nothing is read or delivered after.
    public private(set) var isStopped = false

    public init(
        source: any PowerFlowReading,
        smc: SMCPowerCoordinator? = nil,
        interval: Duration = PowerFlowRefresh.interval,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.source = SingleFlightPowerFlowReading(source)
        self.smc = smc
        self.interval = interval
        self.pause = pause
        self.now = now
    }

    /// Whether a run is reading: the section is shown in an open menu.
    public var isShowing: Bool {
        readingRuns > 0
    }

    /// Reads while `isWanted` holds, until the calling task is cancelled,
    /// ``endRuns()`` or ``stop()`` is called, handing each tick to `deliver`
    /// (``PowerFlowRefresh/run(source:smc:interval:while:pause:now:deliver:)``).
    /// The SMC source is told the section is shown when the first such run
    /// begins and hidden when the last ends. Returns at once when cancelled
    /// or ended, even with a display read in flight: that read is not
    /// waited for, and no tick of an ended run is delivered. Returns at once
    /// once stopped.
    public func run(
        while isWanted: @escaping @MainActor @Sendable () -> Bool,
        deliver: @escaping @MainActor @Sendable (PowerFlowTick) -> Void
    ) async {
        guard !isStopped else { return }
        let id = nextRun
        nextRun += 1
        let reads = isWanted()
        if reads {
            readingRuns += 1
            if readingRuns == 1 { smc?.send(.shown(true)) }
        }
        let end = RunEnd()
        // Every way a run ends cancels its task, which ends the loop; a tick
        // read before that and delivered after is dropped here.
        let task = Task { [source, smc, interval, pause, now] in
            await PowerFlowRefresh.run(
                source: source,
                smc: smc,
                interval: interval,
                while: isWanted,
                pause: pause,
                now: now
            ) { [weak self] tick in
                // A tick of a run that has ended (cancelled, collapsed or
                // stopped) is dropped.
                guard self?.isRunning(id) == true else { return }
                deliver(tick)
            }
            end.open()
        }
        runs[id] = Run(task: task, end: end)
        await withTaskCancellationHandler {
            await end.wait()
        } onCancel: {
            task.cancel()
            end.open()
        }
        runs[id] = nil
        if reads {
            readingRuns -= 1
            if readingRuns == 0 { smc?.send(.shown(false)) }
        }
    }

    /// Whether run `id` has not ended.
    private func isRunning(_ id: Int) -> Bool {
        !isStopped && runs[id] != nil
    }

    /// Ends every run at once: the section collapsed. A display read in
    /// flight ends on its own, and its tick is dropped; once the runs have
    /// returned, the SMC source is told the section is hidden. A later run
    /// reads again.
    public func endRuns() {
        for run in runs.values {
            run.task.cancel()
            run.end.open()
        }
        runs.removeAll()
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

/// Ends the wait for a run once, whichever comes first: the run's own end,
/// its caller's cancellation, or the refresher ending it.
final class RunEnd: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Returns once ``open()`` was called, before or after.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isAlreadyOpen = lock.withLock {
                if isOpen { return true }
                waiter = continuation
                return false
            }
            if isAlreadyOpen { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock {
            isOpen = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
    }
}


/// A source whose reads never overlap: a read asked for while another is in
/// flight waits for that one and gets its sample, so the menu never has more
/// than one read of its own in flight.
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
