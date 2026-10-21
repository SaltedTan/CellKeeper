@testable import CellKeeperCore
import Foundation
import Testing

/// A source whose reads stay in flight until the test releases them,
/// counting reads and how many were in flight at once. Once released, later
/// reads end at once, so that a test cannot hang on one.
private actor SuspendedSource: PowerFlowReading {
    private(set) var reads = 0
    private(set) var inFlight = 0
    private(set) var mostInFlight = 0
    private var waiting: [AsyncStream<Void>.Continuation] = []
    private var isReleased = false

    nonisolated var sourceName: String { "a suspended source" }
    nonisolated var updateInterval: Duration { .seconds(1) }

    func currentSample() async -> PowerFlowSample {
        reads += 1
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        let read = reads
        if !isReleased {
            let (released, continuation) = AsyncStream<Void>.makeStream()
            waiting.append(continuation)
            for await _ in released { break }
        }
        inFlight -= 1
        return fastSample(TimeInterval(read))
    }

    /// Ends every read in flight, and lets later ones end at once.
    func release() {
        isReleased = true
        for continuation in waiting {
            continuation.yield()
            continuation.finish()
        }
        waiting.removeAll()
    }

    /// Waits until `count` reads have started.
    func untilReads(_ count: Int) async {
        for _ in 0..<5_000 where reads < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

extension SingleFlightPowerFlowReading {
    /// Waits until `count` reads wait for the one in flight.
    func untilWaiting(_ count: Int) async {
        for _ in 0..<5_000 where waitingReads < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class Received {
    var ticks: [PowerFlowTick] = []

    /// The ticks' display reads.
    var samples: [PowerFlowSample] {
        ticks.compactMap(\.registrySample)
    }
}

@MainActor
private final class Ended {
    var value = false
}

@Suite("Power flow refresher")
@MainActor
struct PowerFlowRefresherTests {
    @Test("A read asked for while one is in flight waits for it and gets its sample")
    func oneReadInFlight() async throws {
        let source = SuspendedSource()
        let reading = SingleFlightPowerFlowReading(source)
        let first = Task { try await reading.currentSample() }
        await source.untilReads(1)
        let second = Task { try await reading.currentSample() }
        await reading.untilWaiting(1)
        #expect(await reading.waitingReads == 1)
        #expect(await source.reads == 1)
        await source.release()
        let samples = try await [first.value, second.value]
        #expect(samples[0] == samples[1])
        // The shared read is ordered by when it began.
        #expect(samples[0].readBegan != nil)
        #expect(await source.mostInFlight == 1)
        #expect(await reading.waitingReads == 0)
        // The next read is a new one.
        _ = try await reading.currentSample()
        #expect(await source.reads == 2)
    }

    @Test("Two runs at once, as when the section's task starts again, make one read at a time")
    func overlappingRuns() async {
        let source = SuspendedSource()
        let refresher = PowerFlowRefresher(source: source, pause: { _ in try? await Task.sleep(for: .seconds(3_600)) })
        let received = Received()
        let firstEnded = Ended()
        let secondEnded = Ended()
        let first = Task {
            await refresher.run(while: { true }) { received.ticks.append($0) }
            firstEnded.value = true
        }
        await source.untilReads(1)
        let second = Task {
            await refresher.run(while: { true }) { received.ticks.append($0) }
            secondEnded.value = true
        }
        await refresher.source.untilWaiting(1)
        #expect(await refresher.source.waitingReads == 1)
        #expect(await source.reads == 1)
        await source.release()
        for _ in 0..<5_000 where received.samples.count < 2 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(received.samples.count == 2)
        #expect(await source.mostInFlight == 1)
        first.cancel()
        second.cancel()
        await untilEnded(firstEnded)
        await untilEnded(secondEnded)
        #expect(firstEnded.value)
        #expect(secondEnded.value)
        // Should a run not have ended, quitting ends it, so a regression
        // fails here instead of hanging.
        refresher.stop()
        _ = await first.value
        _ = await second.value
    }

    @Test("Quitting stops a run whose read is in flight: its sample is dropped and nothing more is read")
    func stopWithReadInFlight() async {
        let source = SuspendedSource()
        let refresher = PowerFlowRefresher(source: source, pause: { _ in })
        let received = Received()
        let run = Task { await refresher.run(while: { true }) { received.ticks.append($0) } }
        await source.untilReads(1)
        refresher.stop()
        #expect(refresher.isStopped)
        await source.release()
        _ = await run.value
        #expect(received.samples.isEmpty)
        #expect(await source.reads == 1)
        // Any later run returns at once, reading nothing.
        await refresher.run(while: { true }) { received.ticks.append($0) }
        #expect(await source.reads == 1)
        #expect(received.samples.isEmpty)
    }

    @Test("Quitting ends a run waiting between reads at once")
    func stopDuringPause() async {
        let source = SuspendedSource()
        await source.release()
        let refresher = PowerFlowRefresher(source: source, pause: { _ in try? await Task.sleep(for: .seconds(3_600)) })
        let received = Received()
        let ended = Ended()
        let run = Task {
            await refresher.run(while: { true }) { received.ticks.append($0) }
            ended.value = true
        }
        for _ in 0..<5_000 where received.samples.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(received.samples.count == 1)
        refresher.stop()
        await untilEnded(ended)
        #expect(ended.value)
        // Should it not have ended, the caller's cancellation ends it, so a
        // regression fails here instead of hanging.
        run.cancel()
        _ = await run.value
        #expect(await source.reads == 1)
    }

    @Test("Cancelling the calling task, as the menu closing does, ends the run")
    func cancelledCaller() async {
        let source = SuspendedSource()
        let refresher = PowerFlowRefresher(source: source, pause: { _ in })
        let received = Received()
        let ended = Ended()
        let run = Task {
            await refresher.run(while: { true }) { received.ticks.append($0) }
            ended.value = true
        }
        await source.untilReads(1)
        run.cancel()
        await source.release()
        await untilEnded(ended)
        #expect(ended.value)
        #expect(received.samples.isEmpty)
        #expect(await source.reads == 1)
        #expect(!refresher.isStopped)
        // Should the run not have ended, quitting ends it, so a regression
        // fails here instead of hanging.
        refresher.stop()
        _ = await run.value
    }

    /// Waits a bounded time for a run to end.
    private func untilEnded(_ ended: Ended) async {
        for _ in 0..<5_000 where !ended.value {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
