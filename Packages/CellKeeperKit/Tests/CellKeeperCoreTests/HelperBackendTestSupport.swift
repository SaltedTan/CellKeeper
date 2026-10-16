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
/// connection drops. It records every request and the helper's reply, and
/// runs its transport's latency hooks around each.
final class TestHelperConnection: HelperConnection, @unchecked Sendable {
    /// A request the backend sent, and the status of the helper's reply.
    struct Exchange: Equatable {
        var request: HelperRequestKind
        var status: HelperStatus
    }

    let session: HelperSession
    private weak var transport: TestHelperTransport?
    private let lock = NSLock()
    private var pendingFailures = 0
    private var helloStatus: HelperStatus?
    private var isMismatchArmed = false
    private var reportsMismatchAfterActivation = false
    private var endsSessionBeforeRestore = false
    private var budgetSpends: [HelperRequestKind: Int] = [:]
    private var recorded: [Exchange] = []

    init(session: HelperSession, helloStatus: HelperStatus?, transport: TestHelperTransport? = nil) {
        self.session = session
        self.helloStatus = helloStatus
        self.transport = transport
    }

    /// Every request the backend sent on this connection, in order.
    var exchanges: [Exchange] {
        lock.withLock { recorded }
    }

    /// Before each of the next `count` requests of `kind` reaches the helper
    /// (and after its admission delay), spends what is left of the session's
    /// request budget, as requests made on the session behind the backend's
    /// back would. Each spend ends with one refused read.
    func spendBudget(before kind: HelperRequestKind, times count: Int = 1) {
        lock.withLock { budgetSpends[kind, default: 0] += count }
    }

    private func takeBudgetSpend(before kind: HelperRequestKind) -> Bool {
        lock.withLock {
            guard let remaining = budgetSpends[kind], remaining > 0 else { return false }
            budgetSpends[kind] = remaining - 1
            return true
        }
    }

    /// The request is about to reach the helper: its admission delay, then
    /// any budget spent behind the backend's back.
    private func arrive(_ kind: HelperRequestKind) async {
        transport?.beforeAdmission?(kind)
        guard takeBudgetSpend(before: kind) else { return }
        for _ in 0...HelperEngine.requestBurst {
            if await session.readState().status == .rateLimited { return }
        }
    }

    /// The helper replied: the exchange is recorded, then the reply's delay.
    private func depart<Reply>(_ kind: HelperRequestKind, _ status: HelperStatus, _ reply: Reply) -> Reply {
        lock.withLock { recorded.append(Exchange(request: kind, status: status)) }
        transport?.beforeReply?(kind)
        return reply
    }

    /// Makes the next `count` requests fail as a transport failure.
    func failNextRequests(_ count: Int) {
        lock.withLock { pendingFailures += count }
    }

    /// Lets `count` requests through, then fails the next one as a
    /// transport failure.
    func failRequest(after count: Int) {
        lock.withLock { requestsBeforeFailure = count }
    }

    private var requestsBeforeFailure: Int?

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
            if let remaining = requestsBeforeFailure {
                if remaining == 0 {
                    requestsBeforeFailure = nil
                    return true
                }
                requestsBeforeFailure = remaining - 1
            }
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
        await arrive(.hello)
        var reply = await session.hello(clientProtocolVersion: clientProtocolVersion)
        if let status = lock.withLock({ helloStatus }) {
            reply.status = status
        }
        return depart(.hello, reply.status, reply)
    }

    func readState() async throws -> HelperStateReply {
        try await failIfInjected()
        await arrive(.readState)
        var reply = await session.readState()
        if takeArmedMismatch() {
            reply.activeControls = []
        }
        return depart(.readState, reply.status, reply)
    }

    func acquireOrRenewLease(control: Int, seconds: Int) async throws -> HelperLeaseReply {
        try await failIfInjected()
        await arrive(.acquireOrRenewLease)
        let reply = await session.acquireOrRenewLease(control: control, seconds: seconds)
        return depart(.acquireOrRenewLease, reply.status, reply)
    }

    func releaseLease(control: Int) async throws -> HelperStatus {
        try await failIfInjected()
        await arrive(.releaseLease)
        let status = await session.releaseLease(control: control)
        return depart(.releaseLease, status, status)
    }

    func setControl(control: Int, active: Bool) async throws -> HelperStatus {
        try await failIfInjected()
        await arrive(.setControl)
        let status = await session.setControl(control: control, active: active)
        if active, status == .ok {
            armMismatchIfRequested()
        }
        return depart(.setControl, status, status)
    }

    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64) async throws -> HelperStatus {
        try await failIfInjected()
        await arrive(.clearControlIfUnchanged)
        let status = await session.clearControlIfUnchanged(control: control, generation: generation, helperInstance: helperInstance)
        return depart(.clearControlIfUnchanged, status, status)
    }

    func restoreDefaults() async throws -> HelperStatus {
        try await failIfInjected()
        if takeSessionEndBeforeRestore() {
            await session.invalidate()
        }
        await arrive(.restoreDefaults)
        let status = await session.restoreDefaults()
        return depart(.restoreDefaults, status, status)
    }

    func restoreDefaultsAndExit() async throws -> HelperStatus {
        try await failIfInjected()
        await arrive(.restoreDefaultsAndExit)
        let status = await session.restoreDefaultsAndExit()
        return depart(.restoreDefaultsAndExit, status, status)
    }

    func invalidate() async {
        await session.invalidate()
    }
}

