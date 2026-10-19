import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

/// The statuses these tests vary: what a refusal reads.
private enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func reading(_ percent: Int?, _ source: PowerSource = .externalPower, battery: Bool = true) -> BatterySnapshot {
        BatterySnapshot(timestamp: start, isBatteryPresent: battery, chargePercent: percent, powerSource: source)
    }

    static func override(_ kind: ChargeOverride.Kind?) -> ChargeOverride? {
        switch kind {
        case .fullCharge?: .fullCharge(at: start, uptime: 10_000)
        case .dischargeToLimit?: .dischargeToLimit(target: 80, at: start, uptime: 10_000)
        case nil: nil
        }
    }

    static func settings(managed: Bool = true, limit: Int = 80) -> ChargingSettings {
        var settings = ChargingSettings.default.withChargeLimit(limit)
        settings.isManagementEnabled = managed
        return settings
    }

    /// What a backend offers, as the controller reports it.
    static let simulated = ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)
    static let noDischarge = ControlCapabilities(availability: .experimental, supportedModes: [.normal, .inhibitCharging])
    static let unavailable = ControlCapabilities.unavailable("No helper is installed.")
    /// A backend that switches charging itself while macOS's own Charge
    /// Limit may be limiting charging: only `.normal`.
    static let withheld = simulated.withoutRestrictingModes
    static let capabilities = [simulated, noDischarge, unavailable, withheld]
}

@Suite("Discharge Now…: why it is disabled")
struct DischargeStartTests {
    private static let managementOff = "Manage charging is off. Turn it on to discharge to the limit."
    private static let limitRange = "Discharging needs a limit of 20–95%."
    private static let backend = "Discharging while plugged in is not available with the current backend."
    private static let noReading = "CellKeeper has no reading of the battery's charge."
    private static let onBattery = "The Mac is on battery. Connect power first."
    private static let notPlugged = "CellKeeper has no battery reading that shows the Mac plugged in."
    private static let atOrBelow = "The battery is already at or below the limit."
    private static let fullCharge = "A temporary full charge is running."
    private static let discharge = "A discharge to the limit is already running."

    /// The view's predicate before the reasons, kept to show that the same
    /// conditions enable the button.
    private static func legacyCanStart(settings: ChargingSettings, status: ControllerStatus?) -> Bool {
        guard let status, let snapshot = status.snapshot, let percent = snapshot.chargePercent else { return false }
        return settings.isManagementEnabled
            && status.activeOverride == nil
            && snapshot.isOnExternalPower
            && percent > settings.chargeLimit
            && ChargingPolicy.dischargeTargetRange.contains(settings.chargeLimit)
            && status.capabilities.supports(.forceDischarge)
    }

    private struct Case: Sendable, CustomStringConvertible {
        var description: String
        var managed = true
        var limit = 80
        var capabilities = Fixture.simulated
        var snapshot: BatterySnapshot? = Fixture.reading(90)
        var override: ChargeOverride.Kind?
        var reason: String?
    }

    private static let cases: [Case] = [
        Case(description: "plugged in above the limit", reason: nil),
        Case(description: "the lowest limit it takes", limit: 20, snapshot: Fixture.reading(21), reason: nil),
        Case(description: "the highest limit it takes", limit: 95, snapshot: Fixture.reading(96), reason: nil),
        Case(description: "management off", managed: false, reason: managementOff),
        Case(description: "limit 100%", limit: 100, snapshot: Fixture.reading(100), reason: limitRange),
        Case(description: "limit 96%", limit: 96, snapshot: Fixture.reading(100), reason: limitRange),
        Case(description: "a backend without a discharge", capabilities: Fixture.noDischarge, reason: backend),
        Case(description: "an unavailable backend", capabilities: Fixture.unavailable, reason: backend),
        Case(description: "macOS's Charge Limit withholding restrictions", capabilities: Fixture.withheld, reason: backend),
        Case(description: "no reading", snapshot: nil, reason: noReading),
        Case(description: "a reading without the charge", snapshot: Fixture.reading(nil), reason: noReading),
        Case(description: "on battery", snapshot: Fixture.reading(90, .battery), reason: onBattery),
        Case(description: "an unknown power source", snapshot: Fixture.reading(90, .unknown), reason: notPlugged),
        Case(description: "at the limit", snapshot: Fixture.reading(80), reason: atOrBelow),
        Case(description: "below the limit", snapshot: Fixture.reading(60), reason: atOrBelow),
        Case(description: "a full charge running", override: .fullCharge, reason: fullCharge),
        Case(description: "a discharge running", override: .dischargeToLimit, reason: discharge),
    ]

