import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

private let utc = TimeZone(identifier: "UTC")!
private let posix = Locale(identifier: "en_US_POSIX")

/// A status from a real evaluation with the simulated backend, with
/// `capabilities` put in place of its own.
private func evaluatedStatus(_ capabilities: ControlCapabilities? = nil, limit: Int = 90) async -> ControllerStatus {
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
    capabilities.macOSChargeLimit = MacOSChargeLimitStatus(reportedLimit: 80, readAt: Date(timeIntervalSince1970: 1_800_000_000), readProblem: nil)
    return capabilities
}

private var nativeSteps: ControlCapabilities {
    .nativeLimit(availability: .experimental, steps: NativeChargeLimitBackend.supportedLimits)
}

private var realChargingModes: ControlCapabilities {
    ControlCapabilities(availability: .experimental, supportedModes: ChargeControlMode.chargingModes)
}

@Suite("Scheduled full charge wording")
struct FullChargeScheduleWordingTests {
    private let start = Date(timeIntervalSince1970: 1_800_003_600)
    private var schedule: FullChargeSchedule {
        FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(12 * 3600))
    }

    @Test("Simulated controls are said to change nothing")
    func simulated() async {
        let text = FullChargeScheduleWording.explanation(for: await evaluatedStatus(), end: schedule.endsAt, timeZone: utc, locale: posix)
        #expect(text == "Simulated: at the start, CellKeeper records a temporary full charge. Nothing on your Mac changes.")
        let deferring = FullChargeScheduleWording.explanation(for: await evaluatedStatus(macOSLimitOn), end: nil, timeZone: utc, locale: posix)
        #expect(deferring.hasSuffix("While macOS's Charge Limit is on, it stays in charge and the full charge has no effect."))
    }

    @Test("An unavailable backend is said to change nothing")
    func unavailable() async {
        let text = FullChargeScheduleWording.explanation(for: await evaluatedStatus(.unavailable("no shortcut")), end: nil, timeZone: utc, locale: posix)
        #expect(text == "Simulated is unavailable (no shortcut), so a scheduled full charge changes nothing; CellKeeper only shows what it would do.")
    }

    @Test("With macOS's Charge Limit: CellKeeper requests 100%, the end gives only the duration at the start, and the return to the limit is a later request that can be delayed")
    func nativeLimit() async {
        let status = await evaluatedStatus(nativeSteps, limit: 85)
        let end = FullChargeScheduleWording.format(schedule.endsAt, timeZone: utc, locale: posix)
        let text = FullChargeScheduleWording.explanation(for: status, end: schedule.endsAt, timeZone: utc, locale: posix)
        #expect(text == "At the start, CellKeeper requests a macOS Charge Limit of 100%. The full charge lasts for the time left until \(end) when it starts (longer only if a full charge that expires later is already running), or less if the battery is full or you unplug first. CellKeeper then requests its 85% limit again at its next check; sleep, or a request that is refused, can delay that. macOS may still hold charging, for battery health or when the battery is warm.")
        #expect(FullChargeScheduleWording.overnightHint(for: status) == "To charge overnight, schedule a start while your Mac is awake and wait until the menu shows macOS enforcing 100%. Returning to your limit can wait until your Mac wakes.")
        let unavailableNative = await evaluatedStatus(.unavailable("no shortcut", style: .nativeLimit(steps: NativeChargeLimitBackend.supportedLimits)))
        #expect(FullChargeScheduleWording.overnightHint(for: unavailableNative) == nil)
        #expect(FullChargeScheduleWording.overnightHint(for: await evaluatedStatus()) == nil)
    }

    @Test("A real backend that switches charging itself: a temporary request that the safety rules still override, and the limit requested again later")
    func realChargingModesBackend() async {
        let text = FullChargeScheduleWording.explanation(for: await evaluatedStatus(realChargingModes, limit: 80), end: nil, timeZone: utc, locale: posix)
        #expect(text == "At the start, CellKeeper requests a temporary full charge: it asks for none of its own restrictions, unless a safety rule such as the temperature pause still pauses charging. The full charge lasts for the time left until the end you choose when it starts (longer only if a full charge that expires later is already running), or less if the battery is full or you unplug first. CellKeeper then requests its 80% limit again at its next check; sleep, or a request that fails or is refused, can delay that.")
    }

    @Test("A schedule that starts during a temperature pause installs its full charge while charging stays paused, and nothing says charging is allowed")
    func suppressedActivation() async throws {
        let clock = KitTestClock()
        let backend = KitExperimentalBackend()
        let controller = ChargeController(
            telemetry: KitHotTelemetry(percent: 70, celsius: 45, clock: clock),
            backend: backend,
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: KitMemoryStorage()),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        await controller.evaluate(.launch)
        let begin = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: begin, endsAt: begin.addingTimeInterval(12 * 3600)))
        clock.advance(by: 3600)
        let status = await controller.evaluate(.periodic)
        let override = try #require(status.activeOverride)
        #expect(override.source == .schedule)
        #expect(status.decision?.state == .temperaturePause)
        #expect(status.currentMode == .inhibitCharging)
        #expect(await backend.currentMode() == .inhibitCharging)
        var texts = [
            FullChargeScheduleWording.explanation(for: status, end: nil, timeZone: utc, locale: posix),
            TemporaryFullChargeWording.line(for: override, status: status, lastResult: nil, timeZone: utc, locale: posix),
            TemporaryFullChargeWording.buttonHelp(for: status),
        ]
        if let outcome = status.fullChargeScheduleOutcome, let line = FullChargeScheduleWording.outcomeLine(outcome) {
            texts.append(line)
        }
        #expect(status.decision?.notes.contains(.fullChargeSuppressed(by: .temperaturePause)) == true)
        // The rule that takes precedence is the explanation, even when the
        // last request (the pause) succeeded.
        #expect(TemporaryFullChargeWording.line(for: override, status: status, lastResult: "Applied and confirmed", timeZone: utc, locale: posix) == "Scheduled full charge requested, not in effect: temperature protection takes precedence.")
        var manual = override
        manual.source = .user
        #expect(TemporaryFullChargeWording.line(for: manual, status: status, lastResult: nil, timeZone: utc, locale: posix) == "Temporary full charge requested, not in effect: temperature protection takes precedence.")
        #expect(status.decision?.notes.map(\.description).contains("Temporary full charge is not in effect: temperature protection takes precedence.") == true)
        for text in texts {
            #expect(!text.lowercased().contains("allows charging"), "in: \(text)")
            #expect(!text.lowercased().contains("charging to 100%"), "in: \(text)")
        }
    }

    /// The menu line and the policy's notes for a full charge that
    /// temperature protection takes precedence over.
    private func suppressionTexts(_ status: ControllerStatus) throws -> [String] {
        let override = try #require(status.activeOverride)
        // A last result is passed to show that the rule, not the result, is
        // the explanation.
        return [TemporaryFullChargeWording.line(for: override, status: status, lastResult: "Refused", timeZone: utc, locale: posix)]
            + (status.decision?.notes.map(\.description) ?? [])
    }

    @Test("While the pause that temperature protection asks for is refused and normal charging reads back, nothing says charging is paused, confirmed or applied")
    func suppressionWhilePauseRefused() async throws {
        let clock = KitTestClock()
        let telemetry = KitMutableTelemetry(percent: 85, celsius: 30, clock: clock)
        let backend = KitExperimentalBackend()
        let controller = ChargeController(
            telemetry: telemetry,
            backend: backend,
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: KitMemoryStorage()),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        // The limit is confirmed by a second reading and charging is held,
        // a restricting change that starts the rate limit.
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        #expect(await controller.evaluate(.periodic).currentMode == .inhibitCharging)
        let begin = clock.now.addingTimeInterval(1)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: begin, endsAt: begin.addingTimeInterval(2 * 3600)))
        // The schedule starts, and its full charge releases the hold.
        await telemetry.set(percent: 70, celsius: 30)
        clock.advance(by: 10)
        let started = await controller.evaluate(.periodic)
        #expect(started.activeOverride?.source == .schedule)
        #expect(started.currentMode == .normal)
        // Hot: temperature protection takes precedence, but its pause is a
        // restricting change within a minute of the last one, so it is refused.
        await telemetry.set(percent: 70, celsius: 45)
        clock.advance(by: 10)
        let status = await controller.evaluate(.periodic)
        #expect(status.decision?.state == .temperaturePause)
        #expect(status.currentMode == .normal)
        #expect(await backend.currentMode() == .normal)
        guard case .refused(.rateLimited)? = status.lastExecution?.result else {
            Issue.record("expected a rate-limited refusal, got \(String(describing: status.lastExecution?.result))")
            return
        }
        let texts = try suppressionTexts(status)
        #expect(texts.first == "Scheduled full charge requested, not in effect: temperature protection takes precedence.")
        for text in texts {
            for claim in ["paused", "confirmed", "applied"] {
                #expect(!text.lowercased().contains(claim), "\(claim) in: \(text)")
            }
        }
    }

    @Test("With the simulated backend, temperature protection taking precedence is named without saying charging is paused, confirmed or applied")
    func suppressionSimulated() async throws {
        let clock = KitTestClock()
        let controller = ChargeController(
            telemetry: KitHotTelemetry(percent: 70, celsius: 45, clock: clock),
            backend: MockChargingBackend(),
            settings: .default,
            scheduleStore: FullChargeScheduleStore(defaults: KitMemoryStorage()),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        await controller.evaluate(.launch)
        let begin = clock.now.addingTimeInterval(3600)
        try await controller.setFullChargeSchedule(FullChargeSchedule(startsAt: begin, endsAt: begin.addingTimeInterval(2 * 3600)))
        clock.advance(by: 3600)
        let status = await controller.evaluate(.periodic)
        #expect(status.decision?.state == .temperaturePause)
        #expect(status.capabilities.availability == .simulated)
        let texts = try suppressionTexts(status)
        #expect(texts.first == "Scheduled full charge requested, not in effect: temperature protection takes precedence.")
        for text in texts {
            for claim in ["paused", "confirmed", "applied"] {
                #expect(!text.lowercased().contains(claim), "\(claim) in: \(text)")
            }
        }
    }

    @Test("Outcomes: the window passed (with the reason only if one was seen), already full, kept, discarded; started and extended are left to the running charge's line")
    func outcomes() {
        #expect(FullChargeScheduleWording.outcomeLine(.started(schedule)) == nil)
        #expect(FullChargeScheduleWording.outcomeLine(.extendedRunning(schedule)) == nil)
        #expect(FullChargeScheduleWording.outcomeLine(.windowPassed(schedule, lastWait: nil)) == "The scheduled window passed before the full charge could start.")
        #expect(FullChargeScheduleWording.outcomeLine(.windowPassed(schedule, lastWait: .onBattery)) == "The scheduled window passed before the full charge could start. Last checked: the Mac was on battery.")
        #expect(FullChargeScheduleWording.outcomeLine(.windowPassed(schedule, lastWait: .managementOff)) == "The scheduled window passed before the full charge could start. Last checked: Manage charging was off.")
        #expect(FullChargeScheduleWording.outcomeLine(.alreadyFull(schedule)) == "The scheduled full charge found the battery already full.")
        #expect(FullChargeScheduleWording.outcomeLine(.keptRunning(schedule)) == "A temporary full charge was already running and expires later than the scheduled one would have, so the schedule changed nothing.")
        #expect(FullChargeScheduleWording.outcomeLine(.discarded(reason: "it could not be read")) == "A saved full-charge schedule was removed: it could not be read.")
    }

    @Test("The armed line shows the window, or why a due schedule cannot start yet")
    func armedLine() {
        let window = FullChargeScheduleWording.window(schedule, timeZone: utc, locale: posix)
        let begin = FullChargeScheduleWording.format(schedule.startsAt, timeZone: utc, locale: posix)
        let end = FullChargeScheduleWording.format(schedule.endsAt, timeZone: utc, locale: posix)
        #expect(window == "\(begin) – \(end)")
        #expect(FullChargeScheduleWording.armedLine(schedule, wait: nil, timeZone: utc, locale: posix) == "Full charge scheduled: \(window)")
        #expect(FullChargeScheduleWording.armedLine(schedule, wait: .managementOff, timeZone: utc, locale: posix) == "Scheduled full charge is due but cannot start yet: Manage charging is off. It can still start until \(end).")
    }

    @Test("Times are shown in the time zone given, so a time-zone change only changes what is displayed")
    func timeZones() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(FullChargeScheduleWording.format(start, timeZone: utc, locale: posix) != FullChargeScheduleWording.format(start, timeZone: tokyo, locale: posix))
    }

    @Test("In the hour a daylight-saving change repeats, times carry the time zone, so the two ends of a window never read the same")
    func repeatedHour() {
        let newYork = TimeZone(identifier: "America/New_York")!
        // ICU puts a narrow no-break space before AM/PM.
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
        // 2026-11-01: 01:30 EDT (05:30Z) and 01:30 EST (06:30Z).
        let first = Date(timeIntervalSince1970: 1_793_511_000)
        let second = Date(timeIntervalSince1970: 1_793_514_600)
        let ambiguous = FullChargeSchedule(startsAt: first, endsAt: second)
        #expect(plain(FullChargeScheduleWording.window(ambiguous, timeZone: newYork, locale: posix)) == "Sun, Nov 1 at 1:30 AM EDT – Sun, Nov 1 at 1:30 AM EST")
        #expect(plain(FullChargeScheduleWording.format(first, timeZone: newYork, locale: posix)) == "Sun, Nov 1 at 1:30 AM EDT")
        // An hour before and after the repeated hour, nothing is ambiguous.
        #expect(plain(FullChargeScheduleWording.format(first.addingTimeInterval(-3600), timeZone: newYork, locale: posix)) == "Sun, Nov 1 at 12:30 AM")
        #expect(plain(FullChargeScheduleWording.format(second.addingTimeInterval(3600), timeZone: newYork, locale: posix)) == "Sun, Nov 1 at 2:30 AM")
        // A window whose ends are not ambiguous shows no time zone.
        let july = FullChargeSchedule(startsAt: Date(timeIntervalSince1970: 1_784_000_000), endsAt: Date(timeIntervalSince1970: 1_784_000_000 + 7200))
        #expect(!FullChargeScheduleWording.window(july, timeZone: newYork, locale: posix).contains("EDT"))
    }
}

