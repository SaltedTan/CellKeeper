import CellKeeperHelperCore
import Foundation

/// A monotonic clock the test advances by hand. Like a real clock, every
/// reading is a little later than the one before (a microsecond), unless the
/// clock is frozen.
final class HelperTestClock: @unchecked Sendable {
    static let tick: TimeInterval = 1e-6

    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var isFrozen = false

    var uptime: TimeInterval {
        lock.withLock {
            if !isFrozen {
                elapsed += Self.tick
            }
            return 50_000 + elapsed
        }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { elapsed += interval }
    }

    /// Stops the per-reading step, so readings repeat until `advance`.
    func freeze() {
        lock.withLock { isFrozen = true }
    }
}

/// A power reading whose values the test sets. Unless a fixed read time is
/// set, each reading is stamped with the clock's current time, like a live
/// read.
final class StubPowerReading: HelperPowerReading, @unchecked Sendable {
    struct Values {
        var stateOfCharge: Int? = 60
        var isOnExternalPower: Bool? = true
        var isAdapterPresent: Bool? = true
        var isThermalPressureHigh = false
        /// nil: stamped with the clock's time when read.
        var readAtUptime: TimeInterval?
        var isUnavailable = false
        /// How long each read takes on the clock.
        var readDuration: TimeInterval = 0
    }

    private let lock = NSLock()
    private let clock: HelperTestClock
    private var values = Values()

    init(clock: HelperTestClock) {
        self.clock = clock
    }

    func update(_ change: (inout Values) -> Void) {
        lock.withLock { change(&values) }
    }

    func latestPowerState() -> HelperPowerState? {
        let values = lock.withLock { self.values }
        if values.readDuration > 0 {
            clock.advance(by: values.readDuration)
        }
        guard !values.isUnavailable else { return nil }
        return HelperPowerState(
            stateOfCharge: values.stateOfCharge,
            isOnExternalPower: values.isOnExternalPower,
            isAdapterPresent: values.isAdapterPresent,
            isThermalPressureHigh: values.isThermalPressureHigh,
            readAtUptime: values.readAtUptime ?? clock.uptime
        )
    }
}

/// Collects the engine's events. A test can make the sink react to them,
/// for example by advancing the clock to model a slow sink.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HelperEvent] = []
    private var reaction: (@Sendable (HelperEvent) -> Void)?

    /// Runs `reaction` inside the sink for every later event; nil stops.
    func react(_ reaction: (@Sendable (HelperEvent) -> Void)?) {
        lock.withLock { self.reaction = reaction }
    }

    var events: [HelperEvent] {
        lock.withLock { recorded }
    }

    /// The recorded hardware writes, in order.
    var writes: [HelperWriteRecord] {
        events.compactMap {
            if case .write(let record) = $0 { return record }
            return nil
        }
    }

    func record(_ event: HelperEvent) {
        let reaction = lock.withLock {
            recorded.append(event)
            return self.reaction
        }
        reaction?(event)
    }

    func count(of event: HelperEvent) -> Int {
        events.filter { $0 == event }.count
    }

    func contains(_ event: HelperEvent) -> Bool {
        events.contains(event)
    }

    func removeAll() {
        lock.withLock { recorded.removeAll() }
    }
}

/// An engine on a simulated control, a stub power reading and a test clock.
struct Harness {
    let clock: HelperTestClock
    let control: SimulatedChargeControl
    let power: StubPowerReading
    let recorder = EventRecorder()
    let engine: HelperEngine

    init(
        control: SimulatedChargeControl = SimulatedChargeControl(),
        clock: HelperTestClock = HelperTestClock(),
        activationHistory: [HelperActivationRecord] = []
    ) {
        self.init(chargeControl: control, clock: clock, activationHistory: activationHistory)
    }

    init(
        chargeControl: any HelperChargeControl,
        clock: HelperTestClock = HelperTestClock(),
        activationHistory: [HelperActivationRecord] = []
    ) {
        self.clock = clock
        self.control = (chargeControl as? SimulatedChargeControl) ?? SimulatedChargeControl()
        let recorder = recorder
        power = StubPowerReading(clock: clock)
        engine = HelperEngine(
            control: chargeControl,
            power: power,
            build: 42,
            uptime: { clock.uptime },
            activationHistory: activationHistory,
            events: { recorder.record($0) }
        )
    }

    /// Starts the engine and returns a session that has said hello.
    func startedSession() async -> HelperSession {
        await engine.start()
        return await introducedSession()
    }

    func introducedSession() async -> HelperSession {
        let session = await engine.openSession()
        _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        return session
    }

    /// Takes the maximum lease on `control` and activates it.
    @discardableResult
    func activate(_ control: HelperControl, on session: HelperSession) async -> HelperStatus {
        let lease = await session.acquireOrRenewLease(control: control.rawValue, seconds: control.maximumLeaseSeconds)
        guard lease.status == .ok else { return lease.status }
        return await session.setControl(control: control.rawValue, active: true)
    }

    /// Spends a session's request budget: reads until the first refusal,
    /// which leaves an over-budget streak of exactly one.
    func exhaustBudget(of session: HelperSession) async {
        for _ in 0...HelperEngine.requestBurst {
            if await session.readState().status == .rateLimited { return }
        }
    }
}

extension HelperStateReply {
    var active: Set<HelperControl> { activeControls.controls }
}
