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
        for _ in 0..<100_000 where reads < count {
            await Task.yield()
        }
    }
}

extension SingleFlightPowerFlowReading {
    /// Waits until `count` reads wait for the one in flight.
    func untilWaiting(_ count: Int) async {
        for _ in 0..<100_000 where waitingReads < count {
            await Task.yield()
        }
    }
}

@MainActor
private final class Received {
    var samples: [PowerFlowSample] = []
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
        let first = Task { await refresher.run(while: { true }) { received.samples.append($0) } }
        await source.untilReads(1)
        let second = Task { await refresher.run(while: { true }) { received.samples.append($0) } }
        await refresher.source.untilWaiting(1)
        #expect(await refresher.source.waitingReads == 1)
        #expect(await source.reads == 1)
        await source.release()
        for _ in 0..<1_000 where received.samples.count < 2 { await Task.yield() }
        #expect(received.samples.count == 2)
        #expect(await source.mostInFlight == 1)
        first.cancel()
        second.cancel()
        await first.value
        await second.value
    }

    @Test("Quitting stops a run whose read is in flight: its sample is dropped and nothing more is read")
    func stopWithReadInFlight() async {
        let source = SuspendedSource()
        let refresher = PowerFlowRefresher(source: source, pause: { _ in })
        let received = Received()
        let run = Task { await refresher.run(while: { true }) { received.samples.append($0) } }
        await source.untilReads(1)
        refresher.stop()
        #expect(refresher.isStopped)
        await source.release()
        await run.value
        #expect(received.samples.isEmpty)
        #expect(await source.reads == 1)
        // Any later run returns at once, reading nothing.
        await refresher.run(while: { true }) { received.samples.append($0) }
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
            await refresher.run(while: { true }) { received.samples.append($0) }
            ended.value = true
        }
        for _ in 0..<100_000 where received.samples.isEmpty { await Task.yield() }
        #expect(received.samples.count == 1)
        refresher.stop()
        for _ in 0..<100_000 where !ended.value { await Task.yield() }
        #expect(ended.value)
        // Should it not have ended, the caller's cancellation ends it, so a
        // regression fails here instead of hanging.
        run.cancel()
        await run.value
        #expect(await source.reads == 1)
    }

    @Test("Cancelling the calling task, as the menu closing does, ends the run")
    func cancelledCaller() async {
        let source = SuspendedSource()
        let refresher = PowerFlowRefresher(source: source, pause: { _ in })
        let received = Received()
        let run = Task { await refresher.run(while: { true }) { received.samples.append($0) } }
        await source.untilReads(1)
        run.cancel()
        await source.release()
        await run.value
        #expect(received.samples.isEmpty)
        #expect(await source.reads == 1)
        #expect(!refresher.isStopped)
    }
}
