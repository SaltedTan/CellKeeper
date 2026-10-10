import CellKeeperCore
import CellKeeperHelperCore
import Foundation
import Testing

/// macOS's Charge Limit report as a backend that switches charging itself
/// reads it, set by the test; counts reads and never runs pmset.
final class StubMacOSChargeLimit: ChargeLimitReading, @unchecked Sendable {
    struct ReadError: Error, CustomStringConvertible {
        var description: String
    }

    private let lock = NSLock()
    private var result: Result<NativeChargeLimitReading, ReadError>
    private var readCount = 0

    init(_ reading: NativeChargeLimitReading = .noLimit) {
        result = .success(reading)
    }

    /// How many times the report was read.
    var reads: Int {
        lock.withLock { readCount }
    }

    /// What macOS reports from now on.
    func set(_ reading: NativeChargeLimitReading) {
        lock.withLock { result = .success(reading) }
    }

    /// Makes every read fail with `message` from now on.
    func fail(_ message: String) {
        lock.withLock { result = .failure(ReadError(description: message)) }
    }

    func readChargeLimit() async throws -> NativeChargeLimitReading {
        try lock.withLock {
            readCount += 1
            return try result.get()
        }
    }
}

/// The capabilities of a simulated helper backend that read macOS's Charge
/// Limit as `limit` (nil: unreadable, with `problem`).
func helperCapabilities(macOSLimit limit: Int?, problem: String? = nil) -> ControlCapabilities {
    let status = MacOSChargeLimitStatus(reportedLimit: limit, readAt: referenceDate, readProblem: problem)
    var capabilities = simulatedCapabilities
    if status.isLimiting {
        capabilities = capabilities.withoutRestrictingModes
    }
    capabilities.macOSChargeLimit = status
    return capabilities
}

@Suite("macOS's Charge Limit monitor")
struct MacOSChargeLimitMonitorTests {
    let clock = TestClock()

    private func monitor(_ reader: StubMacOSChargeLimit) -> MacOSChargeLimitMonitor {
        let clock = clock
        return MacOSChargeLimitMonitor(reader: reader, now: { clock.now }, uptime: { clock.uptime })
    }

    @Test("A reading younger than 30 s is reused; an older one is read again")
    func caching() async {
        let reader = StubMacOSChargeLimit(.limit(80))
        let monitor = monitor(reader)
        #expect(await monitor.lastStatus == nil)
        let first = await monitor.status()
        #expect(first.reportedLimit == 80)
        #expect(first.readAt == clock.now)
        for _ in 0..<3 {
            clock.advance(by: 9)
            _ = await monitor.status()
        }
        #expect(reader.reads == 1)
        reader.set(.noLimit)
        clock.advance(by: 3)
        let fresh = await monitor.status()
        #expect(reader.reads == 2)
        #expect(fresh.reportedLimit == 100)
        #expect(fresh.readAt == clock.now)
    }

    @Test("A forced re-read reads at once, and later checks reuse it")
    func forcedReread() async {
        let reader = StubMacOSChargeLimit(.limit(80))
        let monitor = monitor(reader)
        _ = await monitor.status()
        reader.set(.noLimit)
        clock.advance(by: 5)
        #expect(await monitor.status().isLimiting)
        let refreshed = await monitor.refresh()
        #expect(!refreshed.isLimiting)
        #expect(reader.reads == 2)
        clock.advance(by: 5)
        #expect(await monitor.status() == refreshed)
        #expect(reader.reads == 2)
    }

    @Test("A reading dated after the monotonic clock is read again")
    func clockWentBack() async {
        let reader = StubMacOSChargeLimit(.limit(80))
        let monitor = monitor(reader)
        _ = await monitor.status()
        clock.advance(by: -10)
        _ = await monitor.status()
        #expect(reader.reads == 2)
    }

    @Test("Callers at the same time share one read")
    func sharedRead() async {
        let reader = StubMacOSChargeLimit(.limit(85))
        let monitor = monitor(reader)
        async let first = monitor.status()
        async let second = monitor.status()
        let statuses = await [first, second]
        #expect(statuses.allSatisfy { $0.reportedLimit == 85 })
        #expect(reader.reads == 1)
    }