/// Opens ``TestHelperConnection``s to an engine in the test, and can
/// relaunch the helper as a new engine on the same control, as launchd
/// would.
final class TestHelperTransport: HelperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let makeEngine: (@Sendable () -> HelperEngine)?
    private var currentEngine: HelperEngine
    private var opened: [TestHelperConnection] = []
    private var isReachableValue = true
    private var helloStatusValue: HelperStatus?
    private var beforeAdmissionValue: (@Sendable (HelperRequestKind) -> Void)?
    private var beforeReplyValue: (@Sendable (HelperRequestKind) -> Void)?

    init(engine: HelperEngine, relaunching makeEngine: (@Sendable () -> HelperEngine)? = nil) {
        self.currentEngine = engine
        self.makeEngine = makeEngine
    }

    /// The engine connections are made to now.
    var engine: HelperEngine {
        lock.withLock { currentEngine }
    }

    /// Replaces the engine with a new one, as a relaunched helper process.
    func relaunch() {
        guard let makeEngine else { return }
        let fresh = makeEngine()
        lock.withLock { currentEngine = fresh }
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

    /// Runs, on every connection, as a request is about to reach the
    /// helper. A test moves its clock here to delay the request's admission
    /// (a loaded Mac, App Nap, the NSXPC transport); the backend cannot see
    /// when the helper admits it.
    var beforeAdmission: (@Sendable (HelperRequestKind) -> Void)? {
        get { lock.withLock { beforeAdmissionValue } }
        set { lock.withLock { beforeAdmissionValue = newValue } }
    }

    /// Runs, on every connection, as a reply is about to reach the backend;
    /// a test moves its clock here to delay the reply.
    var beforeReply: (@Sendable (HelperRequestKind) -> Void)? {
        get { lock.withLock { beforeReplyValue } }
        set { lock.withLock { beforeReplyValue = newValue } }
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
        let connection = TestHelperConnection(session: await engine.openSession(), helloStatus: helloStatus, transport: self)
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
    let transport: TestHelperTransport
    let backend: HelperChargingBackend
    /// Watches macOS's Charge Limit through the reader given, if any.
    let macOSChargeLimit: MacOSChargeLimitMonitor?

    /// The helper engine now running; a relaunch replaces it.
    var engine: HelperEngine {
        transport.engine
    }

    static let descriptor = BackendDescriptor(identifier: "test-helper", displayName: "Test helper", summary: "")

    /// - Parameters:
    ///   - isSimulated: false uses a control that says it changes hardware.
    ///   - chargeControl: replaces the control (for a monitor-only helper).
    ///   - backendClockOffset: added to the backend's clock, which otherwise
    ///     is the engine's.
    ///   - macOSReader: macOS's Charge Limit report, watched on the rig's
    ///     clock; nil for a Mac without the Charge Limit.
    init(
        clock: TestClock = TestClock(),
        isSimulated: Bool = true,
        chargeControl: (any HelperChargeControl)? = nil,
        backendClockOffset: TimeInterval = 0,
        macOSReader: (any ChargeLimitReading)? = nil
    ) {
        self.clock = clock
        let control = SimulatedChargeControl()
        self.control = control
        power = StubHelperPower(clock: clock)
        let events = events
        let power = power
        let hardware = chargeControl ?? (isSimulated ? control : UnsimulatedChargeControl(inner: control))
        let makeEngine: @Sendable () -> HelperEngine = {
            HelperEngine(control: hardware, power: power, build: 7, uptime: { clock.uptime }, events: { events.record($0) })
        }
        transport = TestHelperTransport(engine: makeEngine(), relaunching: makeEngine)
        let macOSChargeLimit = macOSReader.map { MacOSChargeLimitMonitor(reader: $0, now: { clock.now }, uptime: { clock.uptime }) }
        self.macOSChargeLimit = macOSChargeLimit
        backend = HelperChargingBackend(
            descriptor: Self.descriptor,
            transport: transport,
            uptime: { clock.uptime + backendClockOffset },
            pause: { clock.advance(by: $0) },
            activity: activity,
            macOSChargeLimit: macOSChargeLimit
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
