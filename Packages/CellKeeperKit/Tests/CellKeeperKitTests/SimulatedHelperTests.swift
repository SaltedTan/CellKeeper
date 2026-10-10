@testable import CellKeeperKit
import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper power reading")
struct SystemHelperPowerReadingTests {
    private func raw(
        percent: Int? = 70,
        state: String? = "AC Power",
        present: Bool = true,
        adapter: [String: Any]? = ["Watts": 68]
    ) -> RawPowerData {
        var source: [String: Any] = ["Type": "InternalBattery", "Is Present": present]
        if let percent {
            source["Current Capacity"] = percent
            source["Max Capacity"] = 100
        }
        if let state {
            source["Power Source State"] = state
        }
        return RawPowerData(powerSource: source, providingPowerSourceType: state, adapter: adapter)
    }

    @Test("Charge, power source and an attached adapter are read from IOPowerSources")
    func onAdapter() {
        let state = SystemHelperPowerReading.powerState(from: raw(), thermalState: .nominal, readAtUptime: 42)
        #expect(state == HelperPowerState(stateOfCharge: 70, isOnExternalPower: true, isAdapterPresent: true, isThermalPressureHigh: false, readAtUptime: 42))
    }

    @Test("On battery without adapter details, no adapter is attached")
    func onBattery() {
        let state = SystemHelperPowerReading.powerState(from: raw(state: "Battery Power", adapter: nil), thermalState: .nominal, readAtUptime: 1)
        #expect(state?.isOnExternalPower == false)
        #expect(state?.isAdapterPresent == false)
    }

    @Test("Adapter details missing while on external power leave presence unknown")
    func presenceUnknown() {
        let state = SystemHelperPowerReading.powerState(from: raw(adapter: nil), thermalState: .nominal, readAtUptime: 1)
        #expect(state?.isOnExternalPower == true)
        #expect(state?.isAdapterPresent == nil)
    }

    @Test("Adapter details while on battery mean an adapter is attached")
    func adapterWhileOnBattery() {
        // What a disabled adapter would look like, if macOS still describes it.
        let state = SystemHelperPowerReading.powerState(from: raw(state: "Battery Power"), thermalState: .nominal, readAtUptime: 1)
        #expect(state?.isOnExternalPower == false)
        #expect(state?.isAdapterPresent == true)
    }

    @Test("Serious or critical thermal state is high thermal pressure", arguments: [
        (ProcessInfo.ThermalState.nominal, false), (.fair, false), (.serious, true), (.critical, true),
    ])
    func thermal(thermalState: ProcessInfo.ThermalState, isHigh: Bool) {
        #expect(SystemHelperPowerReading.powerState(from: raw(), thermalState: thermalState, readAtUptime: 1)?.isThermalPressureHigh == isHigh)
    }

    @Test("Unknown charge, power source or battery are reported as unknown")
    func unknowns() {
        let noCharge = SystemHelperPowerReading.powerState(from: raw(percent: nil), thermalState: .nominal, readAtUptime: 1)
        #expect(noCharge?.stateOfCharge == nil)
        let noSource = SystemHelperPowerReading.powerState(from: raw(state: nil), thermalState: .nominal, readAtUptime: 1)
        #expect(noSource?.isOnExternalPower == nil)
        let noBattery = SystemHelperPowerReading.powerState(from: raw(present: false), thermalState: .nominal, readAtUptime: 1)
        #expect(noBattery?.stateOfCharge == nil)
        #expect(SystemHelperPowerReading.powerState(from: RawPowerData(), thermalState: .nominal, readAtUptime: 1) == nil)
    }
}

/// Refers to an object without keeping it alive.
final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?

    init(_ object: Object?) {
        self.object = object
    }
}

/// Counts reads; each is stamped with the engine's clock.
final class CountingPower: HelperPowerReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let uptime: @Sendable () -> TimeInterval

    init(uptime: @escaping @Sendable () -> TimeInterval) {
        self.uptime = uptime
    }

    var count: Int {
        lock.withLock { reads }
    }

    func latestPowerState() -> HelperPowerState? {
        lock.withLock { reads += 1 }
        return HelperPowerState(stateOfCharge: 60, isOnExternalPower: true, isAdapterPresent: true, isThermalPressureHigh: false, readAtUptime: uptime())
    }
}

