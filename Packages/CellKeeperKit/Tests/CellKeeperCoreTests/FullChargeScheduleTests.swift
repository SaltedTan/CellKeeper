import CellKeeperCore
import Foundation
import Testing

private let hour: TimeInterval = 3600
private let start = referenceDate.addingTimeInterval(hour)
private let schedule = FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(12 * hour))

/// The policy input at wall time `now`, with a reading taken then.
private func inputAt(
    _ now: Date,
    percent: Int? = 70,
    source: PowerSource = .externalPower,
    settings: ChargingSettings = .default,
    present: Bool = true,
    readingAge: TimeInterval = 0
) -> PolicyInput {
    input(snapshot(percent: percent, source: source, at: now.addingTimeInterval(-readingAge), present: present), settings: settings, now: now)
}

@Suite("Scheduled full charge: window and eligibility")
struct FullChargeScheduleCheckTests {
    @Test("Before the window it waits for the start; inside it, it starts with the time left to the end")
    func window() {
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start.addingTimeInterval(-1))) == .notYet)
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start)) == .start(remaining: 12 * hour))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start.addingTimeInterval(11 * hour))) == .start(remaining: hour))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(schedule.endsAt.addingTimeInterval(-1))) == .start(remaining: 1))
    }

    @Test("At and after the end, the window has passed", arguments: [0.0, 1, 86_400])
    func passed(after: TimeInterval) {
        #expect(FullChargeSchedule.check(schedule, input: inputAt(schedule.endsAt.addingTimeInterval(after))) == .passed)
    }

    @Test("Inside the window it waits while management is off, the settings are invalid, there is no usable reading, or the Mac is on battery")
    func waits() {
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        var invalid = ChargingSettings.default
        invalid.chargeLimit = 10
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, settings: off)) == .waiting(.managementOff))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, settings: invalid)) == .waiting(.settingsInvalid))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, source: .battery)) == .waiting(.onBattery))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, source: .unknown)) == .waiting(.noUsableReading))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, percent: nil)) == .waiting(.noUsableReading))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, present: false)) == .waiting(.noUsableReading))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, readingAge: ChargingPolicy.maximumTelemetryAge + 1)) == .waiting(.noUsableReading))
        #expect(FullChargeSchedule.check(schedule, input: input(nil, now: start)) == .waiting(.noUsableReading))
        // Management comes first: nothing else matters while it is off.
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, source: .battery, settings: off)) == .waiting(.managementOff))
    }

    @Test("Unlike the manual button, it may start when the limit is already 100%, and when the battery is already full")
    func startsAtFullLimitAndWhenFull() {
        let noLimit = ChargingSettings.default.withChargeLimit(100)
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, settings: noLimit)) == .start(remaining: 12 * hour))
        #expect(FullChargeSchedule.check(schedule, input: inputAt(start, percent: 100)) == .start(remaining: 12 * hour))
    }

    @Test("A window that is not valid never starts")
    func invalidWindowNeverStarts() {
        let short = FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(60))
        #expect(FullChargeSchedule.check(short, input: inputAt(start)) == .passed)
    }
}

@Suite("Scheduled full charge: validation")
struct FullChargeScheduleValidationTests {
    @Test("The end must be 1–48 hours after the start, and both must be finite")
    func windowBounds() {
        func window(_ length: TimeInterval) -> [FullChargeScheduleIssue] {
            FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(length)).windowIssues
        }
        #expect(window(hour).isEmpty)
        #expect(window(48 * hour).isEmpty)
        #expect(window(hour - 1) == [.windowTooShort])
        #expect(window(48 * hour + 1) == [.windowTooLong])
        #expect(window(-hour) == [.windowTooShort])
        let infinite = FullChargeSchedule(startsAt: start, endsAt: Date(timeIntervalSinceReferenceDate: .infinity))
        #expect(infinite.windowIssues == [.notFinite])
    }

    @Test("When set, the start must be in the future and at most 7 days ahead")
    func leadTime() {
        func issues(startingIn lead: TimeInterval) -> [FullChargeScheduleIssue] {
            let begin = referenceDate.addingTimeInterval(lead)
            return FullChargeSchedule(startsAt: begin, endsAt: begin.addingTimeInterval(2 * hour)).issues(settingAt: referenceDate)
        }
        #expect(issues(startingIn: 60).isEmpty)
        #expect(issues(startingIn: FullChargeSchedule.maximumLeadTime).isEmpty)
        #expect(issues(startingIn: 0) == [.startNotInFuture])
        #expect(issues(startingIn: -hour) == [.startNotInFuture])
        #expect(issues(startingIn: FullChargeSchedule.maximumLeadTime + 1) == [.startTooFarAhead])
    }
}

