@testable import CellKeeperCore
import Foundation
import Testing

/// Holds the timer between ticks until the task is cancelled, so that a
/// test ticks by hand.
private let manualTicks: @Sendable (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3_600)) }

@Suite("SMC power coordinator")
struct SMCPowerCoordinatorTests {
    private func coordinator(_ reader: FakeSMCReader, clock: ManualClock, pause: @escaping @Sendable (Duration) async -> Void = manualTicks) -> SMCPowerCoordinator {
        SMCPowerCoordinator(reader: reader, configuration: SMCPowerSampler.Configuration(), now: { clock.now }, wallNow: { clock.wallNow }, pause: pause)
    }

    /// Ends what a test started: the reader's held calls return, and the
    /// source stops, so no thread stays blocked. No held call should have
    /// needed the reader's watchdog.
    private func finish(_ coordinator: SMCPowerCoordinator, _ reader: FakeSMCReader) async {
        reader.releaseAll()
        coordinator.stop()
        await eventually { await coordinator.isStopped }
        #expect(reader.watchdogReleases == 0, "a held read was released only by the reader's watchdog")
    }

    @Test("Reads on a thread of its own, never the main thread, and asks only for PSTR and PDTR")
    func readerThread() async {
        let reader = FakeSMCReader()
        let clock = ManualClock()
        let source = coordinator(reader, clock: clock)
        await source.apply(.powerSource(.externalPower))
        await source.apply(.shown(true))
        await eventually { await source.isIdle(afterCalls: 1, of: reader) }
        #expect(reader.threads == [SMCReaderThread.name])
        #expect(reader.callsOnMainThread == 0)
        #expect(reader.keys == [[.systemTotalPower, .adapterInputPower]])
        await finish(source, reader)
    }

    @Test("Its timer reads about once a second while shown: the source becomes available and hands out a window; hidden, it reads nothing")
    func timer() async throws {
        let reader = FakeSMCReader([.values(smcValues(macUse: 12, adapterInput: 15))])
        let clock = ManualClock()
        let seconds = Seconds()
        // Each pause waits for the batch it follows to return, then moves
        // the clock a second.
        let source = coordinator(reader, clock: clock) { _ in
            await pace { await seconds.coordinator?.current.inFlight == nil }
            clock.set(await seconds.next())
        }
        await seconds.set(source)
        await source.apply(.powerSource(.externalPower))
        await source.apply(.shown(true))
        await eventually { await source.current.window.count >= 2 }
        #expect(await source.state == .available)
        let window = try #require(await source.publish().window)
        #expect(window.macUseWatts == Double(Float(12)))
        #expect(window.adapterInputWatts == 15)
        await source.apply(.shown(false))
        await eventually { await source.current.inFlight == nil }
        let calls = reader.calls
        try? await Task.sleep(for: .milliseconds(100))
        #expect(reader.calls == calls)
        #expect(await source.current.window.isEmpty)
        await finish(source, reader)
    }

