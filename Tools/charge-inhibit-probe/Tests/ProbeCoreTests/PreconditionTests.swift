import ProbeCore
import Testing

@Suite("Preconditions")
struct PreconditionTests {
    /// Everything as a run needs it: on AC, 62%, charging, no limit, no
    /// helper, no assertion.
    var ready: SystemState {
        SystemState(
            reading: Sample.Reading.charging.sample(at: 0, .baseline),
            chargeLimit: .noLimit,
            aldenteHelperFiles: [],
            otherBatteryDaemons: [],
            assertions: AssertionListing(systemWideLevel: nil, lines: [])
        )
    }

    func check(_ title: String, in state: SystemState) -> Check? {
        Preconditions.evaluate(state).first { $0.title == title }
    }

    func failures(_ state: SystemState) -> [String] {
        Preconditions.evaluate(state).filter { $0.status == .fail }.map(\.title)
    }

    @Test("A Mac that is charging on AC with nothing else in the way is ready")
    func allPass() {
        let checks = Preconditions.evaluate(ready)
        #expect(checks.allSatisfy { $0.status == .pass })
        #expect(Preconditions.summary(checks).hasPrefix("READY"))
    }

    @Test("Not charging: fails with the advice to raise macOS's Charge Limit")
    func notCharging() throws {
        var state = ready
        state.reading = Sample.Reading.stopped.sample(at: 0, .baseline)
        let result = try #require(check("macOS is charging now", in: state))
        #expect(result.status == .fail)
        #expect(result.detail == "macOS isn't charging the battery now — raise macOS's Charge Limit to 100% (System Settings › Battery) and wait until it charges")
        #expect(Preconditions.summary(Preconditions.evaluate(state)).hasPrefix("NOT READY"))
    }

    @Test("Charging flag on, current still at zero: fails until charging is under way")
    func flagWithoutCurrent() throws {
        var state = ready
        state.reading.instantCurrent = 0
        let result = try #require(check("macOS is charging now", in: state))
        #expect(result.status == .fail)
        #expect(result.detail.contains("wait until charging is under way"))
    }

    @Test("On battery, or no battery: fails")
    func power() {
        var state = ready
        state.reading = Sample.Reading.unplugged.sample(at: 0, .baseline)
        #expect(failures(state).contains("On AC power"))

        state = ready
        state.reading.batteryPresent = false
        #expect(failures(state).contains("Battery present"))
    }

    @Test("95% or more: fails")
    func highCharge() {
        var state = ready
        state.reading.percent = 95
        #expect(failures(state) == ["Charge below 95%"])
        state.reading.percent = 94
        #expect(failures(state).isEmpty)
    }

    @Test("Between 75 and 94%, a warning about Optimized Battery Charging's pause at 80%")
    func optimizedChargingWarning() throws {
        var state = ready
        state.reading.percent = 78
        let result = try #require(check("Charge in the recommended 50–74%", in: state))
        #expect(result.status == .warn)
        #expect(result.detail.contains("Optimized Battery Charging"))
        #expect(failures(state).isEmpty)
    }

    @Test("A Charge Limit below 100% fails; an unreadable report only warns")
    func chargeLimit() throws {
        var state = ready
        state.chargeLimit = .limits([80])
        let failed = try #require(check("macOS's Charge Limit is 100%", in: state))
        #expect(failed.status == .fail)
        #expect(failed.detail.contains("80%"))

        state.chargeLimit = .unreadable("unexpected output")
        #expect(check("macOS's Charge Limit is 100%", in: state)?.status == .warn)
    }

    @Test("AlDente's helper files fail the run; other battery-looking daemons only warn")
    func batteryTools() {
        var state = ready
        state.aldenteHelperFiles = [Preconditions.aldenteHelperPaths[1]]
        #expect(failures(state) == ["No AlDente helper"])

        state = ready
        state.otherBatteryDaemons = ["com.example.batterykeeper.helper"]
        #expect(failures(state).isEmpty)
        #expect(check("No other battery-control daemon", in: state)?.status == .warn)
    }

    @Test("Daemon names that suggest a battery or charge-control tool")
    func batteryToolNames() {
        let names = [
            "com.docker.vmnetd.plist", "com.example.BatteryHelper.plist", "com.example.charger.plist",
            "com.apphousekitchen.aldente-pro.helper", "us.zoom.ZoomDaemon.plist", "com.example.smcd.plist",
        ]
        #expect(Preconditions.batteryToolNames(in: names) == [
            "com.apphousekitchen.aldente-pro.helper", "com.example.BatteryHelper.plist",
            "com.example.charger.plist", "com.example.smcd.plist",
        ])
    }

    @Test("A ChargeInhibit someone else holds fails, because the probe's own would then change nothing")
    func existingAssertion() throws {
        var state = ready
        state.assertions = AssertionListing(systemWideLevel: 1, lines: ["pid 1234(sometool): [0x1] 00:01:00 ChargeInhibit named: \"x\""])
        let result = try #require(check("No ChargeInhibit assertion held", in: state))
        #expect(result.status == .fail)
        #expect(result.detail.contains("sometool"))

        state.assertions = nil
        #expect(check("No ChargeInhibit assertion held", in: state)?.status == .warn)
    }

    @Test("No battery current: fails, because the verdict needs it")
    func noCurrent() {
        var state = ready
        state.reading.instantCurrent = nil
        state.reading.averageCurrent = nil
        #expect(failures(state).contains("Battery current readable"))
    }
}