@Suite("Simulated helper")
struct SimulatedHelperTests {
    /// A Simulated helper on a clock that moves only when the backend waits
    /// for its request budget (by the time it waits) and by a microsecond
    /// per reading. On the real clock, the backend's copy of the helper's
    /// budget is judged on the backend's readings and the helper's on its
    /// own; a machine that stalls between the two can make the helper
    /// refuse a request the backend paced, so the outcome would depend on
    /// how fast the machine runs.
    private func steppedHelper() -> HelperChargingBackend {
        let clock = XPCTestClock(step: 1e-6)
        let uptime: @Sendable () -> TimeInterval = { clock.uptime }
        return HelperChargingBackend.simulatedHelper(
            power: CountingPower(uptime: uptime),
            uptime: uptime,
            pause: { clock.advance(by: $0) },
            macOSChargeLimit: nil
        )
    }

    @Test("The Simulated helper is simulated, offers both charging modes, and changes nothing")
    func simulatedHelper() async throws {
        let backend = steppedHelper()
        #expect(backend.descriptor.identifier == HelperChargingBackend.simulatedHelperIdentifier)
        #expect(backend.descriptor.displayName == "Simulated helper")
        let capabilities = await backend.capabilities()
        #expect(capabilities.availability == .simulated)
        #expect(capabilities.supportedModes == ChargeControlMode.chargingModes)
        #expect(try await backend.setMode(.inhibitCharging) == .simulated)
        #expect(try await backend.currentMode() == .inhibitCharging)
        #expect(try await backend.setMode(.normal) == .simulated)
    }

    @Test("The engine is ticked while the backend lives, and released with it")
    func noLeakedTicking() async throws {
        let power = CountingPower(uptime: HelperEngine.continuousUptime)
        var backend: HelperChargingBackend? = HelperChargingBackend.simulatedHelper(power: power, tickInterval: .milliseconds(5), macOSChargeLimit: nil)
        let engine = WeakReference((backend?.transport as? InProcessHelperTransport)?.engine)
        #expect(engine.object != nil)
        _ = try await backend?.setMode(.inhibitCharging)

        // Waits for real ticks, for at most 10 s.
        let before = power.count
        for _ in 0..<2_000 where power.count < before + 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(power.count >= before + 3)

        backend = nil
        for _ in 0..<2_000 where engine.object != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.object == nil)
        let afterRelease = power.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(power.count == afterRelease)
    }

    @Test("Sleep and wake reach the in-process engine")
    func sleepAndWake() async throws {
        let backend = steppedHelper()
        _ = try await backend.setMode(.forceDischarge)
        let transport = try #require(backend.transport as? InProcessHelperTransport)
        await transport.systemWillSleep()
        #expect(try await backend.currentMode() == .normal)
        #expect(await backend.reportedModeOrigin() == .releasedByBackend(.interlock("the Mac is about to sleep")))
        #expect(await backend.capabilities().supportedModes == [.normal, .inhibitCharging])
        await transport.systemDidWake()
        #expect(await backend.capabilities().supportedModes == ChargeControlMode.chargingModes)
    }
}

/// macOS's Charge Limit report, set by the test; never runs pmset.
final class StubChargeLimitReader: ChargeLimitReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: NativeChargeLimitReading

    init(_ reading: NativeChargeLimitReading) {
        self.reading = reading
    }

    func set(_ newReading: NativeChargeLimitReading) {
        lock.withLock { reading = newReading }
    }

    func readChargeLimit() async throws -> NativeChargeLimitReading {
        lock.withLock { reading }
    }
}

/// Wall time and monotonic uptime that advance together, set by the test.
final class KitTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { start.addingTimeInterval(elapsed) } }
    var uptime: TimeInterval { lock.withLock { 10_000 + elapsed } }

    func advance(by interval: TimeInterval) {
        lock.withLock { elapsed += interval }
    }
}

/// Battery telemetry on external power at a fixed charge, stamped with the
/// test clock.
struct KitStubTelemetry: TelemetryProvider {
    let percent: Int
    let clock: KitTestClock

    func currentSnapshot() async throws -> BatterySnapshot {
        BatterySnapshot(timestamp: clock.now, chargePercent: percent, powerSource: .externalPower, isCharging: true, isFullyCharged: false, temperatureCelsius: 30)
    }

