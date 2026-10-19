import ProbeCore
import Testing

@Suite("Preconditions")
struct PreconditionTests {
    /// Everything as a run needs it: on AC, 62%, charging, no limit, no
    /// AlDente, no assertion.
    var ready: SystemState {
        SystemState(
            reading: Sample.Reading.charging.sample(at: 0, .baseline),
            chargeLimit: .noLimit,
            aldenteHelperFiles: [],
            aldenteService: .notFound,
            aldenteProcesses: ProcessScan(matches: [], unreadable: 0),
            otherBatteryDaemons: [],
            assertions: AssertionListing()
        )
    }

    func check(_ title: String, in state: SystemState, _ assertion: AssertionKind = .disableInflow) -> Check? {
        Preconditions.evaluate(state, assertion: assertion).first { $0.title == title }
    }

    func failures(_ state: SystemState, _ assertion: AssertionKind = .disableInflow) -> [String] {
        Preconditions.evaluate(state, assertion: assertion).filter { $0.status == .fail }.map(\.title)
    }

    @Test("A Mac that is charging on AC with nothing else in the way is ready, for either assertion")
    func allPass() {
        let inhibit = Preconditions.evaluate(ready, assertion: .chargeInhibit)
        #expect(inhibit.allSatisfy { $0.status == .pass })
        #expect(Preconditions.summary(inhibit, assertion: .chargeInhibit).hasPrefix("READY"))
        #expect(Preconditions.summary(inhibit, assertion: .chargeInhibit).contains("run --assertion charge-inhibit"))

        let inflow = Preconditions.evaluate(ready, assertion: .disableInflow)
        #expect(!inflow.contains { $0.status == .fail })
        // The one warning: Optimized Battery Charging, which the probe cannot read.
        #expect(inflow.filter { $0.status == .warn }.map(\.title) == ["Optimized Battery Charging off"])
        #expect(Preconditions.summary(inflow, assertion: .disableInflow).hasPrefix("READY"))
        #expect(Preconditions.summary(inflow, assertion: .disableInflow).contains("run --assertion disable-inflow"))
    }

    @Test("Not charging: fails with the advice to raise macOS's Charge Limit")
    func notCharging() throws {
        var state = ready
        state.reading = Sample.Reading.stopped.sample(at: 0, .baseline)
        let result = try #require(check("macOS is charging now", in: state))
        #expect(result.status == .fail)
        #expect(result.detail == "macOS isn't charging the battery now — raise macOS's Charge Limit to 100% (System Settings › Battery) and wait until it charges")
        #expect(Preconditions.summary(Preconditions.evaluate(state, assertion: .disableInflow), assertion: .disableInflow).hasPrefix("NOT READY"))
    }

    @Test("Charging flag on, current still at zero: fails until charging is under way")
    func flagWithoutCurrent() throws {
        var state = ready
        state.reading.instantCurrent = 0
        let result = try #require(check("macOS is charging now", in: state))
        #expect(result.status == .fail)
        #expect(result.detail.contains("wait until charging is under way"))
    }

    @Test("An unreadable charging state or current fails, with its own reason")
    func unreadableChargingState() throws {
        var state = ready
        state.reading.isCharging = nil
        let flag = try #require(check("macOS is charging now", in: state))
        #expect(flag.status == .fail)
        #expect(flag.detail.contains("could not be read"))

        state = ready
        state.reading.instantCurrent = nil
        state.reading.averageCurrent = nil
        #expect(failures(state).contains("macOS is charging now"))
        #expect(failures(state).contains("Battery current readable"))
    }

    @Test("No battery update time, or no system power input, fails for either assertion")
    func updateTimeAndInput() throws {
        var state = ready
        state.reading.updateTime = nil
        for assertion in AssertionKind.allCases {
            #expect(failures(state, assertion) == ["Battery update time readable"])
        }
        state = ready
        state.reading.systemPowerIn = nil
        for assertion in AssertionKind.allCases {
            #expect(failures(state, assertion) == ["System power input readable"])
        }
        let readable = try #require(check("Battery update time readable", in: ready))
        #expect(readable.status == .pass)
        #expect(readable.detail.hasSuffix("s old"))
    }

    @Test("DisableInflow needs at least 40% to start; ChargeInhibit does not check it")
    func minimumCharge() {
        var state = ready
        state.reading.percent = 39
        #expect(failures(state, .disableInflow) == ["Charge at least 40%"])
        #expect(failures(state, .chargeInhibit).isEmpty)
        state.reading.percent = 40
        #expect(failures(state, .disableInflow).isEmpty)
        #expect(check("Charge in the recommended 50–74%", in: state)?.status == .warn)
    }

