import CellKeeperCore
import Foundation
import Testing

@Suite("Power flow wording")
struct PowerFlowWordingTests {
    let english = Locale(identifier: "en_US")

    private func flow(_ snapshot: BatterySnapshot) throws -> PowerFlow {
        try #require(PowerFlow(snapshot))
    }

    private func summary(_ snapshot: BatterySnapshot) throws -> String {
        PowerFlowWording.summary(try flow(snapshot), locale: english)
    }

    @Test("The summary says where the power comes from and goes")
    func summaries() throws {
        #expect(try summary(powerSnapshot()) == "The adapter supplies 45 watts: the Mac uses 30 watts and 15 watts charges the battery.")
        #expect(try summary(powerSnapshot(powerIn: 20_000, load: 30_000, current: -833)) == "The adapter supplies 20 watts and the battery supplies 10 watts: the Mac uses 30 watts.")
        #expect(try summary(powerSnapshot(powerIn: 37_304, load: 37_304, current: 0)) == "The adapter supplies 37.3 watts: the Mac uses 37.3 watts. The battery is idle.")
        #expect(try summary(powerSnapshot(source: .battery, powerIn: 0, load: 11_500, current: -1_000)) == "The battery supplies 12 watts: the Mac uses 11.5 watts. No adapter is connected.")
    }

    @Test("The summary says what is idle or not known")
    func summaryGaps() throws {
        #expect(try summary(powerSnapshot(powerIn: nil, current: nil)) == "The Mac uses 30 watts. The battery's power is not available. The adapter's input is not available.")
        #expect(try summary(powerSnapshot(powerIn: nil)) == "The Mac uses 30 watts and 15 watts charges the battery. The adapter's input is not available.")
        #expect(try summary(powerSnapshot(source: .unknown, current: 0)) == "The Mac uses 30 watts. The battery is idle. The power source is unknown.")
        #expect(try summary(powerSnapshot(source: .battery, current: 0)) == "The Mac uses 30 watts. The battery is idle. No adapter is connected.")
    }

    @Test("The nodes show watts with one decimal")
    func nodes() throws {
        let charging = try flow(powerSnapshot())
        #expect(PowerFlowWording.adapterValue(charging, locale: english) == "45.0 W")
        #expect(PowerFlowWording.adapterSubtitle(charging) == "68 W adapter")
        #expect(PowerFlowWording.batteryValue(charging) == "81%")
        #expect(PowerFlowWording.batterySubtitle(charging, locale: english) == "Charging +15.0 W")
        #expect(PowerFlowWording.macValue(charging, locale: english) == "30.0 W")

        let supplying = try flow(powerSnapshot(powerIn: 20_000, current: -1_025))
        #expect(PowerFlowWording.batterySubtitle(supplying, locale: english) == "Supplying 12.3 W")
        let reading1 = try flow(powerSnapshot(current: 0))
        #expect(PowerFlowWording.batterySubtitle(reading1, locale: english) == "Idle")
        let reading2 = try flow(powerSnapshot(current: nil))
        #expect(PowerFlowWording.batterySubtitle(reading2, locale: english) == "Power not available")
        let reading3 = try flow(powerSnapshot(percent: nil))
        #expect(PowerFlowWording.batteryValue(reading3) == "Not available")

        let unplugged = try flow(powerSnapshot(source: .battery, current: -1_000))
        #expect(PowerFlowWording.adapterValue(unplugged, locale: english) == "Not connected")
        #expect(PowerFlowWording.adapterSubtitle(unplugged) == nil)
        let reading4 = try flow(powerSnapshot(powerIn: nil))
        #expect(PowerFlowWording.adapterValue(reading4, locale: english) == "Not available")
        let reading5 = try flow(powerSnapshot(source: .unknown))
        #expect(PowerFlowWording.adapterValue(reading5, locale: english) == "Unknown")
    }

