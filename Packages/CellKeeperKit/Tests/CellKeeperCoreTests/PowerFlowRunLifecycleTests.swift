@testable import CellKeeperCore
import Foundation
import Testing

// The refresher's run lifecycle (#109 review r2): a read never starts after
// a run has ended, and a run's end is counted once, at the moment it ends,
// so a collapse followed at once by a reopen still hides and resets.

/// A display source that counts the reads it begins. Its reads return at
/// once unless held; a held read waits for ``release()``, at most 10 s (its
/// watchdog, counted), so that no test can hang on one.
private actor CountingSource: PowerFlowReading {
    private(set) var reads = 0
    private(set) var watchdogReleases = 0
    private var holds: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(holds: Bool = false) {
        self.holds = holds
    }

    nonisolated var sourceName: String { "a counting source" }
    nonisolated var updateInterval: Duration { .seconds(60) }

    func currentSample() async -> PowerFlowSample {
        reads += 1
        let read = reads
        if holds {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.watchdog()
            }
            await withCheckedContinuation { waiting.append($0) }
        }
        return fastSample(TimeInterval(read))
    }

    func release() {
        holds = false
        let held = waiting
        waiting = []
        for read in held { read.resume() }
    }

    private func watchdog() {
        guard !waiting.isEmpty else { return }
        watchdogReleases += 1
        release()
    }
}

/// A display source whose reads always fail.
private struct FailingSource: PowerFlowReading {
    var sourceName: String { "a failing source" }
    var updateInterval: Duration { .seconds(60) }

    func currentSample() throws -> PowerFlowSample {
        throw TelemetryTestError()
    }
}

/// An SMC source that records what it is told and counts its publications,
/// running a test's action during a chosen one. It reads nothing.
private final class RecordingSMC: SMCPowerControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var told: [SMCPowerCoordinator.Input] = []
    private var published = 0
    private var stopped = false
    private var duringPublication: [Int: @Sendable () async -> Void] = [:]

    var inputs: [SMCPowerCoordinator.Input] { lock.withLock { told } }
    var publications: Int { lock.withLock { published } }
    var isStopped: Bool { lock.withLock { stopped } }

    /// Runs `action` while publication number `number` is in progress.
    func during(publication number: Int, _ action: @escaping @Sendable () async -> Void) {
        lock.withLock { duringPublication[number] = action }
    }

    func send(_ input: SMCPowerCoordinator.Input) {
        lock.withLock { told.append(input) }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    func publish() async -> SMCPowerPublication {
        let action = lock.withLock {
            published += 1
            return duringPublication.removeValue(forKey: published)
        }
        await action?()
        return SMCPowerPublication(state: .probing, window: nil)
    }
}

/// A publisher that counts its calls and cancels the calling task during a
/// chosen one, for ``PowerFlowRefresh`` without a refresher.
private actor CancellingPublisher: SMCPowerPublishing {
    private(set) var calls = 0
    private let cancelsOn: Int?

    init(cancelsOn: Int?) {
        self.cancelsOn = cancelsOn
    }

    func publish() -> SMCPowerPublication {
        calls += 1
        if calls == cancelsOn {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return SMCPowerPublication(state: .probing, window: nil)
    }
}

/// A telemetry provider that counts its reads.
private actor CountingTelemetry: TelemetryProvider {
    private(set) var reads = 0

    func currentSnapshot() -> BatterySnapshot {
        reads += 1
        return powerSnapshot(update: referenceDate.addingTimeInterval(TimeInterval(reads)))
    }

    nonisolated func powerSourceChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// An action to run on the main actor once, from a pause.
private final class MainHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@MainActor @Sendable () -> Void)?

    func arm(_ action: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { self.action = action }
    }

    func fire() async {
        let pending = lock.withLock {
            defer { action = nil }
            return action
        }
        if let pending {
            await MainActor.run { pending() }
        }
    }
}