    @Test("Only a recognised report of no limit or 100% is off; anything unrecognised or unreadable may be limiting")
    func whatCountsAsLimiting() async {
        let reader = StubMacOSChargeLimit()
        let monitor = monitor(reader)
        let cases: [(NativeChargeLimitReading, Int?, Bool)] = [
            (.limit(80), 80, true),
            (.limit(95), 95, true),
            (.limit(100), 100, false),
            (.noLimit, 100, false),
            (.unrecognized("a limit with reason optimizedBatteryCharging"), nil, true),
        ]
        for (reading, limit, isLimiting) in cases {
            reader.set(reading)
            let status = await monitor.refresh()
            #expect(status.reportedLimit == limit)
            #expect(status.isLimiting == isLimiting)
            #expect((status.readProblem != nil) == (limit == nil))
        }
        let unrecognised = await monitor.refresh()
        #expect(unrecognised.readProblem == "unrecognised report (a limit with reason optimizedBatteryCharging)")

        reader.fail("pmset -g battlimit failed: exit status 1")
        let failed = await monitor.refresh()
        #expect(failed.reportedLimit == nil)
        #expect(failed.isLimiting)
        #expect(failed.readProblem == "pmset -g battlimit failed: exit status 1")
    }

    @Test("A status built without a limit always carries a problem, and one with a limit never does")
    func statusShape() {
        #expect(MacOSChargeLimitStatus(reportedLimit: nil, readAt: referenceDate).readProblem == "no report")
        #expect(MacOSChargeLimitStatus(reportedLimit: 80, readAt: referenceDate, readProblem: "ignored").readProblem == nil)
    }
}

@Suite("Helper backend and macOS's Charge Limit")
struct HelperMacOSChargeLimitBackendTests {
    @Test("While macOS's Charge Limit is on, only normal charging is offered, and the backend stays Simulated")
    func withheldWhileOn() async {
        let rig = HelperRig(macOSReader: StubMacOSChargeLimit(.limit(80)))
        let capabilities = await rig.backend.capabilities()
        #expect(capabilities.availability == .simulated)
        #expect(capabilities.style == .chargingModes)
        #expect(capabilities.supportedModes == [.normal])
        #expect(capabilities.macOSChargeLimit?.reportedLimit == 80)
        #expect(capabilities.macOSChargeLimit?.isLimiting == true)
    }

    @Test("With macOS's Charge Limit off (no limit, or 100%), every charging mode is offered", arguments: [NativeChargeLimitReading.noLimit, .limit(100)])
    func offeredWhileOff(reading: NativeChargeLimitReading) async {
        let rig = HelperRig(macOSReader: StubMacOSChargeLimit(reading))
        let capabilities = await rig.backend.capabilities()
        #expect(capabilities.supportedModes == ChargeControlMode.chargingModes)
        #expect(capabilities.macOSChargeLimit?.reportedLimit == 100)
        #expect(capabilities.macOSChargeLimit?.isLimiting == false)
    }

    @Test("An unrecognised report (how Optimized Battery Charging might appear) withholds every restriction, with the detail")
    func withheldWhenUnrecognised() async {
        let rig = HelperRig(macOSReader: StubMacOSChargeLimit(.unrecognized("a limit with reason optimizedBatteryCharging")))
        let capabilities = await rig.backend.capabilities()
        #expect(capabilities.availability == .simulated)
        #expect(capabilities.supportedModes == [.normal])
        #expect(capabilities.macOSChargeLimit?.reportedLimit == nil)
        #expect(capabilities.macOSChargeLimit?.readProblem?.contains("optimizedBatteryCharging") == true)
    }

    @Test("A report that cannot be read withholds every restriction, with the detail")
    func withheldWhenUnreadable() async {
        let reader = StubMacOSChargeLimit()
        reader.fail("pmset -g battlimit failed: could not be started")
        let rig = HelperRig(macOSReader: reader)
        let capabilities = await rig.backend.capabilities()
        #expect(capabilities.supportedModes == [.normal])
        #expect(capabilities.macOSChargeLimit?.readProblem == "pmset -g battlimit failed: could not be started")
    }

    @Test("Without a monitor (a Mac without the Charge Limit) nothing is withheld or reported")
    func noMonitor() async {
        let rig = HelperRig()
        let capabilities = await rig.backend.capabilities()
        #expect(capabilities.macOSChargeLimit == nil)
        #expect(capabilities.supportedModes == ChargeControlMode.chargingModes)
    }

    @Test("macOS's limit is reported also while the helper cannot be reached")
    func reportedWhileUnreachable() async {
        let rig = HelperRig(macOSReader: StubMacOSChargeLimit(.limit(85)))
        rig.transport.isReachable = false
        let capabilities = await rig.backend.capabilities()
        guard case .unavailable = capabilities.availability else {
            Issue.record("expected unavailable, got \(capabilities.availability)")
            return
        }
        #expect(capabilities.macOSChargeLimit?.reportedLimit == 85)
    }

