import CellKeeperCore
import CellKeeperHelperCore
import CellKeeperKit
import Foundation
import Testing

private let utc = TimeZone(identifier: "UTC")!
private let posix = Locale(identifier: "en_US_POSIX")

private func context(_ status: ControllerStatus, settings: ChargingSettings? = nil) -> ShortcutsActionContext {
    ShortcutsActionContext(status: status, settings: settings ?? status.settings, selectedBackendIdentifier: status.backend.identifier)!
}

/// A Simulated helper on a stepped clock, with macOS's Charge Limit read as
/// `reading` (as in `ControlStatementTests`).
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

@Suite("Shortcuts actions: wording")
struct ShortcutsActionWordingTests {
    private let simulatedNote = "Simulated: nothing on your Mac changes."
    private let readOnlyNote = "Read-only is selected, so CellKeeper changes nothing."
    private let withIt = "The menu shows what CellKeeper does with it."
    private let now = "The menu shows what CellKeeper does now."

    // MARK: - Set CellKeeper Limit

    @Test("A saved limit states the saved setting, the saved resume threshold, the simulation and where to see the rest")
    func limitSavedSimulated() async {
        let status = await evaluatedActionStatus()
        let text = ShortcutsActionWording.limitSaved(in: context(status, settings: ChargingSettings.default.withChargeLimit(70)))
        #expect(text == "CellKeeper saved its limit as 70%. Its saved resume threshold is 67%. \(simulatedNote) \(withIt)")
    }

    @Test("With Manage charging off, the limit is said not to apply, and the simulation is still said")
    func limitSavedManagementOff() async {
        let status = await evaluatedActionStatus()
        var settings = ChargingSettings.default.withChargeLimit(70)
        settings.isManagementEnabled = false
        let saved = ShortcutsActionWording.limitSaved(in: context(status, settings: settings))
        #expect(saved == "CellKeeper saved its limit as 70%. Its saved resume threshold is 67%. Manage charging is off, so the limit is not applied until you turn it on. \(simulatedNote)")
        settings = .default
        settings.isManagementEnabled = false
        let unchanged = ShortcutsActionWording.limitUnchanged(in: context(status, settings: settings))
        #expect(unchanged == "CellKeeper's limit is already 80%. Manage charging is off, so the limit is not applied until you turn it on. \(simulatedNote)")
    }

    @Test("An unchanged limit keeps the qualifiers of the context")
    func limitUnchangedSimulated() async {
        let text = ShortcutsActionWording.limitUnchanged(in: context(await evaluatedActionStatus()))
        #expect(text == "CellKeeper's limit is already 80%. \(simulatedNote)")
    }

    @Test("Read-only is said to change nothing, with no pointer to what it does")
    func limitSavedReadOnly() async {
        let status = await evaluatedActionStatus(ReadOnlyChargingBackend())
        let text = ShortcutsActionWording.limitSaved(in: context(status, settings: ChargingSettings.default.withChargeLimit(70)))
        #expect(text == "CellKeeper saved its limit as 70%. Its saved resume threshold is 67%. \(readOnlyNote)")
    }

    @Test("With macOS's Charge Limit there is no resume threshold, and an unavailable one changes nothing, without its reason")
    func limitSavedNative() async {
        let simulated = await evaluatedActionStatus()
        let settings = ChargingSettings.default.withChargeLimit(85)
        let available = ShortcutsActionWording.limitSaved(in: context(asNativeLimit(simulated), settings: settings))
        #expect(available == "CellKeeper saved its limit as 85%. \(withIt)")
        let unavailable = ShortcutsActionWording.limitSaved(in: context(asNativeLimit(simulated, availability: .unavailable(reason: "no shortcut")), settings: settings))
        #expect(unavailable == "CellKeeper saved its limit as 85%. macOS Charge Limit is unavailable right now, so CellKeeper changes nothing; the menu says why.")
    }