private let hour: @Sendable (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3_600)) }

@Suite("Power flow run lifecycle: no read after a run ends")
@MainActor
struct PowerFlowRunEndReadTests {
    @Test("Quitting while the loop asks whether the section is wanted: nothing more is published or read")
    func stopDuringPredicate() async {
        for ending in ["stop", "endRuns"] {
            let source = CountingSource()
            let smc = RecordingSMC()
            let refresher = PowerFlowRefresher(source: source, smc: smc, pause: { _ in })
            let asks = Box(0)
            let ended = Box(false)
            let ticks = Box<[PowerFlowTick]>([])
            _ = Task {
                await refresher.run(while: {
                    asks.value += 1
                    // 1: the run's start; 2: the loop's first gate; 3: its second.
                    if asks.value == 3 {
                        if ending == "stop" { refresher.stop() } else { refresher.endRuns() }
                    }
                    return true
                }) { ticks.value.append($0) }
                ended.value = true
            }
            await eventually { await MainActor.run { ended.value } }
            try? await Task.sleep(for: .milliseconds(30))
            #expect(await source.reads == 1, "\(ending)")
            #expect(smc.publications == 1, "\(ending)")
            #expect(ticks.value.count == 1, "\(ending)")
            refresher.stop()
        }
    }

    @Test("Quitting during the SMC source's publication: no read begins")
    func stopDuringPublication() async {
        for ending in ["stop", "endRuns"] {
            let source = CountingSource()
            let smc = RecordingSMC()
            let refresher = PowerFlowRefresher(source: source, smc: smc, pause: { _ in })
            smc.during(publication: 2) {
                await MainActor.run {
                    if ending == "stop" { refresher.stop() } else { refresher.endRuns() }
                }
            }
            let ended = Box(false)
            let ticks = Box<[PowerFlowTick]>([])
            _ = Task {
                await refresher.run(while: { true }) { ticks.value.append($0) }
                ended.value = true
            }
            await eventually { await MainActor.run { ended.value } }
            try? await Task.sleep(for: .milliseconds(30))
            #expect(smc.publications == 2, "\(ending)")
            #expect(await source.reads == 1, "\(ending)")
            #expect(ticks.value.count == 1, "\(ending)")
            refresher.stop()
        }
    }

    @Test("An ended run's loop does not ask whether the section is wanted again")
    func runAwarePredicate() async {
        let hook = MainHook()
        let source = CountingSource()
        let refresher = PowerFlowRefresher(source: source, pause: { _ in await hook.fire() })
        hook.arm { refresher.endRuns() }
        let asks = Box(0)
        let ended = Box(false)
        _ = Task {
            await refresher.run(while: {
                asks.value += 1
                return true
            }) { _ in }
            ended.value = true
        }
        await eventually { await MainActor.run { ended.value } }
        try? await Task.sleep(for: .milliseconds(30))
        // The run's start and the loop's first gate; the run ended during
        // the pause, so the next gate stops without asking.
        #expect(asks.value == 2)
        #expect(await source.reads == 1)
        refresher.stop()
    }

    @Test("The single-flight reader starts no read for a caller whose run has ended")
    func singleFlightRefusesEndedCaller() async {
        let source = CountingSource()
        let reading = SingleFlightPowerFlowReading(source)
        let refused = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await reading.currentSample()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        #expect(await refused.value)
        #expect(await source.reads == 0)
        // A caller still running reads.
        _ = try? await reading.currentSample()
        #expect(await source.reads == 1)
    }
}

@Suite("Power flow refresh: cancellation after each wait")
@MainActor
struct PowerFlowRefreshWaitTests {
    @Test("Cancelled while asked whether the section is wanted: nothing is published or read")
    func cancelledDuringPredicate() async {
        let telemetry = CountingTelemetry()
        let publisher = CancellingPublisher(cancelsOn: nil)
        let asks = Box(0)
        await Task { @MainActor in
            await PowerFlowRefresh.run(
                source: BatteryDataPowerFlowReading(telemetry: telemetry),
                smc: publisher,
                while: {
                    asks.value += 1
                    if asks.value == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                    return true
                },
                pause: { _ in }
            ) { _ in }
        }.value
        #expect(await publisher.calls == 1)
        #expect(await telemetry.reads == 1)
    }

