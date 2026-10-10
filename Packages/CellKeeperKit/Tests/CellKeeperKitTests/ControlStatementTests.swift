import CellKeeperCore
import CellKeeperHelperCore
import CellKeeperKit
import Foundation
import Testing

@Suite("What controls charging")
struct ControlStatementTests {
    /// A status from a real evaluation with `backend`.
    private func evaluated(_ backend: any ChargingBackend, settings: ChargingSettings = .default) async -> ControllerStatus {
        let clock = KitTestClock()
        let controller = ChargeController(telemetry: KitStubTelemetry(percent: 70, clock: clock), backend: backend, settings: settings, now: { clock.now }, uptime: { clock.uptime })
        return await controller.evaluate(.launch)
    }

    /// A Simulated helper on a stepped clock (see `SimulatedHelperTests`),
    /// with macOS's Charge Limit read as `reading`.
    private func simulatedHelper(_ reading: NativeChargeLimitReading) -> HelperChargingBackend {
        let clock = XPCTestClock(step: 1e-6)
        let uptime: @Sendable () -> TimeInterval = { clock.uptime }
        return HelperChargingBackend.simulatedHelper(
            power: CountingPower(uptime: uptime),
            tickInterval: .seconds(3600),
            uptime: uptime,
            pause: { clock.advance(by: $0) },
            activity: NoLeaseActivity(),
            macOSChargeLimit: MacOSChargeLimitMonitor(reader: StubChargeLimitReader(reading))
        )
    }

    @Test("The Simulated helper says it is CellKeeper's own control, simulated, while macOS's limit is off")
    func simulatedHelperOff() async {
        let status = await evaluated(simulatedHelper(.noLimit))
        #expect(ControlStatement.text(for: status) == "Simulated helper: CellKeeper's own control, simulated; nothing on your Mac changes")
        #expect(!ControlStatement.isDeferringToMacOS(status))
        #expect(!ControlStatement.offersMacOSLimitGuide(status))
        #expect(ControlStatement.limitNote(for: status) == nil)
        #expect(ControlStatement.isPolicyApplied(status))
    }

    @Test("While macOS's limit is on or unreadable, the Simulated helper defers to it and the steps to turn it off are offered", arguments: [
        NativeChargeLimitReading.limit(80), .unrecognized("unexpected heading"),
    ])
    func simulatedHelperDeferring(reading: NativeChargeLimitReading) async {
        let status = await evaluated(simulatedHelper(reading))
        #expect(status.decision?.state == .deferringToMacOS)
        #expect(ControlStatement.text(for: status) == "Deferring to macOS's Charge Limit")
        #expect(ControlStatement.offersMacOSLimitGuide(status))
        #expect(ControlStatement.limitNote(for: status) == "Not in effect while macOS's Charge Limit is on: CellKeeper defers to it, with no limit, temperature pause or discharge of its own.")
        #expect(ControlStatement.isPolicyApplied(status))
        var off = status
        off.settings.isManagementEnabled = false
        #expect(ControlStatement.limitNote(for: off) == nil)
    }

    @Test("An unavailable backend says so and why; it is never said to defer, and its policy is not applied")
    func unavailable() async {
        let status = await evaluated(ReadOnlyChargingBackend())
        let text = ControlStatement.text(for: status)
        #expect(text == "Unavailable: Read-only is selected, so CellKeeper changes nothing.")
        #expect(!ControlStatement.isPolicyApplied(status))
        #expect(!ControlStatement.offersMacOSLimitGuide(status))
        #expect(ControlStatement.limitNote(for: status) == nil)
        // Even with macOS's limit on, a backend that controls nothing does
        // not defer and offers no steps to turn the limit off.
        var limited = status
        limited.capabilities.macOSChargeLimit = MacOSChargeLimitStatus(reportedLimit: 80, readAt: Date())
        #expect(ControlStatement.text(for: limited) == text)
        #expect(!ControlStatement.isDeferringToMacOS(limited))
        #expect(!ControlStatement.offersMacOSLimitGuide(limited))
        #expect(ControlStatement.limitNote(for: limited) == nil)
        // The same for an unavailable Simulated helper.
        var helper = limited
        helper.backend = BackendDescriptor(identifier: HelperChargingBackend.simulatedHelperIdentifier, displayName: "Simulated helper", summary: "")
        helper.capabilities = .unavailable("CellKeeper's helper is not responding.")
        #expect(ControlStatement.text(for: helper) == "Unavailable: CellKeeper's helper is not responding.")
        #expect(!ControlStatement.isDeferringToMacOS(helper))
    }

