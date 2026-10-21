import Foundation

/// Hands the power flow's refresher what the SMC source collected since the
/// last tick (``SMCPowerCoordinator``; a test fake in tests).
public protocol SMCPowerPublishing: Sendable {
    /// The source's state, and its window since the last call if it is
    /// available and read at least one valid batch. Each window is handed
    /// out once.
    func publish() async -> SMCPowerPublication
}

/// The power flow's SMC source (research note 13 §6.2, D115): reads the
/// owner's reader about once a second while the menu shows the expanded
/// Power flow section, and hands the refresher a window every 3 s.
///
/// Two places, so that a blocked read cannot stall the rest:
/// - **the reader's thread** (``SMCReaderThread``): the reader runs on one
///   thread of its own, never on the main actor or the controller's path;
/// - **this actor,** which a read never blocks: it owns the one-second
///   timer, each batch's deadline, the windows, the state and the
///   lifecycle (``SMCPowerSampler`` holds their logic).
///
/// One read at a time, physically: while a batch is in flight, no other
/// begins, whatever happened meanwhile (a reset, sleep and wake, the menu
/// closed and reopened), so at most one thread is ever blocked. A batch not
/// returned within 2 s is stalled and its late result dropped. Quitting
/// does not wait for a stuck read.
///
/// Display only: what it reads goes only to ``PowerFlowState``, never to the
/// policy, the controller or the calibration.
public actor SMCPowerCoordinator: SMCPowerPublishing {
    /// What the app tells the source, in order (``send(_:)``).
    public enum Input: Sendable, Equatable {
        /// The menu shows the expanded Power flow section, or no longer does
        /// (collapsed, or the menu closed): the timer runs only while shown,
        /// and hiding resets the window.
        case shown(Bool)
        /// The Mac woke: the window resets.
        case wake
        /// The registry track's power source: a change resets the window,
        /// and no batch begins for a second after it.
        case powerSource(PowerSource?)
    }

    private enum Message: Sendable {
        case input(Input)
        case stop
    }

    /// How often a batch is asked for while the section is shown.
    public static let batchInterval: Duration = .seconds(1)

    private var sampler: SMCPowerSampler
    private let reader: any SMCPowerReading
    private let thread = SMCReaderThread()
    private let interval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let wallNow: @Sendable () -> Date
    private let pause: @Sendable (Duration) async -> Void
    private let messages: AsyncStream<Message>.Continuation
    private var timer: Task<Void, Never>?
    /// The number of the last timer started.
    private(set) var timerNumber = 0
    /// True once ``stop()`` took effect: nothing begins or is published.
    private(set) var isStopped = false

    /// A source reading `reader`. The clocks and the pause are the system's
    /// except in tests.
    public init(
        reader: any SMCPowerReading,
        interval: Duration = batchInterval,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        wallNow: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.init(reader: reader, configuration: SMCPowerSampler.Configuration(), interval: interval, now: now, wallNow: wallNow, pause: pause)
    }

    init(
        reader: any SMCPowerReading,
        configuration: SMCPowerSampler.Configuration,
        interval: Duration = batchInterval,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        wallNow: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.reader = reader
        self.sampler = SMCPowerSampler(configuration: configuration)
        self.interval = interval
        self.now = now
        self.wallNow = wallNow
        self.pause = pause
        let (stream, continuation) = AsyncStream.makeStream(of: Message.self)
        messages = continuation
        // Applies what the app sends in the order it was sent; ends once
        // stopped.
        Task { [weak self] in
            for await message in stream {
                guard let self else { return }
                switch message {
                case .input(let input): await self.apply(input)
                case .stop: await self.halt()
                }
            }
        }
    }

    deinit {
        messages.finish()
        thread.stop()
    }

    /// Tells the source about the section, a wake or the power source.
    /// Applied in the order sent, without waiting, so the main actor can
    /// call it as things happen.
    public nonisolated func send(_ input: Input) {
        messages.yield(.input(input))
    }

    /// Stops for quitting: the timer stops, nothing more begins or is
    /// published, and the reader's thread ends once any call in flight
    /// returns. Nothing waits for that call.
    public nonisolated func stop() {
        thread.stop()
        messages.yield(.stop)
        messages.finish()
    }

    /// The source's state, for the menu and the diagnostics.
    public var state: SMCSourceState {
        sampler.state
    }

    public func publish() -> SMCPowerPublication {
        guard !isStopped else { return SMCPowerPublication(state: sampler.state, window: nil) }
        return sampler.publish()
    }

    // MARK: - Internals (driven directly by tests)

    var current: SMCPowerSampler {
        sampler
    }

    func apply(_ input: Input) {
        guard !isStopped else { return }
        switch input {
        case .shown(true):
            sampler.show()
            startTimer()
        case .shown(false):
            timer?.cancel()
            timer = nil
            sampler.hide()
        case .wake:
            sampler.reset()
        case .powerSource(let source):
            sampler.setPowerSource(source, at: now())
        }
    }

    func halt() {
        isStopped = true
        timer?.cancel()
        timer = nil
        sampler.hide()
    }

    /// Ticks at once and then every ``batchInterval`` until hidden or
    /// stopped. Each timer carries its own number: a timer cancelled while
    /// its tick was on its way to the actor (the section hidden, perhaps
    /// shown again) finds a different number there and does nothing.
    private func startTimer() {
        guard timer == nil else { return }
        timerNumber += 1
        let number = timerNumber
        timer = Task { [weak self, pause, interval] in
            while !Task.isCancelled {
                guard await self?.tick(timer: number) != nil else { return }
                await pause(interval)
            }
        }
    }

    /// Timer `number`'s tick: a tick only if that timer is the latest
    /// started. (Hidden, the sampler begins nothing whichever timer ticks.)
    func tick(timer number: Int) {
        guard number == timerNumber else { return }
        tick()
    }

    /// The timer's tick: checks the deadline of the batch in flight, and
    /// hands a new batch to the reader's thread if one may begin.
    func tick() {
        guard !isStopped, let generation = sampler.tick(at: now()) else { return }
        let keys = sampler.keys
        let (reader, now, wallNow) = (reader, now, wallNow)
        thread.run { [weak self] in
            let outcome: SMCPowerSampler.Outcome
            do {
                outcome = .read(try reader.read(keys))
            } catch {
                outcome = .openFailed
            }
            let returned = now()
            let collectedAt = wallNow()
            Task {
                await self?.batchReturned(generation: generation, outcome: outcome, at: returned, collectedAt: collectedAt)
            }
        }
    }

    private func batchReturned(generation: Int, outcome: SMCPowerSampler.Outcome, at returned: ContinuousClock.Instant, collectedAt: Date) {
        sampler.batchReturned(generation: generation, outcome: outcome, at: returned, collectedAt: collectedAt)
    }
}