    @Test("VoiceOver reads each node's value with its units in words")
    func spokenNodes() throws {
        let charging = try flow(powerSnapshot())
        #expect(PowerFlowWording.adapterSpoken(charging, locale: english) == "45 watts in, 68-watt adapter")
        #expect(PowerFlowWording.batterySpoken(charging, locale: english) == "81%, charging at 15 watts")
        #expect(PowerFlowWording.macSpoken(charging, locale: english) == "uses 30 watts")

        let reading6 = try flow(powerSnapshot(powerIn: nil))
        #expect(PowerFlowWording.adapterSpoken(reading6, locale: english) == "Input not available, 68-watt adapter")
        let reading7 = try flow(powerSnapshot(adapter: nil))
        #expect(PowerFlowWording.adapterSpoken(reading7, locale: english) == "45 watts in")
        let reading8 = try flow(powerSnapshot(source: .battery))
        #expect(PowerFlowWording.adapterSpoken(reading8, locale: english) == "Not connected")
        let reading9 = try flow(powerSnapshot(source: .unknown))
        #expect(PowerFlowWording.adapterSpoken(reading9, locale: english) == "Unknown")
        let reading10 = try flow(powerSnapshot(current: -1_025))
        #expect(PowerFlowWording.batterySpoken(reading10, locale: english) == "81%, supplying 12.3 watts")
        let reading11 = try flow(powerSnapshot(current: 0))
        #expect(PowerFlowWording.batterySpoken(reading11, locale: english) == "81%, idle")
        let reading12 = try flow(powerSnapshot(current: nil, percent: nil))
        #expect(PowerFlowWording.batterySpoken(reading12, locale: english) == "Charge not available, power not available")
        #expect(PowerFlowWording.spokenWatts(1, locale: english) == "1 watt")
        #expect(PowerFlowWording.spokenWatts(1.04, locale: english) == "1 watt")
        #expect(PowerFlowWording.spokenWatts(1.06, locale: english) == "1.1 watts")
    }

    @Test("No spoken text writes the watt symbol")
    func spokenHasNoSymbol() throws {
        let snapshots = [
            powerSnapshot(), powerSnapshot(powerIn: 20_000, current: -833), powerSnapshot(current: 0),
            powerSnapshot(source: .battery, current: -1_000), powerSnapshot(powerIn: nil, current: nil),
        ]
        let symbol = try Regex("\\bW\\b")
        for snapshot in snapshots {
            let flow = try flow(snapshot)
            for text in [
                PowerFlowWording.summary(flow, locale: english), PowerFlowWording.adapterSpoken(flow, locale: english),
                PowerFlowWording.batterySpoken(flow, locale: english), PowerFlowWording.macSpoken(flow, locale: english),
            ] {
                #expect(text.firstMatch(of: symbol) == nil, "\(text)")
            }
        }
    }

    @Test("Numbers follow the user's format")
    func locales() throws {
        let german = Locale(identifier: "de_DE")
        let supplying = try flow(powerSnapshot(powerIn: 20_000, current: -1_025))
        #expect(PowerFlowWording.watts(45, locale: german) == "45,0 W")
        #expect(PowerFlowWording.batterySubtitle(supplying, locale: german) == "Supplying 12,3 W")
        #expect(PowerFlowWording.spokenWatts(12.3, locale: german) == "12,3 watts")
        let reading13 = try flow(powerSnapshot(adapter: 1_000))
        #expect(PowerFlowWording.adapterSpoken(reading13, locale: german) == "45 watts in, 1.000-watt adapter")
    }

    @Test("The footnote names the source and how often it updates")
    func footnotes() {
        func footnote(_ interval: Duration) -> String {
            PowerFlowWording.footnote(sourceName: "macOS's battery data", updateInterval: interval)
        }
        #expect(footnote(.seconds(60)) == "From macOS's battery data, updated about once a minute.")
        #expect(footnote(.seconds(1)) == "From macOS's battery data, updated about every second.")
        #expect(footnote(.milliseconds(400)) == "From macOS's battery data, updated about every second.")
        #expect(footnote(.milliseconds(2_500)) == "From macOS's battery data, updated about every 3 seconds.")
        #expect(footnote(.milliseconds(2_499)) == "From macOS's battery data, updated about every 2 seconds.")
        #expect(footnote(.seconds(90)) == "From macOS's battery data, updated about every 90 seconds.")
        #expect(footnote(.seconds(120)) == "From macOS's battery data, updated about every 2 minutes.")
        #expect(footnote(.seconds(Int64.max)).hasPrefix("From macOS's battery data, updated about every "))
    }

    @Test("The chart's series have names")
    func seriesTitles() {
        #expect(PowerFlowHistory.Series.allCases.map(PowerFlowWording.title(of:)) == ["Mac use", "Adapter input", "Battery"])
    }
}