    @Test("A fault is said for the backend in charge")
    func fault() async {
        var simulated = await evaluatedActionStatus()
        simulated.isBackendFaulted = true
        #expect(ShortcutsActionWording.limitUnchanged(in: context(simulated)) == "CellKeeper's limit is already 80%. \(simulatedNote) The control backend is faulted: until you clear the fault in Settings › Control, CellKeeper only asks for normal charging.")
        var native = asNativeLimit(await evaluatedActionStatus())
        native.isBackendFaulted = true
        #expect(ShortcutsActionWording.qualifier(.fault, in: context(native)) == "The control backend is faulted: until you clear the fault in Settings › Control, CellKeeper only gives back your own Charge Limit.")
    }

    @Test("Deferring to macOS's limit gives the menu's note with the warning that CellKeeper's own restriction may remain")
    func deferring() async {
        var status = await evaluatedActionStatus(simulatedHelper(.limit(80)))
        status.ownRestrictionMode = .inhibitCharging
        status.currentMode = nil
        let note = "While macOS reports its Charge Limit on at 80%, CellKeeper withholds new restrictions: its own limit, temperature pause and discharge are not applied. CellKeeper's own restriction (a charging pause, simulated) may remain until a read-back shows it ended."
        #expect(ShortcutsActionWording.qualifier(.deferringToMacOS, in: context(status)) == note)
        #expect(ShortcutsActionWording.limitUnchanged(in: context(status)) == "CellKeeper's limit is already 80%. \(simulatedNote) \(note)")
        // Turning management on is worded with the settings as saved, so
        // the note comes although the status was taken with it off.
        var off = status
        off.settings.isManagementEnabled = false
        #expect(ShortcutsActionWording.management(isOn: true, changed: true, in: context(off, settings: .default)) == "CellKeeper saved Manage charging as on. \(simulatedNote) \(note) \(withIt)")
    }

    @Test("A running full charge and a limit below 50% are said")
    func fullChargeRunningAndLowLimit() async {
        var status = await evaluatedActionStatus()
        status.activeOverride = .fullCharge(at: Date(timeIntervalSince1970: 1_800_000_000), uptime: 10_000)
        let text = ShortcutsActionWording.limitSaved(in: context(status, settings: ChargingSettings.default.withChargeLimit(40)))
        #expect(text == "CellKeeper saved its limit as 40%. Its saved resume threshold is 37%. \(simulatedNote) A temporary full charge is running, which takes precedence over the limit until it ends. Limits below 50% leave little charge for unplugged use. \(withIt)")
    }

    // MARK: - The other actions

    @Test("Start acknowledges the request; it never says a full charge started")
    func fullChargeQueued() async {
        let simulated = await evaluatedActionStatus()
        #expect(ShortcutsActionWording.fullChargeQueued(in: context(simulated)) == "CellKeeper received the request for a temporary full charge. \(simulatedNote) \(withIt)")
        #expect(ShortcutsActionWording.fullChargeQueued(in: context(asNativeLimit(simulated))) == "CellKeeper received the request for a temporary full charge. \(withIt)")
        let readOnly = await evaluatedActionStatus(ReadOnlyChargingBackend())
        #expect(ShortcutsActionWording.fullChargeQueued(in: context(readOnly)) == "CellKeeper received the request for a temporary full charge. \(readOnlyNote)")
    }

    @Test("Stop says what it will do with whatever is running, and no more")
    func stopQueued() async {
        let generic = "CellKeeper will end any temporary full charge or discharge in progress."
        #expect(ShortcutsActionWording.stopQueued(in: nil) == "\(generic) \(now)")
        let simulated = await evaluatedActionStatus()
        let readOnly = await evaluatedActionStatus(ReadOnlyChargingBackend())
        #expect(ShortcutsActionWording.stopQueued(in: context(simulated)) == "\(generic) \(simulatedNote) \(now)")
        #expect(ShortcutsActionWording.stopQueued(in: context(readOnly)) == "\(generic) \(readOnlyNote)")
    }