    @Test("Each condition has its own reason, and none when it can start", arguments: cases)
    private func reason(_ row: Case) async {
        var status = await evaluatedActionStatus()
        status.capabilities = row.capabilities
        status.snapshot = row.snapshot
        status.activeOverride = Fixture.override(row.override)
        #expect(DischargeStart.refusal(settings: Fixture.settings(managed: row.managed, limit: row.limit), status: status) == row.reason)
    }

    @Test("Before the first status there is no reading; settings are checked first")
    func noStatus() {
        #expect(DischargeStart.refusal(settings: Fixture.settings(), status: nil) == Self.noReading)
        #expect(DischargeStart.refusal(settings: Fixture.settings(managed: false), status: nil) == Self.managementOff)
        #expect(DischargeStart.refusal(settings: Fixture.settings(limit: 100), status: nil) == Self.limitRange)
    }

    @Test("The first failing condition decides, in a fixed order")
    func precedence() async {
        // Everything fails; each step fixes the condition just reported.
        var settings = Fixture.settings(managed: false, limit: 100)
        var status = await evaluatedActionStatus()
        status.capabilities = Fixture.unavailable
        status.snapshot = nil
        status.activeOverride = Fixture.override(.fullCharge)
        #expect(DischargeStart.refusal(settings: settings, status: status) == Self.managementOff)
        settings.isManagementEnabled = true
        #expect(DischargeStart.refusal(settings: settings, status: status) == Self.limitRange)
        settings = settings.withChargeLimit(80)
        #expect(DischargeStart.refusal(settings: settings, status: status) == Self.backend)
        status.capabilities = Fixture.simulated
        #expect(DischargeStart.refusal(settings: settings, status: status) == Self.noReading)
        status.snapshot = Fixture.reading(70, .battery)
        #expect(DischargeStart.refusal(settings: settings, status: status) == Self.onBattery)
        status.snapshot = Fixture.reading(70)
        #expect(DischargeStart.refusal(settings: settings, status: status) == Self.atOrBelow)
        status.snapshot = Fixture.reading(90)
        #expect(DischargeStart.refusal(settings: settings, status: status) == Self.fullCharge)
        status.activeOverride = nil
        #expect(DischargeStart.refusal(settings: settings, status: status) == nil)
    }