@Suite("Temporary full charge wording")
struct TemporaryFullChargeWordingTests {
    /// A running full charge with `backend`, after `settle` seconds for its
    /// first change, and the status it was started in.
    private func running(_ backend: any ChargingBackend, limit: Int = 90, settle: TimeInterval = 0) async throws -> (ChargeOverride, ControllerStatus) {
        let clock = KitTestClock()
        let controller = ChargeController(
            telemetry: KitStubTelemetry(percent: 70, clock: clock),
            backend: backend,
            settings: ChargingSettings.default.withChargeLimit(limit),
            now: { clock.now },
            uptime: { clock.uptime }
        )
        await controller.evaluate(.launch)
        clock.advance(by: settle)
        let status = await controller.startFullCharge()
        return (try #require(status.activeOverride), status)
    }

    private func expiry(_ override: ChargeOverride) -> String {
        FullChargeScheduleWording.format(override.expiresAt, timeZone: utc, locale: posix)
    }

    @Test("Simulated: nothing on the Mac changes, and it ends at a check after full, unplugging or its expiry")
    func simulated() async throws {
        let (override, status) = try await running(MockChargingBackend())
        #expect(TemporaryFullChargeWording.line(for: override, status: status, lastResult: nil, timeZone: utc, locale: posix) == "Temporary full charge, simulated: nothing on your Mac changes. It ends at a check after the battery is full, you unplug, or it expires (about \(expiry(override))).")
        var scheduled = override
        scheduled.source = .schedule
        #expect(TemporaryFullChargeWording.line(for: scheduled, status: status, lastResult: nil, timeZone: utc, locale: posix).hasPrefix("Scheduled full charge, simulated:"))
        #expect(TemporaryFullChargeWording.buttonHelp(for: status) == "Records a temporary full charge, simulated: nothing on your Mac changes. It ends at a check after the battery is full, you unplug, or 12 hours pass.")
    }

    @Test("macOS's Charge Limit: the confirmed 100% limit, and the user's limit requested again at a later check, which sleep can delay")
    func nativeLimit() async throws {
        let system = KitFakeChargeLimit()
        let clock = KitTestClock()
        let backend = NativeChargeLimitBackend(runner: system, reader: system, store: KitMemoryRecordStore(), platformIssue: nil, now: { clock.now }, uptime: { clock.uptime })
        let (override, status) = try await running(backend, limit: 85, settle: 60)
        #expect(status.currentMode == .nativeLimit(percent: 100))
        #expect(TemporaryFullChargeWording.line(for: override, status: status, lastResult: nil, timeZone: utc, locale: posix) == "Temporary full charge: macOS's Charge Limit is at 100%, confirmed. CellKeeper requests its 85% limit again at a check after the battery is full, you unplug, or it expires (about \(expiry(override))); sleep can delay that.")
        #expect(TemporaryFullChargeWording.buttonHelp(for: status) == "Requests a macOS Charge Limit of 100% once. CellKeeper requests its limit again at a check after the battery is full, you unplug, or 12 hours pass.")
    }

    @Test("A real backend that switches charging itself: its own restrictions lifted and confirmed, and the limit requested again at a later check")
    func realChargingModesBackend() async throws {
        let (override, status) = try await running(KitExperimentalBackend(), limit: 80)
        #expect(TemporaryFullChargeWording.line(for: override, status: status, lastResult: nil, timeZone: utc, locale: posix) == "Temporary full charge: CellKeeper has lifted its own restrictions, confirmed. It requests its 80% limit again at a check after the battery is full, you unplug, or it expires (about \(expiry(override))); sleep can delay that.")
        #expect(TemporaryFullChargeWording.buttonHelp(for: status) == "Requests a temporary full charge once: CellKeeper asks for none of its own restrictions, unless a safety rule such as the temperature pause still pauses charging. It requests its limit again at a check after the battery is full, you unplug, or 12 hours pass.")
    }

    @Test("A backend that accepts no requests gets help that says nothing changes: Read-only, and an unavailable macOS Charge Limit")
    func unavailableHelp() async {
        let clock = KitTestClock()
        let readOnly = ChargeController(telemetry: KitStubTelemetry(percent: 70, clock: clock), backend: ReadOnlyChargingBackend(reason: "read-only in this test"), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let readOnlyStatus = await readOnly.evaluate(.launch)
        #expect(TemporaryFullChargeWording.buttonHelp(for: readOnlyStatus) == "\(readOnlyStatus.backend.displayName) is unavailable (read-only in this test), so a temporary full charge changes nothing; CellKeeper only shows what it would do.")
        let system = KitFakeChargeLimit()
        let native = NativeChargeLimitBackend(runner: system, reader: system, store: KitMemoryRecordStore(), platformIssue: "this Mac cannot use it", now: { clock.now }, uptime: { clock.uptime })
        let nativeController = ChargeController(telemetry: KitStubTelemetry(percent: 70, clock: clock), backend: native, settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let nativeStatus = await nativeController.evaluate(.launch)
        #expect(nativeStatus.capabilities.isEnforcedByMacOS)
        guard case .unavailable(let reason) = nativeStatus.capabilities.availability else {
            Issue.record("expected an unavailable macOS Charge Limit, got \(nativeStatus.capabilities.availability)")
            return
        }
        #expect(TemporaryFullChargeWording.buttonHelp(for: nativeStatus) == "\(nativeStatus.backend.displayName) is unavailable (\(reason)), so a temporary full charge changes nothing; CellKeeper only shows what it would do.")
        for status in [readOnlyStatus, nativeStatus] {
            let help = TemporaryFullChargeWording.buttonHelp(for: status).lowercased()
            #expect(!help.contains("allows charging"))
            #expect(!help.contains("requests"))
        }
    }

    @Test("Not in effect, or with control unavailable, it says only that it was requested")
    func notInEffect() async throws {
        var (override, status) = try await running(MockChargingBackend())
        status.currentMode = .inhibitCharging
        #expect(TemporaryFullChargeWording.line(for: override, status: status, lastResult: "Refused", timeZone: utc, locale: posix) == "Temporary full charge requested, not in effect (Refused).")
        status.capabilities = .unavailable("x")
        override.source = .schedule
        #expect(TemporaryFullChargeWording.line(for: override, status: status, lastResult: nil, timeZone: utc, locale: posix) == "Scheduled full charge requested, but charging control is unavailable.")
    }
}

@Suite("Full charge wording claims")
struct FullChargeWordingClaimsTests {
    @Test("Nothing promises a ready time, a guaranteed charge, charging that is happening, or an end the full charge cannot keep")
    func noOverclaims() async throws {
        let start = Date(timeIntervalSince1970: 1_800_003_600)
        let schedule = FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(12 * 3600))
        var texts = [FullChargeScheduleWording.startConditions]
        for capabilities in [nil, macOSLimitOn, nativeSteps, realChargingModes, .unavailable("x")] {
            let current = await evaluatedStatus(capabilities)
            texts.append(FullChargeScheduleWording.explanation(for: current, end: schedule.endsAt, timeZone: utc, locale: posix))
            texts.append(FullChargeScheduleWording.overnightHint(for: current) ?? "")
            texts.append(TemporaryFullChargeWording.buttonHelp(for: current))
        }
        let outcomes: [FullChargeScheduleOutcome] = [
            .alreadyFull(schedule), .keptRunning(schedule), .windowPassed(schedule, lastWait: .onBattery), .discarded(reason: "it could not be read"),
        ]
        texts += outcomes.compactMap { FullChargeScheduleWording.outcomeLine($0) }
        let system = KitFakeChargeLimit()
        let clock = KitTestClock()
        let backends: [any ChargingBackend] = [
            MockChargingBackend(),
            KitExperimentalBackend(),
            NativeChargeLimitBackend(runner: system, reader: system, store: KitMemoryRecordStore(), platformIssue: nil, now: { clock.now }, uptime: { clock.uptime }),
        ]
        for backend in backends {
            let controller = ChargeController(telemetry: KitStubTelemetry(percent: 70, clock: clock), backend: backend, settings: .default, now: { clock.now }, uptime: { clock.uptime })
            await controller.evaluate(.launch)
            clock.advance(by: 60)
            let status = await controller.startFullCharge()
            let override = try #require(status.activeOverride)
            texts.append(TemporaryFullChargeWording.line(for: override, status: status, lastResult: nil, timeZone: utc, locale: posix))
        }
        for text in texts {
            let lowered = text.lowercased()
            for claim in ["ready by", "ready for", "guarantee", "at the latest", "until full", "charging to 100% until", "allows charging", "will be full", "sets it back", "100% by", "never runs past", "never past"] {
                #expect(!lowered.contains(claim), "\(claim) in: \(text)")
            }
        }
    }
}

/// Telemetry on external power at a fixed charge and battery temperature.
struct KitHotTelemetry: TelemetryProvider {
    let percent: Int
    let celsius: Double
    let clock: KitTestClock

    func currentSnapshot() async throws -> BatterySnapshot {
        BatterySnapshot(timestamp: clock.now, chargePercent: percent, powerSource: .externalPower, isCharging: true, isFullyCharged: false, temperatureCelsius: celsius)
    }

    func powerSourceChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// Telemetry on external power whose charge and temperature the test sets.
actor KitMutableTelemetry: TelemetryProvider {
    private var percent: Int
    private var celsius: Double
    private let clock: KitTestClock

    init(percent: Int, celsius: Double, clock: KitTestClock) {
        self.percent = percent
        self.celsius = celsius
        self.clock = clock
    }

    func set(percent: Int, celsius: Double) {
        self.percent = percent
        self.celsius = celsius
    }

    func currentSnapshot() -> BatterySnapshot {
        BatterySnapshot(timestamp: clock.now, chargePercent: percent, powerSource: .externalPower, isCharging: true, isFullyCharged: false, temperatureCelsius: celsius)
    }

    nonisolated func powerSourceChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// An in-memory ``KeyValueStorage``.
final class KitMemoryStorage: KeyValueStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { lock.withLock { values[key] as? Data } }
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
}

/// A fake macOS Charge Limit and shortcut that sets what it is given.
final class KitFakeChargeLimit: ShortcutRunning, ChargeLimitReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: NativeChargeLimitReading = .limit(80)

    func shortcutNames() async throws -> [String] { [NativeChargeLimitBackend.defaultShortcutName] }

    func runShortcut(named name: String, input: String) async throws {
        lock.withLock {
            let percent = Int(input) ?? 80
            reading = percent >= 100 ? .noLimit : .limit(percent)
        }
    }

    func readChargeLimit() async throws -> NativeChargeLimitReading {
        lock.withLock { reading }
    }
}

/// An in-memory record of the user's own Charge Limit.
final class KitMemoryRecordStore: OwnershipRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    func load() throws -> Data? { lock.withLock { stored } }
    func save(_ data: Data) throws { lock.withLock { stored = data } }
    func remove() throws { lock.withLock { stored = nil } }
}

/// A backend that switches charging itself and reports real (experimental)
/// control, with nothing behind it.
actor KitExperimentalBackend: ChargingBackend {
    nonisolated let descriptor = BackendDescriptor(identifier: "kit-experimental", displayName: "Experimental test backend", summary: "")
    private var mode: ChargeControlMode = .normal

    func capabilities() -> ControlCapabilities {
        ControlCapabilities(availability: .experimental, supportedModes: ChargeControlMode.chargingModes)
    }

    func currentMode() -> ChargeControlMode? { mode }

    func setMode(_ newMode: ChargeControlMode) -> ControlOutcome {
        mode = newMode
        return .applied
    }
}