    @Test("Repeated checks reuse one reading; checking again reads at once")
    func readsAtMostOncePerPeriod() async {
        let reader = StubMacOSChargeLimit(.limit(80))
        let rig = HelperRig(macOSReader: reader)
        for _ in 0..<4 {
            _ = await rig.backend.capabilities()
        }
        #expect(reader.reads == 1)
        reader.set(.noLimit)
        await rig.backend.recheckAvailability()
        #expect(reader.reads == 2)
        let capabilities = await rig.backend.capabilities()
        #expect(reader.reads == 2)
        #expect(capabilities.supportedModes == ChargeControlMode.chargingModes)
    }

    @Test("A restriction asked for anyway is refused, and nothing is written")
    func restrictionRefused() async {
        let rig = HelperRig(macOSReader: StubMacOSChargeLimit(.limit(80)))
        await #expect(throws: BackendError.unsupportedMode(.inhibitCharging)) {
            try await rig.backend.setMode(.inhibitCharging)
        }
        await #expect(throws: BackendError.unsupportedMode(.forceDischarge)) {
            try await rig.backend.setMode(.forceDischarge)
        }
        #expect(!rig.control.writes.contains { if case .apply(_, active: true) = $0 { true } else { false } })
        // Normal charging is always accepted.
        let outcome = try? await rig.backend.setMode(.normal)
        #expect(outcome == .simulated)
    }

    @Test("Other backends do not check macOS's limit for this: their capabilities carry none")
    func otherBackendsCarryNone() async {
        let native = makeNativeBackend(system: FakeChargeLimitSystem(reading: .limit(80)), store: InMemoryRecordStore())
        let nativeCapabilities = await native.capabilities()
        #expect(nativeCapabilities.isEnforcedByMacOS)
        #expect(nativeCapabilities.macOSChargeLimit == nil)
        let mock = await MockChargingBackend().capabilities()
        #expect(mock.macOSChargeLimit == nil)
        let readOnly = await ReadOnlyChargingBackend().capabilities()
        #expect(readOnly.macOSChargeLimit == nil)
    }

    @Test("Checking again through the controller still reaches the native backend's shortcut check")
    func nativeRecheckThroughController() async {
        let clock = TestClock()
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let native = makeNativeBackend(system: system, store: InMemoryRecordStore(), clock: clock)
        var settings = ChargingSettings.default
        settings.isManagementEnabled = false
        let controller = ChargeController(telemetry: StubTelemetry(snapshot(percent: 70), clock: clock), backend: native, settings: settings, now: { clock.now }, uptime: { clock.uptime })
        await controller.evaluate(.launch)
        await controller.evaluate(.manual)
        #expect(system.listCalls == 1)
        let status = await controller.recheckBackendAvailability()
        #expect(system.listCalls == 2)
        #expect(status.capabilities.macOSChargeLimit == nil)
    }
}

