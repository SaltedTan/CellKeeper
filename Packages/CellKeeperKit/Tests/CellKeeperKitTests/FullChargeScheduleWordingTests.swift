import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

@Suite("Scheduled full charge wording")
struct FullChargeScheduleWordingTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")
    private let start = Date(timeIntervalSince1970: 1_800_003_600)
    private var schedule: FullChargeSchedule {
        FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(12 * 3600))
    }

    /// A status from a real evaluation with the simulated backend, with
    /// `capabilities` put in place of its own.
    private func status(_ capabilities: ControlCapabilities? = nil, limit: Int = 90) async -> ControllerStatus {
        let clock = KitTestClock()
        let controller = ChargeController(
            telemetry: KitStubTelemetry(percent: 70, clock: clock),
            backend: MockChargingBackend(),
            settings: ChargingSettings.default.withChargeLimit(limit),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        var status = await controller.evaluate(.launch)
        if let capabilities { status.capabilities = capabilities }
        return status
    }

    private var macOSLimitOn: ControlCapabilities {
        var capabilities = ControlCapabilities(availability: .simulated, supportedModes: [.normal])
        capabilities.macOSChargeLimit = MacOSChargeLimitStatus(reportedLimit: 80, readAt: start, readProblem: nil)
        return capabilities
    }

    private var native: ControlCapabilities {
        .nativeLimit(availability: .experimental, steps: NativeChargeLimitBackend.supportedLimits)
    }

    private var realChargingModes: ControlCapabilities {
        ControlCapabilities(availability: .experimental, supportedModes: ChargeControlMode.chargingModes)
    }

    @Test("Simulated controls are said to change nothing")
    func simulated() async {
        let text = FullChargeScheduleWording.explanation(for: await status(), end: schedule.endsAt, timeZone: utc, locale: locale)
        #expect(text == "Simulated: at the start, CellKeeper records a temporary full charge. Nothing on your Mac changes.")
        let deferring = FullChargeScheduleWording.explanation(for: await status(macOSLimitOn), end: nil, timeZone: utc, locale: locale)
        #expect(deferring.hasSuffix("While macOS's Charge Limit is on, it stays in charge and the full charge has no effect."))
    }

    @Test("An unavailable backend is said to change nothing")
    func unavailable() async {
        let text = FullChargeScheduleWording.explanation(for: await status(.unavailable("no shortcut")), end: nil, timeZone: utc, locale: locale)
        #expect(text == "Simulated is unavailable (no shortcut), so a scheduled full charge changes nothing; CellKeeper only shows what it would do.")
    }

    @Test("With macOS's Charge Limit, CellKeeper requests 100%, and requests its limit again at its next check; sleep can delay that")
    func nativeLimit() async {
        let nativeStatus = await status(native, limit: 85)
        let end = FullChargeScheduleWording.format(schedule.endsAt, timeZone: utc, locale: locale)
        let text = FullChargeScheduleWording.explanation(for: nativeStatus, end: schedule.endsAt, timeZone: utc, locale: locale)
        #expect(text == "At the start, CellKeeper requests a macOS Charge Limit of 100%. After the battery is full, you unplug, or the charge expires (\(end)), it requests its 85% limit again at its next check; while your Mac sleeps, that waits until it wakes. macOS may still hold charging, for battery health or when the battery is warm.")
        #expect(FullChargeScheduleWording.overnightHint(for: nativeStatus) == "To charge overnight, schedule a start while your Mac is awake and wait until the menu shows macOS enforcing 100%. Returning to your limit can wait until your Mac wakes.")
        let unavailableNative = await status(.unavailable("no shortcut", style: .nativeLimit(steps: NativeChargeLimitBackend.supportedLimits)))
        #expect(FullChargeScheduleWording.overnightHint(for: unavailableNative) == nil)
        #expect(FullChargeScheduleWording.overnightHint(for: await status()) == nil)
    }

    @Test("A real backend that switches charging itself allows charging to 100% and applies its limit again at its next check")
    func realChargingModesBackend() async {
        let text = FullChargeScheduleWording.explanation(for: await status(realChargingModes, limit: 80), end: nil, timeZone: utc, locale: locale)
        #expect(text == "At the start, CellKeeper allows charging to 100%. After the battery is full, you unplug, or the charge expires at the end you choose, its 80% limit applies again from its next check; while your Mac sleeps, that waits until it wakes.")
    }

    @Test("Nothing promises a ready time, a guaranteed charge, or an exact return to the limit")
    func noOverclaims() async {
        var texts = [FullChargeScheduleWording.startConditions]
        for capabilities in [nil, macOSLimitOn, native, realChargingModes, .unavailable("x")] {
            let current = await status(capabilities)
            texts.append(FullChargeScheduleWording.explanation(for: current, end: schedule.endsAt, timeZone: utc, locale: locale))
            texts.append(FullChargeScheduleWording.overnightHint(for: current) ?? "")
        }
        let outcomes: [FullChargeScheduleOutcome] = [
            .alreadyFull(schedule), .keptRunning(schedule, deadline: schedule.endsAt), .windowPassed(schedule, lastWait: .onBattery), .discarded(reason: "it could not be read"),
        ]
        texts += outcomes.compactMap { FullChargeScheduleWording.outcomeLine($0, timeZone: utc, locale: locale) }
        for text in texts {
            let lowered = text.lowercased()
            for claim in ["ready by", "ready for", "guarantee", "at the latest", "will be full", "sets it back", "100% by"] {
                #expect(!lowered.contains(claim), "\(claim) in: \(text)")
            }
        }
    }

    @Test("Outcomes: the window passed (with the reason only if one was seen), already full, kept, discarded; started and extended are left to the running charge's line")
    func outcomes() {
        func line(_ outcome: FullChargeScheduleOutcome) -> String? {
            FullChargeScheduleWording.outcomeLine(outcome, timeZone: utc, locale: locale)
        }
        #expect(line(.started(schedule)) == nil)
        #expect(line(.extendedRunning(schedule, deadline: schedule.endsAt)) == nil)
        #expect(line(.windowPassed(schedule, lastWait: nil)) == "The scheduled window passed before the full charge could start.")
        #expect(line(.windowPassed(schedule, lastWait: .onBattery)) == "The scheduled window passed before the full charge could start. Last checked: the Mac was on battery.")
        #expect(line(.windowPassed(schedule, lastWait: .managementOff)) == "The scheduled window passed before the full charge could start. Last checked: Manage charging was off.")
        #expect(line(.alreadyFull(schedule)) == "The scheduled full charge found the battery already full.")
        let deadline = FullChargeScheduleWording.format(schedule.endsAt, timeZone: utc, locale: locale)
        #expect(line(.keptRunning(schedule, deadline: schedule.endsAt)) == "A temporary full charge was already running, until \(deadline), so the scheduled one changed nothing.")
        #expect(line(.discarded(reason: "it could not be read")) == "A saved full-charge schedule was removed: it could not be read.")
    }

    @Test("The armed line shows the window, or why a due schedule cannot start yet")
    func armedLine() {
        let window = FullChargeScheduleWording.window(schedule, timeZone: utc, locale: locale)
        #expect(window.contains(FullChargeScheduleWording.format(schedule.startsAt, timeZone: utc, locale: locale)))
        #expect(window.contains(FullChargeScheduleWording.format(schedule.endsAt, timeZone: utc, locale: locale)))
        #expect(FullChargeScheduleWording.armedLine(schedule, wait: nil, timeZone: utc, locale: locale) == "Full charge scheduled: \(window)")
        let end = FullChargeScheduleWording.format(schedule.endsAt, timeZone: utc, locale: locale)
        #expect(FullChargeScheduleWording.armedLine(schedule, wait: .managementOff, timeZone: utc, locale: locale) == "Scheduled full charge is due but cannot start yet: Manage charging is off. It can still start until \(end).")
    }

    @Test("Times are shown in the time zone given, so a time-zone change only changes what is displayed")
    func timeZones() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(FullChargeScheduleWording.format(start, timeZone: utc, locale: locale) != FullChargeScheduleWording.format(start, timeZone: tokyo, locale: locale))
    }
}
