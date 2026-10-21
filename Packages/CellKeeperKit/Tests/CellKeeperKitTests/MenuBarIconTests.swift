import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

private let battery = MenuBarIconPreferences.default
private let batteryWithoutPercentage = MenuBarIconPreferences(style: .battery, showsPercentage: false)
private let statusStyle = MenuBarIconPreferences(style: .status, showsPercentage: true)

/// A status from a real evaluation, with its reading and its state replaced.
private func status(
    percent: Int? = 70,
    powerSource: PowerSource = .externalPower,
    isCharging: Bool? = true,
    isBatteryPresent: Bool = true,
    state: PolicyState = .charging,
    isFaulted: Bool = false
) async -> ControllerStatus {
    var status = await evaluatedActionStatus()
    status.snapshot = BatterySnapshot(timestamp: Date(timeIntervalSince1970: 1_800_000_000), isBatteryPresent: isBatteryPresent, chargePercent: percent, powerSource: powerSource, isCharging: isCharging)
    status.decision?.state = state
    status.isBackendFaulted = isFaulted
    return status
}

/// The battery an icon draws, or nil if it shows a symbol.
private func drawnBattery(_ icon: MenuBarIcon) -> MenuBarBattery? {
    guard case .battery(let battery) = icon else { return nil }
    return battery
}

@Suite("Menu bar icon")
struct MenuBarIconTests {
    @Test("Before the first status, both styles show batteryblock")
    func beforeFirstStatus() {
        #expect(MenuBarIcon(status: nil, preferences: battery) == .symbol("batteryblock"))
        #expect(MenuBarIcon(status: nil, preferences: statusStyle) == .symbol("batteryblock"))
    }

    @Test("The status style shows CellKeeper's status symbol for every state, as before")
    func statusStyleSymbols() async {
        let symbols: [PolicyState: String] = [
            .unmanaged: "batteryblock.slash",
            .failSafe: "exclamationmark.triangle",
            .temperaturePause: "thermometer.high",
            .discharging: "minus.plus.batteryblock",
        ]
        for state in PolicyState.allCases {
            let charging = await status(isCharging: true, state: state)
            let notCharging = await status(isCharging: false, state: state)
            #expect(MenuBarIcon(status: charging, preferences: statusStyle) == .symbol(symbols[state] ?? "bolt.batteryblock"), "\(state)")
            #expect(MenuBarIcon(status: notCharging, preferences: statusStyle) == .symbol(symbols[state] ?? "batteryblock"), "\(state)")
            // A fault comes before every state.
            let faulted = await status(state: state, isFaulted: true)
            #expect(MenuBarIcon(status: faulted, preferences: statusStyle) == .symbol("exclamationmark.triangle"), "\(state)")
        }
        var undecided = await status()
        undecided.decision = nil
        undecided.isBackendFaulted = true
        #expect(MenuBarIcon.statusSymbol(for: undecided) == "batteryblock")
    }

    @Test("The Battery style fills to the charge and shows it as text")
    func fillAndText() async throws {
        let reading = await status(percent: 64)
        let drawn = try #require(drawnBattery(MenuBarIcon(status: reading, preferences: battery)))
        #expect(drawn.percent == 64)
        #expect(drawn.fillFraction == 0.64)
        #expect(drawn.percentageText == "64%")

        let hidden = try #require(drawnBattery(MenuBarIcon(status: reading, preferences: batteryWithoutPercentage)))
        #expect(hidden.percent == 64)
        #expect(hidden.percentageText == nil)
    }

    @Test("A charge outside 0–100% is clamped, in the fill and the text", arguments: [(-5, 0), (0, 0), (100, 100), (130, 100)])
    func clamped(reported: Int, shown: Int) async throws {
        let reading = await status(percent: reported)
        let drawn = try #require(drawnBattery(MenuBarIcon(status: reading, preferences: battery)))
        #expect(drawn.percent == shown)
        #expect(drawn.percentageText == "\(shown)%")
        #expect((0...1).contains(drawn.fillFraction))
    }