/// One thread used for nothing but the SMC reader's calls, one at a time,
/// started with the first call: never the main thread, a cooperative
/// thread of Swift's concurrency, or the controller's. A call that blocks
/// blocks only this thread. Once stopped, a call not yet begun is dropped,
/// and the thread ends when the call it is making returns.
final class SMCReaderThread: @unchecked Sendable {
    static let name = "CellKeeper SMC reader"

    private let condition = NSCondition()
    private var job: (@Sendable () -> Void)?
    private var started = false
    private var ended = false
    private var isStopped = false

    /// Whether the thread was started: with the first call, never once
    /// stopped.
    var isStarted: Bool {
        condition.withLock { started }
    }

    /// Whether the thread has ended, once stopped and its call returned.
    var hasEnded: Bool {
        condition.withLock { ended }
    }

    /// Whether a call is waiting for the thread.
    var hasPendingCall: Bool {
        condition.withLock { job != nil }
    }

    /// Runs `job` on the thread. The coordinator hands over one at a time,
    /// only once the last has returned. Once stopped, `job` is dropped and
    /// no thread starts.
    func run(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        guard !isStopped else { return }
        if !started {
            started = true
            let thread = Thread { [self] in
                while let next = next() {
                    next()
                }
                condition.withLock { ended = true }
            }
            thread.name = Self.name
            thread.qualityOfService = .utility
            thread.start()
        }
        self.job = job
        condition.signal()
    }

    func stop() {
        condition.lock()
        defer { condition.unlock() }
        isStopped = true
        job = nil
        condition.signal()
    }

    /// The next call to make, or nil once stopped: the thread then ends. A
    /// stop clears the call waiting, and no call is handed over after it.
    private func next() -> (@Sendable () -> Void)? {
        condition.lock()
        defer { condition.unlock() }
        while job == nil, !isStopped {
            condition.wait()
        }
        guard let job else { return nil }
        self.job = nil
        return job
    }
}
