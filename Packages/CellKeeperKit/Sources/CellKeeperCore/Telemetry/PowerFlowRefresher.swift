import Foundation

/// The menu's display-only reads of the power flow as the app runs them
/// (D114, D115): ``PowerFlowRefresh`` for each time the menu shows the
/// expanded section, through one source whose reads never overlap and,
/// when the build has a reader, the SMC source, and a stop for quitting.
///
/// The section's task can start a run while an earlier one is still
/// finishing (SwiftUI starts it again when the section is expanded or
/// collapsed), so two runs may overlap; they share one read at a time, and
/// the SMC source counts as shown while any run reads. The controller's own
/// telemetry reads are separate and may overlap these
/// (``TelemetryProvider`` allows it).
@MainActor
public final class PowerFlowRefresher {
    let source: SingleFlightPowerFlowReading
    /// The SMC source; nil when the build has no reader (it is absent).
    let smc: SMCPowerCoordinator?
    private let interval: Duration
    private let pause: @Sendable (Duration) async -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var runs: [Int: Task<Void, Never>] = [:]
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

    /// Reads while `isWanted` holds, until the calling task is cancelled or
    /// ``stop()`` is called, handing each tick to `deliver`
    /// (``PowerFlowRefresh/run(source:smc:interval:while:pause:now:deliver:)``).
    /// The SMC source is told the section is shown when the first such run
    /// begins and hidden when the last ends. Returns at once once stopped.
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
        let task = Task { [source, smc, interval, pause, now] in
            await PowerFlowRefresh.run(
                source: source,
                smc: smc,
                interval: interval,
                while: { [weak self] in self?.isStopped == false && isWanted() },
                pause: pause,
                now: now
            ) { [weak self] tick in
                // A tick that ends after stop() is dropped.
                guard self?.isStopped == false else { return }
                deliver(tick)
            }
        }
        runs[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        runs[id] = nil
        if reads {
            readingRuns -= 1
            if readingRuns == 0 { smc?.send(.shown(false)) }
        }
    }

    /// Stops every run and any later one: CellKeeper is quitting. A read in
    /// flight ends on its own, and its tick is dropped; the SMC source stops
    /// without waiting for a call in flight.
    public func stop() {
        isStopped = true
        for task in runs.values {
            task.cancel()
        }
        runs.removeAll()
        smc?.stop()
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