    @Test("Cancelled during the publication: no read begins")
    func cancelledDuringPublication() async {
        let telemetry = CountingTelemetry()
        let publisher = CancellingPublisher(cancelsOn: 2)
        let delivered = Box(0)
        await Task { @MainActor in
            await PowerFlowRefresh.run(
                source: BatteryDataPowerFlowReading(telemetry: telemetry),
                smc: publisher,
                while: { true },
                pause: { _ in }
            ) { _ in delivered.value += 1 }
        }.value
        #expect(await publisher.calls == 2)
        #expect(await telemetry.reads == 1)
        #expect(delivered.value == 1)
    }
}

@Suite("Power flow run lifecycle: collapse and reopen")
@MainActor
struct PowerFlowCollapseReopenTests {
    @Test("Collapsed and reopened at once, without waiting for the old run: hidden at the collapse, shown again, and counted exactly")
    func collapseThenReopen() async {
        let source = CountingSource()
        let smc = RecordingSMC()
        let refresher = PowerFlowRefresher(source: source, smc: smc, pause: { _ in try? await Task.sleep(for: .milliseconds(10)) })
        let state = Box(PowerFlowState())
        let first = Task { await refresher.run(while: { true }) { state.value.take($0) } }
        await eventually { await source.reads >= 1 }
        // The collapse, the hide event: before its run's caller resumes.
        refresher.collapse(&state.value, at: readInstant(100))
        #expect(smc.inputs == [.shown(true), .shown(false)])
        #expect(refresher.readingRuns == 0)
        // Reopened in the same turn: this run begins before the old run's
        // caller resumes.
        let reopened = Box(true)
        let counted = Box<[Int]>([])
        let outcome = await refresher.run(while: { reopened.value }) { tick in
            state.value.take(tick)
            counted.value.append(refresher.readingRuns)
            reopened.value = false
        }
        #expect(counted.value == [1])
        #expect(outcome.hidSection)
        #expect(smc.inputs == [.shown(true), .shown(false), .shown(true), .shown(false)])
        // The old run's caller resumes to nothing left to do.
        let old = await first.value
        #expect(old.hidSection)
        #expect(refresher.readingRuns == 0)
        #expect(smc.inputs.count == 4)
        refresher.stop()
    }

    @Test("Collapsed and reopened at once with a display read in flight: hidden at the collapse, and the reopened run shares the read and is counted exactly")
    func collapseThenReopenWithReadInFlight() async {
        let source = CountingSource(holds: true)
        let smc = RecordingSMC()
        let refresher = PowerFlowRefresher(source: source, smc: smc, pause: { _ in try? await Task.sleep(for: .milliseconds(10)) })
        let state = Box(PowerFlowState())
        let firstTicks = Box(0)
        let first = Task { await refresher.run(while: { true }) { _ in firstTicks.value += 1 } }
        await eventually { await source.reads == 1 }
        refresher.collapse(&state.value, at: readInstant(100))
        #expect(smc.inputs == [.shown(true), .shown(false)])
        #expect(refresher.readingRuns == 0)
        // The held read returns once the reopened run waits for it.
        let readingSource = refresher.source
        Task {
            await eventually { await readingSource.waitingReads == 1 }
            await source.release()
        }
        let reopened = Box(true)
        let counted = Box<[Int]>([])
        await refresher.run(while: { reopened.value }) { tick in
            counted.value.append(refresher.readingRuns)
            reopened.value = false
        }
        #expect(counted.value == [1])
        #expect(await source.reads == 1)
        #expect(firstTicks.value == 0)
        #expect(smc.inputs == [.shown(true), .shown(false), .shown(true), .shown(false)])
        _ = await first.value
        #expect(refresher.readingRuns == 0)
        #expect(await source.watchdogReleases == 0)
        refresher.stop()
    }