    @Test("DisableInflow warns when no read reports the adapter attached")
    func adapterReported() {
        var state = ready
        state.reading.rawExternalConnected = false
        #expect(check("Adapter reported attached", in: state)?.status == .pass)
        state.reading.adapterAttached = false
        let result = check("Adapter reported attached", in: state)
        #expect(result?.status == .warn)
        #expect(result?.detail.contains("cannot be told from an unplugged adapter") == true)
        #expect(failures(state).isEmpty)
        #expect(check("Adapter reported attached", in: state, .chargeInhibit) == nil)
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

    @Test("A Charge Limit below 100% fails, and so does an unreadable report")
    func chargeLimit() throws {
        var state = ready
        state.chargeLimit = .limits([80])
        let failed = try #require(check("macOS's Charge Limit is 100%", in: state))
        #expect(failed.status == .fail)
        #expect(failed.detail.contains("80%"))

        state.chargeLimit = .unreadable("unexpected output")
        let unreadable = try #require(check("macOS's Charge Limit is 100%", in: state))
        #expect(unreadable.status == .fail)
        #expect(unreadable.detail.contains("cannot be ruled out"))
    }

    @Test("AlDente's helper files fail the run")
    func aldenteFiles() {
        var state = ready
        state.aldenteHelperFiles = [Preconditions.aldenteHelperPaths[1]]
        #expect(failures(state) == ["No AlDente helper files"])
    }

    @Test("A loaded AlDente service, or launchctl that does not say, fails; restart is advised only then")
    func aldenteService() throws {
        var state = ready
        state.aldenteService = .loaded
        let loaded = try #require(check("AlDente helper not loaded", in: state))
        #expect(loaded.status == .fail)
        #expect(loaded.detail.contains("restart the Mac only if this check still fails"))

        state.aldenteService = .unknown("launchctl exited with status 5")
        #expect(check("AlDente helper not loaded", in: state)?.status == .fail)

        #expect(check("AlDente helper not loaded", in: ready)?.status == .pass)
    }

    @Test("A running AlDente process, or an unreadable process table, fails")
    func aldenteProcesses() throws {
        var state = ready
        state.aldenteProcesses = ProcessScan(matches: ["com.apphousekitchen.aldente-pro-setapp.helper"], unreadable: 0)
        let running = try #require(check("No AlDente process running", in: state))
        #expect(running.status == .fail)
        #expect(running.detail.contains("aldente-pro-setapp.helper"))
        #expect(running.detail.contains("restart the Mac only if"))

        state.aldenteProcesses = ProcessScan(matches: [], unreadable: 2)
        #expect(check("No AlDente process running", in: state)?.status == .fail)

        state.aldenteProcesses = nil
        #expect(check("No AlDente process running", in: state)?.status == .fail)
    }

    @Test("launchctl's answers: not found, loaded, or unknown")
    func launchdParsing() {
        let missing = "Bad request.\nCould not find service \"com.apphousekitchen.aldente-pro-setapp.helper\" in domain for system\n"
        #expect(LaunchdServiceState.parse(status: 113, output: missing) == .notFound)
        #expect(LaunchdServiceState.parse(status: 0, output: "system/x = {\n}") == .loaded)
        #expect(LaunchdServiceState.parse(status: 1, output: "Operation not permitted") == .unknown("launchctl exited with status 1"))
        #expect(LaunchdServiceState.parse(status: nil, output: "") == .unknown("launchctl could not be run"))
    }

    @Test("AlDente is recognised by its executable path or name")
    func aldenteNames() {
        #expect(ProcessScan.isAlDente("/Library/PrivilegedHelperTools/com.apphousekitchen.aldente-pro-setapp.helper"))
        #expect(ProcessScan.isAlDente("/Applications/Setapp/AlDente Pro.app/Contents/MacOS/AlDente Pro"))
        #expect(ProcessScan.isAlDente("com.apphousekit"))
        #expect(!ProcessScan.isAlDente("/System/Library/CoreServices/powerd.bundle/powerd"))
    }

    @Test("Other battery-looking daemons only warn")
    func otherDaemons() {
        var state = ready
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

    @Test("A ChargeInhibit or DisableInflow someone else holds fails, for either test; an unrunnable pmset fails too")
    func existingAssertion() throws {
        let title = "No ChargeInhibit or DisableInflow assertion held"
        var state = ready
        state.assertions = AssertionListing(
            systemWideLevels: ["ChargeInhibit": 1],
            holders: [.init(type: "ChargeInhibit", process: "sometool", isProbe: false)]
        )
        let result = try #require(check(title, in: state))
        #expect(result.status == .fail)
        #expect(result.detail.contains("ChargeInhibit held by sometool (another assertion)"))

        state.assertions = AssertionListing(systemWideLevels: ["DisableInflow": 1])
        for assertion in AssertionKind.allCases {
            let inflow = try #require(check(title, in: state, assertion))
            #expect(inflow.status == .fail)
            #expect(inflow.detail.contains("a system-wide DisableInflow level of 1 with no holder listed"))
        }

        state.assertions = nil
        #expect(check(title, in: state)?.status == .fail)
    }

    @Test("The Optimized Battery Charging reminder is for DisableInflow only")
    func optimizedChargingReminder() {
        #expect(check("Optimized Battery Charging off", in: ready, .disableInflow)?.status == .warn)
        #expect(check("Optimized Battery Charging off", in: ready, .chargeInhibit) == nil)
    }
}