    @Test("One physical read at a time across resets: a read stuck before sleep is still the only one after wake and after the menu reopens, and its result is dropped")
    func stuckReadAcrossResets() async {
        let reader = FakeSMCReader()
        let clock = ManualClock()
        let source = coordinator(reader, clock: clock)
        await source.apply(.powerSource(.externalPower))
        reader.hold()
        await source.apply(.shown(true))
        await eventually { reader.calls == 1 }
        // The Mac sleeps: the menu closes. It wakes, and the menu is opened
        // again, its timer ticking at once and then every second.
        await source.apply(.shown(false))
        clock.set(600)
        await source.apply(.wake)
        await source.apply(.shown(true))
        for second in 601...605 {
            clock.set(Double(second))
            await source.tick()
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(reader.calls == 1)
        #expect(reader.mostAtOnce == 1)
        #expect(await source.current.inFlight != nil)
        // It returns, valid: dropped, and the next tick reads again.
        reader.releaseAll()
        await eventually { await source.current.inFlight == nil }
        #expect(await source.current.inFlight == nil)
        #expect(await source.current.consecutiveValid == 0)
        await source.tick()
        await eventually { await source.isIdle(afterCalls: 2, of: reader) }
        #expect(await source.current.consecutiveValid == 1)
        await finish(source, reader)
    }

    @Test("A read not back within 2 s is stalled, the source goes on, and its late result is dropped")
    func stalledRead() async {
        let reader = FakeSMCReader()
        let clock = ManualClock()
        let source = coordinator(reader, clock: clock)
        await source.apply(.powerSource(.externalPower))
        await source.apply(.shown(true))
        // The timer's first tick reads at once; the test ticks the next two.
        for second in 1...2 {
            await eventually { await source.isIdle(afterCalls: second, of: reader) }
            clock.set(Double(second))
            await source.tick()
        }
        await eventually { await source.state == .available }
        #expect(await source.state == .available)
        reader.hold()
        clock.set(3)
        await source.tick()
        await eventually { reader.calls == 4 }
        clock.set(5)
        await source.tick()
        #expect(await source.current.inFlight?.isStalled == true)
        #expect(await source.state == .failing)
        // The actor is not blocked: it still publishes and takes inputs.
        #expect(await source.publish() == SMCPowerPublication(state: .failing, window: nil))
        await source.apply(.wake)
        reader.releaseAll()
        await eventually { await source.current.inFlight == nil }
        #expect(await source.current.consecutiveValid == 0)
        #expect(await source.state == .failing)
        await finish(source, reader)
    }

    @Test("A read that returns 2.1 s after it began, before any tick saw it, is a stall and publishes nothing")
    func lateReturnBeforeTick() async {
        let reader = FakeSMCReader()
        let clock = ManualClock()
        let source = coordinator(reader, clock: clock)
        await source.apply(.powerSource(.externalPower))
        await source.apply(.shown(true))
        for second in 1...2 {
            await eventually { await source.isIdle(afterCalls: second, of: reader) }
            clock.set(Double(second))
            await source.tick()
        }
        await eventually { await source.isIdle(afterCalls: 3, of: reader) }
        #expect(await source.state == .available)
        _ = await source.publish()
        reader.hold()
        clock.set(3)
        await source.tick()
        await eventually { reader.calls == 4 }
        // The read returns at 5.1 s; the timer has not ticked since 3 s.
        clock.set(5.1)
        reader.releaseAll()
        await eventually { await source.current.inFlight == nil }
        #expect(await source.state == .failing)
        #expect(await source.publish() == SMCPowerPublication(state: .failing, window: nil))
        await finish(source, reader)
    }

    @Test("A reader that cannot open backs off; the placeholder's \"unavailable\" does the same")
    func openFails() async {
        let reader = FakeSMCReader([.openFails(.unavailable)])
        let clock = ManualClock()
        let source = coordinator(reader, clock: clock)
        await source.apply(.shown(true))
        await eventually { await source.state == .backingOff }
        #expect(await source.state == .backingOff)
        #expect(await source.current.nextOpenAttempt == readInstant(30))
        await finish(source, reader)
    }

    @Test("What the app sends is applied in order")
    func inputsInOrder() async {
        let reader = FakeSMCReader()
        let clock = ManualClock()
        let source = coordinator(reader, clock: clock)
        source.send(.powerSource(.externalPower))
        source.send(.shown(true))
        source.send(.powerSource(.battery))
        source.send(.shown(false))
        source.send(.powerSource(.externalPower))
        await eventually { await source.current.generation >= 3 }
        #expect(await source.current.isShown == false)
        #expect(await source.current.powerSource == .externalPower)
        // Hidden once and two power-source changes: three resets.
        #expect(await source.current.generation == 3)
        await finish(source, reader)
    }

    @Test("Stopped, nothing begins or is published, and a read in flight is not waited for")
    func stop() async {
        let reader = FakeSMCReader()
        let clock = ManualClock()
        let source = coordinator(reader, clock: clock)
        reader.hold()
        await source.apply(.shown(true))
        await eventually { reader.calls == 1 }
        source.stop()
        await eventually { await source.isStopped }
        #expect(await source.isStopped)
        await source.apply(.shown(true))
        await source.tick()
        #expect(await source.publish().window == nil)
        reader.releaseAll()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(reader.calls == 1)
    }
}

/// Counts seconds for a pause that moves a manual clock, and holds the
/// coordinator it waits on.
private actor Seconds {
    private var value = 0.0
    private(set) weak var coordinator: SMCPowerCoordinator?

    func set(_ coordinator: SMCPowerCoordinator) {
        self.coordinator = coordinator
    }

    func next() -> Double {
        value += 1
        return value
    }
}

/// A flag set from any thread, with a note.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    private var text: String?

    var value: Bool { lock.withLock { isSet } }
    var note: String? { lock.withLock { text } }

    func set(note: String? = nil) {
        lock.withLock {
            isSet = true
            text = note
        }
    }
}

@Suite("SMC reader thread")
struct SMCReaderThreadTests {
    @Test("Once stopped, a call handed over is dropped and no thread starts")
    func stoppedDropsCalls() async {
        let thread = SMCReaderThread()
        let ran = Flag()
        thread.stop()
        thread.run { ran.set() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!ran.value)
        #expect(!thread.isStarted)
        #expect(!thread.hasPendingCall)
    }

    @Test("Stopped while a call runs: a call waiting at the stop is dropped, and the thread ends once the running call returns")
    func stopWhileRunning() async {
        let thread = SMCReaderThread()
        let release = DispatchSemaphore(value: 0)
        let first = Flag()
        let second = Flag()
        thread.run {
            first.set(note: Thread.current.name)
            // Bounded, should the test fail before releasing it.
            _ = release.wait(timeout: .now() + .seconds(10))
        }
        await eventually { first.value }
        #expect(first.note == SMCReaderThread.name)
        thread.run { second.set() }
        #expect(thread.hasPendingCall)
        thread.stop()
        #expect(!thread.hasPendingCall)
        #expect(!thread.hasEnded)
        release.signal()
        await eventually { thread.hasEnded }
        #expect(thread.hasEnded)
        #expect(!second.value)
    }
}
