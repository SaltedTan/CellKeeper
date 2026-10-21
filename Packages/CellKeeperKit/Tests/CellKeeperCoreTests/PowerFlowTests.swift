import CellKeeperCore
import Foundation
import Testing

/// A reading with the power flow's inputs. Watts are given in mW, as macOS
/// reports them; the battery's power is `voltage` × `current`.
func powerSnapshot(
    source: PowerSource = .externalPower,
    powerIn: Int? = 45_000,
    load: Int? = 30_000,
    voltage: Int? = 12_000,
    current: Int? = 1_250,
    adapter: Int? = 68,
    percent: Int? = 81,
    present: Bool = true,
    update: Date? = referenceDate,
    at timestamp: Date = referenceDate
) -> BatterySnapshot {
    BatterySnapshot(
        timestamp: timestamp,
        sourceTimestamp: update,
        isBatteryPresent: present,
        chargePercent: percent,
        powerSource: source,
        isCharging: (current ?? 0) > 0,
        voltageMillivolts: voltage,
        amperageMilliamps: current,
        adapterWatts: adapter,
        systemPowerInMilliwatts: powerIn,
        systemLoadMilliwatts: load
    )
}

@Suite("Power flow")
struct PowerFlowTests {
    @Test("Without the Mac's power use there is no flow, whatever else is known")
    func unavailableWithoutLoad() {
        #expect(PowerFlow(powerSnapshot(load: nil)) == nil)
        #expect(PowerFlow(powerSnapshot(source: .battery, powerIn: nil, load: nil)) == nil)
        #expect(PowerFlow(powerSnapshot(load: 0)) != nil)
    }

    @Test("Charging on the adapter: the adapter feeds the Mac and the battery")
    func chargingOnAdapter() throws {
        let flow = try #require(PowerFlow(powerSnapshot()))
        #expect(flow.adapterInputWatts == 45)
        #expect(flow.macUseWatts == 30)
        #expect(flow.batteryWatts == 15)
        #expect(flow.battery == .charging(watts: 15))
        #expect(flow.adapterRatingWatts == 68)
        #expect(flow.chargePercent == 81)
        #expect(flow.adapterToMacWatts == 30)
        #expect(flow.adapterToBatteryWatts == 15)
        #expect(flow.batteryToMacWatts == nil)
    }

    @Test("An adapter too weak for the Mac: the battery supplies the rest, on external power")
    func supplyingOnAdapter() throws {
        let flow = try #require(PowerFlow(powerSnapshot(powerIn: 20_000, load: 30_000, current: -833)))
        let supplied = 12_000.0 * 833 / 1_000_000
        #expect(flow.battery == .supplying(watts: supplied))
        #expect(flow.batteryWatts == -supplied)
        #expect(flow.adapterToMacWatts == 20)
        #expect(flow.batteryToMacWatts == supplied)
        #expect(flow.adapterToBatteryWatts == nil)
    }

    @Test("Full on the adapter, as observed: SystemPowerIn equals SystemLoad and the battery is idle")
    func idleAtFull() throws {
        let flow = try #require(PowerFlow(powerSnapshot(powerIn: 37_304, load: 37_304, current: 0, percent: 100)))
        #expect(flow.battery == .idle)
        #expect(flow.adapterToMacWatts == 37.304)
        #expect(flow.adapterToBatteryWatts == nil)
        #expect(flow.batteryToMacWatts == nil)
    }

    @Test("On battery power: no adapter flow, even with a power input reported")
    func onBattery() throws {
        let flow = try #require(PowerFlow(powerSnapshot(source: .battery, powerIn: 500, load: 11_500, current: -1_000, adapter: 68)))
        #expect(flow.adapterInputWatts == nil)
        #expect(flow.adapterRatingWatts == nil)
        #expect(flow.adapterToMacWatts == nil)
        #expect(flow.adapterToBatteryWatts == nil)
        #expect(flow.battery == .supplying(watts: 12))
        #expect(flow.batteryToMacWatts == 12)
    }

    @Test("An unknown power source gives no adapter input")
    func unknownSource() throws {
        let flow = try #require(PowerFlow(powerSnapshot(source: .unknown)))
        #expect(flow.adapterInputWatts == nil)
        #expect(flow.adapterToMacWatts == nil)
        #expect(flow.adapterToBatteryWatts == nil)
        #expect(flow.battery == .charging(watts: 15))
    }

    @Test("Below 0.3 W either way the battery is idle", arguments: [
        (300, PowerFlow.Battery.charging(watts: 0.3)), (299, .idle), (0, .idle),
        (-299, .idle), (-300, .supplying(watts: 0.3)),
    ])
    func idleThreshold(current: Int, expected: PowerFlow.Battery) throws {
        let flow = try #require(PowerFlow(powerSnapshot(voltage: 1_000, current: current)))
        #expect(flow.battery == expected)
    }

    @Test("Without the battery's voltage or current, its flows are unknown")
    func batteryUnknown() throws {
        for (voltage, current) in [(nil, 1_250), (12_000, nil), (nil, nil)] as [(Int?, Int?)] {
            let flow = try #require(PowerFlow(powerSnapshot(voltage: voltage, current: current)))
            #expect(flow.battery == nil)
            #expect(flow.batteryWatts == nil)
            #expect(flow.adapterToBatteryWatts == nil)
            #expect(flow.batteryToMacWatts == nil)
            #expect(flow.adapterToMacWatts == 30)
        }
    }

    @Test("Without the adapter's input, only the battery's flows are known on external power")
    func adapterInputUnknown() throws {
        let flow = try #require(PowerFlow(powerSnapshot(powerIn: nil)))
        #expect(flow.adapterInputWatts == nil)
        #expect(flow.adapterToMacWatts == nil)
        #expect(flow.adapterToBatteryWatts == 15)
    }

    @Test("Values that do not add up are shown as reported, with nothing made up")
    func noForcedBalance() throws {
        // 45 W in, 30 W used, 10 W charging: 5 W unaccounted for.
        let flow = try #require(PowerFlow(powerSnapshot(powerIn: 45_000, load: 30_000, current: 833)))
        #expect(flow.adapterInputWatts == 45)
        #expect(flow.adapterToMacWatts == 30)
        #expect(flow.adapterToBatteryWatts == 12_000.0 * 833 / 1_000_000)
        // More in than used while supplying: the use, not the input, reaches the Mac.
        let odd = try #require(PowerFlow(powerSnapshot(powerIn: 35_000, load: 30_000, current: -500)))
        #expect(odd.adapterToMacWatts == 30)
        #expect(odd.batteryToMacWatts == 6)
    }

    @Test("A charge reported on battery power gives no adapter flow")
    func chargingOnBattery() throws {
        let flow = try #require(PowerFlow(powerSnapshot(source: .battery)))
        #expect(flow.battery == .charging(watts: 15))
        #expect(flow.adapterToBatteryWatts == nil)
    }

    @Test("Without a battery there is no charge")
    func noBatteryCharge() throws {
        let flow = try #require(PowerFlow(powerSnapshot(present: false)))
        #expect(flow.chargePercent == nil)
    }

    @Test("A flow is active from 0.3 W")
    func activeFlows() {
        #expect(!PowerFlow.isActive(nil))
        #expect(!PowerFlow.isActive(0))
        #expect(!PowerFlow.isActive(0.29))
        #expect(PowerFlow.isActive(0.3))
        #expect(PowerFlow.isActive(45))
    }
}