    func powerSourceChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

@Suite("Simulated helper and macOS's Charge Limit")
struct SimulatedHelperCoexistenceTests {
    @Test("A release that fails on the Simulated helper is reported as possibly remaining, until a read-back shows it ended")
    func failedReleaseOnSimulatedHelper() async throws {
        let clock = KitTestClock()
        let control = SimulatedChargeControl()
        let reader = StubChargeLimitReader(.noLimit)
        let uptime: @Sendable () -> TimeInterval = { clock.uptime }
        let monitor = MacOSChargeLimitMonitor(reader: reader, now: { clock.now }, uptime: uptime)
        let backend = HelperChargingBackend.simulatedHelper(
            control: control,
            power: CountingPower(uptime: uptime),
            tickInterval: .seconds(3600),
            uptime: uptime,
            pause: { _ in },
            activity: NoLeaseActivity(),
            macOSChargeLimit: monitor
        )
        let controller = ChargeController(telemetry: KitStubTelemetry(percent: 85, clock: clock), backend: backend, settings: .default, now: { clock.now }, uptime: uptime)
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        let held = await controller.evaluate(.periodic)
        #expect(held.currentMode == .inhibitCharging)

        reader.set(.limit(80))
        control.failNextApplies(4)
        control.failNextRestores(4)
        clock.advance(by: 60)
        let failed = await controller.evaluate(.periodic)
        #expect(control.activeControls == [.chargingInhibited])
        #expect(failed.ownRestriction.mayBeInEffect)
        #expect(failed.events.contains { $0.kind == .safety && $0.message.contains("No read-back has confirmed that this restriction ended, so it may remain") && $0.message.contains("(simulated; your Mac's charging is not changed)") })
        #expect(!failed.events.contains { $0.message.contains("restricts nothing") || $0.message.contains("confirms that this restriction ended") || $0.message.contains("never compete") })

        var recovered: ControllerStatus?
        for _ in 0..<6 where recovered == nil {
            clock.advance(by: 60)
            let status = await controller.evaluate(.periodic)
            if status.currentMode == .normal { recovered = status }
        }
        let status = try #require(recovered)
        #expect(control.activeControls.isEmpty)
        #expect(status.ownRestriction == .noneInEffect)
        #expect(status.events.contains { $0.kind == .safety && $0.message.contains("A read-back now shows normal charging") && $0.message.contains("(simulated; your Mac's charging is not changed)") })
        let notice = MacOSChargeLimitWording.releaseState(failed.ownRestriction, isSimulated: failed.isControlSimulated)
        #expect(notice.contains("These are the simulated helper's controls; your Mac's charging is not changed."))
    }

    @Test("Only a Mac with macOS's Charge Limit gets a monitor, and making one reads nothing")
    func monitorOnlyWithTheFeature() async {
        #expect(MacOSChargeLimitMonitor.system(featureIssue: "macOS's Charge Limit needs a Mac with Apple silicon.") == nil)
        let monitor = MacOSChargeLimitMonitor.system(featureIssue: nil)
        #expect(monitor != nil)
        let lastStatus = await monitor?.lastStatus
        #expect(lastStatus == nil)
    }

    /// A Simulated helper on a stepped clock (see `SimulatedHelperTests`),
    /// so its request budget never depends on how fast the machine runs.
    private func steppedHelper(macOSChargeLimit monitor: MacOSChargeLimitMonitor) -> HelperChargingBackend {
        let clock = XPCTestClock(step: 1e-6)
        let uptime: @Sendable () -> TimeInterval = { clock.uptime }
        return HelperChargingBackend.simulatedHelper(
            power: CountingPower(uptime: uptime),
            uptime: uptime,
            pause: { clock.advance(by: $0) },
            macOSChargeLimit: monitor
        )
    }

    @Test("While macOS's Charge Limit is on, the Simulated helper stays Simulated but offers only normal charging")
    func withheldWhileOn() async throws {
        let monitor = MacOSChargeLimitMonitor(reader: StubChargeLimitReader(.limit(80)))
        let backend = steppedHelper(macOSChargeLimit: monitor)
        let capabilities = await backend.capabilities()
        #expect(capabilities.availability == .simulated)
        #expect(capabilities.supportedModes == [.normal])
        #expect(capabilities.macOSChargeLimit?.reportedLimit == 80)
        #expect(capabilities.macOSChargeLimit?.isLimiting == true)
        await #expect(throws: BackendError.unsupportedMode(.inhibitCharging)) {
            try await backend.setMode(.inhibitCharging)
        }
    }

    @Test("With macOS's Charge Limit off, the Simulated helper offers both charging modes")
    func offeredWhileOff() async throws {
        let monitor = MacOSChargeLimitMonitor(reader: StubChargeLimitReader(.noLimit))
        let backend = steppedHelper(macOSChargeLimit: monitor)
        let capabilities = await backend.capabilities()
        #expect(capabilities.supportedModes == ChargeControlMode.chargingModes)
        #expect(capabilities.macOSChargeLimit?.isLimiting == false)
        #expect(try await backend.setMode(.inhibitCharging) == .simulated)
        #expect(try await backend.setMode(.normal) == .simulated)
    }
}