    @Test("The simulated backend says what it does; macOS's Charge Limit has its own summary")
    func otherBackends() async {
        let simulated = await evaluated(MockChargingBackend())
        #expect(ControlStatement.text(for: simulated) == "Simulated: CellKeeper records what it would do; nothing on your Mac changes")
        var native = simulated
        native.capabilities = .nativeLimit(availability: .experimental, steps: NativeChargeLimitBackend.supportedLimits)
        native.capabilities.macOSChargeLimit = MacOSChargeLimitStatus(reportedLimit: 80, readAt: Date())
        #expect(ControlStatement.text(for: native) == nil)
        #expect(!ControlStatement.isDeferringToMacOS(native))
        #expect(!ControlStatement.offersMacOSLimitGuide(native))
        #expect(ControlStatement.limitNote(for: native) == nil)
    }
}

@Suite("Charge limits offered")
struct ChargeLimitChoicesTests {
    @Test("CellKeeper's own control offers every whole percentage from 20 to 100, also while deferring or unavailable")
    func ownControl() {
        let capabilities = ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)
        for offered in [
            ChargeLimitChoices.offered(capabilities: capabilities, isNativeChosen: false),
            .offered(capabilities: capabilities.withoutRestrictingModes, isNativeChosen: false),
            .offered(capabilities: .unavailable("not responding"), isNativeChosen: false),
            .offered(capabilities: nil, isNativeChosen: false),
        ] {
            #expect(offered == .wholePercent(20...100))
            #expect(offered.values == Array(20...100))
            #expect(offered.values.count == 81)
            #expect(!offered.isNativeSteps)
        }
        for limit in 20...100 {
            #expect(ChargingSettings.default.withChargeLimit(limit).chargeLimit == limit)
            #expect(ChargingSettings.default.withChargeLimit(limit).validationIssues.isEmpty)
        }
    }

    @Test("macOS's Charge Limit offers only its steps, also before any status and while a switch away from it is pending")
    func nativeSteps() {
        let native = ControlCapabilities.nativeLimit(availability: .experimental, steps: [80, 90, 100])
        #expect(ChargeLimitChoices.offered(capabilities: native, isNativeChosen: true) == .steps([80, 90, 100]))
        #expect(ChargeLimitChoices.offered(capabilities: native, isNativeChosen: false) == .steps([80, 90, 100]))
        #expect(ChargeLimitChoices.offered(capabilities: nil, isNativeChosen: true) == .steps(NativeChargeLimitBackend.supportedLimits))
        // A switch to macOS's Charge Limit is pending: the backend in charge decides.
        let helperInCharge = ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)
        #expect(ChargeLimitChoices.offered(capabilities: helperInCharge, isNativeChosen: true) == .wholePercent(20...100))
    }

    @Test("The Battery settings link uses System Settings' URL scheme, with System Settings itself as the fallback")
    func batterySettingsLink() {
        #expect(BatterySettingsLink.batteryPane.scheme == "x-apple.systempreferences")
        #expect(BatterySettingsLink.batteryPane.absoluteString == "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        #expect(BatterySettingsLink.systemSettingsApp.path == "/System/Applications/System Settings.app")
    }
}