@Suite("Scheduled full charge: the override it starts")
struct ScheduledOverrideTests {
    @Test("Its monotonic deadline is the time left to the end, with no one-hour minimum and at most 48 hours")
    func deadline() throws {
        let late = try #require(ChargeOverride.scheduledFullCharge(at: referenceDate, uptime: 5_000, remaining: 600))
        #expect(late.kind == .fullCharge)
        #expect(late.source == .schedule)
        #expect(late.expiresAtUptime == 5_600)
        #expect(late.expiresAt == referenceDate.addingTimeInterval(600))
        #expect(late.startedAt == referenceDate)
        let long = try #require(ChargeOverride.scheduledFullCharge(at: referenceDate, uptime: 5_000, remaining: 100 * hour))
        #expect(long.expiresAtUptime == 5_000 + ChargeOverride.maximumDuration)
    }

    @Test("It is not made from a time left that is not positive and finite", arguments: [0.0, -1, .nan, .infinity])
    func noOverride(remaining: TimeInterval) {
        #expect(ChargeOverride.scheduledFullCharge(at: referenceDate, uptime: 5_000, remaining: remaining) == nil)
    }

    @Test("A manual full charge keeps its one-hour minimum and is the user's")
    func manualUnchanged() {
        let manual = ChargeOverride.fullCharge(at: referenceDate, uptime: 0, duration: 60)
        #expect(manual.source == .user)
        #expect(manual.expiresAtUptime == ChargeOverride.minimumDuration)
    }

    @Test("Its deadline estimate follows the monotonic deadline, whatever the wall clock did")
    func deadlineEstimate() {
        let manual = ChargeOverride.fullCharge(at: referenceDate, uptime: 1_000)
        let shifted = referenceDate.addingTimeInterval(-10 * hour)
        #expect(manual.deadlineEstimate(now: shifted, uptime: 2_000) == shifted.addingTimeInterval(12 * hour - 1_000))
        #expect(manual.isLive(atUptime: 1_000 + 12 * hour - 1))
        #expect(!manual.isLive(atUptime: 1_000 + 12 * hour))
    }
}

@Suite("Override expiry clock")
struct OverrideExpiryClockTests {
    let manual = ChargeOverride.fullCharge(at: referenceDate, uptime: 0, duration: 3600)

    @Test("By default an override's expiry is judged on the policy's uptime")
    func defaultsToUptime() {
        let plain = input(snapshot(percent: 70), override: manual, uptime: 3600)
        #expect(plain.overrideUptime == plain.uptime)
        #expect(ChargingPolicy.evaluate(plain).overrideEnded == .expired)
        #expect(ChargingPolicy.evaluate(input(snapshot(percent: 70), override: manual, uptime: 3599)).overrideEnded == nil)
    }

    @Test("An override's expiry is judged on the override clock, read after the backend's reads, not on the earlier uptime")
    func judgedOnOverrideClock() {
        var straddling = input(snapshot(percent: 70), override: manual, uptime: 3570)
        straddling.overrideUptime = 3630
        #expect(ChargingPolicy.evaluate(straddling).overrideEnded == .expired)
        var discharge = input(snapshot(percent: 90), override: .dischargeToLimit(target: 80, at: referenceDate, uptime: 0, duration: 3600), uptime: 3570)
        discharge.overrideUptime = 3630
        let ended = ChargingPolicy.evaluate(discharge)
        #expect(ended.overrideEnded == .expired)
        #expect(ended.desiredMode != .forceDischarge)
    }

    @Test("The rate limit of restricting requests keeps the earlier uptime")
    func rateLimitKeepsUptime() {
        let recent: [TimeInterval] = [10_000 - 30]
        var holding = input(snapshot(percent: 85), memory: memoryAfterReading(85), recentRestrictingRequests: recent)
        holding.overrideUptime = 10_100
        let decision = ChargingPolicy.evaluate(holding)
        #expect(decision.desiredMode == .inhibitCharging)
        guard case .refuse(.rateLimited) = decision.action else {
            Issue.record("expected a rate-limited refusal, got \(decision.action)")
            return
        }
    }

