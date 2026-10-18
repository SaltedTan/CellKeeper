import CellKeeperCore
import Foundation
import Testing

@Suite("Diagnostics report")
struct DiagnosticsReportTests {
    let clock = TestClock()
    let environment = DiagnosticsEnvironment(appVersion: "0.1.0 (1)", systemVersion: "Version 27.0.1 (Build 26A434)", modelIdentifier: "Mac16,1")

    @Test("The report names the app, macOS and model, and every section")
    func header() async {
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)

        let lines = report.split(separator: "\n").map(String.init)
        #expect(lines.first == "CellKeeper diagnostics")
        #expect(lines.contains("Generated: \(referenceDate.formatted(.iso8601))"))
        #expect(lines.contains("App: 0.1.0 (1)"))
        #expect(lines.contains("macOS: Version 27.0.1 (Build 26A434)"))
        #expect(lines.contains("Model: Mac16,1"))
        for title in ["Control", "Settings", "Battery", "Decision", "Activity (oldest first)"] {
            #expect(lines.contains("== \(title)"))
        }
        #expect(!lines.contains("== macOS Charge Limit"))
    }

    @Test("The report shows an armed schedule, why a due one waits, a scheduled full charge, and the schedule's outcome")
    func scheduledFullCharge() async throws {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: 70, source: .battery), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, scheduleStore: FullChargeScheduleStore(defaults: InMemoryStorage()), now: { clock.now }, uptime: { clock.uptime })
        let start = clock.now.addingTimeInterval(3600)
        let schedule = FullChargeSchedule(startsAt: start, endsAt: start.addingTimeInterval(7200))
        let armed = try await controller.setFullChargeSchedule(schedule)
        let window = "\(start.formatted(.iso8601)) to \(schedule.endsAt.formatted(.iso8601))"
        #expect(DiagnosticsReport.text(status: armed, environment: environment, generatedAt: referenceDate).contains("Scheduled full charge: \(window)\n"))

        clock.advance(by: 3600)
        let waiting = await controller.evaluate(.periodic)
        #expect(DiagnosticsReport.text(status: waiting, environment: environment, generatedAt: referenceDate).contains("Scheduled full charge: \(window); due, waiting: the Mac is on battery"))

        await telemetry.set(snapshot(percent: 70))
        let started = await controller.evaluate(.powerSourceChanged)
        let report = DiagnosticsReport.text(status: started, environment: environment, generatedAt: referenceDate)
        #expect(report.contains("Override: Scheduled full charge, started"))
        #expect(report.contains("Schedule outcome: started (window \(window))"))
        #expect(!report.contains("Scheduled full charge: "))
    }

    @Test("The report shows the backend, settings, battery, decision and activity")
    func content() async {
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)

        #expect(report.contains("Backend: Simulated (simulated)"))
        #expect(report.contains("Availability: simulated"))
        #expect(report.contains("Charge limit: 80%"))
        #expect(report.contains("Resume threshold: 75%"))
        #expect(report.contains("Charge: 78%"))
        #expect(report.contains("Power source: external power (externalPower)"))
        #expect(report.contains("State: charging to the limit (charging)"))
        #expect(report.contains("Reason: Charging from 78% toward the 80% limit."))
        // Every activity event appears, in order.
        let activity = report.components(separatedBy: "== Activity (oldest first)\n")[1]
        let messages = status.events.map(\.message)
        #expect(!messages.isEmpty)
        var searchStart = activity.startIndex
        for message in messages {
            guard let range = activity.range(of: message, range: searchStart..<activity.endIndex) else {
                Issue.record("missing or out of order: \(message)")
                return
            }
            searchStart = range.upperBound
        }
    }

    @Test("The report names states, modes, the power source and the charging status in plain words, then their identifiers; activity keeps its kinds' identifiers")
    func plainWordsWithIdentifiers() async {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: 85, charging: false, temperature: nil), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        let status = await controller.evaluate(.periodic)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)
        let lines = report.split(separator: "\n").map(String.init)

        #expect(lines.contains("Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)"))
        #expect(lines.contains("Reported mode: a charging pause (inhibitCharging)"))
        #expect(lines.contains("Power source: external power (externalPower)"))
        #expect(lines.contains("Charging status: not charging (notCharging)"))
        #expect(lines.contains("State: holding at the limit (holding)"))
        #expect(lines.contains("Wants: a charging pause (inhibitCharging)"))
        #expect(lines.contains { $0.hasSuffix(" [decision] Holding at the limit (at a periodic check): wants a charging pause, action disable charging. Charge 85% has reached the 80% limit; charging paused.") })
        #expect(lines.contains { $0.hasSuffix(" [telemetry] Battery 85%, on external power, not charging, temperature n/a.") })
    }

    @Test("Paths in error messages do not name the macOS account")
    func redactsAccountNames() async {
        struct FileError: Error, CustomStringConvertible {
            var description: String {
                #"Error Domain=NSCocoaErrorDomain Code=513 "You don’t have permission to save the file “record.json” in the folder “CellKeeper”." UserInfo={NSFilePath=/Users/alice.smith/Library/Containers/io.github.saltedtan.CellKeeper/Data/Library/Application Support/CellKeeper/record.json, NSURL=file:///Users/alice.smith/Library/Containers/x}"#
            }
        }
        let telemetry = StubTelemetry(snapshot(percent: 78), clock: clock)
        await telemetry.fail(with: FileError())
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        #expect(status.telemetryError?.contains("alice.smith") == true)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)

        #expect(!report.contains("alice"))
        #expect(report.contains("NSFilePath=/Users/<user>/Library/Containers/io.github.saltedtan.CellKeeper/Data/Library/Application Support/CellKeeper/record.json"))
        #expect(report.contains("NSURL=file:///Users/<user>/Library/Containers/x"))
    }

    @Test("Missing telemetry and an unknown model are stated, not omitted")
    func missingValues() async {
        let telemetry = StubTelemetry(snapshot(percent: 78), clock: clock)
        await telemetry.fail(with: TelemetryTestError())
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        var unknownModel = environment
        unknownModel.modelIdentifier = nil
        let report = DiagnosticsReport.text(status: status, environment: unknownModel, generatedAt: referenceDate)
        #expect(report.contains("Model: unknown"))
        #expect(report.contains("Telemetry: unavailable: test telemetry failure"))
        #expect(report.contains("State: fail-safe (failSafe)"))
    }

    @Test("With macOS's Charge Limit, the report shows what macOS reports and the recorded limit")
    func nativeLimit() async throws {
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let backend = makeNativeBackend(system: system, store: store, clock: clock)
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        var settings = ChargingSettings.default
        settings = settings.withChargeLimit(85)
        let controller = ChargeController(telemetry: telemetry, backend: backend, settings: settings, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        #expect(status.nativeLimit?.ownerLimit == 80)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)

        #expect(report.contains("== macOS Charge Limit"))
        #expect(report.contains("Availability: experimental"))
        #expect(report.contains("Style: macOS Charge Limit, steps 80, 85, 90, 95, 100"))
        #expect(report.contains("Reported mode: a macOS Charge Limit of 85% (nativeLimit(85%))"))
        #expect(report.contains("State: limit enforced by macOS (osEnforcedLimit)"))
        #expect(report.contains("Wants: a macOS Charge Limit of 85% (nativeLimit(85%))"))
        #expect(report.contains("Reported by macOS: 85%"))
        #expect(report.contains("Own limit: 80% recorded"))
        #expect(report.contains("CellKeeper's limit: 85%"))
        #expect(report.contains("Shortcut found: yes"))
        #expect(report.contains("Flags: none"))
        #expect(!report.contains("Management refused"))
    }

    @Test("A refused attempt to turn management on is in the report, with the kept change")
    func managementRefused() async throws {
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let backend = makeNativeBackend(system: system, store: store, clock: clock)
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: backend, settings: ChargingSettings.default.withChargeLimit(90), now: { clock.now }, uptime: { clock.uptime })
        await controller.evaluate(.launch)
        system.changeExternally(to: 95)
        await controller.evaluate(.periodic)
        store.removeFails = true
        let refused = try await controller.apply(settings: ChargingSettings.default.withChargeLimit(90), adoptionsSeen: 1)
        let report = DiagnosticsReport.text(status: refused, environment: environment, generatedAt: referenceDate)

        #expect(report.contains("Management refused: Manage charging stays off: CellKeeper could not remove its record"))
        #expect(report.contains("Kept outside change: 95% at"))
        #expect(report.contains("Manage charging: off"))
    }
}