    @Test("Closing the menu hides the section at that moment, and the run's outcome clears the SMC track from then, though the menu was reopened first")
    func closeThenReopen() async {
        let smc = RecordingSMC()
        let refresher = PowerFlowRefresher(source: FailingSource(), smc: smc, pause: { _ in try? await Task.sleep(for: .milliseconds(10)) }, now: { readInstant(50) })
        var state = PowerFlowState()
        state.status(powerSnapshot(update: referenceDate), at: 1)
        state.tick(.window(smcWindow(began: 40)), at: 45)
        let first = Task { await refresher.run(while: { true }) { _ in } }
        await eventually { smc.inputs.count == 1 }
        // The menu closes: the cancellation ends the run then and there.
        first.cancel()
        #expect(smc.inputs == [.shown(true), .shown(false)])
        #expect(refresher.readingRuns == 0)
        // Reopened before the closed run's caller resumes.
        let reopened = Box(true)
        await refresher.run(while: { reopened.value }) { _ in reopened.value = false }
        let outcome = await first.value
        #expect(outcome.hidSection)
        #expect(outcome.endedAt == readInstant(50))
        // The close's clear drops the window read before the close.
        var closed = state
        outcome.clearSMCTrackIfHidden(&closed)
        #expect(closed.shownTrack == .registry)
        // A window read after the reopen and shown before the close's clear
        // arrives is kept by it.
        state.tick(.window(smcWindow(began: 51)), at: 54)
        #expect(state.shownTrack == .smc)
        outcome.clearSMCTrackIfHidden(&state)
        #expect(state.shownTrack == .smc)
        #expect(smc.inputs == [.shown(true), .shown(false), .shown(true), .shown(false)])
        refresher.stop()
    }

    @Test("Across a collapse and reopen with the SMC source itself, no batch or window from before the collapse is accepted after it")
    func noOldWindowAfterReopen() async throws {
        let reader = FakeSMCReader()
        let clock = ManualClock()
        let coordinator = SMCPowerCoordinator(reader: reader, configuration: SMCPowerSampler.Configuration(), now: { clock.now }, wallNow: { clock.wallNow }, pause: hour)
        let refresher = PowerFlowRefresher(source: FailingSource(), smc: coordinator, pause: hour, now: { clock.now })
        let state = Box(PowerFlowState())
        state.value.takeStatus(snapshot: powerSnapshot(update: referenceDate), evaluatedAt: referenceDate, readBegan: readInstant(0))
        await coordinator.apply(.powerSource(.externalPower))
        let first = Task { await refresher.run(while: { true }) { state.value.take($0) } }
        // The timer's first tick reads at 0 s; the test ticks to 3 s.
        for second in 1...3 {
            await eventually { await coordinator.isIdle(afterCalls: second, of: reader) }
            clock.set(Double(second))
            await coordinator.tick()
        }
        await eventually { await coordinator.isIdle(afterCalls: 4, of: reader) }
        #expect(await coordinator.state == .available)
        // A batch in flight from 4 s, and a window published at 4.5 s that is
        // still on its way when the section collapses at 5 s.
        reader.hold()
        clock.set(4)
        await coordinator.tick()
        await eventually { reader.calls == 5 }
        clock.set(4.5)
        let inTransit = try #require(await coordinator.publish().window)
        clock.set(5)
        refresher.collapse(&state.value)
        await eventually { await coordinator.current.isShown == false }
        // The window on its way arrives after the collapse: refused.
        state.value.take(PowerFlowTick(content: .window(inTransit), smcState: .available, at: readInstant(5.2)))
        #expect(state.value.shownTrack == .registry)
        // The batch in flight returns, within its deadline: dropped.
        clock.set(5.5)
        reader.releaseAll()
        await eventually { await coordinator.current.inFlight == nil }
        #expect(await coordinator.current.window.isEmpty)
        // Reopened at 6 s: the timer's first tick reads at once.
        clock.set(6)
        let second = Task { await refresher.run(while: { true }) { state.value.take($0) } }
        await eventually { await coordinator.isIdle(afterCalls: 6, of: reader) }
        for time in 7...8 {
            clock.set(Double(time))
            await coordinator.tick()
            await eventually { await coordinator.isIdle(afterCalls: time, of: reader) }
        }
        // Whatever the reopened run's own first tick took, the window holds
        // only batches begun after the reopen.
        let fresh = try #require(await coordinator.publish().window)
        #expect(fresh.firstBatchBegan >= readInstant(6))
        #expect(fresh.batches >= 2)
        state.value.take(PowerFlowTick(content: .window(fresh), smcState: .available, at: readInstant(9)))
        #expect(state.value.shownTrack == .smc)
        first.cancel()
        second.cancel()
        refresher.stop()
        reader.releaseAll()
        #expect(reader.watchdogReleases == 0)
    }
}

