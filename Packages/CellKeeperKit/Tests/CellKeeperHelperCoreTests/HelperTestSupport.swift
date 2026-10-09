import CellKeeperHelperCore
import Foundation

/// A monotonic clock the test advances by hand.
final class HelperTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0

    var uptime: TimeInterval {
        lock.withLock { 50_000 + elapsed }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { elapsed += interval }
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

/// Collects the engine's events.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HelperEvent] = []

    var events: [HelperEvent] {
        lock.withLock { recorded }
    }

    func record(_ event: HelperEvent) {
        lock.withLock { recorded.append(event) }
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
    let clock = HelperTestClock()
    let control: SimulatedChargeControl
    let power: StubPowerReading
    let recorder = EventRecorder()
    let engine: HelperEngine

    init(control: SimulatedChargeControl = SimulatedChargeControl()) {
        self.init(chargeControl: control)
    }

    init(chargeControl: any HelperChargeControl) {
        self.control = (chargeControl as? SimulatedChargeControl) ?? SimulatedChargeControl()
        let clock = clock
        let recorder = recorder
        power = StubPowerReading(clock: clock)
        engine = HelperEngine(
            control: chargeControl,
            power: power,
            build: 42,
            uptime: { clock.uptime },
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
}

extension HelperStateReply {
    var active: Set<HelperControl> { activeControls.controls }
}
