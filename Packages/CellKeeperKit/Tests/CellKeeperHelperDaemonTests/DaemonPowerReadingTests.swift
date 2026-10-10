@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

/// The same rules as the app's `SystemHelperPowerReading` (D45), checked on
/// the daemon's own copy.
@Suite("Daemon power reading")
struct DaemonPowerReadingTests {
    private func battery(percent: Int? = 70, max: Int = 100, present: Bool? = true) -> [String: Any] {
        var description: [String: Any] = [:]
        if let present {
            description["Is Present"] = present
        }
        if let percent {
            description["Current Capacity"] = percent
            description["Max Capacity"] = max
        }
        return description
    }

    private func state(
        battery: [String: Any]? = nil,
        source: String? = "AC Power",
        adapter: Bool = true,
        thermal: ProcessInfo.ThermalState = .nominal,
        at uptime: TimeInterval = 1
    ) -> HelperPowerState? {
        DaemonPowerReading.powerState(
            battery: battery ?? self.battery(),
            providingPowerSourceType: source,
            hasAdapterDetails: adapter,
            thermalState: thermal,
            readAtUptime: uptime
        )
    }

    @Test("Charge, external power and an attached adapter, stamped with the read time")
    func onAdapter() {
        #expect(state(at: 42) == HelperPowerState(stateOfCharge: 70, isOnExternalPower: true, isAdapterPresent: true, isThermalPressureHigh: false, readAtUptime: 42))
    }

    @Test("On battery without adapter details, no adapter is attached")
    func onBattery() {
        let reading = state(source: "Battery Power", adapter: false)
        #expect(reading?.isOnExternalPower == false)
        #expect(reading?.isAdapterPresent == false)
    }

    @Test("Adapter details missing while on external power leave presence unknown")
    func presenceUnknown() {
        let reading = state(adapter: false)
        #expect(reading?.isOnExternalPower == true)
        #expect(reading?.isAdapterPresent == nil)
    }

    @Test("Adapter details while on battery mean an adapter is attached")
    func adapterWhileOnBattery() {
        let reading = state(source: "Battery Power")
        #expect(reading?.isOnExternalPower == false)
        #expect(reading?.isAdapterPresent == true)
    }

    @Test("Any other providing source, or none, is unknown external power", arguments: ["UPS Power", nil])
    func otherSource(source: String?) {
        let reading = state(source: source, adapter: false)
        #expect(reading?.isOnExternalPower == nil)
        #expect(reading?.isAdapterPresent == nil)
    }

    @Test("Serious or critical thermal state is high thermal pressure", arguments: [
        (ProcessInfo.ThermalState.nominal, false), (.fair, false), (.serious, true), (.critical, true),
    ])
    func thermal(thermalState: ProcessInfo.ThermalState, isHigh: Bool) {
        #expect(state(thermal: thermalState)?.isThermalPressureHigh == isHigh)
    }

    @Test("The charge is a rounded percentage of the maximum capacity")
    func percentage() {
        #expect(state(battery: battery(percent: 2_999, max: 4_000))?.stateOfCharge == 75)
        #expect(state(battery: battery(percent: 100, max: 100))?.stateOfCharge == 100)
    }

    @Test("Unknown, absent or implausible charge is reported as unknown")
    func unknownCharge() {
        #expect(state(battery: battery(percent: nil))?.stateOfCharge == nil)
        #expect(state(battery: battery(present: false))?.stateOfCharge == nil)
        #expect(state(battery: battery(percent: 120))?.stateOfCharge == nil)
        #expect(state(battery: battery(percent: -1))?.stateOfCharge == nil)
        #expect(state(battery: battery(percent: 50, max: 0))?.stateOfCharge == nil)
        #expect(state(battery: ["Current Capacity": "70", "Max Capacity": 100])?.stateOfCharge == nil)
        // Presence not reported: a described battery counts as present.
        #expect(state(battery: battery(present: nil))?.stateOfCharge == 70)
    }

    @Test("No battery and no providing source means no reading")
    func nothing() {
        #expect(DaemonPowerReading.powerState(battery: nil, providingPowerSourceType: nil, hasAdapterDetails: true, thermalState: .nominal, readAtUptime: 1) == nil)
        // A desktop Mac: no battery, but a providing source.
        let desktop = DaemonPowerReading.powerState(battery: nil, providingPowerSourceType: "AC Power", hasAdapterDetails: false, thermalState: .nominal, readAtUptime: 1)
        #expect(desktop?.stateOfCharge == nil)
        #expect(desktop?.isOnExternalPower == true)
    }

    @Test("Only the presence and capacity keys of the battery are kept; no identifiers")
    func keys() {
        #expect(DaemonPowerReading.batteryKeys == ["Is Present", "Current Capacity", "Max Capacity"])
    }

    @Test("The live reading is stamped with the uptime taken just before it (read-only smoke test)")
    func live() {
        // A virtual machine may report no power source at all.
        if let reading = DaemonPowerReading(uptime: { 1_234 }).latestPowerState() {
            #expect(reading.readAtUptime == 1_234)
            #expect(reading.stateOfCharge.map { (0...100).contains($0) } ?? true)
        }
    }
}