@Suite("Power flow run accounting")
struct PowerFlowRunAccountingTests {
    @Test("A run ends once: a second end neither counts nor hides again")
    func ledgerEndsOnce() {
        let smc = RecordingSMC()
        let ledger = RunLedger(smc: smc)
        ledger.begin(1, reads: true)
        ledger.begin(2, reads: true)
        #expect(ledger.end(1) == false)
        #expect(ledger.end(1) == false)
        #expect(ledger.readingRuns == 1)
        #expect(smc.inputs == [.shown(true)])
        #expect(ledger.end(2))
        #expect(ledger.end(2) == false)
        #expect(ledger.readingRuns == 0)
        #expect(smc.inputs == [.shown(true), .shown(false)])
        // A run that does not read never shows or hides.
        ledger.begin(3, reads: false)
        #expect(ledger.end(3) == false)
        #expect(smc.inputs.count == 2)
    }

    @Test("The first way a run ends decides its outcome; later ones change nothing")
    func runEndFirstWins() async {
        let smc = RecordingSMC()
        let ledger = RunLedger(smc: smc)
        ledger.begin(1, reads: true)
        let end = RunEnd()
        end.finish(at: readInstant(5)) { ledger.end(1) }
        end.finish(at: readInstant(9)) { ledger.end(1) }
        let outcome = await end.wait()
        #expect(outcome == PowerFlowRunOutcome(hidSection: true, endedAt: readInstant(5)))
        #expect(smc.inputs == [.shown(true), .shown(false)])
    }
}

@Suite("SMC power coordinator: timers")
struct SMCPowerTimerTests {
    @Test("A tick of a timer since replaced, on its way to the actor when the section was hidden and shown again, does nothing")
    func staleTimerTick() async {
        let reader = FakeSMCReader()
        let clock = ManualClock()
        let source = SMCPowerCoordinator(reader: reader, configuration: SMCPowerSampler.Configuration(), now: { clock.now }, wallNow: { clock.wallNow }, pause: hour)
        await source.apply(.shown(true))
        await eventually { await source.isIdle(afterCalls: 1, of: reader) }
        let stale = await source.timerNumber
        await source.apply(.shown(false))
        await source.apply(.shown(true))
        await eventually { await source.isIdle(afterCalls: 2, of: reader) }
        clock.set(1)
        await source.tick(timer: stale)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(reader.calls == 2)
        #expect(await source.current.inFlight == nil)
        // The running timer's tick reads.
        await source.tick(timer: await source.timerNumber)
        await eventually { reader.calls == 3 }
        #expect(reader.calls == 3)
        reader.releaseAll()
        source.stop()
        await eventually { await source.isStopped }
        #expect(reader.watchdogReleases == 0)
    }
}