    @Test("The minimum temperature pause keeps the earlier uptime")
    func temperaturePauseKeepsUptime() {
        let tripped = PolicyMemory(temperatureTripped: true, temperatureTrippedAtUptime: 10_000 - 200)
        var cooled = input(snapshot(percent: 70, temperature: 30), memory: tripped)
        cooled.overrideUptime = 10_200
        let decision = ChargingPolicy.evaluate(cooled)
        #expect(decision.state == .temperaturePause)
        #expect(decision.memory.temperatureTripped)
    }
}

@Suite("Scheduled full charge: the policy ignores where an override came from")
struct ScheduledOverridePolicyParityTests {
    static let cases: [(String, PolicyInput)] = {
        let user = ChargeOverride.fullCharge(at: referenceDate, uptime: 9_000)
        let hot = snapshot(percent: 70, temperature: 45)
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        return [
            ("charging", input(snapshot(percent: 70), override: user)),
            ("already full", input(snapshot(percent: 100, fullyCharged: true), override: user)),
            ("on battery", input(snapshot(percent: 70, source: .battery), override: user)),
            ("temperature pause", input(hot, override: user)),
            ("safety floor", input(snapshot(percent: 8), override: user)),
            ("no telemetry", input(nil, override: user)),
            ("management off", input(snapshot(percent: 70), settings: off, override: user)),
            ("expired", input(snapshot(percent: 70), override: user, uptime: 9_000 + 13 * 3600)),
            ("macOS's limit on", input(snapshot(percent: 70), override: user, capabilities: helperCapabilities(macOSLimit: 80))),
            ("faulted, holding", input(snapshot(percent: 70), override: user, currentMode: .inhibitCharging, faulted: true)),
            ("native", input(snapshot(percent: 70), override: user, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 80))),
            ("native, faulted, normal", input(snapshot(percent: 70), override: user, capabilities: nativeCapabilities, currentMode: .normal, faulted: true)),
            ("native, no telemetry", input(nil, override: user, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 80))),
        ]
    }()

    @Test("Every decision is the same for a full charge the user started and one a schedule started", arguments: cases.map(\.0))
    func parity(name: String) throws {
        let userInput = try #require(Self.cases.first { $0.0 == name }?.1)
        var scheduledInput = userInput
        scheduledInput.activeOverride?.source = .schedule
        #expect(ChargingPolicy.evaluate(userInput) == ChargingPolicy.evaluate(scheduledInput))
    }
}

@Suite("Scheduled full charge: no exemption on macOS's Charge Limit")
struct ScheduledNativeActionTests {
    let scheduled = ChargeOverride.scheduledFullCharge(at: referenceDate, uptime: 10_000, remaining: 3 * 3600)

    @Test("Its 100% limit is a restricting change, so it waits for the rate limit")
    func rateLimited() {
        // A restricting change 30 s before this evaluation's uptime.
        let recent: [TimeInterval] = [9_970]
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 70), override: scheduled, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 80), recentRestrictingRequests: recent))
        #expect(decision.state == .fullChargeOverride)
        #expect(decision.desiredMode == .nativeLimit(percent: 100))
        guard case .refuse(.rateLimited) = decision.action else {
            Issue.record("expected a rate-limited refusal, got \(decision.action)")
            return
        }
    }

    @Test("With a faulted backend: refused while the user's own limit is in effect, and the user's limit requested while anything else is or may be")
    func faulted() {
        let normal = ChargingPolicy.evaluate(input(snapshot(percent: 70), override: scheduled, capabilities: nativeCapabilities, currentMode: .normal, faulted: true))
        #expect(normal.action == .refuse(.backendFaulted))
        let held = ChargingPolicy.evaluate(input(snapshot(percent: 70), override: scheduled, capabilities: nativeCapabilities, currentMode: .nativeLimit(percent: 95), faulted: true))
        #expect(held.action == .enableCharging)
        let unknown = ChargingPolicy.evaluate(input(snapshot(percent: 70), override: scheduled, capabilities: nativeCapabilities, currentMode: nil, faulted: true))
        #expect(unknown.action == .enableCharging)
    }

    @Test("While macOS's own limit is on, a backend that switches charging itself is asked for nothing restricting")
    func macOSLimitOn() {
        let decision = ChargingPolicy.evaluate(input(snapshot(percent: 70), override: scheduled, capabilities: helperCapabilities(macOSLimit: 80)))
        #expect(decision.state == .deferringToMacOS)
        #expect(decision.desiredMode == .normal)
        #expect(decision.overrideEnded == nil)
    }
}