@Suite("Diagnostics report: moments with their UTC offset")
struct DiagnosticsOffsetTimeTests {
    private let date = try! Date("2026-10-23T06:00:00Z", strategy: .iso8601)

    private func report(_ value: DiagnosticsValue) -> String {
        value.reportText
    }

    @Test("A moment with its offset reads as ISO 8601 with that offset, \"Z\" for none; a moment without one stays in UTC")
    func offsets() {
        #expect(report("\(time: date, utcOffset: 3600)") == "2026-10-23T07:00:00+01:00")
        #expect(report("\(time: date, utcOffset: -4 * 3600)") == "2026-10-23T02:00:00-04:00")
        #expect(report("\(time: date, utcOffset: 19_800)") == "2026-10-23T11:30:00+05:30")
        #expect(report("\(time: date, utcOffset: 0)") == "2026-10-23T06:00:00Z")
        #expect(report("\(time: date)") == "2026-10-23T06:00:00Z")
    }

    @Test("An offset no time zone can have is written in UTC")
    func impossibleOffset() {
        #expect(report("\(time: date, utcOffset: 100_000)") == "2026-10-23T06:00:00Z")
    }

    @Test("Plain text formats it like any other moment")
    func plain() {
        let value: DiagnosticsValue = "from \(time: date, utcOffset: 3600)"
        #expect(value.plainText(formattingTime: { $0 == date ? "<start>" : "<other>" }) == "from <start>")
    }
}