    @Test("The bolt shows while macOS reports charging, the plug on power otherwise, nothing on battery")
    func glyphs() async {
        let cases: [(PowerSource, Bool?, MenuBarBattery.Glyph)] = [
            (.externalPower, true, .bolt),
            (.externalPower, false, .plug),
            (.externalPower, nil, .plug),
            (.battery, false, .none),
            (.battery, nil, .none),
            (.unknown, nil, .none),
            (.unknown, false, .none),
            // What macOS reports decides, as for the status symbol.
            (.unknown, true, .bolt),
        ]
        for (powerSource, isCharging, glyph) in cases {
            let icon = MenuBarIcon(status: await status(powerSource: powerSource, isCharging: isCharging), preferences: battery)
            #expect(drawnBattery(icon)?.glyph == glyph, "\(powerSource), charging \(String(describing: isCharging))")
        }
    }

    @Test("Held at the limit, full or paused on power, the battery shows the plug", arguments: [PolicyState.holding, .osEnforcedLimit, .deferringToMacOS, .unmanaged, .temperaturePause])
    func plugWhileHeld(state: PolicyState) async {
        let icon = MenuBarIcon(status: await status(percent: 80, isCharging: false, state: state), preferences: battery)
        #expect(drawnBattery(icon)?.glyph == .plug)
    }

    @Test("A fault, the fail-safe and a temperature pause keep a symbol beside the battery; other states show none")
    func attention() async {
        for state in PolicyState.allCases {
            let expected: String? = switch state {
            case .failSafe: "exclamationmark.triangle"
            case .temperaturePause: "thermometer.high"
            default: nil
            }
            let icon = MenuBarIcon(status: await status(state: state), preferences: battery)
            #expect(drawnBattery(icon)?.attentionSymbol == expected, "\(state)")
            // A fault comes first, also over a temperature pause.
            let faulted = MenuBarIcon(status: await status(state: state, isFaulted: true), preferences: battery)
            #expect(drawnBattery(faulted)?.attentionSymbol == "exclamationmark.triangle", "\(state)")
        }
    }

    @Test("Without a battery or a known charge, the Battery style shows the status symbol")
    func fallback() async {
        let noBattery = await status(isBatteryPresent: false, state: .holding)
        #expect(MenuBarIcon(status: noBattery, preferences: battery) == .symbol("bolt.batteryblock"))
        let unknownCharge = await status(percent: nil, isCharging: false, state: .failSafe)
        #expect(MenuBarIcon(status: unknownCharge, preferences: battery) == .symbol("exclamationmark.triangle"))
        var noReading = await status(state: .unmanaged)
        noReading.snapshot = nil
        #expect(MenuBarIcon(status: noReading, preferences: battery) == .symbol("batteryblock.slash"))
    }

    @Test("The status style ignores the percentage setting")
    func statusStyleHasNoPercentage() async {
        let hidden = MenuBarIconPreferences(style: .status, showsPercentage: false)
        let charging = await status()
        #expect(MenuBarIcon(status: charging, preferences: statusStyle) == .symbol("bolt.batteryblock"))
        #expect(MenuBarIcon(status: charging, preferences: hidden) == .symbol("bolt.batteryblock"))
    }
}

@Suite("Menu bar battery fill")
struct MenuBarBatteryFillTests {
    private func width(_ percent: Int, in width: Double = 19, minimum: Double = 2) -> Double {
        MenuBarBattery(percent: percent, glyph: .none, percentageText: nil, attentionSymbol: nil).fillWidth(in: width, minimum: minimum)
    }

    @Test("Empty at 0%, full at 100%, proportional in half points between")
    func proportional() {
        #expect(width(0) == 0)
        #expect(width(100) == 19)
        #expect(width(50) == 9.5)
        // 19 × 0.64 = 12.16, to the nearest half point.
        #expect(width(64) == 12)
        // 19 × 0.66 = 12.54.
        #expect(width(66) == 12.5)
    }

    @Test("Any charge above 0% shows at least the minimum sliver")
    func sliver() {
        for percent in 1...10 {
            #expect(width(percent) >= 2, "\(percent)%")
        }
        #expect(width(1) == 2)
        #expect(width(20) == 4)
    }

    @Test("The fill grows with the charge and never leaves the battery")
    func monotonic() {
        var previous = -1.0
        for percent in -10...110 {
            let fill = width(percent)
            #expect(fill >= previous, "\(percent)%")
            #expect((0...19).contains(fill), "\(percent)%")
            previous = fill
        }
        // A minimum wider than the battery still fits.
        #expect(width(1, in: 1.5, minimum: 2) == 1.5)
        #expect(width(50, in: 0, minimum: 2) == 0)
    }
}