@Suite("Policy and macOS's Charge Limit")
struct MacOSChargeLimitPolicyTests {
    @Test("While macOS's Charge Limit is on, the policy restricts nothing and names the limit")
    func defers() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 50), capabilities: helperCapabilities(macOSLimit: 80)))
        #expect(decision.state == .deferringToMacOS)
        #expect(decision.desiredMode == .normal)
        #expect(decision.reason == .macOSChargeLimitActive(limit: 80))
        #expect(decision.action == .noAction)
    }

    @Test("A hold in place is released")
    func releasesHold() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), capabilities: helperCapabilities(macOSLimit: 80), currentMode: .inhibitCharging))
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .enableCharging)
    }

    @Test("At the limit, nothing is held; the latch still follows the readings")
    func atTheLimit() {
        let memory = memoryAfterReading(85)
        let gated = ChargingPolicy.evaluate(input(snapshot(percent: 85), capabilities: helperCapabilities(macOSLimit: 80), memory: memory))
        #expect(gated.state == .deferringToMacOS)
        #expect(gated.desiredMode == .normal)
        #expect(gated.memory.limitReached)
        // Once macOS's limit is off, the confirmed limit holds at once.
        let off = ChargingPolicy.evaluate(input(snapshot(percent: 85, at: referenceDate.addingTimeInterval(60)), capabilities: helperCapabilities(macOSLimit: 100), memory: gated.memory, now: referenceDate.addingTimeInterval(60), uptime: 10_060))
        #expect(off.state == .holding)
        #expect(off.desiredMode == .inhibitCharging)
    }

    @Test("A hot battery is not paused by CellKeeper; macOS limits charging and has its own thermal limiting")
    func hot() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 60, temperature: 45), capabilities: helperCapabilities(macOSLimit: 85)))
        #expect(decision.state == .deferringToMacOS)
        #expect(decision.desiredMode == .normal)
        #expect(decision.memory.temperatureTripped)
    }

    @Test("Sleep and the safety floor change nothing: nothing is restricted either way")
    func sleepAndFloor() {
        let sleeping = ChargingPolicy.evaluate(input(snapshot(percent: 79), capabilities: helperCapabilities(macOSLimit: 80), sleepImminent: true))
        #expect(sleeping.desiredMode == .normal)
        #expect(sleeping.state == .deferringToMacOS)
        let low = ChargingPolicy.evaluate(input(snapshot(percent: 8), capabilities: helperCapabilities(macOSLimit: 80)))
        #expect(low.desiredMode == .normal)
        #expect(low.memory.belowSafetyFloor)
    }

    @Test("An unreadable report defers too, with the problem in the reason")
    func unreadable() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), capabilities: helperCapabilities(macOSLimit: nil, problem: "unrecognised report (a limit with reason optimizedBatteryCharging)"), currentMode: .inhibitCharging))
        #expect(decision.state == .deferringToMacOS)
        #expect(decision.desiredMode == .normal)
        #expect(decision.reason == .macOSChargeLimitUnknown(problem: "unrecognised report (a limit with reason optimizedBatteryCharging)"))
        #expect(decision.reason.description.contains("optimizedBatteryCharging"))
    }

    @Test("A discharge session ends, with a note saying why")
    func dischargeEnds() {
        let session = ChargeOverride.dischargeToLimit(target: 80, at: referenceDate, uptime: 9_000)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 90), override: session, capabilities: helperCapabilities(macOSLimit: 80), currentMode: .forceDischarge))
        #expect(decision.overrideEnded == .interrupted)
        #expect(decision.notes.contains(.dischargeEndedForMacOSChargeLimit))
        #expect(!decision.notes.contains(.dischargeUnsupported))
        #expect(decision.desiredMode == .normal)
        #expect(decision.action == .enableCharging)
    }

    @Test("A temporary full charge is kept, and still completes when full")
    func fullCharge() {
        let full = ChargeOverride.fullCharge(at: referenceDate, uptime: 9_000)
        let charging = ChargingPolicy.evaluate(input(snapshot(percent: 85), override: full, capabilities: helperCapabilities(macOSLimit: 80)))
        #expect(charging.overrideEnded == nil)
        #expect(charging.desiredMode == .normal)
        let completed = ChargingPolicy.evaluate(input(snapshot(percent: 100), override: full, capabilities: helperCapabilities(macOSLimit: 80)))
        #expect(completed.overrideEnded == .completed)
    }

    @Test("Settings, management off and unusable telemetry come first")
    func precedence() {
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        let unmanaged = ChargingPolicy.evaluate(input(snapshot(percent: 85), settings: off, capabilities: helperCapabilities(macOSLimit: 80)))
        #expect(unmanaged.state == .unmanaged)
        let noTelemetry = ChargingPolicy.evaluate(input(nil, capabilities: helperCapabilities(macOSLimit: 80)))
        #expect(noTelemetry.state == .failSafe)
        #expect(noTelemetry.reason == .telemetryUnavailable)
    }

    @Test("With macOS's Charge Limit off, CellKeeper's own limit applies as usual")
    func offAppliesLimit() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), capabilities: helperCapabilities(macOSLimit: 100), memory: memoryAfterReading(85)))
        #expect(decision.state == .holding)
        #expect(decision.action == .disableCharging)
    }

    @Test("The native Charge Limit backend is never affected")
    func nativeUnaffected() {
        var capabilities = nativeCapabilities
        capabilities.macOSChargeLimit = MacOSChargeLimitStatus(reportedLimit: 80, readAt: referenceDate)
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 85), capabilities: capabilities))
        #expect(decision.state == .osEnforcedLimit)
        #expect(decision.desiredMode == .nativeLimit(percent: 80))
    }

    @Test("The reasons name macOS's limit, say CellKeeper's is not enforced, and say where to turn it off")
    func wording() {
        let active = DecisionReason.macOSChargeLimitActive(limit: 85).description
        #expect(active.contains("85%"))
        #expect(active.contains("does not enforce its own limit"))
        #expect(active.contains("System Settings › Battery › Charging"))
        let unknown = DecisionReason.macOSChargeLimitUnknown(problem: "pmset -g battlimit failed: exit status 1").description
        #expect(unknown.contains("pmset -g battlimit failed: exit status 1"))
        #expect(unknown.contains("may be limiting"))
        #expect(unknown.contains("System Settings › Battery › Charging"))
    }
}