    @Test("Enabled exactly when the old predicate allowed it, and otherwise one plain sentence")
    func sameConditions() async {
        let base = await evaluatedActionStatus()
        let snapshots: [BatterySnapshot?] = [nil, Fixture.reading(nil)] + [19, 20, 21, 79, 80, 81, 90, 95, 96, 100].flatMap { percent in
            [Fixture.reading(percent), Fixture.reading(percent, .battery), Fixture.reading(percent, .unknown), Fixture.reading(percent, battery: false)]
        }
        let overrides: [ChargeOverride.Kind?] = [nil, .fullCharge, .dischargeToLimit]
        var checked = 0
        var enabled = 0
        for managed in [true, false] {
            for limit in [20, 21, 79, 80, 81, 94, 95, 96, 100] {
                let settings = Fixture.settings(managed: managed, limit: limit)
                #expect((DischargeStart.refusal(settings: settings, status: nil) == nil) == Self.legacyCanStart(settings: settings, status: nil))
                for capabilities in Fixture.capabilities {
                    for snapshot in snapshots {
                        for override in overrides {
                            var status = base
                            status.capabilities = capabilities
                            status.snapshot = snapshot
                            status.activeOverride = Fixture.override(override)
                            let refusal = DischargeStart.refusal(settings: settings, status: status)
                            let legacy = Self.legacyCanStart(settings: settings, status: status)
                            #expect((refusal == nil) == legacy, "managed \(managed), limit \(limit), \(String(describing: snapshot)), \(String(describing: override))")
                            if let refusal {
                                #expect(refusal.hasSuffix(".") && !refusal.contains("forceDischarge") && !refusal.contains("externalPower"))
                            } else {
                                enabled += 1
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 2 * 9 * 4 * 42 * 3)
        // Manage charging on, the simulated backend, no override, plugged
        // in with a charge above a limit of 20–95%: 8 + 7 + 6 + 5 + 4 + 3 + 2
        // charges above the seven limits in range, with a battery present
        // or not (the old predicate did not check).
        #expect(enabled == 35 * 2)
    }

    @Test("A stored limit below 20%, which the settings' own setter clamps, is refused for its range, as before")
    func limitBelowRange() async {
        var settings = Fixture.settings()
        settings.chargeLimit = 19
        var status = await evaluatedActionStatus()
        status.capabilities = Fixture.simulated
        status.snapshot = Fixture.reading(90)
        #expect(DischargeStart.refusal(settings: settings, status: status) == Self.limitRange)
        #expect(!Self.legacyCanStart(settings: settings, status: status))
    }
}

@Suite("Charge to 100% once: why it is disabled")
struct FullChargeStartReasonTests {
    @Test("The first failing condition decides, in a fixed order")
    func precedence() async {
        var settings = Fixture.settings(managed: false, limit: 100)
        var status = await evaluatedActionStatus()
        status.snapshot = Fixture.reading(70, .battery)
        status.activeOverride = Fixture.override(.dischargeToLimit)
        #expect(FullChargeStart.refusal(settings: settings, status: status) == "A discharge to the limit is running. Stop it first.")
        status.activeOverride = nil
        #expect(FullChargeStart.refusal(settings: settings, status: status) == "Manage charging is off. Turn it on to charge to 100% once.")
        settings.isManagementEnabled = true
        #expect(FullChargeStart.refusal(settings: settings, status: status) == "CellKeeper's limit is already 100%.")
        settings = settings.withChargeLimit(80)
        #expect(FullChargeStart.refusal(settings: settings, status: status) == "The Mac is on battery. Connect power first.")
        status.snapshot = Fixture.reading(70, battery: false)
        #expect(FullChargeStart.refusal(settings: settings, status: status) == "CellKeeper has no battery reading that shows the Mac plugged in.")
        status.snapshot = Fixture.reading(70)
        #expect(FullChargeStart.refusal(settings: settings, status: status) == nil)
    }

    @Test("Enabled exactly when D97's conditions hold, and otherwise one plain sentence")
    func sameConditions() async {
        let base = await evaluatedActionStatus()
        let snapshots: [BatterySnapshot?] = [nil, Fixture.reading(nil), Fixture.reading(nil, .battery)] + [20, 79, 80, 81, 100].flatMap { percent in
            [Fixture.reading(percent), Fixture.reading(percent, .battery), Fixture.reading(percent, .unknown), Fixture.reading(percent, battery: false)]
        }
        var enabled = 0
        for managed in [true, false] {
            for limit in [20, 80, 95, 99, 100] {
                let settings = Fixture.settings(managed: managed, limit: limit)
                for capabilities in Fixture.capabilities {
                    for snapshot in snapshots {
                        for override in [nil, ChargeOverride.Kind.fullCharge, .dischargeToLimit] {
                            var status = base
                            status.capabilities = capabilities
                            status.snapshot = snapshot
                            status.activeOverride = Fixture.override(override)
                            let refusal = FullChargeStart.refusal(settings: settings, status: status)
                            let allowed = managed && override == nil && limit < 100
                                && snapshot?.isBatteryPresent == true && snapshot?.isOnExternalPower == true
                            #expect((refusal == nil) == allowed, "managed \(managed), limit \(limit), \(String(describing: snapshot)), \(String(describing: override))")
                            if let refusal {
                                #expect(refusal.hasSuffix(".") && !refusal.contains("externalPower"))
                            } else {
                                enabled += 1
                            }
                        }
                    }
                }
            }
        }
        // Manage charging on, four limits below 100%, any of the four
        // backends, plugged in with a battery (six readings), no override.
        #expect(enabled == 4 * 4 * 6)
    }
}
