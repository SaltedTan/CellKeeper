import Foundation

/// The menu's display-only reads of the power flow as the app runs them
/// (D114): ``PowerFlowRefresh`` for each time the menu shows the expanded
/// section, through one source whose reads never overlap, and a stop for
/// quitting.
///
/// The section's task can start a run while an earlier one is still
/// finishing (SwiftUI starts it again when the section is expanded or
/// collapsed), so two runs may overlap; they share one read at a time. The
/// controller's own telemetry reads are separate and may overlap these
/// (``TelemetryProvider`` allows it).
@MainActor
public final class PowerFlowRefresher {
    let source: SingleFlightPowerFlowReading
    private let interval: Duration
    private let pause: @Sendable (Duration) async -> Void
    private var runs: [Int: Task<Void, Never>] = [:]
    private var nextRun = 0
    /// True once ``stop()`` was called: nothing is read or delivered after.
    public private(set) var isStopped = false

    public init(
        source: any PowerFlowReading,
        interval: Duration = PowerFlowRefresh.interval,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.source = SingleFlightPowerFlowReading(source)
        self.interval = interval
        self.pause = pause
    }

    /// Reads while `isWanted` holds, until the calling task is cancelled or
    /// ``stop()`` is called, handing each sample to `deliver`
    /// (``PowerFlowRefresh/run(source:interval:while:pause:deliver:)``).
    /// Returns at once once stopped.
    public func run(
        while isWanted: @escaping @MainActor @Sendable () -> Bool,
        deliver: @escaping @MainActor @Sendable (PowerFlowSample) -> Void
    ) async {
        guard !isStopped else { return }
        let id = nextRun
        nextRun += 1
        let task = Task { [source, interval, pause] in
            await PowerFlowRefresh.run(
                source: source,
                interval: interval,
                while: { [weak self] in self?.isStopped == false && isWanted() },
                pause: pause
            ) { [weak self] sample in
                // A read that ends after stop() is dropped.
                guard self?.isStopped == false else { return }
                deliver(sample)
            }
        }
        runs[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        runs[id] = nil
    }

    /// Stops every run and any later one: CellKeeper is quitting. A read in
    /// flight ends on its own, and its sample is dropped.
    public func stop() {
        isStopped = true
        for task in runs.values {
            task.cancel()
        }
        runs.removeAll()
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