@Suite("Scheduled full charge: store")
struct FullChargeScheduleStoreTests {
    let storage = InMemoryStorage()

    private var store: FullChargeScheduleStore { FullChargeScheduleStore(defaults: storage) }

    private func storeJSON(_ json: String, key: String = FullChargeScheduleStore.key) {
        storage.set(Data(json.utf8), forKey: key)
    }

    @Test("A schedule is saved under its own key and read back")
    func roundTrip() throws {
        #expect(store.loadSchedule() == .none)
        try store.saveSchedule(schedule)
        #expect(FullChargeScheduleStore.key == "fullChargeSchedule.v1")
        #expect(storage.data(forKey: FullChargeScheduleStore.key) != nil)
        #expect(store.loadSchedule() == .schedule(schedule))
        store.removeSchedule()
        #expect(store.loadSchedule() == .none)
        #expect(storage.data(forKey: FullChargeScheduleStore.key) == nil)
    }

    @Test("A schedule whose window is not valid is not saved")
    func invalidNotSaved() {
        let short = FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(60))
        #expect(throws: FullChargeScheduleError(issues: [.windowTooShort])) { try store.saveSchedule(short) }
        #expect(storage.data(forKey: FullChargeScheduleStore.key) == nil)
    }

    @Test("Both endpoints are required; unknown keys are ignored", arguments: [
        #"{"startsAt":1800003600}"#, #"{"endsAt":1800046800}"#, #"{}"#, #"{"startsAt":"soon","endsAt":1800046800}"#, "not json",
    ])
    func partialRecords(json: String) {
        storeJSON(json)
        guard case .unusable = store.loadSchedule() else {
            Issue.record("expected an unusable record")
            return
        }
    }

    @Test("A value under the key that is not data is unusable, not absent")
    func notData() {
        let values: [any Sendable] = ["not a record", 42, true, ["startsAt": 1_800_003_600.0]]
        for value in values {
            storage.set(value, forKey: FullChargeScheduleStore.key)
            #expect(store.loadSchedule() == .unusable(reason: "it is not a schedule record"))
        }
        storage.set(nil, forKey: FullChargeScheduleStore.key)
        #expect(store.loadSchedule() == .none)
    }

    @Test("Unknown keys are ignored")
    func unknownKeys() {
        storeJSON(#"{"startsAt":1800003600,"endsAt":1800046800,"note":"from a later version"}"#)
        #expect(store.loadSchedule() == .schedule(FullChargeSchedule(startsAt: Date(timeIntervalSince1970: 1_800_003_600), endsAt: Date(timeIntervalSince1970: 1_800_046_800))))
    }

    @Test("A stored window that is not 1–48 hours is unusable, and says why")
    func invalidWindow() {
        storeJSON(#"{"startsAt":1800003600,"endsAt":1800003610}"#)
        #expect(store.loadSchedule() == .unusable(reason: FullChargeScheduleIssue.windowTooShort.description))
    }

    @Test("A later format, under a new key, is never read or removed")
    func laterFormat() {
        let later = Data(#"{"version":2,"start":"Friday"}"#.utf8)
        storage.set(later, forKey: "fullChargeSchedule.v2")
        #expect(store.loadSchedule() == .none)
        store.removeSchedule()
        #expect(storage.data(forKey: "fullChargeSchedule.v2") == later)
    }

    @Test("An unreadable schedule does not affect the stored charging settings")
    func settingsIndependent() throws {
        let settingsStore = SettingsStore(defaults: storage)
        let settings = ChargingSettings.default.withChargeLimit(90)
        try settingsStore.save(settings)
        storeJSON("not json")
        let loaded = settingsStore.loadChargingSettings()
        #expect(loaded.settings == settings)
        #expect(loaded.recoveryReason == nil)
    }
}
