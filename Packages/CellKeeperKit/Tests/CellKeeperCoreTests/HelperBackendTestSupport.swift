import CellKeeperCore
import CellKeeperHelperCore
import Foundation

/// The helper's power reading, set by the test. Unless `readAtUptime` is
/// set, each reading is stamped with the clock's current time, like a live
/// read.
final class StubHelperPower: HelperPowerReading, @unchecked Sendable {
    struct Values {
        var stateOfCharge: Int? = 60
        var isOnExternalPower: Bool? = true
        var isAdapterPresent: Bool? = true
        var isThermalPressureHigh = false
        var readAtUptime: TimeInterval?
        var isUnavailable = false
    }

    private let lock = NSLock()
    private let clock: TestClock
    private var values = Values()

    init(clock: TestClock) {
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
final class HelperEventLog: @unchecked Sendable {
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

    func contains(where predicate: (HelperEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }

    func count(where predicate: (HelperEvent) -> Bool) -> Int {
        events.filter(predicate).count
    }
}

struct TransportTestError: Error, CustomStringConvertible {
    var description: String { "test transport failure" }
}

/// A connection to an engine in the test that can fail like an NSXPC one:
/// a failure throws and ends the session, as the helper would when the
/// connection drops.
final class TestHelperConnection: HelperConnection, @unchecked Sendable {
    let session: HelperSession
    private let lock = NSLock()
    private var pendingFailures = 0
    private var helloStatus: HelperStatus?
    private var isMismatchArmed = false
    private var reportsMismatchAfterActivation = false
    private var endsSessionBeforeRestore = false

    init(session: HelperSession, helloStatus: HelperStatus?) {
        self.session = session
        self.helloStatus = helloStatus
    }

    /// Makes the next `count` requests fail as a transport failure.
    func failNextRequests(_ count: Int) {
        lock.withLock { pendingFailures += count }
    }

    /// After the next successful activation, the next state read reports
    /// nothing active, as if the read-back did not match.
    func reportMismatchAfterNextActivation() {
        lock.withLock { reportsMismatchAfterActivation = true }
    }

    /// Ends the session just before the next restore reaches the helper,
    /// as if the connection had dropped in between.
    func endSessionBeforeNextRestore() {
        lock.withLock { endsSessionBeforeRestore = true }
    }

    private func takeSessionEndBeforeRestore() -> Bool {
        lock.withLock {
            defer { endsSessionBeforeRestore = false }
            return endsSessionBeforeRestore
        }
    }

    private func takeFailure() -> Bool {
        lock.withLock {
            guard pendingFailures > 0 else { return false }
            pendingFailures -= 1
            return true
        }
    }

    private func failIfInjected() async throws {
        if takeFailure() {
            await session.invalidate()
            throw TransportTestError()
        }
    }

    private func takeArmedMismatch() -> Bool {
        lock.withLock {
            defer { isMismatchArmed = false }
            return isMismatchArmed
        }
    }

    private func armMismatchIfRequested() {
        lock.withLock {
            if reportsMismatchAfterActivation {
                reportsMismatchAfterActivation = false
                isMismatchArmed = true
            }
        }
    }

    func hello(clientProtocolVersion: Int) async throws -> HelperHelloReply {
        try await failIfInjected()
        var reply = await session.hello(clientProtocolVersion: clientProtocolVersion)
        if let status = lock.withLock({ helloStatus }) {
            reply.status = status
        }
        return reply
    }

    func readState() async throws -> HelperStateReply {
        try await failIfInjected()
        var reply = await session.readState()
        if takeArmedMismatch() {
            reply.activeControls = []
        }
        return reply
    }

    func acquireOrRenewLease(control: Int, seconds: Int) async throws -> HelperLeaseReply {
        try await failIfInjected()
        return await session.acquireOrRenewLease(control: control, seconds: seconds)
    }

    func releaseLease(control: Int) async throws -> HelperStatus {
        try await failIfInjected()
        return await session.releaseLease(control: control)
    }

    func setControl(control: Int, active: Bool) async throws -> HelperStatus {
        try await failIfInjected()
        let status = await session.setControl(control: control, active: active)
        if active, status == .ok {
            armMismatchIfRequested()
        }
        return status
    }

    func restoreDefaults() async throws -> HelperStatus {
        try await failIfInjected()
        if takeSessionEndBeforeRestore() {
            await session.invalidate()
        }
        return await session.restoreDefaults()
    }

    func restoreDefaultsAndExit() async throws -> HelperStatus {
        try await failIfInjected()
        return await session.restoreDefaultsAndExit()
    }

    func invalidate() async {
        await session.invalidate()
    }
}

/// Opens ``TestHelperConnection``s to an engine in the test.
final class TestHelperTransport: HelperTransport, @unchecked Sendable {
    let engine: HelperEngine
    private let lock = NSLock()
    private var opened: [TestHelperConnection] = []
    private var isReachableValue = true
    private var helloStatusValue: HelperStatus?

    init(engine: HelperEngine) {
        self.engine = engine
    }

    /// False makes `connect()` fail, as if the helper were not installed.
    var isReachable: Bool {
        get { lock.withLock { isReachableValue } }
        set { lock.withLock { isReachableValue = newValue } }
    }

    /// Replaces the status of `hello` on later connections.
    var helloStatus: HelperStatus? {
        get { lock.withLock { helloStatusValue } }
        set { lock.withLock { helloStatusValue = newValue } }
    }

    var connections: [TestHelperConnection] {
        lock.withLock { opened }
    }

    var latest: TestHelperConnection? {
        connections.last
    }

    func connect() async throws -> any HelperConnection {
        guard isReachable else { throw TransportTestError() }
        await engine.start()
        let connection = TestHelperConnection(session: await engine.openSession(), helloStatus: helloStatus)
        lock.withLock { opened.append(connection) }
        return connection
    }
}

/// A charge control that changes the simulated state but says it is real,
/// for the outcomes a hardware helper reports.
struct UnsimulatedChargeControl: HelperChargeControl {
    let inner: SimulatedChargeControl

    func probe() -> HelperProbe {
        HelperProbe(capabilities: inner.probe().capabilities, isSimulated: false)
    }

    func apply(_ control: HelperControl, active: Bool) throws {
        try inner.apply(control, active: active)
    }

    func readBack() throws -> Set<HelperControl> {
        try inner.readBack()
    }

    func restoreDefaults() throws {
        try inner.restoreDefaults()
    }
}

/// Records when the backend starts and stops holding a control.
final class RecordingLeaseActivity: LeaseActivity, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []

    /// Every call, in order.
    var changes: [Bool] {
        lock.withLock { calls }
    }

    /// Whether the activity is held now.
    var isHolding: Bool {
        changes.last ?? false
    }

    func setHolding(_ isHolding: Bool) {
        lock.withLock { calls.append(isHolding) }
    }
}

/// A helper engine on a simulated control, a stub power reading and a test
/// clock, and a backend that talks to it through a ``TestHelperTransport``.
struct HelperRig {
    let clock: TestClock
    let control: SimulatedChargeControl
    let power: StubHelperPower
    let events = HelperEventLog()
    let activity = RecordingLeaseActivity()
    let engine: HelperEngine
    let transport: TestHelperTransport
    let backend: HelperChargingBackend

    static let descriptor = BackendDescriptor(identifier: "test-helper", displayName: "Test helper", summary: "")

    /// - Parameters:
    ///   - isSimulated: false uses a control that says it changes hardware.
    ///   - chargeControl: replaces the control (for a monitor-only helper).
    ///   - backendClockOffset: added to the backend's clock, which otherwise
    ///     is the engine's.
    init(clock: TestClock = TestClock(), isSimulated: Bool = true, chargeControl: (any HelperChargeControl)? = nil, backendClockOffset: TimeInterval = 0) {
        self.clock = clock
        let control = SimulatedChargeControl()
        self.control = control
        power = StubHelperPower(clock: clock)
        let events = events
        engine = HelperEngine(
            control: chargeControl ?? (isSimulated ? control : UnsimulatedChargeControl(inner: control)),
            power: power,
            build: 7,
            uptime: { clock.uptime },
            events: { events.record($0) }
        )
        transport = TestHelperTransport(engine: engine)
        backend = HelperChargingBackend(
            descriptor: Self.descriptor,
            transport: transport,
            uptime: { clock.uptime + backendClockOffset },
            pause: { clock.advance(by: $0) },
            activity: activity
        )
    }

    /// A controller for this rig's backend, with telemetry on the same clock.
    func controller(percent: Int = 85, settings: ChargingSettings = .default) -> (ChargeController, StubTelemetry) {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: percent), clock: clock)
        let controller = ChargeController(
            telemetry: telemetry,
            backend: backend,
            settings: settings,
            now: { clock.now },
            uptime: { clock.uptime }
        )
        return (controller, telemetry)
    }

    /// Takes a first reading, then a second, distinct one a minute later, so
    /// that a charge at or above the limit is acted on (rule R14).
    @discardableResult
    func confirmedEvaluation(_ controller: ChargeController) async -> ControllerStatus {
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        return await controller.evaluate(.periodic)
    }

    /// The engine's state as another client sees it.
    func observedState() async -> HelperStateReply {
        let session = await engine.openSession()
        _ = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        let state = await session.readState()
        await session.invalidate()
        return state
    }
}