    @Test("Manage charging: saved or already so, with the qualifiers of the context")
    func management() async {
        let simulated = await evaluatedActionStatus()
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        #expect(ShortcutsActionWording.management(isOn: true, changed: true, in: context(simulated)) == "CellKeeper saved Manage charging as on. \(simulatedNote) \(withIt)")
        #expect(ShortcutsActionWording.management(isOn: true, changed: false, in: context(simulated)) == "Manage charging is already on. \(simulatedNote)")
        #expect(ShortcutsActionWording.management(isOn: false, changed: true, in: context(asNativeLimit(simulated), settings: off)) == "CellKeeper saved Manage charging as off. \(now)")
        #expect(ShortcutsActionWording.management(isOn: false, changed: false, in: nil) == "Manage charging is already off.")
    }

    @Test("Every result that uses a qualifier says it in the same words, whatever its sentence")
    func qualifiersIndependentOfSentence() async {
        var faulted = await evaluatedActionStatus()
        faulted.isBackendFaulted = true
        var running = await evaluatedActionStatus()
        running.activeOverride = .fullCharge(at: Date(timeIntervalSince1970: 1_800_000_000), uptime: 10_000)
        let statuses = [
            await evaluatedActionStatus(), await evaluatedActionStatus(ReadOnlyChargingBackend()), faulted, running,
            asNativeLimit(await evaluatedActionStatus()), await evaluatedActionStatus(simulatedHelper(.limit(80))),
        ]
        var off = ChargingSettings.default.withChargeLimit(40)
        off.isManagementEnabled = false
        for status in statuses {
            for settings in [status.settings, off] {
                let ctx = context(status, settings: settings)
                let results: [(String, [ShortcutsActionWording.Qualifier])] = [
                    (ShortcutsActionWording.limitSaved(in: ctx), [.managementOff, .simulated, .noRequests, .fault, .deferringToMacOS, .fullChargeRunning, .belowHalf]),
                    (ShortcutsActionWording.limitUnchanged(in: ctx), [.managementOff, .simulated, .noRequests, .fault, .deferringToMacOS, .fullChargeRunning, .belowHalf]),
                    (ShortcutsActionWording.fullChargeQueued(in: ctx), [.simulated, .noRequests, .fault, .deferringToMacOS]),
                    (ShortcutsActionWording.management(isOn: true, changed: false, in: ctx), [.simulated, .noRequests, .fault, .deferringToMacOS]),
                    (ShortcutsActionWording.stopQueued(in: ctx), [.simulated, .noRequests]),
                    (ShortcutsActionWording.management(isOn: false, changed: true, in: ctx), [.simulated, .noRequests]),
                ]
                for (text, qualifiers) in results {
                    for qualifier in qualifiers {
                        if let sentence = ShortcutsActionWording.qualifier(qualifier, in: ctx) {
                            #expect(text.contains(sentence), "\(qualifier) missing from: \(text)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Get CellKeeper Status

    @Test("The status value: the battery, D89's words for macOS's report and CellKeeper's state, the backend, and the saved settings")
    func statusSimulated() async throws {
        let status = await evaluatedActionStatus()
        let value = ShortcutsStatus(status: status, settings: status.settings, selectedBackendIdentifier: status.backend.identifier, timeZone: utc, locale: posix)
        #expect(value.batteryCharge == 70)
        #expect(value.chargingStatus == "charging")
        #expect(value.state == "charging to the limit")
        #expect(value.control == "Simulated")
        #expect(value.isSimulated == true)
        #expect(value.chargeLimit == 80)
        #expect(value.isManagingCharging)
        let checked = try #require(status.lastEvaluation)
        #expect(value.checkedAt == checked)
        #expect(value.title == "Battery 70%")
        let time = checked.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: posix, timeZone: utc))
        #expect(value.dialog == "Battery 70%, charging. CellKeeper (Simulated): charging to the limit; its limit is 80%. \(simulatedNote) Checked at \(time).")
    }

    @Test("A backend that accepts no requests: its state is not applied, and it changes nothing")
    func statusReadOnly() async {
        let status = await evaluatedActionStatus(ReadOnlyChargingBackend())
        let value = ShortcutsStatus(status: status, settings: status.settings, selectedBackendIdentifier: status.backend.identifier)
        #expect(value.state == "charging to the limit, not applied")
        #expect(value.isSimulated == false)
        #expect(value.dialog.contains(readOnlyNote))
    }

    @Test("With macOS's Charge Limit, what macOS reports is said, never the read problem", arguments: [80, 100, nil] as [Int?])
    func statusNative(reportedLimit: Int?) async {
        let status = asNativeLimit(await evaluatedActionStatus(), reportedLimit: reportedLimit, readProblem: "pmset said something odd")
        let value = ShortcutsStatus(status: status, settings: status.settings, selectedBackendIdentifier: status.backend.identifier)
        switch reportedLimit {
        case 80?: #expect(value.dialog.contains("macOS reports its Charge Limit at 80%."))
        case 100?: #expect(value.dialog.contains("macOS reports its Charge Limit at 100% (no limit)."))
        default: #expect(value.dialog.contains("macOS's Charge Limit could not be read."))
        }
        #expect(!value.dialog.contains("pmset"))
        #expect(value.control == "macOS Charge Limit")
    }

    @Test("A faulted backend is the state")
    func statusFaulted() async {
        var status = await evaluatedActionStatus()
        status.isBackendFaulted = true
        let value = ShortcutsStatus(status: status, settings: status.settings, selectedBackendIdentifier: status.backend.identifier)
        #expect(value.state == "control backend faulted")
    }

    @Test("No battery, or no reading: no charge, and said so")
    func statusNoBattery() async {
        var status = await evaluatedActionStatus()
        status.snapshot?.isBatteryPresent = false
        let noBattery = ShortcutsStatus(status: status, settings: status.settings, selectedBackendIdentifier: status.backend.identifier)
        #expect(noBattery.batteryCharge == nil)
        #expect(noBattery.title == "Battery charge unknown")
        #expect(noBattery.dialog.hasPrefix("No battery detected. "))
        status.snapshot = nil
        let noReading = ShortcutsStatus(status: status, settings: status.settings, selectedBackendIdentifier: status.backend.identifier)
        #expect(noReading.batteryCharge == nil)
        #expect(noReading.chargingStatus == "unknown")
        #expect(noReading.dialog.hasPrefix("No battery reading. "))
    }

    @Test("Unsettled: nothing backend-specific")
    func statusUnsettled() async {
        var status = await evaluatedActionStatus()
        status.pendingBackend = ReadOnlyChargingBackend().descriptor
        let value = ShortcutsStatus(status: status, settings: status.settings, selectedBackendIdentifier: ReadOnlyChargingBackend().descriptor.identifier, timeZone: utc, locale: posix)
        #expect(value.isSimulated == nil)
        #expect(value.dialog.hasPrefix("Battery 70%, charging. CellKeeper is still starting or switching how it controls charging. Checked at "))
        #expect(!value.dialog.contains("Simulated"))
    }
}

@Suite("Shortcuts actions: the UI's checks")
struct ShortcutsActionChecksTests {
    @Test("Limits outside 20–100 are refused with Settings' own text; every offered value is accepted as it is")
    func wholePercent() {
        let choices = ChargeLimitChoices.wholePercent(ChargingSettings.chargeLimitRange)
        for limit in [Int.min, 0, 19, 101, Int.max] {
            #expect(ChargeLimitRequest(limit: limit, choices: choices, settings: .default) == .refused(SettingsIssue.chargeLimitOutOfRange(limit, allowed: ChargingSettings.chargeLimitRange).description))
        }
        #expect(ChargeLimitRequest(limit: 15, choices: choices, settings: .default) == .refused("Charge limit 15% is outside 20–100%."))
        for limit in choices.values {
            guard case .accepted(let settings) = ChargeLimitRequest(limit: limit, choices: choices, settings: .default) else {
                Issue.record("\(limit)% was not accepted")
                continue
            }
            #expect(settings.chargeLimit == limit)
            #expect(settings.isValid)
        }
    }

    @Test("macOS's Charge Limit accepts only its steps, and says which")
    func steps() {
        let choices = ChargeLimitChoices.steps(NativeChargeLimitBackend.supportedLimits)
        #expect(ChargeLimitRequest(limit: 83, choices: choices, settings: .default) == .refused("83% cannot be set with macOS's Charge Limit. It accepts 80, 85, 90, 95 or 100%."))
        #expect(ChargeLimitRequest(limit: 70, choices: choices, settings: .default) == .refused("70% cannot be set with macOS's Charge Limit. It accepts 80, 85, 90, 95 or 100%."))
        #expect(ChargeLimitRequest(limit: 85, choices: choices, settings: .default) == .accepted(ChargingSettings.default.withChargeLimit(85)))
    }

    private struct StartCase: Sendable, CustomStringConvertible {
        var description: String
        var override: ChargeOverride.Kind?
        var managed = true
        var limit = 80
        var snapshot: BatterySnapshot?
        var refusal: String?
    }

    private static let plugged = BatterySnapshot(timestamp: Date(timeIntervalSince1970: 1_800_000_000), chargePercent: 70, powerSource: .externalPower, isCharging: true)

    private static func with(_ change: (inout BatterySnapshot) -> Void) -> BatterySnapshot {
        var snapshot = plugged
        change(&snapshot)
        return snapshot
    }

    private static let startCases: [StartCase] = [
        StartCase(description: "plugged in with a battery", snapshot: plugged, refusal: nil),
        StartCase(description: "a full charge running", override: .fullCharge, snapshot: plugged, refusal: "A temporary full charge is already running."),
        StartCase(description: "a discharge running", override: .dischargeToLimit, snapshot: plugged, refusal: "A discharge to the limit is running. Stop it first."),
        StartCase(description: "management off, also on battery", managed: false, snapshot: with { $0.powerSource = .battery }, refusal: "Manage charging is off. Turn it on to charge to 100% once."),
        StartCase(description: "limit 100%", limit: 100, snapshot: plugged, refusal: "CellKeeper's limit is already 100%."),
        StartCase(description: "on battery", snapshot: with { $0.powerSource = .battery }, refusal: "The Mac is on battery. Connect power first."),
        StartCase(description: "no reading", snapshot: nil, refusal: "CellKeeper has no battery reading that shows the Mac plugged in."),
        StartCase(description: "external power with no battery (the menu used to allow it)", snapshot: with { $0.isBatteryPresent = false }, refusal: "CellKeeper has no battery reading that shows the Mac plugged in."),
        StartCase(description: "unknown power source", snapshot: with { $0.powerSource = .unknown }, refusal: "CellKeeper has no battery reading that shows the Mac plugged in."),
    ]

    @Test("Charge to 100% once: the menu's button and the action refuse exactly these cases", arguments: startCases)
    private func fullChargeStart(_ row: StartCase) async {
        var status = await evaluatedActionStatus()
        status.snapshot = row.snapshot
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        switch row.override {
        case .fullCharge?: status.activeOverride = .fullCharge(at: start, uptime: 10_000)
        case .dischargeToLimit?: status.activeOverride = .dischargeToLimit(target: 80, at: start, uptime: 10_000)
        case nil: status.activeOverride = nil
        }
        var settings = ChargingSettings.default.withChargeLimit(row.limit)
        settings.isManagementEnabled = row.managed
        #expect(FullChargeStart.refusal(settings: settings, status: status) == row.refusal)
    }
}

@Suite("Settings changes: the banner and the log, by source")
struct SettingsReconciliationTests {
    private let earlier = "An earlier problem with a change in Settings."
    private var on: ChargingSettings { .default }
    private var off: ChargingSettings {
        var settings = ChargingSettings.default
        settings.isManagementEnabled = false
        return settings
    }

    @Test("Only the UI's changes touch the banner when they are made")
    func bannerWhenMade() {
        let results: [SettingsChangeResult] = [.saved(previous: .default), .unchanged, .refused(SettingsChangeResult.saveFailed)]
        #expect(results.map { SettingsReconciliation.banner(after: $0, source: .ui) } == [.clear, .keep, .show(SettingsChangeResult.saveFailed)])
        for source in [SettingsChangeSource.shortcuts, .adoption] {
            for result in results {
                #expect(SettingsReconciliation.banner(after: result, source: source).applied(to: earlier) == earlier)
            }
        }
        // An unchanged value from the UI leaves the banner as it is.
        #expect(SettingsReconciliation.banner(after: .unchanged, source: .ui).applied(to: earlier) == earlier)
    }

    @Test("Only CellKeeper's own refused change is logged here, in fixed words: the UI shows its own, an action logs its outcome")
    func logWhenMade() {
        let failed = SettingsChangeResult.refused(SettingsChangeResult.saveFailed)
        #expect(SettingsReconciliation.logMessage(after: failed, source: .ui) == nil)
        #expect(SettingsReconciliation.logMessage(after: failed, source: .shortcuts) == nil)
        #expect(SettingsReconciliation.logMessage(after: failed, source: .adoption) == "CellKeeper could not save Manage charging as off after keeping a Charge Limit set outside it: CellKeeper could not save its settings.")
        #expect(SettingsReconciliation.logMessage(after: .saved(previous: on), source: .adoption) == nil)
    }

    @Test("Kept off by the controller: both sources keep it off; only the UI's change shows the banner, an action's is logged")
    func keptOff() {
        let controller = SettingsReconciliation.ControllerResult.applied(isManagementEnabled: false, managementRefusal: "Manage charging stays off: test.")
        let ui = SettingsReconciliation.outcome(sent: on, current: on, controller: controller, source: .ui)
        #expect(ui == .init(keepsManagementOff: true, banner: .show("Manage charging stays off: test.")))
        let action = SettingsReconciliation.outcome(sent: on, current: on, controller: controller, source: .shortcuts)
        #expect(action.keepsManagementOff)
        #expect(action.banner.applied(to: earlier) == earlier)
        #expect(action.logMessage == "A Shortcuts action turned Manage charging on, but CellKeeper kept it off. Manage charging stays off: test.")
    }

    @Test("A newer change on its way, or a change that did not turn management on, is left alone")
    func leftAlone() {
        let controller = SettingsReconciliation.ControllerResult.applied(isManagementEnabled: false, managementRefusal: nil)
        var newer = on
        newer.chargeLimit = 90
        for source in [SettingsChangeSource.ui, .shortcuts, .adoption] {
            #expect(SettingsReconciliation.outcome(sent: on, current: newer, controller: controller, source: source) == .init())
            #expect(SettingsReconciliation.outcome(sent: off, current: off, controller: controller, source: source) == .init())
        }
    }

    @Test("An adoption's own change never touches the banner: not when saved, not when its save fails, whichever command found the adoption")
    func adoption() {
        for result in [SettingsChangeResult.saved(previous: on), .refused(SettingsChangeResult.saveFailed)] {
            #expect(SettingsReconciliation.banner(after: result, source: .adoption).applied(to: earlier) == earlier)
            #expect(SettingsReconciliation.banner(after: result, source: .adoption).applied(to: nil) == nil)
        }
        let applied = SettingsReconciliation.outcome(sent: off, current: off, controller: .applied(isManagementEnabled: false, managementRefusal: nil), source: .adoption)
        #expect(applied.banner.applied(to: earlier) == earlier)
        let rejected = SettingsReconciliation.outcome(sent: off, current: off, controller: .rejected("invalid"), source: .adoption)
        #expect(rejected.banner.applied(to: earlier) == earlier)
        #expect(rejected.logMessage != nil)
    }

    @Test("A rejected change shows the banner only for the UI")
    func rejected() {
        #expect(SettingsReconciliation.outcome(sent: on, current: on, controller: .rejected("invalid"), source: .ui).banner == .show("Settings were rejected: invalid"))
        let action = SettingsReconciliation.outcome(sent: on, current: on, controller: .rejected("invalid"), source: .shortcuts)
        #expect(action.banner == .keep)
        #expect(action.logMessage?.contains("invalid") == false)
    }
}

/// No action's words carry an unavailability reason, a report problem or a
/// save error: a status full of distinctive strings goes through every
/// dialog, refusal, status value and log line.
@Suite("Shortcuts actions: fixed text only")
@MainActor
struct ShortcutsActionFixedTextTests {
    private let marker = "SECRET-7f3a"

    private func statuses() async -> [ControllerStatus] {
        let path = "\(marker) /Users/someone/Library/Containers/x"
        let readOnly = await evaluatedActionStatus(ReadOnlyChargingBackend(reason: path))
        var simulatedUnavailable = await evaluatedActionStatus()
        simulatedUnavailable.capabilities = .unavailable(path)
        let native = asNativeLimit(await evaluatedActionStatus(), availability: .unavailable(reason: path), reportedLimit: nil, readProblem: path)
        let nativeReadProblem = asNativeLimit(await evaluatedActionStatus(), reportedLimit: nil, readProblem: path)
        var deferring = await evaluatedActionStatus()
        deferring.capabilities.macOSChargeLimit = MacOSChargeLimitStatus(reportedLimit: nil, readAt: Date(timeIntervalSince1970: 1_800_000_000), readProblem: path)
        deferring.telemetryError = path
        var faulted = await evaluatedActionStatus()
        faulted.isBackendFaulted = true
        faulted.telemetryError = path
        return [readOnly, simulatedUnavailable, native, nativeReadProblem, deferring, faulted]
    }

    @Test("Wording, status values, refusals and log lines never contain them")
    func noDistinctiveStrings() async {
        for status in await statuses() {
            // The status does carry the marker, so its absence below means something.
            var fields = ""
            dump(status, to: &fields)
            #expect(fields.contains(marker))
            var texts: [String] = []
            let ctx = context(status)
            texts += [
                ShortcutsActionWording.limitSaved(in: ctx), ShortcutsActionWording.limitUnchanged(in: ctx),
                ShortcutsActionWording.fullChargeQueued(in: ctx), ShortcutsActionWording.stopQueued(in: ctx),
                ShortcutsActionWording.management(isOn: true, changed: true, in: ctx), ShortcutsActionWording.management(isOn: false, changed: true, in: ctx),
            ]
            let value = ShortcutsStatus(status: status, settings: status.settings, selectedBackendIdentifier: status.backend.identifier)
            texts += [value.chargingStatus, value.state, value.control, value.title, value.dialog]

            let clock = ManualDeadlineClock()
            let logged = LogLines()
            let coordinator = ShortcutsActionCoordinator(clock: clock, log: { logged.lines.append($0) })
            let target = FakeActionTarget(clock: clock, status: status, selectedBackendIdentifier: status.backend.identifier)
            coordinator.attach(target)
            for outcome in [
                await coordinator.setChargeLimit(70), await coordinator.setChargeLimit(15), await coordinator.startFullCharge(),
                await coordinator.stopOverride(), await coordinator.setManagement(false), await coordinator.setManagement(true),
            ] {
                switch outcome {
                case .done(let text), .refused(let text): texts.append(text)
                }
            }
            target.failsToSave = true
            if case .refused(let text) = await coordinator.setChargeLimit(60) { texts.append(text) }
            if case .status(let reported) = await coordinator.status() { texts.append(reported.dialog) }
            texts += logged.lines
            for text in texts {
                #expect(!text.contains(marker), "leaked into: \(text)")
                #expect(!text.contains("/Users/"), "leaked into: \(text)")
            }
        }
    }
}
